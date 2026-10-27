import AppKit
import ShottyCore

/// Checks for the review round 3 editor fixes (`--selftest`). Same rules as EditorSelfChecks: no
/// window or sheet on screen, no files, no real clipboard, no saved settings touched.
enum Round3EditorChecks {
    @MainActor
    static func run(check: (Bool, String) -> Void, note: (String) -> Void) {
        resizeIsReversible(check)
        topGripGrowsUpwards(check)
        bubbleTailDoesNotDrift(check)
        squashedBoxKeepsLastLine(check)
        thinDragsKeepTheirSize(check)
        counterSizeAfterGripResize(check)
        textUndoStaysInItsBox(check)
        pasteKeepsImageScale(check, note)
    }

    typealias E = EditorSelfChecks
    typealias R2 = Round2SelfChecks

    static func r(_ f: CGRect) -> String { "(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))" }

    /// Presses on `grip` of the (selected) element and moves the pointer through `path`, then releases.
    @MainActor
    static func gripDrag(_ c: CanvasView, from grip: CGPoint, through path: [CGPoint]) {
        E.mouse(c, .leftMouseDown, grip)
        for p in path { E.mouse(c, .leftMouseDragged, p) }
        E.mouse(c, .leftMouseUp, path.last ?? grip)
    }

    /// Frames equal within a hundredth of a pixel (the events go through view coordinates).
    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    static func steps(_ a: CGPoint, _ b: CGPoint, _ n: Int) -> [CGPoint] {
        (1...n).map { i in
            guard i < n else { return b }
            let t = CGFloat(i) / CGFloat(n)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    @MainActor
    static func newBox(_ ed: EditorWindowController, _ kind: ElementKind, at p: CGPoint, _ text: String) -> Element? {
        ed.canvas.tool = .draw(kind)
        R2.typeNewBox(ed.canvas, at: p, text)
        guard let e = ed.doc.state.elements.last, e.kind == kind else { return nil }
        ed.canvas.tool = .select
        ed.canvas.setSelection([e.id])
        return e
    }

    // CORE_EDITOR-R3-1: narrowing and widening back in one drag leaves the box as it started.
    @MainActor
    static func resizeIsReversible(_ check: (Bool, String) -> Void) {
        let ed = E.editor()
        let c = ed.canvas, doc = ed.doc
        guard let box = newBox(ed, .text, at: CGPoint(x: 100, y: 100), "A sentence that is long enough to need two lines")
        else { check(false, "R3-1: text box created"); return }
        let grip = Grip.right.position(in: box.frame)
        let narrow = CGPoint(x: box.frame.minX + 30, y: grip.y)
        E.mouse(c, .leftMouseDown, grip)
        for p in steps(grip, narrow, 10) { E.mouse(c, .leftMouseDragged, p) }
        let narrowest = doc.element(box.id)?.frame ?? .null
        for p in steps(narrow, grip, 10) { E.mouse(c, .leftMouseDragged, p) }
        E.mouse(c, .leftMouseUp, grip)
        let after = doc.element(box.id)?.frame ?? .null
        check(narrowest.height > box.frame.height * 2 && same(after, box.frame),
              "CORE_EDITOR-R3-1: narrow then widen back in one drag: \(r(box.frame)) → narrowest \(r(narrowest)) → \(r(after)) (back to the start)")
    }

    // CORE_EDITOR-R3-1: the top grip squashing a box grows it upwards; moving back restores it.
    @MainActor
    static func topGripGrowsUpwards(_ check: (Bool, String) -> Void) {
        let ed = E.editor()
        let c = ed.canvas, doc = ed.doc, s = doc.pixelScale
        guard let box = newBox(ed, .text, at: CGPoint(x: 100, y: 100), "Hello") else { check(false, "R3-1: Hello box"); return }
        let grip = Grip.top.position(in: box.frame)
        let down = CGPoint(x: grip.x, y: grip.y + box.frame.height * 0.8) // squash, not past the bottom
        E.mouse(c, .leftMouseDown, grip)
        for p in steps(grip, down, 10) { E.mouse(c, .leftMouseDragged, p) }
        let mid = doc.element(box.id)?.frame ?? .null
        let midFits = doc.element(box.id).map { R2.fits($0, s).0 } ?? false
        for p in steps(down, grip, 10) { E.mouse(c, .leftMouseDragged, p) }
        E.mouse(c, .leftMouseUp, grip)
        let after = doc.element(box.id)?.frame ?? .null
        check(abs(mid.maxY - box.frame.maxY) < 0.5 && midFits && same(after, box.frame),
              "CORE_EDITOR-R3-1: top grip squashing the box keeps the bottom edge (\(r(box.frame)) → \(r(mid)), text fits) and back gives \(r(after))")
    }

    // CORE_EDITOR-R3-2: pulling a bubble's bottom up past its text over many events doesn't move the tail.
    @MainActor
    static func bubbleTailDoesNotDrift(_ check: (Bool, String) -> Void) {
        let ed = E.editor()
        let c = ed.canvas, doc = ed.doc
        ed.canvas.tool = .draw(.speechBubble)
        E.drag(c, CGPoint(x: 200, y: 100), CGPoint(x: 600, y: 260))
        c.activeTextView?.insertText("one\ntwo\nthree", replacementRange: NSRange(location: 0, length: 0))
        c.endTextEdit()
        guard var b = doc.state.elements.last, b.kind == .speechBubble else { check(false, "R3-2: bubble"); return }
        c.tool = .select
        // Tip 100 px below the body, like the reviewer's probe.
        doc.update(b.id) { $0.points = [CGPoint(x: b.frame.minX + 100, y: b.frame.maxY + 100)] }
        b = doc.element(b.id)!
        c.setSelection([b.id])
        let tip0 = b.points[0]
        let g = Grip.bottom.position(in: b.frame)
        let up = CGPoint(x: g.x, y: g.y - 60)
        gripDrag(c, from: g, through: steps(g, up, 20))
        let a = doc.element(b.id)!
        check(abs(a.points[0].y - tip0.y) < 0.5 && R2.fits(a, doc.pixelScale).0,
              "CORE_EDITOR-R3-2: bottom grip up 60 px in 20 events: tip.y \(Int(tip0.y)) → \(Int(a.points[0].y)), body \(r(b.frame)) → \(r(a.frame))")
        doc.undo()
        let g2 = Grip.bottomRight.position(in: b.frame)
        let to = CGPoint(x: g2.x - 100, y: g2.y - 100)
        gripDrag(c, from: g2, through: steps(g2, to, 10))
        let many = doc.element(b.id)!
        doc.undo()
        gripDrag(c, from: g2, through: [to])
        let one = doc.element(b.id)!
        check(abs(many.points[0].y - one.points[0].y) < 0.01 && same(many.frame, one.frame) && abs(many.points[0].y - tip0.y) < 0.5,
              "CORE_EDITOR-R3-2: bottom-right grip, 10 events = 1 event (tipBelow \(Int(many.points[0].y - many.frame.maxY)) vs \(Int(one.points[0].y - one.frame.maxY)))")
    }

    // CORE_EDITOR-R3-3: dragging the bottom grip up to the top edge still shows every line.
    @MainActor
    static func squashedBoxKeepsLastLine(_ check: (Bool, String) -> Void) {
        for kind in [ElementKind.text, .speechBubble] {
            let ed = E.editor()
            let c = ed.canvas, doc = ed.doc
            guard let e = newBox(ed, kind, at: CGPoint(x: 100, y: 100), "one\ntwo\nthree") else { check(false, "R3-3: \(kind)"); return }
            let g = Grip.bottom.position(in: e.frame)
            gripDrag(c, from: g, through: [CGPoint(x: g.x, y: e.frame.minY + 1)])
            let a = doc.element(e.id)!
            let f = R2.fits(a, doc.pixelScale)
            check(f.0, "CORE_EDITOR-R3-3: \(kind) squashed with the bottom grip: \(r(e.frame)) → \(r(a.frame)), inner \(f.1) ≥ need \(f.2)")
        }
    }

    // CORE_EDITOR-R3-4: a wide thin text drag keeps its width; a tall narrow bubble drag its height.
    @MainActor
    static func thinDragsKeepTheirSize(_ check: (Bool, String) -> Void) {
        let ed = E.editor(width: 1600, height: 1200)
        let c = ed.canvas, doc = ed.doc, s = doc.pixelScale
        c.tool = .draw(.text)
        E.drag(c, CGPoint(x: 100, y: 100), CGPoint(x: 1100, y: 120))
        c.activeTextView?.insertText("A caption along the picture", replacementRange: NSRange(location: 0, length: 0))
        c.endTextEdit()
        let t = doc.state.elements.last
        check(t?.kind == .text && t?.frame.width == 1000 && (t.map { R2.fits($0, s).0 } ?? false),
              "CORE_EDITOR-R3-4: a 1000×20 px text drag keeps its width (\(r(t?.frame ?? .null)))")
        c.tool = .draw(.speechBubble)
        E.drag(c, CGPoint(x: 100, y: 300), CGPoint(x: 210, y: 700))
        c.activeTextView?.insertText("Hi", replacementRange: NSRange(location: 0, length: 0))
        c.endTextEdit()
        let b = doc.state.elements.last
        let tipBelow = (b?.points.first?.y ?? 0) > (b?.frame.maxY ?? .infinity)
        check(b?.kind == .speechBubble && b?.frame.minY == 300 && b?.frame.height == 400 && (b?.frame.width ?? 0) >= 60 * s && tipBelow,
              "CORE_EDITOR-R3-4: a 110×400 px bubble drag keeps its height and place (\(r(b?.frame ?? .null)), tail below: \(tipBelow))")
        c.tool = .draw(.text)
        E.click(c, CGPoint(x: 100, y: 900))
        c.activeTextView?.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        c.endTextEdit()
        let k = doc.state.elements.last
        check(k?.frame.width == 240 * s, "CORE_EDITOR-R3-4: a click still gets the default 240 pt text box (\(r(k?.frame ?? .null)))")
    }

    // CORE_EDITOR-R3-5: Size picks the counter's own style size after a grip resize, and it applies.
    @MainActor
    static func counterSizeAfterGripResize(_ check: (Bool, String) -> Void) {
        let ed = E.editor()
        let c = ed.canvas, doc = ed.doc, s = doc.pixelScale
        let sizes = EditorWindowController.counterSizes
        let i28 = sizes.firstIndex(of: 28)!
        c.tool = .draw(.counter)
        ed.counterSizeChanged(E.popup(sizes.map { "\(Int($0))" }, i28))
        E.click(c, CGPoint(x: 400, y: 400))
        guard let ctr = doc.state.elements.last, ctr.kind == .counter else { check(false, "R3-5: counter"); return }
        c.tool = .select
        c.setSelection([ctr.id])
        let g = Grip.bottomRight.position(in: ctr.frame)
        gripDrag(c, from: g, through: [CGPoint(x: g.x + 80, y: g.y + 80)])
        let big = doc.element(ctr.id)!.frame.width
        ed.counterSizeChanged(E.popup(sizes.map { "\(Int($0))" }, i28))
        let w = doc.element(ctr.id)!.frame.width
        doc.undo()
        let undone = doc.element(ctr.id)!.frame.width
        check(abs(w - 28 * s) < 0.5 && abs(undone - big) < 0.5 && big > w,
              "CORE_EDITOR-R3-5: counter placed at 28 pt, grip-resized to \(Int(big)) px, Size 28 → \(Int(w)) px (undo → \(Int(undone)))")
    }

    // CORE_EDITOR-R3-6: ⌘Z while typing undoes only this box's typing, not an earlier box's.
    @MainActor
    static func textUndoStaysInItsBox(_ check: (Bool, String) -> Void) {
        let ed = E.editor()
        let c = ed.canvas, doc = ed.doc
        c.tool = .draw(.text)
        E.click(c, CGPoint(x: 100, y: 100))
        let tv1 = c.activeTextView
        tv1?.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
        c.endTextEdit()
        E.click(c, CGPoint(x: 100, y: 500))
        c.activeTextView?.insertText("xyz", replacementRange: NSRange(location: 0, length: 0))
        ed.editorUndo(nil)
        let afterOne = c.activeTextView?.string ?? "?"
        ed.editorUndo(nil)
        ed.editorUndo(nil)
        let tv1Text = tv1?.string ?? "?"
        ed.editorRedo(nil)
        let redone = c.activeTextView?.string ?? "?"
        let windowKeepsOld = ed.window?.undoManager?.canUndo ?? false
        c.endTextEdit()
        let texts = doc.state.elements.map(\.text)
        check(afterOne == "" && tv1Text == "abc" && redone == "xyz" && !windowKeepsOld && texts == ["abc", "xyz"],
              "CORE_EDITOR-R3-6: undo while typing box 2 → '\(afterOne)', more undos leave box 1's view '\(tv1Text)', redo → '\(redone)', window manager holds old typing: \(windowKeepsOld), doc \(texts)")
    }

    // CORE_EDITOR-R3-7 / CAPTURE_APP-R3-3: pasted pictures come in at their own on-screen size.
    @MainActor
    static func pasteKeepsImageScale(_ check: (Bool, String) -> Void, _ note: (String) -> Void) {
        let pb = NSPasteboard(name: NSPasteboard.Name("shotty-selftest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let savedElements = ElementClipboard.elements
        ElementClipboard.elements = [] // so Paste reads the picture, not copied annotations
        defer { ElementClipboard.elements = savedElements }
        for (docScale, imgScale, expect) in [(CGFloat(2), CGFloat(1), CGFloat(400)), (1, 2, 100), (2, 2, 200)] {
            let ed = E.editor(scale: docScale)
            ed.pasteboardForTesting = pb
            Output.copyToClipboard(SelfTest.sampleImage(width: 200, height: 100, scale: imgScale), pixelScale: imgScale, to: pb)
            ed.paste(nil)
            let e = ed.doc.state.elements.last
            check(e?.kind == .image && abs((e?.frame.width ?? 0) - expect) < 0.5,
                  "CORE_EDITOR-R3-7/CAPTURE_APP-R3-3: 200 px @\(Int(imgScale))x pasted into a \(Int(docScale))x picture is \(Int(e?.frame.width ?? 0)) px wide (want \(Int(expect)))")
        }
        note("Insert Image from File uses the same insertImage(sourceScale:) with ImageExporter.loadForEditor's scale; its NSOpenPanel sheet can't run headless.")
    }
}
