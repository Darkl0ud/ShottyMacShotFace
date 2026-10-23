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
    /// Esc dropped the drag while the button was still down: the coming mouseUp must not capture.
    private(set) var pressAborted = false
    /// Mouse button currently held over the overlay.
    private(set) var isPressed = false

    private var windows: [NSWindow] = []
    /// One per screen. The self-test adds its own offscreen views here.
    var drawViews: [SelectionDrawView] = []
    private var completion: ((Outcome) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let primaryHeight: CGFloat

    init(snapshot: ScreenSnapshot, mode: Mode, showMagnifier: Bool) {
        self.snapshot = snapshot
        self.mode = mode
        self.showMagnifier = showMagnifier
        primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    }

    var selectionRect: CGRect? { dragStart.map { CGRect(corner: $0, cursor) } }

    var isActive: Bool { completion != nil }

    func begin(_ completion: @escaping (Outcome) -> Void) {
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
            let container = SelectionContainerView(overlay: self, globalRect: global,
                                                   frame: CGRect(origin: .zero, size: screen.frame.size))
            w.contentView = container
            drawViews.append(container.drawView)
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        cursor = mouseLocation()
        attach(completion)
        let start = windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first
        start?.makeKey()
        if let v = (start?.contentView as? SelectionContainerView)?.drawView { start?.makeFirstResponder(v) }
        updateHover()
        refresh()
    }

    /// The window-independent half of begin(), separate so the self-test can drive a live overlay
    /// without putting windows on the screen.
    func attach(_ completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        // Losing focus (⌘-Tab, Spotlight, another app activating) cancels: otherwise the
        // full-screen overlay would keep covering everything while keys go to another app, and a
        // Shift-up there would leave the pointer frozen system-wide.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancelled) }
        })
        // The capture hotkey's own ⌃⇧ are usually still held now. Releasing ⌃ first would look
        // like "Shift alone" and drop into precision mode, so wait until every modifier is up.
        precisionArmed = pointer.modifiers().intersection(Self.chordModifiers).isEmpty
    }

    func mouseLocation() -> CGPoint { Geometry.flipPoint(pointer.location(), primaryHeight: primaryHeight) }

    private func updateHover() { hovered = snapshot.window(at: cursor) }

    /// Redraws only the screens whose picture actually changed (see SelectionDrawView.refresh).
    func refresh() {
        for v in drawViews { v.refresh() }
    }

    /// The size the capture of `sel` will really have, from the same pixel maths as the crop
    /// (edges at half pixels in precision mode round outward, so width × scale can be 1 px short).
    func sizeLabel(_ sel: CGRect) -> String {
        guard let s = snapshot.pixelSize(for: sel) else { return "0 × 0 px" }
        return "\(Int(s.width)) × \(Int(s.height)) px"
    }

    func hoverSizeLabel(_ w: WindowInfo) -> String {
        if mode == .region { return sizeLabel(w.frame) }
        let s = snapshot.scale(for: w.frame)
        return "\(Int((w.frame.width * s).rounded())) × \(Int((w.frame.height * s).rounded())) px"
    }

    // MARK: Precision (hold Shift)

    /// Pointer speed while Shift is held.
    static let precisionFactor: CGFloat = 0.25
    static let chordModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// The real pointer and keyboard state, behind closures so the self-test never touches Warren's mouse.
    struct Pointer {
        var warp: (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) }
        /// false = the on-screen pointer stops following the mouse; movement still arrives as deltas.
        var follow: (Bool) -> Void = { CGAssociateMouseAndMouseCursorPosition($0 ? 1 : 0) }
        var setHidden: (Bool) -> Void = { $0 ? NSCursor.hide() : NSCursor.unhide() }
        /// Cocoa (y-up) pointer location.
        var location: () -> CGPoint = { NSEvent.mouseLocation }
        var modifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    }
    var pointer = Pointer()
    private(set) var isPrecise = false
    /// false until every modifier held when the overlay opened has been released.
    private(set) var precisionArmed = true

    /// Shift down: freeze and hide the real pointer and drive our own crosshair from raw movement,
    /// at a quarter of the speed. Moving the real pointer on every event instead (the first version)
    /// fought macOS's own pointer handling and made it snap back.
    func setPrecise(_ on: Bool) {
        guard on != isPrecise else { return }
        isPrecise = on
        if on {
            cursor = mouseLocation()
            pointer.follow(false)
            pointer.setHidden(true)
        } else {
            // One hand-off: put the real pointer where our crosshair is, then let it follow again.
            pointer.warp(cursor)
            pointer.follow(true)
            pointer.setHidden(false)
        }
        refresh()
    }

    func track(_ e: NSEvent?) {
        guard isPrecise, let e else {
            cursor = mouseLocation()
            return
        }
        let k = Self.precisionFactor
        var p = CGPoint(x: cursor.x + e.deltaX * k, y: cursor.y + e.deltaY * k) // deltaY is already y-down
        p.x = min(max(p.x, snapshot.frame.minX), snapshot.frame.maxX - 1)
        p.y = min(max(p.y, snapshot.frame.minY), snapshot.frame.maxY - 1)
        cursor = p
    }

    /// Precision only for Shift on its own, and only once the hotkey's modifiers have been let go.
    func flagsChanged(_ e: NSEvent) {
        let held = e.modifierFlags.intersection(Self.chordModifiers)
        if !precisionArmed {
            if held.isEmpty { precisionArmed = true }
            return
        }
        setPrecise(held == .shift)
    }

    // MARK: Events (forwarded from the views)

    private weak var lastMotion: NSEvent?
    private var lastMotionStamp: (TimeInterval, NSEvent.EventType)?

    /// The same mouse move can reach us twice: the window delivers it to its first responder
    /// (acceptsMouseMovedEvents, needed for the key screen) AND to the owner of a .mouseMoved
    /// tracking area (needed for the other screens), and here both are the same view. Applying the
    /// delta twice would make Shift-precision 50% instead of 25%, so each event counts once.
    private func isRepeat(_ e: NSEvent) -> Bool {
        let stamp = (e.timestamp, e.type)
        defer { lastMotion = e; lastMotionStamp = stamp }
        if e === lastMotion { return true }
        // A second copy of a real event has the same timestamp; two real moves never do.
        if e.timestamp > 0, let last = lastMotionStamp, last.0 == stamp.0, last.1 == stamp.1 { return true }
        return false
    }

    /// The hotkey's own modifier release can reach the previous app before we're active. Any mouse
    /// motion with none of them held proves they're up, so Shift precision is allowed from then on.
    private func rearmPrecisionIfReleased() {
        if !precisionArmed, pointer.modifiers().intersection(Self.chordModifiers).isEmpty { precisionArmed = true }
    }

    func mouseMoved(_ e: NSEvent? = nil) {
        if let e, isRepeat(e) { return }
        rearmPrecisionIfReleased()
        track(e)
        if dragStart == nil { updateHover() }
        refresh()
    }

    func mouseDown(_ e: NSEvent? = nil) {
        pressAborted = false
        isPressed = true
        // While precise, the real pointer is frozen elsewhere; our crosshair is the truth.
        if !isPrecise { cursor = mouseLocation() }
        if mode == .region { dragStart = cursor }
        refresh()
    }

    func mouseDragged(_ e: NSEvent? = nil) {
        if let e, isRepeat(e) { return }
        rearmPrecisionIfReleased()
        track(e)
        if pressAborted { updateHover() }
        refresh()
    }

    func mouseUp(_ e: NSEvent? = nil) {
        isPressed = false
        if !isPrecise { cursor = mouseLocation() }
        if pressAborted {
            // Esc already dropped this press; releasing the button just lets the user start again.
            pressAborted = false
            updateHover()
            refresh()
            return
        }
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
            if dragStart != nil {
                dragStart = nil
                pressAborted = true
                refresh()
            } else {
                finish(.cancelled)
            }
        case 49: // Space
            mode = mode == .region ? .window : .region
            // Switching mode mid-press abandons that press (like Esc), so releasing doesn't capture.
            if dragStart != nil || isPressed { pressAborted = true }
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
            if !isPrecise { pointer.warp(p); pointer.follow(true) }
            cursor = p
            if dragStart == nil { updateHover() }
            refresh()
        default:
            break
        }
    }

    func finish(_ outcome: Outcome) {
        guard let c = completion else { return }
        completion = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        setPrecise(false)
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        drawViews.removeAll()
        NSCursor.arrow.set()
        c(outcome)
    }
}

