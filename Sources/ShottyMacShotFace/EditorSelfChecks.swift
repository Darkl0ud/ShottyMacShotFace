import AppKit
import ShottyCore

/// Editor behaviour checks for `--selftest`, driven through the real CanvasView and
/// EditorWindowController with synthetic NSEvents. They never show a window or sheet, write a
/// file, touch the clipboard or change the user's saved tool styles (see the controller's
/// *ForTesting seams).
enum EditorSelfChecks {
    @MainActor
    static func run(check: (Bool, String) -> Void, note: (String) -> Void) {
        unsavedCapturePrompts(check)
        textBoxes(check)
        textOverlayFollowsStyle(check)
        toolSwitchDeselects(check)
        zoomPopupStaysTidy(check)
        noEditsMidDrag(check)
        clickNearDiagonalArrow(check)
        cropDoesNotLinger(check)
        filterDragIsLayered(check, note)
        counterSizeAndBorder(check)
    }

    // MARK: Helpers

    @MainActor
    final class Host: EditorHost {
        var closed = 0
        func editorDidClose(_ editor: EditorWindowController) { closed += 1 }
    }

    @MainActor
    static func editor(width: Int = 1200, height: Int = 800, scale: CGFloat = 2) -> EditorWindowController {
        let img = SelfTest.sampleImage(width: width, height: height, scale: scale)
        let ed = EditorWindowController(document: EditorDocument(image: img, pixelScale: scale, title: "check"))
        ed.toolStylesForTesting = [:]
        ed.savePromptResponder = { _ in .alertSecondButtonReturn } // Cancel, unless a check says otherwise
        ed.saveActionForTesting = { true }
        return ed
    }

