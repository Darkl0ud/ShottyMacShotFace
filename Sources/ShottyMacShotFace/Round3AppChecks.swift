import AppKit
import ShottyCore

/// Checks for the review round 3 app-shell fixes (`--selftest`). Same rules as Round2SelfChecks:
/// no window, sheet or menu on screen, no real clipboard (private pasteboards), no saved settings.
/// The only files are a few temporary images, removed again.
enum Round3AppChecks {
    @MainActor
    static func run(check: (Bool, String) -> Void, note: (String) -> Void) {
        askKeepsOtherDestinations(check)
        clipboardScaleMatchesFileOpen(check, note)
        hotkeyDuringQuitReviewBeeps(check)
    }

    // CAPTURE_APP-R3-1: Ask each time plus other ticked destinations ("pick any combination").
    @MainActor
    static func askKeepsOtherDestinations(_ check: (Bool, String) -> Void) {
        typealias P = AppDelegate.DeliveryPlan
        let plans: [([Destination], P)] = [
            ([], P(immediate: [.editor], showsMenu: false)),
            ([.editor, .clipboard], P(immediate: [.editor, .clipboard], showsMenu: false)),
            ([.ask], P(immediate: [], showsMenu: true)),
            ([.clipboard, .ask], P(immediate: [.clipboard], showsMenu: true)),
            ([.editor, .clipboard, .file, .fileAs, .ask], P(immediate: [.clipboard, .file], showsMenu: true)),
        ]
        let wrong = plans.filter { AppDelegate.planDelivery($0.0) != $0.1 }.map { "\($0.0.map(\.rawValue))" }
        check(wrong.isEmpty, "CA-R3-1: delivery plan runs clipboard/pattern save first, then asks about the rest (wrong for \(wrong))")

        let pb = NSPasteboard(name: NSPasteboard.Name("shotty-selftest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let ad = AppDelegate()
        let fakeURL = URL(fileURLWithPath: "/tmp/shotty-selftest-pattern.png")
        var saves = 0, saveAsPanels = 0
        var menus: [NSMenu] = [], docs: [EditorDocument] = []
        ad.clipboard = pb
        ad.saveWithPattern = { _ in saves += 1; return fakeURL }
        ad.presentSaveAs = { _, done in saveAsPanels += 1; done(nil) }
        ad.presentDestinationMenu = { menus.append($0) }
        ad.presentEditor = { docs.append($0) }
        let img = SelfTest.sampleImage(width: 300, height: 200, scale: 1)
        let r = CaptureResult(image: img, scale: 1, title: "R3", date: Date())

        func choose(_ d: Destination, in menu: NSMenu?) {
            guard let item = menu?.items.first(where: { ($0.representedObject as? AppDelegate.DestinationChoice)?.destination == d })
            else { return }
            ad.destinationChosen(item)
        }
        func choices(_ menu: NSMenu?) -> [Destination] {
            menu?.items.compactMap { ($0.representedObject as? AppDelegate.DestinationChoice)?.destination } ?? []
        }

        // Ask + clipboard + pattern save: both happen at once, then the menu; its editor knows.
        ad.deliver(r, to: [.clipboard, .file, .ask])
        let copied = Output.clipboardHasImage(pb)
        let offered = choices(menus.last)
        choose(.editor, in: menus.last)
        check(copied && saves == 1 && menus.count == 1 && docs.isEmpty == false,
              "CA-R3-1: Ask + Copy + Save: copied \(copied), saved \(saves)×, menu shown \(menus.count)×, editor from menu \(docs.count)")
        check(docs.first?.wasExported == true && docs.first?.fileURL == fakeURL,
              "CA-R3-1: editor opened from the menu counts as exported and owns the pattern file (exported \(docs.first?.wasExported ?? false))")
        check(offered.contains(.editor) && offered.contains(.fileAs) && !offered.contains(.clipboard) && !offered.contains(.file) && saves == 1,
              "CA-R3-1: the menu offers only what hasn't happened yet (\(offered.map(\.rawValue)))")

        // Ask + editor + Save As: nothing opens before the user chooses.
        docs = []; menus = []
        ad.deliver(r, to: [.editor, .fileAs, .ask])
        check(docs.isEmpty && saveAsPanels == 0 && menus.count == 1,
              "CA-R3-1: Ask + Editor + Save As leaves both to the menu (editors \(docs.count), panels \(saveAsPanels))")

        // Ask alone: an editor from the menu holds the only copy, so closing it must still ask.
        docs = []; menus = []
        ad.deliver(r, to: [.ask])
        choose(.editor, in: menus.last)
        check(docs.count == 1 && docs.first?.wasExported == false && choices(menus.last).count == 4,
              "CA-R3-1: Ask alone: full menu, and its editor isn't marked exported")
    }

    // CAPTURE_APP-R3-2: the clipboard and Open Image from File agree on the scale.
    @MainActor
    static func clipboardScaleMatchesFileOpen(_ check: (Bool, String) -> Void, _ note: (String) -> Void) {
        let img = SelfTest.sampleImage(width: 600, height: 400, scale: 1)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-r3-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func tiff(_ image: CGImage, dpi: CGFloat) -> Data? {
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = NSSize(width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
            return rep.tiffRepresentation
        }

        var mismatches: [String] = []
        for dpi: CGFloat in [72, 96, 108, 144, 216, 300, 600] {
            guard let data = tiff(img, dpi: dpi) else { mismatches.append("\(Int(dpi)): no tiff"); continue }
            let pb = NSPasteboard(name: NSPasteboard.Name("shotty-selftest-\(UUID().uuidString)"))
            pb.clearContents()
            pb.setData(data, forType: .tiff)
            let clip = Output.imageFromClipboardWithScale(pb)?.scale ?? 0
            pb.releaseGlobally()
            let url = dir.appendingPathComponent("\(Int(dpi)).tiff")
            try? data.write(to: url)
            let file = ImageExporter.loadForEditor(from: url)?.pixelScale ?? 0
            let want: CGFloat = dpi >= 200 ? 3 : dpi >= 140 ? 2 : 1
            if clip != file || clip != want { mismatches.append("\(Int(dpi)) dpi: clipboard \(clip), file \(file)") }
        }
        check(mismatches.isEmpty, "CA-R3-2: clipboard scale = Open Image from File scale at 72…600 dpi (\(mismatches))")

        // A full-size PNG beside a half-size 144 dpi TIFF: the PNG is opened, so the TIFF can't set its scale.
        let pb = NSPasteboard(name: NSPasteboard.Name("shotty-selftest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let item = NSPasteboardItem()
        let small = SelfTest.sampleImage(width: 300, height: 200, scale: 1)
        if let png = try? ImageExporter.data(for: img, format: .png) { item.setData(png, forType: .png) }
        if let t = tiff(small, dpi: 144) { item.setData(t, forType: .tiff) }
        pb.writeObjects([item])
        let got = Output.imageFromClipboardWithScale(pb)
        note("CA-R3-2 png 600 px + tiff 300 px@144 → \(got?.image.width ?? 0) px at \(got?.scale ?? 0)x")
        check(got.map { $0.image.width != 600 || $0.scale == 1 } ?? false,
              "CA-R3-2: a full-size PNG doesn't take a smaller TIFF's scale (\(got?.image.width ?? 0) px, \(got?.scale ?? 0)x)")
    }

    // CAPTURE_APP-R3-4: a hotkey refused because of the Quit review says so.
    @MainActor
    static func hotkeyDuringQuitReviewBeeps(_ check: (Bool, String) -> Void) {
        let ad = AppDelegate()
        var beeps = 0
        ad.beep = { beeps += 1 }
        ad.isReviewingQuit = true // what applicationShouldTerminate sets while its sheets are up
        let refused = !ad.canStartCapture
        ad.capture(.region)
        ad.isReviewingQuit = false
        check(refused && beeps == 1 && ad.canStartCapture,
              "CA-R3-4: a capture hotkey during the Quit review beeps instead of doing nothing (beeps \(beeps))")
    }
}
