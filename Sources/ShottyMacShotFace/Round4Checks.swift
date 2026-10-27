import AppKit
import ImageIO
import ShottyCore

/// Checks for the review round 4 fixes (`--selftest`). Same rules as the earlier rounds: no window,
/// sheet, alert or menu on screen, no real clipboard (private pasteboards), no saved settings.
/// The only files are a few images in a temporary folder, removed again.
enum Round4Checks {
    @MainActor
    static func run(check: (Bool, String) -> Void, note: (String) -> Void) {
        topGripStaysOnThePicture(check)
        upTailSurvivesTopGrip(check)
        pastedAnnotationsKeepTheirSize(check)
        savesKeepTheirScale(check, note)
        failedPatternSaveStaysOnTheMenu(check)
    }

    typealias E = EditorSelfChecks
    typealias R2 = Round2SelfChecks
    typealias R3 = Round3EditorChecks

    static func r(_ f: CGRect) -> String { R3.r(f) }

    // CORE_EDITOR-R4-1: narrowing a caption at the top of the picture with a top corner grip grows
    // it downwards once it reaches the top edge, instead of off the picture.
    @MainActor
    static func topGripStaysOnThePicture(_ check: (Bool, String) -> Void) {
        let ed = E.editor()
        let c = ed.canvas, doc = ed.doc, s = doc.pixelScale
        guard let b = R3.newBox(ed, .text, at: CGPoint(x: 100, y: 10), "A caption sentence that is long enough to wrap when narrowed")
        else { check(false, "CE-R4-1: caption box"); return }
        let g = Grip.topRight.position(in: b.frame)
        R3.gripDrag(c, from: g, through: R3.steps(g, CGPoint(x: b.frame.minX + 200, y: g.y), 8))
        let a = doc.element(b.id) ?? b
        check(a.frame.minY >= -0.01 && R2.fits(a, s).0 && a.frame.height > b.frame.height,
              "CORE_EDITOR-R4-1: caption at y=\(Int(b.frame.minY)) narrowed with the top-right grip: \(r(b.frame)) → \(r(a.frame)) stays on the picture, text fits")
    }

    // CORE_EDITOR-R4-1: a bubble whose tail points up keeps its tail when a top grip makes it grow upwards.
    @MainActor
    static func upTailSurvivesTopGrip(_ check: (Bool, String) -> Void) {
        let ed = E.editor()
        let c = ed.canvas, doc = ed.doc, s = doc.pixelScale
        c.tool = .draw(.speechBubble)
        E.drag(c, CGPoint(x: 300, y: 300), CGPoint(x: 700, y: 400))
        c.activeTextView?.insertText("Some words in a bubble that wrap", replacementRange: NSRange(location: 0, length: 0))
        c.endTextEdit()
        guard var b = doc.state.elements.last, b.kind == .speechBubble else { check(false, "CE-R4-1: bubble"); return }
        doc.update(b.id) { $0.points = [CGPoint(x: b.frame.minX + 50, y: b.frame.minY - 60)] }
        b = doc.element(b.id) ?? b
        c.tool = .select
        c.setSelection([b.id])
        let g = Grip.topRight.position(in: b.frame)
        R3.gripDrag(c, from: g, through: R3.steps(g, CGPoint(x: b.frame.minX + 130, y: g.y), 8))
        let a = doc.element(b.id) ?? b
        let tip = a.points.first ?? .zero
        check(!a.frame.contains(tip) && tip.y < a.frame.minY && R2.fits(a, s).0,
              "CORE_EDITOR-R4-1: up-tail bubble narrowed with the top-right grip: \(r(b.frame)) → \(r(a.frame)), tip y \(Int(b.points[0].y)) → \(Int(tip.y)) stays outside the body")
    }