final class OverlayWindow: NSWindow {
    // Borderless windows refuse key status by default, and then Esc/Space would never arrive.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The frozen screen lives in a CALayer (the GPU just composites it). Above it, the dim and the
/// selection border are CAShapeLayers, and only the small things (crosshair, labels, magnifier)
/// are drawn by the CPU. Filling the 35% dim on the CPU cost ~19 ms per 5K screen per mouse event.
final class SelectionContainerView: NSView {
    let dimView: SelectionDimView
    let drawView: SelectionDrawView

    init(overlay: SelectionOverlay, globalRect: CGRect, frame: CGRect) {
        dimView = SelectionDimView(globalRect: globalRect, frame: frame)
        drawView = SelectionDrawView(overlay: overlay, globalRect: globalRect, frame: frame)
        drawView.dimView = dimView
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.contents = overlay.snapshot.crop(globalRect)
        for v in [dimView, drawView] as [NSView] {
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Dims everything outside the selection and outlines it, composited by the GPU.
final class SelectionDimView: NSView {
    /// This screen's rect in global points.
    let globalRect: CGRect
    let dim = CAShapeLayer()
    let border = CAShapeLayer()
    private(set) var shownSelection: CGRect?

    init(globalRect: CGRect, frame: CGRect) {
        self.globalRect = globalRect
        super.init(frame: frame)
        wantsLayer = true
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        border.fillColor = nil
        border.strokeColor = SelectionDrawView.accent.cgColor
        border.lineWidth = 1
        layer?.addSublayer(dim)
        layer?.addSublayer(border)
    }

    // Hand-added sublayers stay at contentsScale 1 and render blurry on Retina unless told.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        dim.contentsScale = scale
        border.contentsScale = scale
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Not flipped: the layers then use Core Animation's own y-up space, with no guessing about
    // how AppKit flips a backing layer's sublayers.
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Global (y-down) rect → this view's y-up coordinates.
    func local(_ g: CGRect) -> CGRect {
        CGRect(x: g.minX - globalRect.minX, y: globalRect.maxY - g.maxY, width: g.width, height: g.height)
    }

    func show(selection global: CGRect?) {
        guard global != shownSelection || dim.frame != bounds else { return }
        shownSelection = global
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit animation lagging behind the pointer
        dim.frame = bounds
        border.frame = bounds
        if let global {
            let r = local(global)
            let p = CGMutablePath(); p.addRect(bounds); p.addRect(r)
            dim.path = p
            border.path = CGPath(rect: r.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        } else {
            dim.path = nil
            border.path = nil
        }
        CATransaction.commit()
    }
}

final class SelectionDrawView: NSView {
    weak var overlay: SelectionOverlay?
    weak var dimView: SelectionDimView?
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
    override func flagsChanged(with event: NSEvent) { overlay?.flagsChanged(event) }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -globalRect.minX, dy: -globalRect.minY) }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - globalRect.minX, y: p.y - globalRect.minY) }

