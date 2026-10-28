import AppKit
import ShottyCore

/// Checks for the review round 5 fixes (`--selftest`). Same rules as the earlier rounds: no window,
/// sheet, alert or menu on screen, no real clipboard (private pasteboards), no saved settings.
enum Round5Checks {
    @MainActor
    static func run(check: (Bool, String) -> Void, note: (String) -> Void) {
        pastedTextRefitsAtTheTargetScale(check)
        secondFailedPatternSaveReshowsTheMenu(check)
        note("CORE_EDITOR-R5-1/CAPTURE_APP-R5-1: GIF can't store a resolution; the README now says so "
            + "and the gifCannotStoreScaleButBMPCan unit test pins the limitation (and BMP's correctness).")
    }

    typealias E = EditorSelfChecks

    // CORE_EDITOR-R5-3: a wrapped text box pasted from a 2x editor into a 1x one is re-fitted at
    // the target scale. Fonts don't rasterize linearly, so the halved frame could be a hair too
    // short for its text at 1x and drawText clipped the last line.
    @MainActor
    static func pastedTextRefitsAtTheTargetScale(_ check: (Bool, String) -> Void) {
        let pb = NSPasteboard(name: NSPasteboard.Name("shotty-selftest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let saved = (ElementClipboard.elements, ElementClipboard.changeCount, ElementClipboard.pixelScale)
        defer { (ElementClipboard.elements, ElementClipboard.changeCount, ElementClipboard.pixelScale) = saved }
        let retina = E.editor(scale: 2), plain = E.editor(width: 600, height: 400, scale: 1)
        retina.pasteboardForTesting = pb
        plain.pasteboardForTesting = pb
        // The reviewer's reproduction: this text in a 220 px box, fitted at 2x, needs ~2.5 px more
        // at 1x than half its 2x height provides (more than drawText's 2 px slack).
        var t = Element(kind: .text, frame: CGRect(x: 40, y: 40, width: 220, height: 30))
        t.text = "Some words in a text box that wrap around twice at least"
        t = Renderer.fittingText(t, pixelScale: 2)
        retina.doc.mutate { $0.elements = [t] }
        retina.canvas.setSelection([t.id])
        retina.copy(nil)
        plain.paste(nil)
        let got = plain.doc.state.elements.first { $0.kind == .text }
        // fittingText never shrinks a frame, so "needs no growth at 1x" means the text fits.
        let need = got.map { Renderer.frameFittingText($0, pixelScale: 1).height } ?? -1
        let have = got?.frame.height ?? -1
        check(got != nil && need == have,
              "CORE_EDITOR-R5-3: text pasted 2x → 1x is re-fitted: box \(have) px tall, its text needs \(need) px")
    }

    // CAPTURE_APP-R5-2: a pattern save chosen from the Ask menu that fails AGAIN re-shows the
    // menu (the capture lives only in the menu items, so no menu meant no retry and a lost
    // capture); a retry that works doesn't bring the menu back.
    @MainActor
    static func secondFailedPatternSaveReshowsTheMenu(_ check: (Bool, String) -> Void) {
        struct Unplugged: Error {}
        let pb = NSPasteboard(name: NSPasteboard.Name("shotty-selftest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        var errors = 0
        Output.showErrorForTesting = { _, _ in errors += 1 }
        defer { Output.showErrorForTesting = nil }
        let ad = AppDelegate()
        var fail = true
        var menus: [NSMenu] = []
        ad.clipboard = pb
        ad.saveWithPattern = { _ in
            if fail { throw Unplugged() }
            return URL(fileURLWithPath: "/tmp/shotty-selftest-r5.png")
        }
        ad.presentDestinationMenu = { menus.append($0) }
        ad.presentEditor = { _ in }
        let r = CaptureResult(image: SelfTest.sampleImage(width: 300, height: 200, scale: 1), scale: 1,
                              title: "R5", date: Date())
        func fileItem(_ menu: NSMenu?) -> NSMenuItem? {
            menu?.items.first { ($0.representedObject as? AppDelegate.DestinationChoice)?.destination == .file }
        }
        ad.deliver(r, to: [.file, .ask])                            // fails: the first menu
        if let i = fileItem(menus.last) { ad.destinationChosen(i) } // fails again: menu re-shown
        let reshown = menus.count
        let stillOffered = fileItem(menus.last) != nil
        fail = false
        if let i = fileItem(menus.last) { ad.destinationChosen(i) } // works: no new menu
        check(reshown == 2 && stillOffered && menus.count == 2 && errors == 2,
              "CAPTURE_APP-R5-2: a retry that fails again re-shows the menu (\(reshown) menus, \(errors) errors) "
              + "still offering the save (\(stillOffered)); a retry that works doesn't (\(menus.count) menus)")
    }

    // CAPTURE_APP-R5-3: the self-test's own artifacts record their render scale, so the report
    // images open in Preview at their on-screen size. SelfTest calls this with the 2x render it
    // just wrote (the check lives here, with the round's other checks; only the URL comes from there).
    static func artifactKeepsScale(_ url: URL, _ check: (Bool, String) -> Void) {
        let back = ImageExporter.loadForEditor(from: url)?.pixelScale ?? 0
        check(back == 2, "CAPTURE_APP-R5-3: \(url.lastPathComponent) (a 2x render) reopens at \(back)x (want 2)")
    }
}
