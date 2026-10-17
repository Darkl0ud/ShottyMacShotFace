import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Draws a document (picture + annotations) into a y-down CGContext.
/// The same code paints the editor view and the exported file, so what you see is what you save.
public final class Renderer {
    /// Pixels per point of the document; style sizes are in points.
    public var pixelScale: CGFloat = 1
    public var counterStart: Int = 1
    private let ci = CIContext(options: [.cacheIntermediates: false])

    public init(pixelScale: CGFloat = 1) { self.pixelScale = pixelScale }

    /// The whole document as one image. `excluding` leaves elements out (the one being dragged,
    /// or the text box being typed into) while still counting them for step-counter numbering.
    public func flatten(_ s: DocState, excluding: Set<UUID> = []) -> CGImage? {
        Bitmap.render(width: s.image.width, height: s.image.height, colorSpace: s.image.colorSpace) { ctx in
            Bitmap.drawImage(s.image, in: s.canvasRect, ctx: ctx)
            var counter = counterStart
            for e in s.elements {
                var number = 0
                if e.kind == .counter { number = counter; counter += 1 }
                if excluding.contains(e.id) { continue }
                draw(e, number: number, in: ctx, canvas: s.canvasRect, deviceScale: 1)
            }
        }
    }

    /// `deviceScale` = device pixels per document pixel. Only shadows need it, because Quartz
    /// applies shadow offsets in device space, ignoring the zoom transform.
    /// Filters (highlight/obfuscate) need to read back pixels, so they only work in bitmap contexts.
    public func draw(_ e: Element, number: Int, in ctx: CGContext, canvas: CGRect, deviceScale: CGFloat) {
        let s = pixelScale
        let st = e.style
        let lw = st.lineWidth * s
        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch e.kind {
        case .rectangle:
            withShadow(e, ctx, deviceScale) {
                if !st.fill.isClear { ctx.setFillColor(st.fill.cgColor); ctx.fill(e.frame) }
                strokeShape(ctx, lw: lw, color: st.stroke, frame: e.frame) { ctx.addRect($0) }
            }

        case .ellipse:
            withShadow(e, ctx, deviceScale) {
                if !st.fill.isClear { ctx.setFillColor(st.fill.cgColor); ctx.fillEllipse(in: e.frame) }
                strokeShape(ctx, lw: lw, color: st.stroke, frame: e.frame) { ctx.addEllipse(in: $0) }
            }

        case .line, .arrow:
            guard e.points.count == 2 else { return }
            withShadow(e, ctx, deviceScale) { drawLine(e, ctx: ctx, lw: max(lw, 0.5)) }

        case .freehand:
            guard let first = e.points.first else { return }
            withShadow(e, ctx, deviceScale) {
                let path = CGMutablePath()
                path.move(to: first)
                if e.points.count == 1 {
                    path.addLine(to: first)
                } else {
                    // Curving through the midpoints smooths out the jitter of raw mouse samples.
                    for i in 1..<e.points.count {
                        let p0 = e.points[i - 1], p1 = e.points[i]
                        path.addQuadCurve(to: (p0 + p1) * 0.5, control: p0)
                    }
                    path.addLine(to: e.points[e.points.count - 1])
                }
                ctx.addPath(path)
                ctx.setStrokeColor(st.stroke.cgColor)
                ctx.setLineWidth(max(lw, 0.5))
                ctx.setLineCap(.round); ctx.setLineJoin(.round)
                ctx.strokePath()
            }

        case .text:
            withShadow(e, ctx, deviceScale) {
                if !st.fill.isClear { ctx.setFillColor(st.fill.cgColor); ctx.fill(e.frame) }
                strokeShape(ctx, lw: lw, color: st.stroke, frame: e.frame) { ctx.addRect($0) }
                drawText(e.text, in: e.frame.insetBy(dx: 4 * s, dy: 2 * s), style: st, ctx: ctx, center: false)
            }

        case .speechBubble:
            let path = Self.bubblePath(frame: e.frame, tip: e.points.first, pixelScale: s)
            withShadow(e, ctx, deviceScale) {
                if !st.fill.isClear { ctx.addPath(path); ctx.setFillColor(st.fill.cgColor); ctx.fillPath() }
                if lw > 0, !st.stroke.isClear {
                    ctx.addPath(path); ctx.setStrokeColor(st.stroke.cgColor)
                    ctx.setLineWidth(lw); ctx.setLineJoin(.round); ctx.strokePath()
                }
            }
            drawText(e.text, in: e.frame.insetBy(dx: 8 * s, dy: 6 * s), style: st, ctx: ctx, center: true)

        case .counter:
            withShadow(e, ctx, deviceScale) {
                ctx.setFillColor(st.fill.cgColor)
                ctx.fillEllipse(in: e.frame)
                strokeShape(ctx, lw: lw, color: st.stroke, frame: e.frame) { ctx.addEllipse(in: $0) }
            }
            drawCounterNumber(number, in: e.frame, color: st.stroke, ctx: ctx)

        case .highlight:
            drawHighlight(e, ctx: ctx, canvas: canvas)

        case .obfuscate:
            let r = e.frame.integral.intersection(canvas)
            guard !r.isNull, r.width >= 1, r.height >= 1, let snap = ctx.makeImage() else { return }
            if st.obfuscateMode == .blur {
                drawSoftBlur(in: r, radius: max(1, st.blurRadius * s), snapshot: snap, ctx: ctx, canvas: canvas)
            } else if let piece = snap.cropping(to: r),
                      let out = Self.pixelate(piece, cellSize: max(2, st.pixelSize * s), ci: ci) {
                // Pixelation keeps a hard edge on purpose: the blocks are the look.
                // .copy replaces the pixels; normal blending would let the original show through
                // wherever the capture is semi-transparent (window shadows, torn edges).
                ctx.setBlendMode(.copy)
                Bitmap.drawImage(out, in: r, ctx: ctx)
            }

        case .image:
            guard let img = e.image else { return }
            withShadow(e, ctx, deviceScale) {
                Bitmap.drawImage(img, in: e.frame, ctx: ctx)
                strokeShape(ctx, lw: lw, color: st.stroke, frame: e.frame) { ctx.addRect($0) }
            }
        }
    }