    static let accent = NSColor.systemBlue

    /// Everything draw() depends on, as far as this screen can see it.
    struct DrawnState: Equatable {
        var cursor: CGPoint?        // only while the cursor is on this screen
        var selection: CGRect?      // for the size label, which follows the cursor
        var hovered: CGWindowID?
        var hoveredFrame: CGRect?
        var mode: SelectionOverlay.Mode
        var precise: Bool           // the stand-in pointer and crosshair are drawn only where the cursor is
        var dragging: Bool
    }

    private(set) var drawnState: DrawnState?
    /// How often refresh() asked for a repaint (for the self-test).
    private(set) var redraws = 0

    func currentState() -> DrawnState? {
        guard let o = overlay else { return nil }
        let here = globalRect.contains(o.cursor)
        // No hover box anywhere while a selection is being dragged (draw() paints none then either).
        let hover = o.dragStart != nil ? nil : o.hovered.flatMap { globalRect.intersects($0.frame) ? $0 : nil }
        return DrawnState(cursor: here ? o.cursor : nil, selection: here ? o.selectionRect : nil,
                          hovered: hover?.windowID, hoveredFrame: hover?.frame, mode: o.mode,
                          precise: here && o.isPrecise, dragging: here && o.dragStart != nil)
    }

    /// Marks this screen dirty only if what it shows changed: a mouse move on one display no
    /// longer repaints every other display too.
    func refresh() {
        dimView?.show(selection: overlay?.selectionRect)
        let s = currentState()
        guard s != drawnState else { return }
        drawnState = s
        redraws += 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let o = overlay, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cur = local(o.cursor)
        let cursorHere = bounds.contains(cur)

        if let sel = o.selectionRect {
            // The dim and border are SelectionDimView's layers; only the label is drawn here.
            let r = local(sel)
            if cursorHere { drawLabel(o.sizeLabel(sel), near: CGPoint(x: r.maxX, y: r.maxY), ctx: ctx) }
        } else if let w = o.hovered {
            let r = local(w.frame)
            ctx.setFillColor(Self.accent.withAlphaComponent(o.mode == .window ? 0.25 : 0.12).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(Self.accent.cgColor)
            ctx.setLineWidth(o.mode == .window ? 3 : 1.5)
            ctx.stroke(r.insetBy(dx: 1, dy: 1))
            if bounds.intersects(r) {
                drawLabel("\(w.displayTitle)  ·  \(o.hoverSizeLabel(w))", near: CGPoint(x: max(r.minX, 4), y: max(r.minY, 4)),
                          ctx: ctx, below: true)
            }
        }

        if cursorHere, o.dragStart == nil, o.mode == .region { drawCrosshair(at: cur, ctx: ctx) }
        if cursorHere, o.isPrecise { drawPointer(at: cur, ctx: ctx) }
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

    /// Stand-in for the hidden system pointer in Shift-precision mode: a small crosshair.
    private func drawPointer(at p: CGPoint, ctx: CGContext) {
        let x = p.x.rounded() + 0.5, y = p.y.rounded() + 0.5, r: CGFloat = 9
        for (color, w) in [(NSColor.white, CGFloat(3)), (NSColor.black, CGFloat(1))] {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(w)
            ctx.move(to: CGPoint(x: x - r, y: y)); ctx.addLine(to: CGPoint(x: x + r, y: y))
            ctx.move(to: CGPoint(x: x, y: y - r)); ctx.addLine(to: CGPoint(x: x, y: y + r))
            ctx.strokePath()
        }
    }

    /// Zoomed, unsmoothed view of the pixels around the pointer, for pixel-exact edges.
    private func drawMagnifier(around global: CGPoint, local cur: CGPoint, ctx: CGContext) {
        guard let o = overlay else { return }
        // Sample from the display under the pointer only, so the lens shows its real pixels.
        let area = o.snapshot.part(at: global)?.frame ?? o.snapshot.frame
        let scale = o.snapshot.scale(at: global)
        let spanPts: CGFloat = 15
        let size: CGFloat = 132
        var src = CGRect(x: global.x - spanPts / 2, y: global.y - spanPts / 2, width: spanPts, height: spanPts)
        // Keep the sample inside the picture so the zoom never stretches at screen edges.
        src.origin.x = min(max(src.minX, area.minX), area.maxX - spanPts)
        src.origin.y = min(max(src.minY, area.minY), area.maxY - spanPts)
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
        let cell = size / (spanPts * scale)
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

        // Pixel position on this display, in that display's own pixels.
        let posPx = CGPoint(x: (global.x - area.minX) * scale, y: (global.y - area.minY) * scale)
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
