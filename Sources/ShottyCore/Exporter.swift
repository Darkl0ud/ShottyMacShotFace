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

    /// Formats that can't store transparency get a white background instead of black.
    public var supportsAlpha: Bool { self == .png || self == .tiff || self == .gif || self == .heic }
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
    public static func data(for image: CGImage, format: ImageFormat, quality: Double = 0.9) throws -> Data {
        let img = format.supportsAlpha ? image : (onWhite(image) ?? image)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, format.utType.identifier as CFString, 1, nil)
        else { throw ExportError.encodeFailed(format) }
        var props: [CFString: Any] = [:]
        if format.usesQuality { props[kCGImageDestinationLossyCompressionQuality] = max(0.05, min(1, quality)) }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodeFailed(format) }
        return out as Data
    }

    public static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double = 0.9) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(for: image, format: format, quality: quality).write(to: url, options: .atomic)
    }

    public static func onWhite(_ image: CGImage) -> CGImage? {
        Bitmap.render(width: image.width, height: image.height, colorSpace: image.colorSpace) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            Bitmap.drawImage(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), ctx: ctx)
        }
    }

    public static func load(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
