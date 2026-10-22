import AppKit
import ShottyCore

/// Full-screen overlay for picking a region or a window on the frozen snapshot.
/// Region mode: drag a rectangle, or click to take the window under the cursor.
/// Window mode: click a window to capture it on its own. Space switches modes, Esc cancels,
/// arrow keys nudge the pointer by a point (⇧ for 10), Return takes the highlighted window.
@MainActor
final class SelectionOverlay {
    enum Mode { case region, window }
    enum Outcome { case region(CGRect), window(WindowInfo), cancelled }

    let snapshot: ScreenSnapshot
    private(set) var mode: Mode
    let showMagnifier: Bool

    // All positions are global points, y-down (the same space as the snapshot).
    var cursor: CGPoint = .zero
    var dragStart: CGPoint?
    var hovered: WindowInfo?

    private var windows: [NSWindow] = []
    private var completion: ((Outcome) -> Void)?
    private let primaryHeight: CGFloat

    init(snapshot: ScreenSnapshot, mode: Mode, showMagnifier: Bool) {
        self.snapshot = snapshot
        self.mode = mode
        self.showMagnifier = showMagnifier
        primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    }

    var selectionRect: CGRect? { dragStart.map { CGRect(corner: $0, cursor) } }

    func begin(_ completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = true
            w.hasShadow = false
            w.backgroundColor = .black
            w.acceptsMouseMovedEvents = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let global = Geometry.flipRect(screen.frame, primaryHeight: primaryHeight)
            w.contentView = SelectionContainerView(overlay: self, globalRect: global,
                                                   frame: CGRect(origin: .zero, size: screen.frame.size))
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        // After a warp macOS ignores real mouse movement for 0.25 s by default, which would make
        // Shift-precision movement stutter. Turn that pause off while the overlay is up.
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        cursor = mouseLocation()
        let start = windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first
        start?.makeKey()
        if let v = (start?.contentView as? SelectionContainerView)?.drawView { start?.makeFirstResponder(v) }
        updateHover()
        refresh()
    }

    func mouseLocation() -> CGPoint { Geometry.flipPoint(NSEvent.mouseLocation, primaryHeight: primaryHeight) }

    private func updateHover() { hovered = snapshot.window(at: cursor) }

    func refresh() {
        for w in windows { (w.contentView as? SelectionContainerView)?.drawView.needsDisplay = true }
    }

    // MARK: Precision (hold Shift)

    /// Pointer speed while Shift is held.
    static let precisionFactor: CGFloat = 0.25
    /// Moves the real on-screen pointer. Swappable so the self-test doesn't move Warren's mouse.
    var warp: (CGPoint) -> Void = { p in
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Normally the selection follows the real pointer. With Shift held, we move our own cursor by a
    /// fraction of the hand's movement (the event's raw delta) and put the real pointer there, so what
    /// you see is always what gets selected. Letting go of Shift simply resumes following the pointer.
    func track(_ e: NSEvent?) {
        guard let e, e.modifierFlags.contains(.shift) else {
            cursor = mouseLocation()
            return
        }
        let k = Self.precisionFactor
        var p = CGPoint(x: cursor.x + e.deltaX * k, y: cursor.y + e.deltaY * k) // deltaY is already y-down
        p.x = min(max(p.x, snapshot.frame.minX), snapshot.frame.maxX - 1)
        p.y = min(max(p.y, snapshot.frame.minY), snapshot.frame.maxY - 1)
        cursor = p
        warp(p)
    }

    // MARK: Events (forwarded from the views)

    func mouseMoved(_ e: NSEvent? = nil) {
        track(e)
        if dragStart == nil { updateHover() }
        refresh()
    }

    func mouseDown(_ e: NSEvent? = nil) {
        // A click doesn't move the pointer: keep the precise position if Shift is down.
        if !(e?.modifierFlags.contains(.shift) ?? false) { cursor = mouseLocation() }
        if mode == .region { dragStart = cursor }
        refresh()
    }

    func mouseDragged(_ e: NSEvent? = nil) {
        track(e)
        refresh()
    }

    func mouseUp(_ e: NSEvent? = nil) {
        if !(e?.modifierFlags.contains(.shift) ?? false) { cursor = mouseLocation() }
        switch mode {
        case .region:
            if let r = selectionRect, r.width >= 3, r.height >= 3 {
                finish(.region(r))
            } else if let w = hovered {
                // A click without dragging grabs the window's area, like Greenshot.
                finish(.region(w.frame.intersection(snapshot.frame)))
            } else {
                dragStart = nil
                refresh()
            }
        case .window:
            if let w = hovered { finish(.window(w)) }
        }
    }

    func keyDown(_ e: NSEvent) {
        switch Int(e.keyCode) {
        case 53: // Esc: first drop a drag in progress, then cancel
            if dragStart != nil { dragStart = nil; refresh() } else { finish(.cancelled) }
        case 49: // Space
            mode = mode == .region ? .window : .region
            dragStart = nil
            updateHover()
            refresh()
        case 36, 76: // Return / Enter
            if let r = selectionRect, r.width >= 3, r.height >= 3, mode == .region { finish(.region(r)) }
            else if let w = hovered { finish(mode == .window ? .window(w) : .region(w.frame.intersection(snapshot.frame))) }
        case 123, 124, 125, 126: // arrows
            let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            var p = cursor
            switch Int(e.keyCode) {
            case 123: p.x -= step
            case 124: p.x += step
            case 125: p.y += step
            default: p.y -= step
            }
            warp(p)
            cursor = p
            if dragStart == nil { updateHover() }
            refresh()
        default:
            break
        }
    }

    func finish(_ outcome: Outcome) {
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        NSCursor.arrow.set()
        let c = completion
        completion = nil
        c?(outcome)
    }
}

final class OverlayWindow: NSWindow {
    // Borderless windows refuse key status by default, and then Esc/Space would never arrive.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The frozen screen lives in a CALayer (the GPU just composites it), so redrawing the overlay on
/// every mouse move only repaints the light drawing view on top.
final class SelectionContainerView: NSView {
    let drawView: SelectionDrawView