    /// Sends a real mouse event to the canvas at a document point.
    @MainActor
    static func mouse(_ c: CanvasView, _ type: NSEvent.EventType, _ p: CGPoint, shift: Bool = false) {
        let win = c.convert(CGPoint(x: p.x * c.zoom, y: p.y * c.zoom), to: nil)
        guard let ev = NSEvent.mouseEvent(with: type, location: win, modifierFlags: shift ? [.shift] : [],
                                          timestamp: 0, windowNumber: c.window?.windowNumber ?? 0, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        switch type {
        case .leftMouseDown: c.mouseDown(with: ev)
        case .leftMouseDragged: c.mouseDragged(with: ev)
        default: c.mouseUp(with: ev)
        }
    }

    @MainActor
    static func click(_ c: CanvasView, _ p: CGPoint) { mouse(c, .leftMouseDown, p); mouse(c, .leftMouseUp, p) }

    @MainActor
    static func drag(_ c: CanvasView, _ a: CGPoint, _ b: CGPoint) {
        mouse(c, .leftMouseDown, a)
        mouse(c, .leftMouseDragged, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        mouse(c, .leftMouseDragged, b)
        mouse(c, .leftMouseUp, b)
    }

    @MainActor
    static func key(_ c: CanvasView, _ ch: String, keyCode: UInt16) {
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: c.window?.windowNumber ?? 0, context: nil, characters: ch,
                                        charactersIgnoringModifiers: ch, isARepeat: false, keyCode: keyCode) else { return }
        c.keyDown(with: ev)
    }

    /// A pop-up standing in for one of the property bar's, set to `index`.
    @MainActor
    static func popup(_ titles: [String], _ index: Int) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: titles)
        p.selectItem(at: index)
        return p
    }

    static func isBlue(_ c: NSColor?) -> Bool {
        guard let s = c?.usingColorSpace(.sRGB) else { return false }
        return s.blueComponent > 0.8 && s.redComponent < 0.2
    }

    // MARK: CORE_EDITOR-3 / C1

    @MainActor
    static func unsavedCapturePrompts(_ check: (Bool, String) -> Void) {
        let ed = editor()
        let host = Host()
        ed.host = host
        var prompts = 0
        ed.savePromptResponder = { _ in prompts += 1; return .alertSecondButtonReturn } // Cancel
        check(ed.hasUnsavedWork, "C1: a fresh, never-saved capture counts as unsaved work")
        check(ed.windowShouldClose(ed.window!) == false && prompts == 1 && host.closed == 0,
              "CORE_EDITOR-3: closing an un-annotated new capture asks first (prompts \(prompts)), Cancel keeps it")

        ed.doc.wasExported = true
        prompts = 0
        check(!ed.hasUnsavedWork && ed.windowShouldClose(ed.window!) && prompts == 0,
              "CORE_EDITOR-3: a capture already copied/saved closes without asking")
        ed.doc.add(Element(kind: .rectangle, frame: CGRect(x: 10, y: 10, width: 50, height: 50)))
        check(ed.hasUnsavedWork, "C1: an edit after exporting counts as unsaved work again")

        var result: Bool?
        ed.confirmDiscardForQuit { result = $0 }
        check(result == false && prompts == 1 && host.closed == 0, "C1: quit prompt, Cancel → done(false)")

        ed.savePromptResponder = { _ in .alertThirdButtonReturn } // Don't Save
        result = nil
        ed.confirmDiscardForQuit { result = $0 }
        check(result == true && host.closed == 0 && !ed.hasUnsavedWork,
              "C1: quit prompt, Don't Save → done(true), window not closed, no second prompt")

        ed.doc.add(Element(kind: .rectangle, frame: CGRect(x: 80, y: 10, width: 50, height: 50)))
        ed.savePromptResponder = { _ in .alertFirstButtonReturn } // Save
        var saves = 0
        ed.saveActionForTesting = { saves += 1; return true }
        result = nil
        ed.confirmDiscardForQuit { result = $0 }
        check(result == true && saves == 1 && !ed.hasUnsavedWork && ed.doc.wasExported && host.closed == 0,
              "C1: quit prompt, Save → saves, done(true), window not closed")
        ed.saveActionForTesting = { false }
        ed.doc.add(Element(kind: .rectangle, frame: CGRect(x: 150, y: 10, width: 50, height: 50)))
        result = nil
        ed.confirmDiscardForQuit { result = $0 }
        check(result == false, "C1: quit prompt, Save that fails → done(false)")
    }

    // MARK: CORE_EDITOR-1, -8

    @MainActor
    static func textBoxes(_ check: (Bool, String) -> Void) {
        let ed = editor()
        let c = ed.canvas, doc = ed.doc
        c.tool = .draw(.text)

        // Click, type nothing, finish: no element and no undo steps.
        let steps0 = doc.undoStack.count, count0 = doc.state.elements.count
        click(c, CGPoint(x: 100, y: 100))
        check(c.isEditingText, "text tool click starts typing")
        c.endTextEdit()
        check(doc.undoStack.count == steps0 && doc.state.elements.count == count0,
              "CORE_EDITOR-8: an empty new text box leaves no element and no undo steps (\(doc.undoStack.count - steps0) steps)")

        // Click, type two lines, finish: one undo step, and the box fits both lines.
        click(c, CGPoint(x: 100, y: 100))
        let text = "first line\nsecond line, which is long enough to wrap inside a 240 pt box"
        c.activeTextView?.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        let overlay = c.activeTextView?.frame.height ?? 0
        c.endTextEdit()
        guard let e = doc.state.elements.last, e.kind == .text, e.text == text else {
            check(false, "typed text box exists"); return
        }
        let s = doc.pixelScale
        let inner = Renderer.textRect(for: e, pixelScale: s)
        let need = Renderer.textHeight(e.text, style: e.style, pixelScale: s, width: inner.width)
        check(inner.height >= need, "CORE_EDITOR-1: the committed box fits all its text (\(Int(inner.height)) ≥ \(Int(need)) px)")
        check(overlay / c.zoom >= need - 1 && abs(overlay / c.zoom - inner.height) <= 2 * s,
              "CORE_EDITOR-1: the typing overlay grew with the text and matches the committed box (\(Int(overlay / c.zoom)) vs \(Int(inner.height)) px)")
        check(doc.undoStack.count == steps0 + 1, "CORE_EDITOR-8: create + type is one undo step (\(doc.undoStack.count - steps0))")
        doc.undo()
        check(!doc.state.elements.contains { $0.id == e.id }, "CORE_EDITOR-8: one undo removes the whole text box")

        // Bigger font on an existing box grows it too.
        doc.redo()
        c.tool = .select
        c.setSelection([e.id])
        ed.fontSizeChanged(popup(EditorWindowController.fontSizes.map { "\(Int($0))" },
                                 EditorWindowController.fontSizes.firstIndex(of: 48)!))
        if let big = doc.element(e.id) {
            let need48 = Renderer.textHeight(big.text, style: big.style, pixelScale: s,
                                             width: Renderer.textRect(for: big, pixelScale: s).width)
            check(big.style.fontSize == 48 && Renderer.textRect(for: big, pixelScale: s).height >= need48,
                  "CORE_EDITOR-1: a bigger font grows the selected text box (\(Int(e.frame.height)) → \(Int(big.frame.height)) px)")
        }
    }

    // MARK: CORE_EDITOR-9

    @MainActor
    static func textOverlayFollowsStyle(_ check: (Bool, String) -> Void) {
        let ed = editor()
        let c = ed.canvas, doc = ed.doc
        let id = doc.add(Element(kind: .text, frame: CGRect(x: 100, y: 100, width: 400, height: 80)))
        doc.update(id) { $0.text = "Hello" }
        c.tool = .draw(.text)
        click(c, CGPoint(x: 150, y: 120)) // clicking existing text with the text tool edits it
        check(c.editingID == id, "text tool click on a text box edits it")
        ed.fontSizeChanged(popup(EditorWindowController.fontSizes.map { "\(Int($0))" },
                                 EditorWindowController.fontSizes.firstIndex(of: 36)!))
        let want = 36 * doc.pixelScale * c.zoom
        let got = c.activeTextView?.font?.pointSize ?? 0
        check(abs(got - want) < 0.5, "CORE_EDITOR-9: the text overlay takes a new font size mid-typing (\(got) vs \(want))")
        let well = NSColorWell()
        well.color = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        ed.lineColorChanged(well)
        check(isBlue(c.activeTextView?.textColor), "CORE_EDITOR-9: the text overlay takes a new colour mid-typing")
        c.endTextEdit()

        // Speech bubble: the overlay text is vertically centred, as the renderer draws it.
        let bid = doc.add(Element(kind: .speechBubble, frame: CGRect(x: 600, y: 100, width: 400, height: 200),
                                  points: [CGPoint(x: 650, y: 400)]))
        doc.update(bid) { $0.text = "Hi" }
        c.tool = .select
        c.setSelection([bid])
        c.beginTextEdit(bid)
        if let tv = c.activeTextView, let b = doc.element(bid) {
            let box = Renderer.textRect(for: b, pixelScale: doc.pixelScale)
            let lineH = Renderer.textHeight("Hi", style: b.style, pixelScale: doc.pixelScale, width: box.width) * c.zoom
            let top = tv.frame.minY + tv.textContainerInset.height
            let expected = box.midY * c.zoom - lineH / 2
            check(abs(top - expected) < 3 * doc.pixelScale * c.zoom + 2,
                  "CORE_EDITOR-9: bubble overlay text is vertically centred (top \(Int(top)) vs \(Int(expected)) pt)")
        } else {
            check(false, "CORE_EDITOR-9: bubble edit opens an overlay")
        }
        c.endTextEdit()
    }

    // MARK: CORE_EDITOR-4

    @MainActor
    static func toolSwitchDeselects(_ check: (Bool, String) -> Void) {
        let ed = editor()
        let c = ed.canvas, doc = ed.doc
        c.tool = .draw(.rectangle)
        drag(c, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250))
        guard let rect = doc.state.elements.last, rect.kind == .rectangle else { check(false, "rectangle drawn"); return }
        check(c.selection == [rect.id], "a new shape stays selected")
        key(c, "a", keyCode: 0) // A = arrow tool
        check(c.tool == .draw(.arrow) && c.selection.isEmpty, "CORE_EDITOR-4: picking a drawing tool deselects")
        let i8 = EditorWindowController.thicknesses.firstIndex(of: 8)!
        ed.thicknessChanged(popup(EditorWindowController.thicknesses.map { "\(Int($0)) pt" }, i8))
        check(doc.element(rect.id)?.style.lineWidth == rect.style.lineWidth,
              "CORE_EDITOR-4: a property change for the arrow tool leaves the rectangle alone")
        check(ed.toolStylesForTesting?[.rectangle] == nil && ed.toolStylesForTesting?[.arrow]?.lineWidth == 8,
              "CORE_EDITOR-4: only the arrow tool's remembered style changes")
        // Even if a shape of another kind is selected (e.g. by code), it isn't restyled.
        c.setSelection([rect.id])
        ed.thicknessChanged(popup(EditorWindowController.thicknesses.map { "\(Int($0)) pt" }, 1))
        check(doc.element(rect.id)?.style.lineWidth == rect.style.lineWidth,
              "CORE_EDITOR-4: with a drawing tool, other kinds in the selection aren't restyled")
        // The shape just drawn with the tool does follow it.
        drag(c, CGPoint(x: 400, y: 100), CGPoint(x: 600, y: 300))
        if let arrow = doc.state.elements.last, arrow.kind == .arrow {
            ed.thicknessChanged(popup(EditorWindowController.thicknesses.map { "\(Int($0)) pt" }, i8))
            check(doc.element(arrow.id)?.style.lineWidth == 8, "CORE_EDITOR-4: the arrow just drawn takes the arrow tool's change")
        }
    }

    // MARK: CORE_EDITOR-5

    @MainActor
    static func zoomPopupStaysTidy(_ check: (Bool, String) -> Void) {
        let ed = editor(width: 3000, height: 2000)
        let p = ed.zoomPopupForTesting
        ed.zoomActual(nil)
        let before = p.numberOfItems
        for _ in 0..<6 { ed.canvas.zoom(by: 1.05, around: CGPoint(x: 200, y: 200)) }
        let zoom = ed.canvas.zoom
        check(p.numberOfItems == before, "CORE_EDITOR-5: pinching adds no zoom menu items (\(before) → \(p.numberOfItems))")
        check(p.selectedTag() == EditorWindowController.customZoomTag && p.titleOfSelectedItem?.hasSuffix("%") == true,
              "CORE_EDITOR-5: a non-preset zoom shows as \(p.titleOfSelectedItem ?? "?")")
        ed.zoomChosen(p)
        check(abs(ed.canvas.zoom - zoom) < 0.0001, "CORE_EDITOR-5: choosing the current-zoom item keeps the zoom (not Fit)")
        p.selectItem(withTag: EditorWindowController.zoomLevels.firstIndex(of: 1)!)
        ed.zoomChosen(p)
        check(abs(ed.canvas.zoom * (ed.window?.backingScaleFactor ?? 2) - 1) < 0.01 && p.numberOfItems == before,
              "CORE_EDITOR-5: presets still work by tag")
    }

    // MARK: CORE_EDITOR-7

    @MainActor
    static func noEditsMidDrag(_ check: (Bool, String) -> Void) {
        let ed = editor()
        let c = ed.canvas, doc = ed.doc
        let id = doc.add(Element(kind: .rectangle, frame: CGRect(x: 100, y: 100, width: 100, height: 100)))
        c.tool = .draw(.ellipse)
        mouse(c, .leftMouseDown, CGPoint(x: 400, y: 400))
        mouse(c, .leftMouseDragged, CGPoint(x: 500, y: 480))
        let undoItem = NSMenuItem(title: "Undo", action: #selector(EditorWindowController.editorUndo(_:)), keyEquivalent: "z")
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(EditorWindowController.delete(_:)), keyEquivalent: "")
        check(c.isDragging && !ed.validateMenuItem(undoItem) && !ed.validateMenuItem(deleteItem),
              "CORE_EDITOR-7: Undo and Delete are disabled while dragging")
        ed.editorUndo(nil) // the toolbar button isn't menu-validated
        check(doc.element(id) != nil, "CORE_EDITOR-7: Undo mid-drag does nothing")
        mouse(c, .leftMouseUp, CGPoint(x: 500, y: 480))
        doc.undo()
        doc.undo()
        check(doc.state.elements.isEmpty && !doc.canUndo, "CORE_EDITOR-7: every earlier step is still reachable by undo")
    }

    // MARK: CORE_EDITOR-10

    @MainActor
    static func clickNearDiagonalArrow(_ check: (Bool, String) -> Void) {
        let ed = editor()
        let c = ed.canvas, doc = ed.doc
        let id = doc.add(Element(kind: .arrow, points: [CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 500)]))
        c.tool = .select
        click(c, CGPoint(x: 420, y: 140)) // inside the bounding box, far from the shaft
        check(c.selection.isEmpty, "CORE_EDITOR-10: clicking empty space inside a diagonal arrow's box selects nothing")
        click(c, CGPoint(x: 300, y: 300))
        check(c.selection == [id], "clicking on the arrow still selects it")
        drag(c, CGPoint(x: 50, y: 50), CGPoint(x: 600, y: 200))
        check(c.selection == [id], "a real rubber band still selects what it touches")
    }

    // MARK: CORE_EDITOR-11

    @MainActor
    static func cropDoesNotLinger(_ check: (Bool, String) -> Void) {
        let ed = editor()
        let c = ed.canvas
        c.tool = .crop
        mouse(c, .leftMouseDown, CGPoint(x: 100, y: 100))
        mouse(c, .leftMouseDragged, CGPoint(x: 300, y: 300))
        key(c, "v", keyCode: 9) // V = Select, mid-drag
        mouse(c, .leftMouseDragged, CGPoint(x: 400, y: 400))
        check(c.tool == .select && c.cropRect == nil && !c.isDragging,
              "CORE_EDITOR-11: switching tools mid crop-drag leaves no crop rectangle in Select mode")
        mouse(c, .leftMouseUp, CGPoint(x: 400, y: 400))

        c.tool = .crop
        c.setCropRect(CGRect(x: 100, y: 100, width: 300, height: 200))
        ed.effectRotateCW(nil)
        check(c.cropRect == nil, "CORE_EDITOR-11: an effect clears a pending crop rectangle")
        c.setCropRect(CGRect(x: 100, y: 100, width: 300, height: 200))
        ed.doc.undo() // back to the unrotated size
        check(c.cropRect == nil, "CORE_EDITOR-11: a size change (undo of a rotate) clears it too")
    }

    // MARK: CORE_EDITOR-12

    @MainActor
    static func filterDragIsLayered(_ check: (Bool, String) -> Void, _ note: (String) -> Void) {
        let ed = editor(width: 5120, height: 2880)
        let c = ed.canvas, doc = ed.doc
        for i in 0..<10 {
            doc.add(Element(kind: .rectangle, frame: CGRect(x: 100 + i * 300, y: 2000, width: 250, height: 200)))
        }
        var top = UUID()
        for i in 0..<3 {
            var e = Element(kind: .obfuscate, frame: CGRect(x: 200 + i * 1500, y: 300, width: 1200, height: 900))
            e.style.obfuscateMode = .blur
            e.style.blurRadius = 20
            top = doc.add(e)
        }
        func ms(_ body: () -> Void) -> Double { let t = Date(); body(); return Date().timeIntervalSince(t) * 1000 }
        _ = c.renderer.flatten(doc.state) // warm-up
        let full = ms { _ = c.renderer.flatten(doc.state) }
        c.tool = .select
        c.setSelection([top])
        mouse(c, .leftMouseDown, CGPoint(x: 3800, y: 700))
        mouse(c, .leftMouseDragged, CGPoint(x: 3820, y: 710))
        _ = c.renderDragFrameForTesting() // builds the cached layer below
        mouse(c, .leftMouseDragged, CGPoint(x: 3840, y: 720))
        var frame: CGImage?
        let layered = ms { frame = c.renderDragFrameForTesting() }
        let reference = c.renderer.flatten(doc.state)
        mouse(c, .leftMouseUp, CGPoint(x: 3840, y: 720))
        note("5K drag of the top blur box (3 × r=20 pt blur, 10 rects): full re-render \(Int(full)) ms, layered \(Int(layered)) ms")
        check(frame != nil && layered < full * 0.7,
              "CORE_EDITOR-12: dragging a blur box re-renders only from it up (\(Int(layered)) vs \(Int(full)) ms)")
        if let frame, let reference, let a = PixelReader(frame), let b = PixelReader(reference) {
            var diff = 0
            for y in stride(from: 0, to: a.height, by: 37) {
                for x in stride(from: 0, to: a.width, by: 37) where a[x, y].differs(from: b[x, y], by: 2) { diff += 1 }
            }
            check(diff == 0, "CORE_EDITOR-12: the layered drag frame matches a full render (\(diff) samples differ)")
        }
    }

    // MARK: CORE_EDITOR-16

    @MainActor
    static func counterSizeAndBorder(_ check: (Bool, String) -> Void) {
        let ed = editor()
        let c = ed.canvas, doc = ed.doc
        c.tool = .draw(.counter)
        click(c, CGPoint(x: 300, y: 300))
        guard let placed = doc.state.elements.last, placed.kind == .counter else { check(false, "counter placed"); return }
        let groups = ed.visiblePropertyGroups
        check(groups.contains("counterSize") && !groups.contains("font"),
              "CORE_EDITOR-16: counters show a Size control, not the font controls that did nothing")
        ed.counterSizeChanged(popup(EditorWindowController.counterSizes.map { "\(Int($0))" },
                                    EditorWindowController.counterSizes.firstIndex(of: 48)!))
        let w = doc.element(placed.id)?.frame.width ?? 0
        check(abs(w - 48 * doc.pixelScale) < 0.01 && doc.element(placed.id)?.frame.midX == placed.frame.midX,
              "CORE_EDITOR-16: Size resizes the selected counter around its centre (\(Int(placed.frame.width)) → \(Int(w)) px)")
        click(c, CGPoint(x: 600, y: 300))
        check(abs((doc.state.elements.last?.frame.width ?? 0) - 48 * doc.pixelScale) < 0.01, "CORE_EDITOR-16: the next counter uses the new size")

        c.tool = .draw(.arrow)
        let well = NSColorWell()
        well.color = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        ed.lineColorChanged(well)
        let b = ed.borderStyle()
        check(b.color.b > 0.9 && b.color.r < 0.1, "CORE_EDITOR-16: Border uses the line colour shown in the bar (arrow tool's blue)")
    }
}
