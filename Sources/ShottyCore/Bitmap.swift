import AppKit
import CoreGraphics

/// Small helpers for drawing into offscreen bitmaps in *document* orientation (y-down, origin at
/// the top-left), which is how screenshots and the editor think about pixels.
public enum Bitmap {
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Captures may come in Display P3; keep that colour space when we can draw into it.
    public static func drawableSpace(_ cs: CGColorSpace?) -> CGColorSpace {
        guard let cs, cs.model == .rgb, cs.supportsOutput else { return sRGB }
        return cs
    }

    public static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace? = nil) -> CGContext? {
        CGContext(
            data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
            space: drawableSpace(colorSpace), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Runs `body` with a y-down context (and a matching flipped NSGraphicsContext for text),
    /// then returns the pixels.
    public static func render(width: Int, height: Int, colorSpace: CGColorSpace? = nil,
                              _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = makeContext(width: width, height: height, colorSpace: colorSpace) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// CGContext.draw assumes y-up; in a y-down context it would paint the image upside down.
    /// Flip locally around the target rect so the image lands the right way up.
    public static func drawImage(_ img: CGImage, in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    public static func solid(width: Int, height: Int, color: RGBA) -> CGImage? {
        render(width: width, height: height) { ctx in
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}

/// Reads 8-bit sRGB pixels; row 0 is the top of the image, matching document coordinates.
public struct PixelReader {
    public let width: Int, height: Int
    private let data: [UInt8]

    public init?(_ image: CGImage) {
        // Locals, because a closure can't read self's properties before `data` is set.
        let width = image.width, height = image.height
        self.width = width; self.height = height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: Bitmap.sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Drawn without a flip, a bitmap context's first memory row is the image's top row.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        data = buf
    }

    public struct Pixel: Equatable, Sendable {
        public let r: UInt8, g: UInt8, b: UInt8, a: UInt8
        public func differs(from o: Pixel, by tol: Int) -> Bool {
            abs(Int(r) - Int(o.r)) > tol || abs(Int(g) - Int(o.g)) > tol
                || abs(Int(b) - Int(o.b)) > tol || abs(Int(a) - Int(o.a)) > tol
        }
    }

    public subscript(x: Int, y: Int) -> Pixel {
        let i = (y * width + x) * 4
        return Pixel(r: data[i], g: data[i + 1], b: data[i + 2], a: data[i + 3])
    }
}