    init(overlay: SelectionOverlay, globalRect: CGRect, frame: CGRect) {
        drawView = SelectionDrawView(overlay: overlay, globalRect: globalRect, frame: frame)
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.contents = overlay.snapshot.crop(globalRect)
        drawView.autoresizingMask = [.width, .height]
        addSubview(drawView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

final class SelectionDrawView: NSView {
    weak var overlay: SelectionOverlay?
    /// This screen's rect in global points, so local ↔ global is a plain offset.
    let globalRect: CGRect

    init(overlay: SelectionOverlay, globalRect: CGRect, frame: CGRect) {
        self.overlay = overlay
        self.globalRect = globalRect
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set(); overlay?.mouseMoved(event) }
    override func mouseDown(with event: NSEvent) { overlay?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { overlay?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { overlay?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { overlay?.finish(.cancelled) }
    override func keyDown(with event: NSEvent) { overlay?.keyDown(event) }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -globalRect.minX, dy: -globalRect.minY) }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - globalRect.minX, y: p.y - globalRect.minY) }

    static let accent = NSColor.systemBlue

    override func draw(_ dirtyRect: NSRect) {
        guard let o = overlay, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cur = local(o.cursor)
        let cursorHere = bounds.contains(cur)
        let px = o.snapshot.scale

        if let sel = o.selectionRect {
            let r = local(sel)
            // Dim everything outside the selection.
            let p = CGMutablePath(); p.addRect(bounds); p.addRect(r)
            ctx.addPath(p)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(Self.accent.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
            if cursorHere {
                drawLabel("\(Int((sel.width * px).rounded())) × \(Int((sel.height * px).rounded())) px",
                          near: CGPoint(x: r.maxX, y: r.maxY), ctx: ctx)
            }
        } else if let w = o.hovered {
            let r = local(w.frame)
            ctx.setFillColor(Self.accent.withAlphaComponent(o.mode == .window ? 0.25 : 0.12).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(Self.accent.cgColor)
            ctx.setLineWidth(o.mode == .window ? 3 : 1.5)
            ctx.stroke(r.insetBy(dx: 1, dy: 1))
            if bounds.intersects(r) {
                let size = "\(Int(w.frame.width * px)) × \(Int(w.frame.height * px)) px"
                drawLabel("\(w.displayTitle)  ·  \(size)", near: CGPoint(x: max(r.minX, 4), y: max(r.minY, 4)),
                          ctx: ctx, below: true)
            }
        }

        if cursorHere, o.dragStart == nil, o.mode == .region { drawCrosshair(at: cur, ctx: ctx) }
        if cursorHere, o.showMagnifier { drawMagnifier(around: o.cursor, local: cur, ctx: ctx) }
        if cursorHere { drawHint(o.mode, ctx: ctx) }
    }

    private func drawCrosshair(at p: CGPoint, ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        for (color, phase) in [(NSColor.black, CGFloat(0)), (NSColor.white, CGFloat(4))] {
            ctx.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
            ctx.setLineDash(phase: phase, lengths: [4, 4])
            ctx.move(to: CGPoint(x: 0, y: p.y.rounded() + 0.5)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: p.y.rounded() + 0.5))
            ctx.move(to: CGPoint(x: p.x.rounded() + 0.5, y: 0)); ctx.addLine(to: CGPoint(x: p.x.rounded() + 0.5, y: bounds.maxY))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Zoomed, unsmoothed view of the pixels around the pointer, for pixel-exact edges.
    private func drawMagnifier(around global: CGPoint, local cur: CGPoint, ctx: CGContext) {
        guard let o = overlay else { return }
        let spanPts: CGFloat = 15
        let size: CGFloat = 132
        var src = CGRect(x: global.x - spanPts / 2, y: global.y - spanPts / 2, width: spanPts, height: spanPts)
        // Keep the sample inside the picture so the zoom never stretches at screen edges.
        src.origin.x = min(max(src.minX, o.snapshot.frame.minX), o.snapshot.frame.maxX - spanPts)
        src.origin.y = min(max(src.minY, o.snapshot.frame.minY), o.snapshot.frame.maxY - spanPts)
        guard let crop = o.snapshot.crop(src) else { return }

        var m = CGRect(x: cur.x + 26, y: cur.y + 26, width: size, height: size)
        if m.maxX > bounds.maxX - 4 { m.origin.x = cur.x - 26 - size }
        if m.maxY > bounds.maxY - 4 { m.origin.y = cur.y - 26 - size }

        ctx.saveGState()
        ctx.addEllipse(in: m); ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor); ctx.fill(m)
        ctx.interpolationQuality = .none
        Bitmap.drawImage(crop, in: m, ctx: ctx)
        // Box around the exact pixel under the pointer.
        let cell = size / (spanPts * o.snapshot.scale)
        let offset = CGPoint(x: (global.x - src.minX) / spanPts * size, y: (global.y - src.minY) / spanPts * size)
        let cellRect = CGRect(x: m.minX + (offset.x / cell).rounded(.down) * cell,
                              y: m.minY + (offset.y / cell).rounded(.down) * cell, width: cell, height: cell)
        // Greenshot-style crosshair: lines across the whole lens through the centre of the pointer's
        // pixel, stopping just short of it so the pixel itself stays visible. Each line is drawn twice
        // (a wide white halo under a thin black line) so it shows on both light and dark content.
        let c = CGPoint(x: cellRect.midX, y: cellRect.midY)
        let gap = cell / 2 + 2
        let arms: [(CGPoint, CGPoint)] = [
            (CGPoint(x: m.minX, y: c.y), CGPoint(x: c.x - gap, y: c.y)),
            (CGPoint(x: c.x + gap, y: c.y), CGPoint(x: m.maxX, y: c.y)),
            (CGPoint(x: c.x, y: m.minY), CGPoint(x: c.x, y: c.y - gap)),
            (CGPoint(x: c.x, y: c.y + gap), CGPoint(x: c.x, y: m.maxY)),
        ]
        for (color, width) in [(NSColor.white.withAlphaComponent(0.85), CGFloat(3)),
                               (NSColor.black, CGFloat(1))] {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            for (a, b) in arms { ctx.move(to: a); ctx.addLine(to: b) }
            ctx.strokePath()
        }
        ctx.setStrokeColor(NSColor.systemRed.cgColor); ctx.setLineWidth(1.5)
        ctx.stroke(cellRect)
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(3)
        ctx.strokeEllipse(in: m)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(1)
        ctx.strokeEllipse(in: m.insetBy(dx: -1.5, dy: -1.5))

        let posPx = CGPoint(x: (global.x - o.snapshot.frame.minX) * o.snapshot.scale,
                            y: (global.y - o.snapshot.frame.minY) * o.snapshot.scale)
        drawLabel("\(Int(posPx.x)), \(Int(posPx.y))", near: CGPoint(x: m.midX - 30, y: m.maxY + 4), ctx: ctx, below: true)
    }

    private func drawHint(_ mode: SelectionOverlay.Mode, ctx: CGContext) {
        let text = mode == .region
            ? "Drag to select · hold ⇧ to move slowly · click a window to take its area · Space: window mode · arrows nudge · Esc: cancel"
            : "Click a window to capture it · Space: region mode · Esc: cancel"
        drawLabel(text, near: CGPoint(x: bounds.midX, y: 28), ctx: ctx, below: true, centered: true)
    }

    private func drawLabel(_ text: String, near p: CGPoint, ctx: CGContext, below: Bool = true, centered: Bool = false) {
        let str = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let s = str.size()
        var box = CGRect(x: p.x + (centered ? -s.width / 2 - 8 : 6), y: below ? p.y + 6 : p.y - s.height - 12,
                         width: s.width + 16, height: s.height + 6)
        box.origin.x = min(max(box.minX, 4), bounds.maxX - box.width - 4)
        box.origin.y = min(max(box.minY, 4), bounds.maxY - box.height - 4)
        let path = CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.fillPath()
        str.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 3))
    }
}
