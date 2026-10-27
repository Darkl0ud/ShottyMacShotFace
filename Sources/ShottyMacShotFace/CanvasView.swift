import AppKit
import ShottyCore

enum Tool: Equatable {
    case select, crop, draw(ElementKind)

    var kind: ElementKind? {
        if case .draw(let k) = self { return k }
        return nil
    }
}

@MainActor
protocol CanvasDelegate: AnyObject {
    func canvasSelectionChanged()
    func canvasToolChanged()
    func canvasCropChanged()
    func canvasZoomChanged()
    func canvasSmartZoom()
    func style(for kind: ElementKind) -> ElementStyle
}

/// The editing surface. Document coordinates are image pixels (y-down); the view shows them at
/// `zoom` points per pixel, so on a Retina screen zoom = 0.5 is "actual size".
final class CanvasView: NSView, NSTextViewDelegate {
    let doc: EditorDocument
    let renderer: Renderer
    weak var delegate: CanvasDelegate?

    var tool: Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            // A tool key (V, Esc, R…) can arrive while the mouse button is still down. Finish that
            // drag now; left running, a crop drag kept redrawing its rectangle in Select mode.
            finishDrag(shift: false)
            endTextEdit()
            if tool != .crop { cropRect = nil }
            // Greenshot behaviour: picking a drawing tool deselects, so property changes made for
            // the new tool can't restyle a shape of another kind that happened to be selected.
            if tool.kind != nil { setSelection([]) }
            window?.invalidateCursorRects(for: self)
            delegate?.canvasToolChanged()
            needsDisplay = true
        }
    }

    private(set) var selection: Set<UUID> = []
    var zoom: CGFloat = 1 {
        didSet { updateSize(); delegate?.canvasZoomChanged() }
    }
    private(set) var cropRect: CGRect?

    private var cache: CGImage?
    private var fastBackground: CGImage?
    private var fastID: UUID?
    /// Everything below the dragged element(s), for drags the single-element fast path can't do
    /// (filters, elements under others, multi-selection moves).
    private var layerBase: CGImage?
    private var layerBaseIndex = -1
    private var lastDocSize: CGSize = .zero

    private enum Drag {
        case none
        case creating(UUID, start: CGPoint)
        case moving(start: CGPoint, originals: [UUID: Element])
        /// `original` is the element at mouse-down: every event resizes from it (see mouseDragged).
        case resizing(UUID, Handle, original: Element)
        case rubberBand(start: CGPoint, current: CGPoint)
        case cropping(start: CGPoint)
    }
    private var drag: Drag = .none
    private var textView: NSTextView?
    /// The typing history of the current text edit only (see undoManager(for:)).
    private var textUndo: UndoManager?
    private(set) var editingID: UUID?
    /// A text box created by the current click/drag: its creation stays one open live change
    /// until the typing ends, so create + type is one undo step and an empty box leaves no trace.
    private var newTextID: UUID?

    /// True between mouse-down and mouse-up of a canvas drag. Menu commands that change the
    /// document are disabled meanwhile (see EditorWindowController.validateMenuItem).
    var isDragging: Bool { if case .none = drag { return false }; return true }

    static let toolKeys: [String: Tool] = [
        "v": .select, "r": .draw(.rectangle), "e": .draw(.ellipse), "l": .draw(.line), "a": .draw(.arrow),
        "f": .draw(.freehand), "t": .draw(.text), "s": .draw(.speechBubble), "i": .draw(.counter),
        "h": .draw(.highlight), "o": .draw(.obfuscate), "c": .crop,
    ]

    init(document: EditorDocument, renderer: Renderer) {
        doc = document
        self.renderer = renderer
        lastDocSize = document.state.size
        super.init(frame: .zero)
        // Since macOS 14 views don't clip their drawing to their bounds by default; anything drawn
        // past the edge showed up as a strip beside the picture.
        clipsToBounds = true
        updateSize()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var selectedElements: [Element] { doc.state.elements.filter { selection.contains($0.id) } }

    func setSelection(_ s: Set<UUID>) {
        guard s != selection else { return }
        selection = s
        delegate?.canvasSelectionChanged()
        needsDisplay = true
    }

    private func updateSize() {
        let s = doc.state.size
        setFrameSize(NSSize(width: (s.width * zoom).rounded(), height: (s.height * zoom).rounded()))
        positionTextView()
        needsDisplay = true
    }

    /// Called by the controller whenever the document changes (edits, undo, redo).
    func documentChanged() {
        cache = nil
        let valid = selection.filter { doc.element($0) != nil }
        if valid != selection { selection = valid; delegate?.canvasSelectionChanged() }
        if editingID.map({ doc.element($0) == nil }) == true { endTextEdit(commit: false) }
        if !isDragging { layerBase = nil }
        let s = doc.state.size
        if s != lastDocSize {
            // A crop rectangle drawn on the old geometry (before a rotate, resize, shadow, undo
            // of a crop…) would cut the wrong area.
            lastDocSize = s
            if cropRect != nil { cropRect = nil; delegate?.canvasCropChanged() }
        }
        if frame.size != NSSize(width: (s.width * zoom).rounded(), height: (s.height * zoom).rounded()) { updateSize() }
        // Keep the text being typed in the font/size/colour just picked, not the old one.
        if editingID != nil { positionTextView() }
        needsDisplay = true
    }

    // MARK: Coordinates

    private func docPoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x / zoom, y: p.y / zoom)
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * zoom, y: r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
    }

    private func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom, y: p.y * zoom) }

    /// Grab distance: about 5 screen points whatever the zoom.
    private var tolerance: CGFloat { 5 / zoom }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let canvas = doc.state.canvasRect
        if doc.state.image.alphaInfo != .none, doc.state.image.alphaInfo != .noneSkipLast,
           doc.state.image.alphaInfo != .noneSkipFirst {
            // Only under the picture itself: the view is rounded up to whole points, and a checker
            // sliver along the edge looked like a dashed border.
            drawChecker(ctx, in: viewRect(canvas).intersection(dirtyRect))
        }

        ctx.saveGState()
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.interpolationQuality = zoom * (window?.backingScaleFactor ?? 2) >= 2.5 ? .none : .high
        if let (bg, e) = fastPath() {
            // While dragging the top element, reuse a picture of everything else and draw only it.
            Bitmap.drawImage(bg, in: canvas, ctx: ctx)
            renderer.draw(e, number: doc.counterNumber(for: e.id) ?? 0, in: ctx, canvas: canvas,
                          deviceScale: zoom * (window?.backingScaleFactor ?? 2))
        } else if let frame = layeredFrame() {
            Bitmap.drawImage(frame, in: canvas, ctx: ctx)
        } else {
            if cache == nil { cache = renderer.flatten(doc.state, excluding: editingID.map { [$0] } ?? []) }
            if let c = cache { Bitmap.drawImage(c, in: canvas, ctx: ctx) }
        }
        ctx.restoreGState()
        drawOverlays(ctx)
    }

    private func fastPath() -> (CGImage, Element)? {
        let id: UUID
        switch drag {
        case .creating(let i, _): id = i
        case .resizing(let i, _, _): id = i
        case .moving(_, let originals) where originals.count == 1: id = originals.keys.first!
        default: return nil
        }
        guard editingID == nil, let e = doc.element(id), !e.kind.isFilter,
              doc.state.elements.last?.id == id else { return nil }
        if fastID != id || fastBackground == nil {
            fastBackground = renderer.flatten(doc.state, excluding: [id])
            fastID = id
        }
        return fastBackground.map { ($0, e) }
    }

    /// Any other drag: reuse a picture of everything below the lowest dragged element, and only
    /// re-render from there up. Dragging a blur box no longer re-runs every filter under it on
    /// each mouse event (filters above it still must, since they read the pixels it changes).
    private func layeredFrame() -> CGImage? {
        guard editingID == nil else { return nil }
        let ids: Set<UUID>
        switch drag {
        case .creating(let i, _): ids = [i]
        case .resizing(let i, _, _): ids = [i]
        case .moving(_, let originals): ids = Set(originals.keys)
        default: return nil
        }
        guard let start = doc.state.elements.firstIndex(where: { ids.contains($0.id) }) else { return nil }
        if layerBase == nil || layerBaseIndex != start {
            layerBase = renderer.flattenPrefix(doc.state, count: start)
            layerBaseIndex = start
        }
        guard let base = layerBase else { return nil }
        return renderer.flatten(doc.state, over: base, from: start)
    }

    /// For the self-check: one drag frame rendered the way draw() would, and the full re-render.
    func renderDragFrameForTesting() -> CGImage? { layeredFrame() }

    private func drawChecker(_ ctx: CGContext, in r: CGRect) {
        guard !r.isNull else { return }
        let size: CGFloat = 8
        // The squares are whole 8 pt tiles; clip so the last row/column can't hang past the picture.
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: r)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(r)
        ctx.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
        var y = (r.minY / size).rounded(.down) * size
        while y < r.maxY {
            var x = (r.minX / size).rounded(.down) * size
            while x < r.maxX {
                if (Int(x / size) + Int(y / size)) % 2 == 0 { ctx.fill(CGRect(x: x, y: y, width: size, height: size)) }
                x += size
            }
            y += size
        }
    }

    private func drawOverlays(_ ctx: CGContext) {
        let accent = NSColor.controlAccentColor
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Selection outlines and grips
        let creating: Bool = { if case .creating = drag { return true }; return false }()
        if !creating {
            for e in selectedElements {
                let r = viewRect(e.bounds).insetBy(dx: -3, dy: -3)
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.stroke(r)
            }
            ctx.setLineDash(phase: 0, lengths: [])
            if selection.count == 1, editingID == nil, let e = selectedElements.first {
                for (_, p) in e.handles() {
                    let v = viewPoint(p)
                    let h = CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
                    ctx.setFillColor(NSColor.white.cgColor); ctx.fill(h)
                    ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(1.5); ctx.stroke(h)
                }
            }
        }

        if case .rubberBand(let a, let b) = drag {
            let r = viewRect(CGRect(corner: a, b))
            ctx.setFillColor(accent.withAlphaComponent(0.1).cgColor); ctx.fill(r)
            ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3]); ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
        }

        if let c = cropRect {
            let r = viewRect(c)
            let p = CGMutablePath(); p.addRect(bounds); p.addRect(r)
            ctx.addPath(p)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [5, 4]); ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        }

        if let id = editingID, let e = doc.element(id) {
            ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3]); ctx.stroke(viewRect(e.frame))
        }
    }

    // MARK: Mouse

    override func resetCursorRects() {
        let cursor: NSCursor
        switch tool {
        case .select: cursor = .arrow
        case .draw(.text): cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        // A drag whose mouse-up never arrived (e.g. the capture overlay opened mid-drag).
        if isDragging { finishDrag(shift: false) }
        if editingID != nil { endTextEdit() }
        window?.makeFirstResponder(self)
        let p = docPoint(event)
        switch tool {
        case .select:
            selectDown(p, event)
        case .crop:
            cropRect = nil
            drag = .cropping(start: p)
            delegate?.canvasCropChanged()
        case .draw(let kind):
            // Grips of the selected shape stay grabbable with a drawing tool, so you can place a
            // counter (or any shape) and resize it straight away without switching to Select.
            if beginResizeIfOnGrip(p) { break }
            // With the text tools, clicking existing text edits it instead of stacking a new box on top.
            if kind.hasText, let hit = doc.hitTest(p, tolerance: tolerance), hit.kind == kind {
                setSelection([hit.id]); beginTextEdit(hit.id); return
            }
            createDown(kind, p)
        }
        needsDisplay = true
    }

    private func selectDown(_ p: CGPoint, _ event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        if event.clickCount == 2, let hit = doc.hitTest(p, tolerance: tolerance), hit.kind.hasText {
            setSelection([hit.id]); beginTextEdit(hit.id); return
        }
        if beginResizeIfOnGrip(p) { return }
        if let hit = doc.hitTest(p, tolerance: tolerance) {
            if shift {
                var s = selection
                if s.contains(hit.id) { s.remove(hit.id) } else { s.insert(hit.id) }
                setSelection(s)
                if !s.contains(hit.id) { return }
            } else if !selection.contains(hit.id) {
                setSelection([hit.id])
            }
            doc.beginLiveChange()
            var originals: [UUID: Element] = [:]
            for e in selectedElements { originals[e.id] = e }
            drag = .moving(start: p, originals: originals)
        } else {
            if !shift { setSelection([]) }
            drag = .rubberBand(start: p, current: p)
        }
    }

    /// Starts resizing if `p` is on a grip of the single selected element.
    private func beginResizeIfOnGrip(_ p: CGPoint) -> Bool {
        guard selection.count == 1, let id = selection.first, let e = doc.element(id),
              let h = e.handles().first(where: { viewPoint($0.1).distance(to: viewPoint(p)) <= 7 })?.0
        else { return false }
        doc.beginLiveChange()
        drag = .resizing(id, h, original: e)
        return true
    }

    private func createDown(_ kind: ElementKind, _ p: CGPoint) {
        let style = delegate?.style(for: kind) ?? .defaults(for: kind)
        var e = Element(kind: kind, style: style)
        switch kind {
        case .line, .arrow: e.points = [p, p]
        case .freehand: e.points = [p]
        case .counter:
            // One click places a numbered marker.
            let d = style.fontSize * 2 * doc.pixelScale
            e.frame = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            doc.add(e)
            setSelection([e.id])
            return
        case .speechBubble:
            e.frame = CGRect(origin: p, size: .zero)
            e.points = [p]
        default:
            e.frame = CGRect(origin: p, size: .zero)
        }
        setSelection([])
        doc.beginLiveChange()
        doc.mutateLive { $0.elements.append(e) }
        drag = .creating(e.id, start: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = docPoint(event)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .creating(let id, let start):
            let s = doc.pixelScale
            doc.mutateLive { st in
                guard let i = st.elements.firstIndex(where: { $0.id == id }) else { return }
                var e = st.elements[i]
                switch e.kind {
                case .line, .arrow:
                    e.points[1] = shift ? Geometry.snap45(from: start, to: p) : p
                case .freehand:
                    if let last = e.points.last, last.distance(to: p) * zoom >= 1 { e.points.append(p) }
                case .speechBubble:
                    e.frame = CGRect(corner: start, shift ? Geometry.squareCorner(from: start, to: p) : p)
                    e.points = [CGPoint(x: e.frame.minX + e.frame.width * 0.25,
                                        y: e.frame.maxY + max(20 * s, e.frame.height * 0.5))]
                default:
                    e.frame = CGRect(corner: start, shift ? Geometry.squareCorner(from: start, to: p) : p)
                }
                st.elements[i] = e
            }
        case .moving(let start, let originals):
            var d = p - start
            if shift { if abs(d.x) > abs(d.y) { d.y = 0 } else { d.x = 0 } }
            doc.mutateLive { st in
                for i in st.elements.indices {
                    if var e = originals[st.elements[i].id] { e.move(by: d); st.elements[i] = e }
                }
            }
        case .resizing(let id, let h, let original):
            var target = p
            if shift, case .point(let idx) = h, original.points.count == 2 {
                target = Geometry.snap45(from: original.points[1 - idx], to: p)
            }
            let s = doc.pixelScale
            doc.mutateLive { st in
                guard let i = st.elements.firstIndex(where: { $0.id == id }) else { return }
                // From the mouse-down element, never the previous event's frame: narrowing grows a
                // text box so no text is hidden, and that growth must go away again on widening.
                st.elements[i] = Renderer.resizedFittingText(original, h, to: target, pixelScale: s,
                                                             canvasTop: st.canvasRect.minY)
            }
        case .rubberBand(let start, _):
            drag = .rubberBand(start: start, current: p)
            needsDisplay = true
        case .cropping(let start):
            guard tool == .crop else { break }
            let r = CGRect(corner: start, p).intersection(doc.state.canvasRect)
            cropRect = r.isNull ? nil : r
            delegate?.canvasCropChanged()
            needsDisplay = true
        case .none:
            break
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        finishDrag(shift: event.modifierFlags.contains(.shift))
    }

    /// Ends the current drag the way a mouse-up would. Safe to call when nothing is dragging.
    private func finishDrag(shift: Bool) {
        let ending = drag
        // Reset first: finishing can start a text edit, which must not see a drag in progress.
        drag = .none
        switch ending {
        case .creating(let id, _):
            finishCreating(id)
        case .moving, .resizing:
            doc.endLiveChange()
        case .rubberBand(let a, let b):
            let r = CGRect(corner: a, b)
            let v = viewRect(r)
            // A plain click on empty space already deselected in mouseDown. Its zero-size "band"
            // would still intersect the bounding box of a diagonal arrow it doesn't touch.
            if max(v.width, v.height) >= 3 {
                let hits = Set(doc.state.elements.filter { $0.bounds.insetBy(dx: -1, dy: -1).intersects(r) }.map(\.id))
                setSelection(shift ? selection.union(hits) : hits)
            }
        case .cropping:
            if let c = cropRect, c.width < 2 || c.height < 2 { cropRect = nil }
            delegate?.canvasCropChanged()
        case .none:
            return
        }
        fastBackground = nil
        fastID = nil
        layerBase = nil
        cache = nil
        needsDisplay = true
    }

    private func finishCreating(_ id: UUID) {
        guard let e = doc.element(id) else { doc.cancelLiveChange(); return }
        let s = doc.pixelScale
        var tooSmall = false
        switch e.kind {
        case .line, .arrow: tooSmall = e.points[0].distance(to: e.points[1]) < 3
        case .freehand: tooSmall = false
        case .text, .speechBubble:
            let fixed = Self.usableTextFrame(e, pixelScale: s)
            if fixed != e { doc.mutateLive { st in if let i = st.elements.firstIndex(where: { $0.id == id }) { st.elements[i] = fixed } } }
        default: tooSmall = e.frame.width < 3 || e.frame.height < 3
        }
        if tooSmall {
            doc.cancelLiveChange()
            return
        }
        setSelection([id])
        if e.kind.hasText {
            // The live change stays open until the typing ends (endTextEdit).
            beginTextEdit(id)
            newTextID = id
            return
        }
        doc.endLiveChange()
    }

    /// A text box or bubble just drawn, made big enough to type in (thresholds in points). Only the
    /// side that is too small takes its default, so a long thin caption drag keeps its width and a
    /// tall narrow bubble its height. A click (both sides small) gets the whole default box.
    static func usableTextFrame(_ e: Element, pixelScale s: CGFloat) -> Element {
        let isText = e.kind == .text
        let narrow = e.frame.width < (isText ? 40 : 60) * s, flat = e.frame.height < 12 * s
        guard narrow || flat else { return e }
        var out = e
        let o = e.frame.origin
        let w = narrow ? (isText ? 240 : 200) * s : e.frame.width
        let h = flat ? (isText ? e.style.fontSize * 2.4 : 80) * s : e.frame.height
        out.frame = CGRect(x: o.x, y: o.y, width: w, height: h)
        if !isText {
            // The tail goes below the new body, placed the way a drag places it (a click keeps
            // the old fixed default).
            out.points = [narrow && flat ? CGPoint(x: o.x + 50 * s, y: o.y + 130 * s)
                          : CGPoint(x: o.x + w * 0.25, y: o.y + h + max(20 * s, h * 0.5))]
        }
        return out
    }

    // MARK: Trackpad zoom

    /// 5% to 800% of actual size (actual size = one image pixel per screen pixel).
    private var zoomRange: ClosedRange<CGFloat> {
        let actual = 1 / (window?.backingScaleFactor ?? 2)
        return (actual * 0.05)...(actual * 8)
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    /// Two-finger double-tap: toggles between actual size and fit, like Preview.
    override func smartMagnify(with event: NSEvent) { delegate?.canvasSmartZoom() }

    /// Zooms while keeping the picture point under `viewPoint` (the fingers) where it is on screen.
    /// We zoom ourselves instead of using NSScrollView magnification, because that would just stretch
    /// the drawn bitmap (blurry) and break the view → picture coordinate maths used by every tool.
    func zoom(by factor: CGFloat, around viewPoint: CGPoint) {
        let docAnchor = CGPoint(x: viewPoint.x / zoom, y: viewPoint.y / zoom)
        let onScreen = CGPoint(x: viewPoint.x - visibleRect.minX, y: viewPoint.y - visibleRect.minY)
        let newZoom = min(max(zoom * factor, zoomRange.lowerBound), zoomRange.upperBound)
        guard newZoom != zoom else { return }
        zoom = newZoom
        scroll(CGPoint(x: docAnchor.x * newZoom - onScreen.x, y: docAnchor.y * newZoom - onScreen.y))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        let shift = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case 53: // Esc
            if tool == .crop, cropRect != nil { cropRect = nil; delegate?.canvasCropChanged(); needsDisplay = true }
            else if tool != .select { tool = .select }
            else { setSelection([]) }
            return
        case 51, 117: // Delete, Forward Delete
            deleteSelection(); return
        case 36, 76: // Return
            if tool == .crop { applyCrop(); return }
            if selection.count == 1, let e = selectedElements.first, e.kind.hasText { beginTextEdit(e.id) }
            return
        case 123...126 where mods.isEmpty: // arrows (a `where` on a comma list only guards the last value)
            nudge(keyCode: Int(event.keyCode), step: shift ? 10 : 1); return
        case 116: reorder(shift ? .front : .forward); return // Page Up
        case 121: reorder(shift ? .back : .backward); return // Page Down
        default: break
        }
        if mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased(), let t = Self.toolKeys[ch] {
            tool = t
            return
        }
        super.keyDown(with: event)
    }

    private func nudge(keyCode: Int, step: CGFloat) {
        guard !selection.isEmpty, !isDragging else { return }
        // Steps are in screen points, so a nudge looks the same at any zoom.
        let k = step / zoom
        let d: CGPoint
        switch keyCode {
        case 123: d = CGPoint(x: -k, y: 0)
        case 124: d = CGPoint(x: k, y: 0)
        case 125: d = CGPoint(x: 0, y: k)
        default: d = CGPoint(x: 0, y: -k)
        }
        let ids = selection
        doc.mutate { st in for i in st.elements.indices where ids.contains(st.elements[i].id) { st.elements[i].move(by: d) } }
    }

    // MARK: Operations used by the controller

    func deleteSelection() {
        // Keys and menu shortcuts still arrive while the mouse button is held; editing the
        // document under a drag would tangle its undo history.
        guard !selection.isEmpty, !isDragging else { return }
        doc.remove(selection)
        setSelection([])
    }

    func selectAll() {
        tool = .select
        setSelection(Set(doc.state.elements.map(\.id)))
    }

    func reorder(_ z: EditorDocument.ZOrder) {
        guard !selection.isEmpty, !isDragging else { return }
        doc.reorder(selection, z)
    }

    func duplicateSelection() {
        guard !selection.isEmpty, !isDragging else { return }
        setSelection(doc.duplicate(selection, offset: 10 * doc.pixelScale))
    }

    func applyCrop() {
        guard let c = cropRect else { return }
        cropRect = nil
        doc.crop(to: c)
        tool = .select
        delegate?.canvasCropChanged()
    }

    func cancelCrop() {
        cropRect = nil
        tool = .select
        delegate?.canvasCropChanged()
    }

    func setCropRect(_ r: CGRect?) {
        cropRect = r
        delegate?.canvasCropChanged()
        needsDisplay = true
    }

    /// Applies a style tweak to the selected elements (only those whose kind matches)
    /// as one undo step. Text boxes grow to fit a bigger font; counters take their size from it.
    /// `sizesCounters`: the change comes from the counter Size control, so counters take the size
    /// even when their style already has it (a grip resize changes the frame, not the style).
    func applyStyleToSelection(matching kinds: (ElementKind) -> Bool = { _ in true }, sizesCounters: Bool = false,
                               _ change: (inout ElementStyle) -> Void) {
        let ids = selection.filter { id in doc.element(id).map { kinds($0.kind) } ?? false }
        guard !ids.isEmpty else { return }
        let s = doc.pixelScale
        let body: (inout DocState) -> Void = { st in
            for i in st.elements.indices where ids.contains(st.elements[i].id) {
                var e = st.elements[i]
                let before = e.style
                change(&e.style)
                if e.kind == .counter, e.style.fontSize != before.fontSize || sizesCounters {
                    let d = e.style.fontSize * 2 * s
                    e.frame = CGRect(x: e.frame.midX - d / 2, y: e.frame.midY - d / 2, width: d, height: d)
                }
                if e.kind.hasText { e = Renderer.fittingText(e, pixelScale: s) }
                st.elements[i] = e
            }
        }
        // While a just-created text box is being typed into, its creation is still one open
        // live change: fold the style tweak into it so create + style + type stays one step.
        if doc.isInLiveChange, !isDragging { doc.mutateLive(body) } else { doc.mutate(body) }
    }

    // MARK: Text editing

    private func textRect(_ e: Element) -> CGRect { Renderer.textRect(for: e, pixelScale: doc.pixelScale) }

    func beginTextEdit(_ id: UUID) {
        guard let e = doc.element(id), e.kind.hasText else { return }
        endTextEdit()
        editingID = id
        // Its own history per edit: on the window's shared manager, ⌘Z while typing went on to
        // undo typing in earlier, already committed boxes, and kept every old text view alive.
        textUndo = UndoManager()
        let tv = NSTextView(frame: viewRect(textRect(e)))
        tv.string = e.text
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.delegate = self
        addSubview(tv)
        textView = tv
        positionTextView()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        cache = nil
        needsDisplay = true
    }

    /// Lays the text overlay over the box in the element's current style. Runs on zoom, on
    /// every document change (a font/size/colour picked mid-typing) and on every keystroke.
    private func positionTextView() {
        guard let tv = textView, let id = editingID, let e = doc.element(id) else { return }
        let r = viewRect(textRect(e))
        tv.alignment = e.kind == .speechBubble ? .center : .left
        tv.font = Renderer.font(for: e.style, pixelScale: doc.pixelScale, sizeOverride: e.style.fontSize * doc.pixelScale * zoom)
        let color = NSColor(cgColor: e.style.stroke.cgColor) ?? .black
        tv.textColor = color
        tv.insertionPointColor = color
        // Size the overlay with the renderer's own measurement, so what you see while typing is
        // exactly the box that gets committed (endTextEdit grows the element the same way).
        let need = Renderer.textHeight(tv.string, style: e.style, pixelScale: doc.pixelScale,
                                       width: textRect(e).width, center: e.kind == .speechBubble) * zoom
        // The renderer centres bubble text vertically; do the same here so it doesn't jump on commit.
        let inset = e.kind == .speechBubble ? max(0, (r.height - need) / 2) : 0
        tv.textContainerInset = NSSize(width: 0, height: inset)
        tv.minSize = r.size
        tv.maxSize = NSSize(width: r.width, height: .greatestFiniteMagnitude)
        tv.frame = CGRect(x: r.minX, y: r.minY, width: r.width, height: max(r.height, need + 2 * inset))
    }

    func textDidChange(_ notification: Notification) { positionTextView() }

    func endTextEdit(commit: Bool = true) {
        guard let id = editingID, let tv = textView else { return }
        let text = tv.string
        // Still the open creation step of a box made by the last click (see finishCreating)?
        let isNew = newTextID == id && doc.isInLiveChange
        newTextID = nil
        editingID = nil
        textView = nil
        tv.removeFromSuperview()
        textUndo?.removeAllActions()
        textUndo = nil
        if commit, let e = doc.element(id) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, e.kind == .text {
                // A new box left empty leaves no trace in the history; emptying an old one deletes it.
                if isNew { doc.cancelLiveChange() } else { doc.remove([id]) }
            } else {
                var typed = e
                typed.text = text
                // Grow the box to fit every line, in the same step as the text itself.
                let fitted = Renderer.fittingText(typed, pixelScale: doc.pixelScale)
                let frame = fitted.frame
                if isNew {
                    doc.mutateLive { st in
                        guard let i = st.elements.firstIndex(where: { $0.id == id }) else { return }
                        st.elements[i].text = text
                        st.elements[i].frame = frame
                        st.elements[i].points = fitted.points
                    }
                    doc.endLiveChange()
                } else if text != e.text || frame != e.frame {
                    doc.update(id) { $0.text = text; $0.frame = frame; $0.points = fitted.points }
                }
            }
        } else if isNew {
            doc.endLiveChange()
        }
        cache = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    var isEditingText: Bool { editingID != nil }
    var activeTextView: NSTextView? { textView }
    /// What ⌘Z / ⇧⌘Z act on while typing.
    var activeTextUndoManager: UndoManager? { textView == nil ? nil : textUndo }

    func undoManager(for view: NSTextView) -> UndoManager? { textUndo }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        // Esc or ⌘↩ finishes the text; plain Return makes a new line.
        if sel == #selector(NSResponder.cancelOperation(_:)) || sel == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            endTextEdit()
            return true
        }
        return false
    }
}

/// Keeps a small picture centred in the editor instead of stuck in the corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}