    // MARK: Pieces

    private func withShadow(_ e: Element, _ ctx: CGContext, _ deviceScale: CGFloat, _ body: () -> Void) {
        guard e.style.shadow else { body(); return }
        let k = pixelScale * deviceScale
        ctx.setShadow(offset: CGSize(width: 2 * k, height: -2 * k), blur: 3 * k,
                      color: CGColor(gray: 0, alpha: 0.5))
        // A transparency layer gives one shadow for fill + outline together, not two overlapping.
        // Sized to the element: without a rect Quartz allocates a layer the size of the whole
        // canvas, which made a 5K capture with 30 shadowed shapes take half a second to draw.
        let lw = e.style.lineWidth * pixelScale
        let margin = max(lw * 4, 14 * pixelScale) + 2
        ctx.beginTransparencyLayer(in: e.bounds.insetBy(dx: -margin, dy: -margin), auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    /// Strokes inside the frame so a shape's outer edge is exactly where the user dragged.
    private func strokeShape(_ ctx: CGContext, lw: CGFloat, color: RGBA, frame: CGRect,
                             add: (CGRect) -> Void) {
        guard lw > 0, !color.isClear else { return }
        let inner = frame.insetBy(dx: lw / 2, dy: lw / 2)
        guard inner.width > 0, inner.height > 0 else {
            ctx.setFillColor(color.cgColor); ctx.fill(frame); return
        }
        add(inner)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lw)
        ctx.strokePath()
    }

    private func drawLine(_ e: Element, ctx: CGContext, lw: CGFloat) {
        var a = e.points[0], b = e.points[1]
        let len = a.distance(to: b)
        let heads: ArrowHeads = (e.kind == .arrow && len >= 1) ? e.style.arrowHeads : .none
        let headLen = max(lw * 3.5, 10 * pixelScale), headWidth = headLen * 0.85
        let dir = len > 0 ? (b - a) * (1 / len) : CGPoint(x: 1, y: 0)
        let hasEnd = heads == .end || heads == .both, hasStart = heads == .start || heads == .both
        // Stop the shaft inside the head so its round cap can't poke past the tip.
        if hasEnd { b = b - dir * min(headLen * 0.8, len) }
        if hasStart { a = a + dir * min(headLen * 0.8, len) }

        ctx.setStrokeColor(e.style.stroke.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.move(to: a); ctx.addLine(to: b)
        ctx.strokePath()

        ctx.setFillColor(e.style.stroke.cgColor)
        func head(tip: CGPoint, d: CGPoint) {
            let base = tip - d * headLen
            let perp = CGPoint(x: -d.y, y: d.x) * (headWidth / 2)
            ctx.move(to: tip); ctx.addLine(to: base + perp); ctx.addLine(to: base - perp)
            ctx.closePath(); ctx.fillPath()
        }
        if hasEnd { head(tip: e.points[1], d: dir) }
        if hasStart { head(tip: e.points[0], d: dir * -1) }
    }

    public static func font(for st: ElementStyle, pixelScale: CGFloat, sizeOverride: CGFloat? = nil) -> NSFont {
        let size = sizeOverride ?? st.fontSize * pixelScale
        var f = NSFont(name: st.fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        if st.bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        if st.italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    private func drawText(_ text: String, in rect: CGRect, style st: ElementStyle, ctx: CGContext, center: Bool) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = center ? .center : .left
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font(for: st, pixelScale: pixelScale),
            .foregroundColor: NSColor(cgColor: st.stroke.cgColor) ?? .black,
            .paragraphStyle: para,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        var target = rect
        if center {
            let h = str.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            if h < rect.height { target = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h + 1) }
        }
        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: -2, dy: -2))
        // AppKit text drawing goes through NSGraphicsContext, so point it at this CGContext
        // (which is y-down, hence flipped: true).
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        str.draw(with: target, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private func drawCounterNumber(_ n: Int, in r: CGRect, color: RGBA, ctx: CGContext) {
        let font = NSFont.boldSystemFont(ofSize: r.height * (n >= 100 ? 0.4 : n >= 10 ? 0.5 : 0.6))
        let str = NSAttributedString(string: "\(n)", attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: color.cgColor) ?? .white,
        ])
        let size = str.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        str.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHighlight(_ e: Element, ctx: CGContext, canvas: CGRect) {
        let r = e.frame.intersection(canvas)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return }
        switch e.style.highlightMode {
        case .text:
            // Multiply darkens like a real marker pen: black text stays black.
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(e.style.fill.cgColor)
            ctx.fill(r)
        case .area:
            let p = CGMutablePath()
            p.addRect(canvas); p.addRect(r)
            ctx.addPath(p)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
            ctx.fillPath(using: .evenOdd)
        case .grayscale:
            guard let snap = ctx.makeImage(), let gray = Self.grayscale(snap, ci: ci),
                  let original = snap.cropping(to: r.integral) else { return }
            ctx.setBlendMode(.copy)
            Bitmap.drawImage(gray, in: canvas, ctx: ctx)
            Bitmap.drawImage(original, in: r.integral, ctx: ctx)
        case .magnify:
            let m = max(1, e.style.magnification)
            let src = CGRect(x: r.midX - r.width / (2 * m), y: r.midY - r.height / (2 * m),
                             width: r.width / m, height: r.height / m).integral.intersection(canvas)
            guard !src.isNull, let snap = ctx.makeImage(), let piece = snap.cropping(to: src) else { return }
            ctx.interpolationQuality = .high
            ctx.setBlendMode(.copy)
            Bitmap.drawImage(piece, in: r, ctx: ctx)
        }
    }

