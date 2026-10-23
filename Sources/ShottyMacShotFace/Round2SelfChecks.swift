import AppKit
import ShottyCore

/// Checks for the review round 2 fixes (`--selftest`). Same rules as EditorSelfChecks: no window
/// or sheet on screen, no files, no clipboard, no saved settings touched.
enum Round2SelfChecks {
    @MainActor
    static func run(check: (Bool, String) -> Void) {
        resizeKeepsTextVisible(check)
        bubbleKeepsTail(check)
        tinyDraggedTextBox(check)
        fontAndCounterSizeStayApart(check)
        clipboardKeepsRetinaScale(check)
        overlayChecks(check)
    }

    typealias E = EditorSelfChecks

    @MainActor
    static func typeNewBox(_ c: CanvasView, at p: CGPoint, _ text: String) {
        E.click(c, p)
        c.activeTextView?.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        c.endTextEdit()
    }

    static func fits(_ e: Element, _ s: CGFloat) -> (Bool, Int, Int) {
        let inner = Renderer.textRect(for: e, pixelScale: s)
        let need = Renderer.textHeight(e.text, style: e.style, pixelScale: s, width: inner.width, center: e.kind == .speechBubble)
        return (inner.height + 0.5 >= need, Int(inner.height), Int(need))
    }

    // CE-R2-1: narrowing a text box with its grip keeps all text visible (live, during the drag).
    @MainActor
    static func resizeKeepsTextVisible(_ check: (Bool, String) -> Void) {
        let ed = E.editor()
        let c = ed.canvas, doc = ed.doc, s = doc.pixelScale
        c.tool = .draw(.text)
        typeNewBox(c, at: CGPoint(x: 100, y: 100), "A sentence that is long enough to need two lines")
        guard let box = doc.state.elements.last, box.kind == .text else { check(false, "R2: text box created"); return }
        c.tool = .select
        c.setSelection([box.id])
        let grip = Grip.right.position(in: box.frame)
        let target = CGPoint(x: box.frame.minX + box.frame.width * 0.4, y: grip.y)
        E.mouse(c, .leftMouseDown, grip)
        E.mouse(c, .leftMouseDragged, target)
        let mid = doc.element(box.id).map { fits($0, s) }
        E.mouse(c, .leftMouseUp, target)
        guard let after = doc.element(box.id) else { check(false, "R2: box still there"); return }
        let f = fits(after, s)
        check(mid?.0 == true && f.0 && after.frame.width < box.frame.width * 0.5,
              "CE-R2-1: narrowing a text box grows it so no text is hidden (\(Int(box.frame.width))→\(Int(after.frame.width)) px wide, inner \(f.1) ≥ need \(f.2), also during the drag)")
        doc.undo()
        check(doc.element(box.id)?.frame == box.frame, "CE-R2-1: the resize (with its growth) is one undo step")
    }

    // CE-R2-2: a bubble that grows to fit many lines keeps its tail.
    @MainActor
    static func bubbleKeepsTail(_ check: (Bool, String) -> Void) {
        let ed = E.editor()
        let c = ed.canvas, doc = ed.doc, s = doc.pixelScale
        c.tool = .draw(.speechBubble)
        typeNewBox(c, at: CGPoint(x: 200, y: 100), (1...8).map { "line \($0)" }.joined(separator: "\n"))
        guard let b = doc.state.elements.last, b.kind == .speechBubble, let tip = b.points.first else {
            check(false, "R2: bubble created"); return
        }
        let path = Renderer.bubblePath(frame: b.frame, tip: tip, pixelScale: s)
        check(fits(b, s).0 && tip.y > b.frame.maxY + 20 * s - 0.5 && path.boundingBox.maxY > b.frame.maxY + 1,
              "CE-R2-2: an 8-line bubble keeps its tail (tip \(Int(tip.y - b.frame.maxY)) px below the body, drawn)")
    }

