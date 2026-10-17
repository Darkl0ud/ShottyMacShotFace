import CoreGraphics
import CoreImage

public struct TornSides: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let top = TornSides(rawValue: 1)
    public static let right = TornSides(rawValue: 2)
    public static let bottom = TornSides(rawValue: 4)
    public static let left = TornSides(rawValue: 8)
    public static let all: TornSides = [.top, .right, .bottom, .left]
}

/// Whole-picture effects (Greenshot's "Effects" menu). Each takes a flat image and returns a new one.
public enum Effects {
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    public static func dropShadow(_ img: CGImage, pixelScale s: CGFloat, offset: CGFloat = 4,
                                  blur: CGFloat = 8, opacity: CGFloat = 0.6) -> CGImage? {
        let o = offset * s, b = blur * s
        let m = Int(ceil(b * 1.5 + o))
        let w = img.width, h = img.height
        return Bitmap.render(width: w + 2 * m, height: h + 2 * m, colorSpace: img.colorSpace) { ctx in
            // Shadow offsets are in device space (y-up), so -o moves the shadow down.
            ctx.setShadow(offset: CGSize(width: o, height: -o), blur: b, color: CGColor(gray: 0, alpha: opacity))
            Bitmap.drawImage(img, in: CGRect(x: m, y: m, width: w, height: h), ctx: ctx)
        }
    }

    public static func border(_ img: CGImage, width bw: Int, color: RGBA) -> CGImage? {
        let w = img.width + 2 * bw, h = img.height + 2 * bw
        return Bitmap.render(width: w, height: h, colorSpace: img.colorSpace) { ctx in
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            Bitmap.drawImage(img, in: CGRect(x: bw, y: bw, width: img.width, height: img.height), ctx: ctx)
        }
    }

    /// Small deterministic RNG so torn edges look the same in tests (and on re-render).
    struct LCG {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
    }

    /// The jagged outline used by `tornEdges`; exposed for tests.
    public static func tornPath(width w: CGFloat, height h: CGFloat, tooth: CGFloat, range: CGFloat,
                                sides: TornSides, seed: UInt64 = 42) -> CGPath {
        var rng = LCG(state: seed)
        let p = CGMutablePath()
        func step() -> CGFloat { range * (0.5 + rng.next() * 0.5) }
        func depth() -> CGFloat { tooth * rng.next() }

        p.move(to: CGPoint(x: 0, y: sides.contains(.top) ? depth() : 0))
        // Top edge, left → right
        var x: CGFloat = 0
        while x < w {
            x = min(w, x + step())
            p.addLine(to: CGPoint(x: x, y: sides.contains(.top) ? depth() : 0))
        }
        // Right edge, top → bottom
        var y: CGFloat = 0
        while y < h {
            y = min(h, y + step())
            p.addLine(to: CGPoint(x: sides.contains(.right) ? w - depth() : w, y: y))
        }
        // Bottom edge, right → left
        x = w
        while x > 0 {
            x = max(0, x - step())
            p.addLine(to: CGPoint(x: x, y: sides.contains(.bottom) ? h - depth() : h))
        }
        // Left edge, bottom → top
        y = h
        while y > 0 {
            y = max(0, y - step())
            p.addLine(to: CGPoint(x: sides.contains(.left) ? depth() : 0, y: y))
        }
        p.closeSubpath()
        return p
    }

    public static func tornEdges(_ img: CGImage, pixelScale s: CGFloat, toothHeight: CGFloat = 12,
                                 range: CGFloat = 20, sides: TornSides = .all, shadow: Bool = true) -> CGImage? {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let path = tornPath(width: w, height: h, tooth: toothHeight * s, range: range * s, sides: sides)
        guard let torn = Bitmap.render(width: img.width, height: img.height, colorSpace: img.colorSpace, { ctx in
            ctx.addPath(path)
            ctx.clip()
            Bitmap.drawImage(img, in: CGRect(x: 0, y: 0, width: w, height: h), ctx: ctx)
        }) else { return nil }
        return shadow ? dropShadow(torn, pixelScale: s) : torn
    }

    public static func grayscale(_ img: CGImage) -> CGImage? { Renderer.grayscale(img, ci: ci) }
    public static func invert(_ img: CGImage) -> CGImage? { Renderer.invert(img, ci: ci) }

    public static func rotate(_ img: CGImage, clockwise: Bool) -> CGImage? {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        return Bitmap.render(width: img.height, height: img.width, colorSpace: img.colorSpace) { ctx in
            // y-down space: +90° turns clockwise on screen.
            if clockwise {
                ctx.translateBy(x: h, y: 0); ctx.rotate(by: .pi / 2)
            } else {
                ctx.translateBy(x: 0, y: w); ctx.rotate(by: -.pi / 2)
            }
            Bitmap.drawImage(img, in: CGRect(x: 0, y: 0, width: w, height: h), ctx: ctx)
        }
    }

    public static func resize(_ img: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        return Bitmap.render(width: width, height: height, colorSpace: img.colorSpace) { ctx in
            ctx.interpolationQuality = .high
            Bitmap.drawImage(img, in: CGRect(x: 0, y: 0, width: width, height: height), ctx: ctx)
        }
    }

    /// Cuts away fully transparent edges (alpha ≤ threshold). Nil if nothing to cut or all transparent.
    public static func trimTransparent(_ img: CGImage, threshold: UInt8 = 0) -> CGImage? {
        guard let px = PixelReader(img) else { return nil }
        func rowUsed(_ y: Int) -> Bool { (0..<px.width).contains { px[$0, y].a > threshold } }
        func colUsed(_ x: Int, _ y0: Int, _ y1: Int) -> Bool { (y0...y1).contains { px[x, $0].a > threshold } }
        guard let top = (0..<px.height).first(where: rowUsed) else { return nil }
        let bottom = (0..<px.height).reversed().first(where: rowUsed)!
        let left = (0..<px.width).first { colUsed($0, top, bottom) }!
        let right = (0..<px.width).reversed().first { colUsed($0, top, bottom) }!
        let r = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        if r.size == CGSize(width: px.width, height: px.height) { return nil }
        return img.cropping(to: r)
    }

    /// Greenshot's auto-crop: trims borders that match the top-left pixel's colour.
    /// Returns nil when there's nothing to trim (or the picture is one solid colour).
    public static func autoCropRect(_ img: CGImage, tolerance: Int = 8) -> CGRect? {
        guard let px = PixelReader(img) else { return nil }
        let ref = px[0, 0]
        func rowDiffers(_ y: Int) -> Bool { (0..<px.width).contains { px[$0, y].differs(from: ref, by: tolerance) } }
        func colDiffers(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
            (y0...y1).contains { px[x, $0].differs(from: ref, by: tolerance) }
        }
        guard let top = (0..<px.height).first(where: rowDiffers) else { return nil }
        let bottom = (0..<px.height).reversed().first(where: rowDiffers)!
        let left = (0..<px.width).first { colDiffers($0, top, bottom) }!
        let right = (0..<px.width).reversed().first { colDiffers($0, top, bottom) }!
        let r = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        return r.size == CGSize(width: px.width, height: px.height) ? nil : r
    }
}