    /// Blur that fades out past the box instead of stopping dead at it.
    /// - The area blurred is bigger than the box, so pixels at the box edge mix with their real
    ///   neighbours rather than copies of themselves (which made the inside look like a flat slab).
    /// - Inside the box the blur is total; the fade only happens *outside*, so softening the edge
    ///   never makes covered text partly readable.
    private func drawSoftBlur(in r: CGRect, radius: CGFloat, snapshot snap: CGImage, ctx: CGContext, canvas: CGRect) {
        let feather = (radius * 2).rounded(.up)
        let outer = r.insetBy(dx: -feather, dy: -feather).integral.intersection(canvas)
        let inner = r.offsetBy(dx: -outer.minX, dy: -outer.minY)
        guard let piece = snap.cropping(to: outer),
              let blurred = Self.blur(piece, radius: radius, ci: ci),
              let core = blurred.cropping(to: inner) else { return }

        // The box itself: replace outright (no original showing through, even on transparent captures).
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        Bitmap.drawImage(core, in: r, ctx: ctx)
        ctx.restoreGState()

        // The fade: only the ring around the box, blended over the original through a soft mask.
        guard feather > 0, let mask = Self.featherMask(size: outer.size, inner: inner, feather: feather) else { return }
        ctx.saveGState()
        let ring = CGMutablePath()
        ring.addRect(outer); ring.addRect(r)
        ctx.addPath(ring)
        ctx.clip(using: .evenOdd)
        // Mask and image are both drawn upright in the same local frame, so they stay aligned.
        ctx.translateBy(x: outer.minX, y: outer.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: outer.size)
        ctx.clip(to: local, mask: mask)
        ctx.draw(blurred, in: local)
        ctx.restoreGState()
    }