    // CE-R2-3: a tiny accidental drag with the text tool still gives a usable box.
    @MainActor
    static func tinyDraggedTextBox(_ check: (Bool, String) -> Void) {
        let ed = E.editor()
        let c = ed.canvas, doc = ed.doc, s = doc.pixelScale
        c.tool = .draw(.text)
        E.drag(c, CGPoint(x: 100, y: 100), CGPoint(x: 114, y: 130))
        let tv = c.activeTextView?.frame
        c.activeTextView?.insertText("Hello world", replacementRange: NSRange(location: 0, length: 0))
        c.endTextEdit()
        guard let e = doc.state.elements.last, e.kind == .text else { check(false, "R2: tiny box created"); return }
        let inner = Renderer.textRect(for: e, pixelScale: s)
        check((tv.map { $0.minX.isFinite && $0.width > 10 } ?? false) && !inner.isNull && e.frame.width >= 40 * s && e.frame.height < 100 * s,
              "CE-R2-3: a 14×30 px drag gets a normal text box (overlay at \(Int(tv?.minX ?? -1)), box \(Int(e.frame.width))×\(Int(e.frame.height)) px)")
        var narrow = Element(kind: .text, frame: CGRect(x: 0, y: 0, width: 6, height: 6))
        narrow.text = "x"
        check(!Renderer.textRect(for: narrow, pixelScale: 2).isNull, "CE-R2-3: the text rect of a very small box is never null")
    }

    // CE-R2-4: font size and counter size don't leak into each other in a mixed selection.
    @MainActor
    static func fontAndCounterSizeStayApart(_ check: (Bool, String) -> Void) {
        let ed = E.editor()
        let c = ed.canvas, doc = ed.doc
        c.tool = .draw(.counter)
        E.click(c, CGPoint(x: 500, y: 500))
        guard let counter = doc.state.elements.last, counter.kind == .counter else { check(false, "R2: counter"); return }
        c.tool = .draw(.text)
        typeNewBox(c, at: CGPoint(x: 100, y: 100), "Some text")
        guard let text = doc.state.elements.last, text.kind == .text else { check(false, "R2: text"); return }
        c.tool = .select
        c.setSelection([counter.id, text.id])
        ed.fontSizeChanged(E.popup(EditorWindowController.fontSizes.map { "\(Int($0))" },
                                   EditorWindowController.fontSizes.firstIndex(of: 48)!))
        check(doc.element(text.id)?.style.fontSize == 48 && doc.element(counter.id)?.frame == counter.frame
              && ed.style(for: .counter).fontSize == counter.style.fontSize,
              "CE-R2-4: font size 48 on a mixed selection changes the text, not the counter or the counter tool's size")
        ed.counterSizeChanged(E.popup(EditorWindowController.counterSizes.map { "\(Int($0))" },
                                      EditorWindowController.counterSizes.firstIndex(of: 48)!))
        check(doc.element(text.id)?.style.fontSize == 48 && abs((doc.element(counter.id)?.frame.width ?? 0) - 48 * doc.pixelScale) < 0.01,
              "CE-R2-4: counter Size changes the counter, not the text's font")
    }

