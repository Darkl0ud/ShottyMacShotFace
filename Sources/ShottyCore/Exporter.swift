import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg, tiff, bmp, gif, heic

    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    public var displayName: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }

    public var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .gif: return .gif
        case .heic: return .heic
        }
    }

    /// Formats that can store partial transparency. The others get a white background instead
    /// of black. GIF isn't one: it has 1-bit transparency, and ImageIO turns every partly
    /// transparent pixel (soft shadows) into opaque black; see `ImageExporter.forGIF`.
    public var supportsAlpha: Bool { self == .png || self == .tiff || self == .heic }
    public var usesQuality: Bool { self == .jpeg || self == .heic }

    public static func from(extension ext: String) -> ImageFormat? {
        let e = ext.lowercased()
        if e == "jpeg" || e == "jpg" { return .jpeg }
        if e == "tif" { return .tiff }
        return ImageFormat(rawValue: e)
    }
}

public enum ExportError: Error, LocalizedError {
    case encodeFailed(ImageFormat)
    public var errorDescription: String? {
        switch self {
        case .encodeFailed(let f): return "Couldn't encode the image as \(f.displayName)."
        }
    }
}

public enum ImageExporter {
    /// `pixelScale` is stored as the file's resolution (72 dpi per point, so 144 for Retina). That's
    /// how loadForEditor, Preview and other apps know a 2x capture is 2x: without it, the app's own
    /// Retina saves reopened, and were inserted, at twice their on-screen size.
    public static func data(for image: CGImage, format: ImageFormat, quality: Double = 0.9,
                            pixelScale: CGFloat = 1) throws -> Data {
        let img: CGImage
        if format.supportsAlpha { img = image }
        else if format == .gif { img = forGIF(image) ?? image }
        else { img = onWhite(image) ?? image }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, format.utType.identifier as CFString, 1, nil)
        else { throw ExportError.encodeFailed(format) }
        var props: [CFString: Any] = [:]
        if format.usesQuality { props[kCGImageDestinationLossyCompressionQuality] = max(0.05, min(1, quality)) }
        let dpi = 72 * max(1, pixelScale)
        props[kCGImagePropertyDPIWidth] = dpi
        props[kCGImagePropertyDPIHeight] = dpi
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodeFailed(format) }
        return out as Data
    }

    public static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double = 0.9,
                             pixelScale: CGFloat = 1) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(for: image, format: format, quality: quality, pixelScale: pixelScale).write(to: url, options: .atomic)
    }

    public static func onWhite(_ image: CGImage) -> CGImage? {
        Bitmap.render(width: image.width, height: image.height, colorSpace: image.colorSpace) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            Bitmap.drawImage(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), ctx: ctx)
        }
    }

    /// GIF keeps only on/off transparency: pixels under half opacity become fully transparent
    /// (so a shadow margin stays see-through), the rest are composited onto white and made opaque.
    public static func forGIF(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = Bitmap.makeContext(width: w, height: h), let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let row = ctx.bytesPerRow
        let px = data.bindMemory(to: UInt8.self, capacity: row * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * row + x * 4
                let a = Int(px[i + 3])
                if a == 255 { continue }
                if a < 128 {
                    px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
                } else {
                    // Premultiplied colour over white: c + (1 - a) * 255.
                    for k in 0..<3 { px[i + k] = UInt8(min(255, Int(px[i + k]) + 255 - a)) }
                    px[i + 3] = 255
                }
            }
        }
        return ctx.makeImage()
    }

    /// The picture as it should be seen: phone photos store pixels sideways plus an EXIF
    /// orientation tag, which CGImageSourceCreateImageAtIndex ignores.
    public static func load(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return orientedImage(src)
    }

    /// For opening a file in the editor: the upright picture plus its pixel scale.
    /// 144 dpi files are Retina screenshots, so they're treated as 2x and annotations get sized right.
    public static func loadForEditor(from url: URL) -> (image: CGImage, pixelScale: CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = orientedImage(src) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return (img, pixelScale(dpi: CGFloat(dpi)))
    }

    /// One rule for every image source (files and the clipboard), so a picture means the same
    /// size wherever it comes from. 144 dpi is Retina; 140 leaves room for rounding in the file.
    public static func pixelScale(dpi: CGFloat) -> CGFloat {
        dpi >= 140 ? 2 : 1
    }

    static func orientedImage(_ src: CGImageSource) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard orientation != 1 else { return CGImageSourceCreateImageAtIndex(src, 0, nil) }
        // A full-size "thumbnail" is ImageIO's way of applying the orientation transform.
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