    // CORE_EDITOR-R4-2: annotations copied from a 2x capture paste into a 1x one at the same
    // on-screen size (half the pixels), and back again.
    @MainActor
    static func pastedAnnotationsKeepTheirSize(_ check: (Bool, String) -> Void) {
        let pb = NSPasteboard(name: NSPasteboard.Name("shotty-selftest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let saved = (ElementClipboard.elements, ElementClipboard.changeCount, ElementClipboard.pixelScale)
        defer { (ElementClipboard.elements, ElementClipboard.changeCount, ElementClipboard.pixelScale) = saved }
        let retina = E.editor(scale: 2), plain = E.editor(width: 600, height: 400, scale: 1)
        retina.pasteboardForTesting = pb
        plain.pasteboardForTesting = pb
        var rect = Element(kind: .rectangle, frame: CGRect(x: 200, y: 100, width: 400, height: 200))
        rect.style.lineWidth = 3
        let arrow = Element(kind: .arrow, points: [CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 300)])
        retina.doc.mutate { $0.elements = [rect, arrow] }
        retina.canvas.setSelection([rect.id, arrow.id])
        retina.copy(nil)
        plain.paste(nil)
        let got = plain.doc.state.elements
        let r1 = got.first { $0.kind == .rectangle }, a1 = got.first { $0.kind == .arrow }
        // Half the pixels, then the usual 10 pt cascade (10 px in a 1x picture).
        let wantRect = CGRect(x: 110, y: 60, width: 200, height: 100)
        let ok1 = r1.map { R3.same($0.frame, wantRect) && $0.style.lineWidth == 3 } ?? false
        let ok2 = a1?.points == [CGPoint(x: 60, y: 60), CGPoint(x: 260, y: 160)]
        // Copying from the 1x picture back into the 2x one doubles them again.
        plain.canvas.setSelection(Set(got.map(\.id)))
        plain.copy(nil)
        retina.doc.mutate { $0.elements = [] }
        retina.paste(nil)
        let back = retina.doc.state.elements.first { $0.kind == .rectangle }
        let ok3 = back.map { R3.same($0.frame, CGRect(x: 240, y: 140, width: 400, height: 200)) } ?? false
        check(ok1 && ok2 && ok3,
              "CORE_EDITOR-R4-2: 2x → 1x paste: rect \(r(r1?.frame ?? .null)) (want \(r(wantRect))), arrow \(a1?.points.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? []); 1x → 2x: \(r(back?.frame ?? .null)) (want (240,140 400x200))")
    }

    static func pngDPI(_ data: Data?) -> CGFloat {
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 0 }
        return CGFloat((p[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72)
    }

    // CAPTURE_APP-R4-1: every save and copy of a Retina capture says it's Retina (144 dpi), so
    // reopening or inserting it gives its real size.
    @MainActor
    static func savesKeepTheirScale(_ check: (Bool, String) -> Void, _ note: (String) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-r4-\(UUID().uuidString)")
        let savedLast = Output.lastSavedURL
        defer { try? FileManager.default.removeItem(at: dir); Output.lastSavedURL = savedLast }
        let img = SelfTest.sampleImage(width: 400, height: 200, scale: 2)

        // Output.write: Save As and every pattern save go through it.
        var wrong: [String] = []
        for f in ["png", "jpg", "tiff", "heic"] {
            let url = dir.appendingPathComponent("out.\(f)")
            do { try Output.write(img, to: url, pixelScale: 2) } catch { wrong.append("\(f): \(error)"); continue }
            let back = ImageExporter.loadForEditor(from: url)?.pixelScale ?? 0
            if back != 2 { wrong.append("\(f) reopens at \(back)x") }
        }
        check(wrong.isEmpty, "CAPTURE_APP-R4-1: a 2x capture saved as PNG/JPEG/TIFF/HEIC reopens as 2x (\(wrong))")

        // The editor's ⌘S into its file, then Insert Image from File's path into a 2x capture: 1:1.
        let ed = E.editor(width: 800, height: 400, scale: 2)
        ed.saveActionForTesting = nil
        let url = dir.appendingPathComponent("editor.png")
        ed.doc.fileURL = url
        ed.saveDocument(nil)
        let loaded = ImageExporter.loadForEditor(from: url)
        let target = E.editor(width: 1600, height: 1200, scale: 2)
        if let loaded { target.insertImage(loaded.image, sourceScale: loaded.pixelScale) }
        let w = target.doc.state.elements.last?.frame.width ?? 0
        check(loaded?.pixelScale == 2 && abs(w - 800) < 0.5,
              "CAPTURE_APP-R4-1: editor ⌘S of a 2x capture reopens at \(loaded?.pixelScale ?? 0)x and inserts into a 2x capture \(Int(w)) px wide (want 800)")

        // The clipboard PNGs: Copy (capture and editor) and the picture beside copied annotations.
        let pb = NSPasteboard(name: NSPasteboard.Name("shotty-selftest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        Output.copyToClipboard(img, pixelScale: 2, to: pb)
        let copyDPI = pngDPI(pb.data(forType: .png))
        let pasted = Output.imageFromClipboardWithScale(pb)
        let saved = (ElementClipboard.elements, ElementClipboard.changeCount, ElementClipboard.pixelScale)
        defer { (ElementClipboard.elements, ElementClipboard.changeCount, ElementClipboard.pixelScale) = saved }
        ed.pasteboardForTesting = pb
        let box = Element(kind: .rectangle, frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        ed.doc.mutate { $0.elements = [box] }
        ed.canvas.setSelection([box.id])
        ed.copy(nil)
        let annDPI = pngDPI(pb.data(forType: .png))
        // That PNG alone (no TIFF), read back as a picture: full size and 2x, as the file would be.
        let pngOnly = Output.imageFromClipboardWithScale(pb)
        check(copyDPI == 144 && annDPI == 144 && pasted?.image.width == 400 && pasted?.scale == 2,
              "CAPTURE_APP-R4-1: copied PNG of a 2x capture is \(Int(copyDPI)) dpi, beside copied annotations \(Int(annDPI)) dpi (want 144); pasted back \(pasted?.image.width ?? 0) px at \(pasted?.scale ?? 0)x")
        check(pngOnly?.image.width == 800 && pngOnly?.scale == 2,
              "CAPTURE_APP-R4-1: the PNG copied beside annotations pastes as a picture \(pngOnly?.image.width ?? 0) px at \(pngOnly?.scale ?? 0)x (want 800 px at 2x)")
        note("CAPTURE_APP-R4-1: Save As (NSSavePanel) and the pattern save into the real output folder can't run headless; both call Output.write(_:to:pixelScale:) checked above.")
    }

    // CAPTURE_APP-R4-2: Ask + Save (pattern) where the save fails: the error is reported and the
    // menu still offers the pattern save, so it can be retried; a later success removes it.
    @MainActor
    static func failedPatternSaveStaysOnTheMenu(_ check: (Bool, String) -> Void) {
        struct Unplugged: Error {}
        let pb = NSPasteboard(name: NSPasteboard.Name("shotty-selftest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        var errors: [String] = []
        Output.showErrorForTesting = { m, _ in errors.append(m) }
        defer { Output.showErrorForTesting = nil }
        let ad = AppDelegate()
        var fail = true, saves = 0
        var menus: [NSMenu] = []
        ad.clipboard = pb
        ad.saveWithPattern = { _ in
            saves += 1
            if fail { throw Unplugged() }
            return URL(fileURLWithPath: "/tmp/shotty-selftest-r4.png")
        }
        ad.presentDestinationMenu = { menus.append($0) }
        ad.presentEditor = { _ in }
        let r = CaptureResult(image: SelfTest.sampleImage(width: 300, height: 200, scale: 1), scale: 1, title: "R4", date: Date())
        func choices(_ menu: NSMenu?) -> [Destination] {
            menu?.items.compactMap { ($0.representedObject as? AppDelegate.DestinationChoice)?.destination } ?? []
        }

        ad.deliver(r, to: [.file, .ask])
        let offered = choices(menus.last)
        let cancelTitle = menus.last?.items.last?.title ?? ""
        // Retry from the menu, now that the folder is back.
        fail = false
        if let item = menus.last?.items.first(where: { ($0.representedObject as? AppDelegate.DestinationChoice)?.destination == .file }) {
            ad.destinationChosen(item)
        }
        // A save that worked is still left off the menu (a second one would make a second file).
        let afterSuccess = choices(ad.makeDestinationMenu(r, after: ad.run([.file], r)))
        check(errors.count == 1 && offered.contains(.file) && cancelTitle == "Discard",
              "CAPTURE_APP-R4-2: failed pattern save: \(errors.count) error shown, menu still offers it (\(offered.map(\.rawValue))), cancel says '\(cancelTitle)'")
        check(saves == 3 && errors.count == 1 && menus.count == 1 && !afterSuccess.contains(.file),
              "CAPTURE_APP-R4-2: retry from the menu saves (\(saves) attempts, want 3), a saved capture's menu leaves it out (\(afterSuccess.map(\.rawValue)))")
    }
}