    // CA-R2-8: a Retina image copied by the app reopens at 2x.
    @MainActor
    static func clipboardKeepsRetinaScale(_ check: (Bool, String) -> Void) {
        let pb = NSPasteboard(name: NSPasteboard.Name("shotty-selftest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let img = SelfTest.sampleImage(width: 400, height: 200, scale: 2)
        Output.copyToClipboard(img, pixelScale: 2, to: pb)
        let got = Output.imageFromClipboardWithScale(pb)
        check(got?.scale == 2 && got?.image.width == 400, "CA-R2-8: a 2x copy reopens as 2x (scale \(got?.scale ?? 0), \(got?.image.width ?? 0) px)")
    }

    // CA-R2-2, -3, -4, -5: overlay behaviour.
    @MainActor
    static func overlayChecks(_ check: (Bool, String) -> Void) {
        let img = SelfTest.sampleImage(width: 1600, height: 1000, scale: 2)
        let win = WindowInfo(windowID: 1, frame: CGRect(x: 100, y: 80, width: 520, height: 320), title: "W", appName: "A", scWindow: nil)
        let snap = ScreenSnapshot(image: img, frame: CGRect(x: 0, y: 0, width: 800, height: 500), scale: 2, displays: [], windows: [win])

        // CA-R2-3: Space mid-press in window mode, then release outside: no capture.
        let o = SelectionOverlay(snapshot: snap, mode: .window, showMagnifier: false)
        var outcome: SelectionOverlay.Outcome?
        // location is Cocoa (y-up): this is global (300, 200), inside the window.
        let inside = CGPoint(x: 300, y: (NSScreen.screens.first?.frame.height ?? 0) - 200)
        o.pointer = .init(warp: { _ in }, follow: { _ in }, setHidden: { _ in },
                          location: { inside }, modifiers: { [] })
        o.attach { outcome = $0 }
        o.mouseMoved(nil)
        check(o.hovered?.windowID == 1, "CA-R2-3 setup: the window is hovered before the press")
        o.mouseDown(nil)
        o.keyDown(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                   isARepeat: false, keyCode: 49)!)
        o.mouseUp(nil)
        let captured: Bool = { if case .none = outcome { return false }; return true }()
        check(!captured, "CA-R2-3: Space during a press, then release: nothing captured")

        // CA-R2-2: hotkey modifiers released while another app was active → the first ⇧ press works.
        var mods: NSEvent.ModifierFlags = [.control, .shift]
        let p = SelectionOverlay(snapshot: snap, mode: .region, showMagnifier: false)
        p.pointer = .init(warp: { _ in }, follow: { _ in }, setHidden: { _ in },
                          location: { CGPoint(x: 300, y: 200) }, modifiers: { mods })
        p.attach { _ in }
        mods = [] // released, but the flagsChanged went to the previous app
        p.mouseMoved(nil)
        mods = [.shift]
        p.flagsChanged(flags(.shift))
        check(p.isPrecise, "CA-R2-2: first ⇧ press after a missed modifier release turns precision on")
        p.flagsChanged(flags([]))
        check(!p.isPrecise, "CA-R2-2: ⇧ release turns it off again")

        // CA-R2-4 + -5: views for two screens; a drag on A must clear B's hover box, and layers are 2x.
        let q = SelectionOverlay(snapshot: snap, mode: .region, showMagnifier: false)
        q.pointer = .init(warp: { _ in }, follow: { _ in }, setHidden: { _ in },
                          location: { CGPoint(x: 300, y: 200) }, modifiers: { [] })
        let vB = SelectionDrawView(overlay: q, globalRect: CGRect(x: 400, y: 0, width: 400, height: 500),
                                   frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        q.hovered = win
        q.cursor = CGPoint(x: 300, y: 200)
        vB.refresh()
        let before = vB.drawnState?.hovered
        q.dragStart = CGPoint(x: 150, y: 150)
        vB.refresh()
        check(before == 1 && vB.drawnState?.hovered == nil, "CA-R2-4: starting a drag clears the hover box on the other screen too")

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let dv = SelectionDimView(globalRect: CGRect(x: 0, y: 0, width: 200, height: 200), frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        w.contentView = dv
        dv.viewDidChangeBackingProperties()
        check(dv.dim.contentsScale == w.backingScaleFactor && dv.border.contentsScale == w.backingScaleFactor,
              "CA-R2-5: dim/border layers render at the screen's scale (\(dv.dim.contentsScale))")
    }

    static func flags(_ f: NSEvent.ModifierFlags) -> NSEvent {
        let cg = CGEvent(source: nil)!
        cg.type = .flagsChanged
        cg.flags = CGEventFlags(rawValue: UInt64(f.rawValue))
        return NSEvent(cgEvent: cg)!
    }
}