    /// Greyscale mask: white inside `inner`, easing to black `feather` pixels further out, with
    /// rounded corners. Built as nested rounded rects (1 px apart), biggest and darkest first.
    static func featherMask(size: CGSize, inner: CGRect, feather: CGFloat) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0, let c = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: 1, y: -1)
        c.setFillColor(gray: 0, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let steps = max(1, Int(feather))
        for i in stride(from: steps, through: 0, by: -1) {
            let d = feather * CGFloat(i) / CGFloat(steps)
            let t = 1 - CGFloat(i) / CGFloat(steps)
            c.setFillColor(gray: t * t * (3 - 2 * t), alpha: 1) // smoothstep: no visible band at either end
            c.addPath(CGPath(roundedRect: inner.insetBy(dx: -d, dy: -d), cornerWidth: d, cornerHeight: d, transform: nil))
            c.fillPath()
        }
        return c.makeImage()
    }

    public static func bubblePath(frame f: CGRect, tip: CGPoint?, pixelScale s: CGFloat) -> CGPath {
        let radius = min(min(f.width, f.height) * 0.25, 20 * s)
        let body = CGPath(roundedRect: f, cornerWidth: radius, cornerHeight: radius, transform: nil)
        guard let tip, !f.contains(tip) else { return body }
        let c = f.center
        let len = c.distance(to: tip)
        guard len > 0 else { return body }
        let d = (tip - c) * (1 / len)
        let perp = CGPoint(x: -d.y, y: d.x) * (min(f.width, f.height) * 0.18)
        let tail = CGMutablePath()
        tail.move(to: c + perp); tail.addLine(to: tip); tail.addLine(to: c - perp); tail.closeSubpath()
        return body.union(tail)
    }

    // MARK: Core Image filters

    static func run(_ out: CIImage?, extent: CGRect, like img: CGImage, ci: CIContext) -> CGImage? {
        guard let out else { return nil }
        return ci.createCGImage(out, from: extent, format: .RGBA8, colorSpace: Bitmap.drawableSpace(img.colorSpace))
    }

    public static func pixelate(_ img: CGImage, cellSize: CGFloat, ci: CIContext) -> CGImage? {
        let input = CIImage(cgImage: img)
        let f = CIFilter.pixellate()
        f.inputImage = input.clampedToExtent()
        f.scale = Float(cellSize)
        f.center = CGPoint(x: input.extent.minX, y: input.extent.maxY)
        return run(f.outputImage?.cropped(to: input.extent), extent: input.extent, like: img, ci: ci)
    }

    public static func blur(_ img: CGImage, radius: CGFloat, ci: CIContext) -> CGImage? {
        let input = CIImage(cgImage: img)
        let f = CIFilter.gaussianBlur()
        f.inputImage = input.clampedToExtent()
        f.radius = Float(radius)
        return run(f.outputImage?.cropped(to: input.extent), extent: input.extent, like: img, ci: ci)
    }

    public static func grayscale(_ img: CGImage, ci: CIContext) -> CGImage? {
        let input = CIImage(cgImage: img)
        let f = CIFilter.colorControls()
        f.inputImage = input
        f.saturation = 0
        return run(f.outputImage, extent: input.extent, like: img, ci: ci)
    }

    public static func invert(_ img: CGImage, ci: CIContext) -> CGImage? {
        let input = CIImage(cgImage: img)
        let f = CIFilter.colorInvert()
        f.inputImage = input
        return run(f.outputImage, extent: input.extent, like: img, ci: ci)
    }
}
