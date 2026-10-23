import AppKit
import Carbon.HIToolbox
import ShottyCore
import SwiftUI

/// `--selftest <dir>`: builds a sample capture, drives the real editor, overlay and settings views
/// offscreen, writes PNGs of each, and runs a real screen capture if permission is granted.
/// Results go to <dir>/report.txt; the exit code is the number of failed checks.
@MainActor
final class SelfTest: NSObject, NSApplicationDelegate {
    let out: URL
    let includeCapture: Bool
    private var lines: [String] = []
    private var failures = 0

    init(outputDir: URL, includeCapture: Bool) {
        out = outputDir
        self.includeCapture = includeCapture
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            await runAll()
            let summary = "\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed)"
            lines.append(summary)
            try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            print(lines.joined(separator: "\n"))
            exit(Int32(min(failures, 100)))
        }
    }

    private func check(_ ok: Bool, _ what: String) {
        lines.append((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    private func note(_ s: String) { lines.append("INFO " + s) }

    private func save(_ img: CGImage?, _ name: String) {
        guard let img else { check(false, "\(name): no image"); return }
        do { try ImageExporter.write(img, to: out.appendingPathComponent(name), format: .png) }
        catch { check(false, "\(name): \(error.localizedDescription)") }
    }

    private func snapshotView(_ v: NSView) -> CGImage? {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.cgImage
    }

    private func time(_ body: () -> Void) -> Double {
        let t = Date()
        body()
        return Date().timeIntervalSince(t) * 1000
    }

    // MARK: Sample content

    /// A fake desktop: gradient, a window with a title bar and some "text" lines.
    static func sampleImage(width: Int, height: Int, scale s: CGFloat) -> CGImage {
        Bitmap.render(width: width, height: height) { ctx in
            let full = CGRect(x: 0, y: 0, width: width, height: height)
            let grad = CGGradient(colorsSpace: Bitmap.sRGB, colors: [
                CGColor(srgbRed: 0.20, green: 0.35, blue: 0.60, alpha: 1),
                CGColor(srgbRed: 0.55, green: 0.30, blue: 0.55, alpha: 1)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: full.maxX, y: full.maxY), options: [])
            let win = CGRect(x: 100 * s, y: 80 * s, width: 520 * s, height: 320 * s)
            ctx.setFillColor(CGColor(gray: 0.98, alpha: 1)); ctx.fill(win)
            ctx.setFillColor(CGColor(gray: 0.88, alpha: 1)); ctx.fill(CGRect(x: win.minX, y: win.minY, width: win.width, height: 28 * s))
            for (i, c) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
                ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: win.minX + (12 + CGFloat(i) * 20) * s, y: win.minY + 8 * s, width: 12 * s, height: 12 * s))
            }
            let text = """
            Server: proxmox-01.lab.local   Status: OK
            Password: hunter2-very-secret
            Uptime: 42 days, 3:14   Load: 0.21 0.18 0.12
            ZFS pool 'tank' ONLINE — 3 × 8 TB raidz1
            """
            let str = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13 * s, weight: .regular), .foregroundColor: NSColor.black,
            ])
            str.draw(with: CGRect(x: win.minX + 20 * s, y: win.minY + 48 * s, width: win.width - 40 * s, height: 200 * s),
                     options: [.usesLineFragmentOrigin])
        }!
    }

    /// One of everything, laid out over the sample window.
    static func sampleDocument() -> EditorDocument {
        let s: CGFloat = 2
        let doc = EditorDocument(image: sampleImage(width: 1600, height: 1000, scale: s), pixelScale: s, title: "Self-test")
        func el(_ k: ElementKind, _ r: CGRect = .zero, _ pts: [CGPoint] = [], _ tweak: (inout Element) -> Void = { _ in }) {
            var e = Element(kind: k, frame: CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s),
                            points: pts.map { CGPoint(x: $0.x * s, y: $0.y * s) })
            tweak(&e)
            doc.add(e)
        }
        el(.obfuscate, CGRect(x: 190, y: 146, width: 170, height: 18)) { $0.style.obfuscateMode = .pixelate }
        el(.obfuscate, CGRect(x: 120, y: 166, width: 300, height: 18)) { $0.style.obfuscateMode = .blur }
        el(.highlight, CGRect(x: 118, y: 126, width: 300, height: 18))
        el(.rectangle, CGRect(x: 112, y: 120, width: 330, height: 30))
        el(.ellipse, CGRect(x: 660, y: 90, width: 120, height: 80)) { $0.style.fill = RGBA(1, 0.9, 0.2, 0.6) }
        el(.arrow, .zero, [CGPoint(x: 700, y: 260), CGPoint(x: 440, y: 160)])
        el(.arrow, .zero, [CGPoint(x: 660, y: 330), CGPoint(x: 760, y: 420)]) { $0.style.arrowHeads = .both; $0.style.stroke = .black }
        el(.line, .zero, [CGPoint(x: 100, y: 440), CGPoint(x: 400, y: 440)]) { $0.style.lineWidth = 4 }
        el(.freehand, .zero, (0..<40).map { CGPoint(x: 420 + CGFloat($0) * 6, y: 460 + 14 * sin(CGFloat($0) / 3)) })
        el(.text, CGRect(x: 640, y: 190, width: 140, height: 30)) { $0.text = "Look here!"; $0.style.bold = true }
        el(.speechBubble, CGRect(x: 120, y: 260, width: 210, height: 60), [CGPoint(x: 160, y: 380)]) {
            $0.text = "Bubble with a tail"
        }
        for x in [380.0, 430.0, 480.0] { el(.counter, CGRect(x: x, y: 300, width: 36, height: 36)) }
        el(.highlight, CGRect(x: 640, y: 440, width: 120, height: 50)) { $0.style.highlightMode = .magnify }
        return doc
    }

    // MARK: Checks

    private func runAll() async {
        note("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let doc = Self.sampleDocument()
        let renderer = Renderer(pixelScale: 2)

        // 1. Every annotation rendered.
        var flat: CGImage?
        let ms = time { flat = renderer.flatten(doc.state) }
        save(flat, "01-annotations.png")
        check(flat?.width == 1600 && flat?.height == 1000, "flatten keeps size (1600×1000), took \(Int(ms)) ms")
        if let flat, let px = PixelReader(flat) {
            // The pixelated password line must not match the original pixels.
            let orig = PixelReader(doc.state.image)!
            var same = 0, total = 0
            for y in stride(from: 296, to: 326, by: 2) { for x in stride(from: 384, to: 716, by: 2) {
                total += 1
                if !px[x, y].differs(from: orig[x, y], by: 2) { same += 1 }
            } }
            check(Double(same) / Double(total) < 0.75, "pixelate changed the secret line (\(total - same)/\(total) px differ)")
        }

        // 2. Performance on a 5K-sized capture with 30 annotations (worst case: full re-render per drag).
        let big = EditorDocument(image: Self.sampleImage(width: 5120, height: 2880, scale: 2), pixelScale: 2)
        for i in 0..<30 {
            var e = Element(kind: i % 3 == 0 ? .arrow : .rectangle,
                            frame: CGRect(x: 100 + i * 120, y: 200 + i * 40, width: 300, height: 200),
                            points: [CGPoint(x: 100 + i * 120, y: 300), CGPoint(x: 400 + i * 120, y: 900)])
            e.style.shadow = true
            big.add(e)
        }
        var e5 = Element(kind: .obfuscate, frame: CGRect(x: 1000, y: 1000, width: 1200, height: 600))
        e5.style.pixelSize = 10
        big.add(e5)
        let r5 = Renderer(pixelScale: 2)
        _ = r5.flatten(big.state) // warm-up
        let ms5 = time { _ = r5.flatten(big.state) }
        check(ms5 < 250, "5K flatten with 31 annotations: \(Int(ms5)) ms (budget 250)")

        // 3. Effects.
        let effects: [(String, CGImage?)] = [
            ("shadow", Effects.dropShadow(flat!, pixelScale: 2)),
            ("torn", Effects.tornEdges(flat!, pixelScale: 2)),
            ("torn-bottom", Effects.tornEdges(flat!, pixelScale: 2, sides: .bottom)),
            ("border", Effects.border(flat!, width: 8, color: .red)),
            ("grayscale", Effects.grayscale(flat!)),
            ("invert", Effects.invert(flat!)),
            ("rotate-cw", Effects.rotate(flat!, clockwise: true)),
            ("resize-50", Effects.resize(flat!, width: 800, height: 500)),
        ]
        for (name, img) in effects {
            check(img != nil, "effect \(name)")
            save(img.flatMap { Effects.resize($0, width: $0.width / 2, height: $0.height / 2) }, "02-effect-\(name).png")
        }

        // 4. The real editor window, rendered offscreen in a few states.
        let ed = EditorWindowController(document: doc)
        ed.window?.setFrame(NSRect(x: 0, y: 0, width: 1180, height: 760), display: false)
        ed.zoomFit(nil)
        if let content = ed.window?.contentView {
            note("editor window \(ed.window!.frame), content \(content.frame), canvas \(ed.canvas.frame), scroll \(ed.canvas.enclosingScrollView?.frame ?? .zero)")
            ed.canvas.setSelection([doc.state.elements[3].id])
            save(snapshotView(content), "03-editor-select.png")
            ed.canvas.tool = .draw(.text)
            save(snapshotView(content), "03-editor-text-tool.png")
            ed.canvas.tool = .draw(.obfuscate)
            save(snapshotView(content), "03-editor-obfuscate-tool.png")
            ed.canvas.tool = .crop
            ed.canvas.setCropRect(CGRect(x: 180, y: 140, width: 1100, height: 700))
            save(snapshotView(content), "03-editor-crop.png")
            ed.canvas.applyCrop()
            check(doc.state.image.width == 1100 && doc.state.image.height == 700, "crop applied (1100×700)")
            doc.undo()
            check(doc.state.image.width == 1600, "undo restores the uncropped picture")
            ed.canvas.tool = .select
            ed.zoomActual(nil)
            check(abs(ed.canvas.zoom * (ed.window?.backingScaleFactor ?? 2) - 1) < 0.01,
                  "actual size = 1 image px per screen px (zoom \(ed.canvas.zoom))")
            // Pinch zoom keeps the point under the fingers in place (zoomed in so the picture is
            // bigger than the view; when it's smaller it is centred instead, by design).
            ed.canvas.zoom(by: 2, around: CGPoint(x: 400, y: 250))
            let fingers = CGPoint(x: 700, y: 500)
            let before = CGPoint(x: fingers.x - ed.canvas.visibleRect.minX, y: fingers.y - ed.canvas.visibleRect.minY)
            let docPt = CGPoint(x: fingers.x / ed.canvas.zoom, y: fingers.y / ed.canvas.zoom)
            ed.canvas.zoom(by: 1.3, around: fingers)
            let after = CGPoint(x: docPt.x * ed.canvas.zoom - ed.canvas.visibleRect.minX,
                                y: docPt.y * ed.canvas.zoom - ed.canvas.visibleRect.minY)
            check(before.distance(to: after) < 1.5,
                  "pinch keeps the point under the fingers (moved \(String(format: "%.2f", before.distance(to: after))) pt)")
            ed.canvas.zoom(by: 1000, around: fingers)
            check(abs(ed.canvas.zoom * (ed.window?.backingScaleFactor ?? 2) - 8) < 0.01, "pinch zoom stops at 800%")
            ed.canvas.zoom(by: 0.00001, around: fingers)
            check(abs(ed.canvas.zoom * (ed.window?.backingScaleFactor ?? 2) - 0.05) < 0.001, "pinch zoom stops at 5%")
            ed.canvasSmartZoom()
            check(abs(ed.canvas.zoom * (ed.window?.backingScaleFactor ?? 2) - 1) < 0.01, "double-tap goes to actual size")
            ed.canvasSmartZoom()
            check(abs(ed.canvas.zoom * (ed.window?.backingScaleFactor ?? 2) - 1) > 0.01, "double-tap again fits the window")

            // Place a step counter and resize it by its grip WITHOUT leaving the counter tool,
            // driving the canvas with real mouse events.
            do {
                let c = ed.canvas
                func send(_ type: NSEvent.EventType, _ docPt: CGPoint) {
                    let win = c.convert(CGPoint(x: docPt.x * c.zoom, y: docPt.y * c.zoom), to: nil)
                    guard let ev = NSEvent.mouseEvent(with: type, location: win, modifierFlags: [], timestamp: 0,
                                                      windowNumber: ed.window!.windowNumber, context: nil,
                                                      eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                    switch type {
                    case .leftMouseDown: c.mouseDown(with: ev)
                    case .leftMouseDragged: c.mouseDragged(with: ev)
                    default: c.mouseUp(with: ev)
                    }
                }
                c.tool = .draw(.counter)
                let countersBefore = doc.state.elements.filter { $0.kind == .counter }.count
                send(.leftMouseDown, CGPoint(x: 1400, y: 150)); send(.leftMouseUp, CGPoint(x: 1400, y: 150))
                let placed = doc.state.elements.last!
                let grip = Grip.bottomRight.position(in: placed.frame)
                send(.leftMouseDown, grip)
                send(.leftMouseDragged, CGPoint(x: grip.x + 40, y: grip.y + 20))
                send(.leftMouseUp, CGPoint(x: grip.x + 40, y: grip.y + 20))
                let after = doc.element(placed.id)!
                let countersAfter = doc.state.elements.filter { $0.kind == .counter }.count
                check(countersAfter == countersBefore + 1, "dragging the grip didn't place a second counter (\(countersAfter - countersBefore) added)")
                check(after.frame.width > placed.frame.width + 30 && after.frame.width == after.frame.height,
                      "counter resized with the counter tool still active and stayed round (\(Int(placed.frame.width)) → \(Int(after.frame.width))×\(Int(after.frame.height)))")
                check(c.tool == .draw(.counter), "counter tool still selected afterwards")
                // A click away from the grips still places the next counter.
                send(.leftMouseDown, CGPoint(x: 1450, y: 600)); send(.leftMouseUp, CGPoint(x: 1450, y: 600))
                check(doc.state.elements.filter { $0.kind == .counter }.count == countersAfter + 1, "clicking elsewhere places the next counter")
                c.tool = .select
            }

            // Typing into a text box through the real NSTextView.
            ed.canvas.tool = .draw(.text)
            let textID = doc.state.elements.first { $0.kind == .text }!.id
            ed.canvas.beginTextEdit(textID)
            ed.canvas.activeTextView?.string = "Edited!"
            ed.canvas.endTextEdit()
            check(doc.element(textID)?.text == "Edited!", "text editing commits into the document")
        } else {
            check(false, "editor window has a content view")
        }

        // 4z. Fixer A's editor checks (contract C3).
        EditorSelfChecks.run(check: { self.check($0, $1) }, note: { self.note($0) })
        Round2SelfChecks.run(check: { self.check($0, $1) })

        // 4a. Opening size: a wide, short capture (2313×233 px @2x, like a strip of text) should give
        // a window about as wide as the picture plus the side palette, and tall enough for every tool.
        do {
            let strip = EditorDocument(image: Self.sampleImage(width: 2313, height: 233, scale: 1), pixelScale: 2)
            let sed = EditorWindowController(document: strip)
            sed.window?.layoutIfNeeded()
            let content = sed.window?.contentView?.frame.size ?? .zero
            let backing = sed.window?.backingScaleFactor ?? 2
            let expectedW = 2313 / backing + 46 + 2
            note("strip editor content \(Int(content.width))×\(Int(content.height)) pt (picture \(Int(2313 / backing)) pt wide)")
            check(content.width <= expectedW + 40, "editor width follows the picture (\(Int(content.width)) ≤ \(Int(expectedW + 40)) pt)")
            if let last = sed.toolButtonFrames().last, let status = sed.statusBarTop() {
                check(last.maxY <= status - 4, "every tool button fits above the status bar (last ends \(Int(last.maxY)), bar at \(Int(status)))")
            }
        }

        // 4b. The canvas must not paint outside its own bounds (since macOS 14 views don't clip by
        // default, so overhang shows up as a strip past the picture). Size 1001×667 at zoom 0.5 is
        // deliberately not a multiple of the 8 pt checkerboard.
        do {
            let oddDoc = EditorDocument(image: Self.sampleImage(width: 1001, height: 667, scale: 1), pixelScale: 1)
            let c = CanvasView(document: oddDoc, renderer: Renderer(pixelScale: 1))
            c.zoom = 0.5
            let pad = 40
            let w = Int(c.bounds.width) + 2 * pad, h = Int(c.bounds.height) + 2 * pad
            if let ctx = Bitmap.makeContext(width: w, height: h) {
                ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1) // y-down like the flipped view
                ctx.translateBy(x: CGFloat(pad), y: CGFloat(pad))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                c.draw(c.bounds)
                NSGraphicsContext.restoreGraphicsState()
                if let img = ctx.makeImage(), let px = PixelReader(img) {
                    let right = pad + Int(c.bounds.width), bottom = pad + Int(c.bounds.height)
                    var spill = 0
                    for y in 0..<h { for x in right..<w where px[x, y].a > 0 { spill += 1 } }
                    for y in bottom..<h { for x in 0..<right where px[x, y].a > 0 { spill += 1 } }
                    check(spill == 0, "canvas paints nothing outside the picture (\(spill) px spilled)")
                }
            }
        }

        // 5. Selection overlay mid-drag with magnifier, and window-hover mode.
        let snapImage = Self.sampleImage(width: 1600, height: 1000, scale: 2)
        let fakeWindow = WindowInfo(windowID: 1, frame: CGRect(x: 100, y: 80, width: 520, height: 320),
                                    title: "Terminal — ssh proxmox", appName: "Terminal", scWindow: nil)
        let snap = ScreenSnapshot(image: snapImage, frame: CGRect(x: 0, y: 0, width: 800, height: 500), scale: 2,
                                  displays: [], windows: [fakeWindow])
        for (name, mode, drag) in [("04-overlay-region-drag.png", SelectionOverlay.Mode.region, true),
                                   ("04-overlay-window-hover.png", SelectionOverlay.Mode.window, false)] {
            let o = SelectionOverlay(snapshot: snap, mode: mode, showMagnifier: true)
            o.cursor = CGPoint(x: 470, y: 300)
            if drag { o.dragStart = CGPoint(x: 140, y: 120) } else { o.hovered = fakeWindow }
            let c = SelectionContainerView(overlay: o, globalRect: snap.frame, frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            o.drawViews = [c.drawView]
            o.refresh()
            // The dim/border are GPU layers now, so they're rendered separately and stacked like the screen does.
            let dim = Self.renderLayer(c.dimView, scale: 2)
            let layer = snapshotView(c.drawView)
            save(Bitmap.render(width: 1600, height: 1000) { ctx in
                let full = CGRect(x: 0, y: 0, width: 1600, height: 1000)
                Bitmap.drawImage(snapImage, in: full, ctx: ctx)
                if let dim { Bitmap.drawImage(dim, in: full, ctx: ctx) }
                if let layer { Bitmap.drawImage(layer, in: full, ctx: ctx) }
            }, name)
        }
        let probe = SelectionOverlay(snapshot: snap, mode: .region, showMagnifier: false)
        do {
            var warps: [CGPoint] = [], follow: [Bool] = [], hidden: [Bool] = []
            probe.pointer = .init(warp: { warps.append($0) }, follow: { follow.append($0) }, setHidden: { hidden.append($0) })
            func event(_ type: CGEventType, dx: Int64 = 0, dy: Int64 = 0, shift: Bool) -> NSEvent? {
                let cg: CGEvent? = type == .flagsChanged ? CGEvent(source: nil)
                    : CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)
                guard let cg else { return nil }
                if type == .flagsChanged { cg.type = .flagsChanged }
                cg.setIntegerValueField(.mouseEventDeltaX, value: dx)
                cg.setIntegerValueField(.mouseEventDeltaY, value: dy)
                cg.flags = shift ? .maskShift : []
                return NSEvent(cgEvent: cg)
            }
            probe.flagsChanged(event(.flagsChanged, shift: true)!)
            probe.cursor = CGPoint(x: 300, y: 200)
            check(probe.isPrecise && follow == [false] && hidden == [true], "⇧ down freezes and hides the real pointer")
            for _ in 0..<4 { probe.mouseMoved(event(.mouseMoved, dx: 10, dy: 5, shift: true)) }
            check(probe.cursor == CGPoint(x: 310, y: 205) && warps.isEmpty,
                  "⇧ moves our crosshair at 25% speed without moving the real pointer (→ \(probe.cursor), \(warps.count) warps)")
            probe.mouseDragged(event(.leftMouseDragged, dx: -3000, dy: 0, shift: true)) // 16-bit field: keep it realistic
            check(probe.cursor.x == snap.frame.minX, "⇧ movement stops at the screen edge (x = \(probe.cursor.x))")
            probe.flagsChanged(event(.flagsChanged, shift: false)!)
            check(!probe.isPrecise && warps == [probe.cursor] && follow == [false, true] && hidden == [true, false],
                  "⇧ up puts the real pointer at the crosshair once, then unfreezes and shows it")
        }
        check(snap.crop(CGRect(x: 100, y: 80, width: 520, height: 320))?.width == 1040, "region crop maps points → pixels")
        check(probe.snapshot.window(at: CGPoint(x: 300, y: 200))?.windowID == 1, "window hit-test under cursor")

        // 5b. Fixer B's capture/overlay/hotkey/app checks.
        await runFixerBChecks(snap: snap, fakeWindow: fakeWindow)

        // 6. Preferences (SwiftUI) in a window.
        let host = NSHostingView(rootView: SettingsView(store: SettingsStore.shared))
        let sw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 592, height: 462), styleMask: [.titled], backing: .buffered, defer: false)
        sw.contentView = host
        save(snapshotView(host), "05-preferences.png")

        // 7. Hotkeys can be registered (then released again so a running copy isn't disturbed).
        let errors = HotkeyManager.shared.register(AppSettings())
        check(errors.isEmpty, "default hotkeys register: \(errors.isEmpty ? "all OK" : errors.values.joined(separator: "; "))")
        HotkeyManager.shared.unregisterAll()

        // 8. Real screen capture.
        let permitted = ScreenCapturer.hasPermission
        note("screen recording permission: \(permitted ? "granted" : "NOT granted")")
        guard includeCapture, permitted else { return }
        let cap = ScreenCapturer()
        do {
            let t = Date()
            let shot = try await cap.snapshot()
            let ms = Int(Date().timeIntervalSince(t) * 1000)
            note("displays: " + shot.parts.map { "\(Int($0.frame.width))×\(Int($0.frame.height))pt @\($0.frame.origin) ×\($0.scale)" }.joined(separator: ", "))
            check(shot.parts.count == shot.displays.count && shot.parts.allSatisfy { $0.image.width == Int(($0.frame.width * $0.scale).rounded()) },
                  "every display captured at its own native size (\(shot.parts.count) displays, \(ms) ms, concurrently)")
            if let full = shot.capture(shot.frame) {
                check(full.image.width == Int((shot.frame.width * full.scale).rounded()), "full-screen capture \(full.image.width)×\(full.image.height) px, scale \(full.scale)")
                save(Effects.resize(full.image, width: full.image.width / 3, height: full.image.height / 3), "06-fullscreen-third.png")
            } else { check(false, "full-screen capture") }
            note("windows found: \(shot.windows.count): " + shot.windows.prefix(6).map(\.displayTitle).joined(separator: " | "))
            if let w = shot.windows.first(where: { $0.scWindow != nil }) {
                cap.includeWindowShadow = true
                let (img, wScale) = try await cap.captureWindow(w)
                note("window capture scale \(wScale)")
                save(img, "06-window-shadow.png")
                let corner = PixelReader(img)?[0, 0]
                note("window '\(w.displayTitle)' frame \(w.frame.size) → \(img.width)×\(img.height) px, corner alpha \(corner?.a ?? 255)")
                cap.includeWindowShadow = false
                let plain = try await cap.captureWindow(w).image
                save(plain, "06-window-plain.png")
                check(plain.width <= img.width, "window capture without shadow is not larger (\(plain.width) ≤ \(img.width))")
                // The window inside the shadow capture must be full size, not shrunk to make room.
                if let px = PixelReader(img) {
                    let row = (0..<px.width).filter { px[$0, px.height / 2].a > 250 }
                    let col = (0..<px.height).filter { px[px.width / 2, $0].a > 250 }
                    let ww = (row.last ?? 0) - (row.first ?? 0) + 1, wh = (col.last ?? 0) - (col.first ?? 0) + 1
                    check(abs(ww - plain.width) <= 2 && abs(wh - plain.height) <= 4,
                          "window inside shadow capture is full size: \(ww)×\(wh) vs \(plain.width)×\(plain.height)")
                    let margins = "left \(row.first ?? -1), right \(px.width - 1 - (row.last ?? 0)), top \(col.first ?? -1), bottom \(px.height - 1 - (col.last ?? 0))"
                    note("shadow margins px: " + margins)
                }
            }
        } catch {
            check(false, "screen capture: \(error.localizedDescription)")
        }
    }
}

// MARK: - Fixer B checks (capture, overlay, hotkeys, app shell)

/// Stands in for an editor when testing the Quit review.
@MainActor
final class FakeQuitEditor: QuitReviewable {
    let name: String
    var hasUnsavedWork: Bool
    var pending: ((Bool) -> Void)?
    var asked: (String) -> Void
    init(_ name: String, unsaved: Bool = true, asked: @escaping (String) -> Void) {
        self.name = name; hasUnsavedWork = unsaved; self.asked = asked
    }
    func confirmDiscardForQuit(_ done: @escaping (Bool) -> Void) { asked(name); pending = done }
}

extension SelfTest {
    /// Synthetic events with explicit, distinct timestamps (a repeat of the same event keeps its own).
    static func cgEvent(_ type: CGEventType, dx: Int64 = 0, dy: Int64 = 0, flags: CGEventFlags = [],
                        stamp: UInt64) -> NSEvent? {
        let cg: CGEvent? = type == .flagsChanged ? CGEvent(source: nil)
            : CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left)
        guard let cg else { return nil }
        if type == .flagsChanged { cg.type = .flagsChanged }
        cg.setIntegerValueField(.mouseEventDeltaX, value: dx)
        cg.setIntegerValueField(.mouseEventDeltaY, value: dy)
        cg.flags = flags
        cg.timestamp = stamp
        return NSEvent(cgEvent: cg)
    }

    static func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                         keyCode: code)!
    }

    /// Renders a dim view's layers (as the GPU would composite them) into a y-up bitmap.
    static func renderLayer(_ v: NSView, scale: CGFloat) -> CGImage? {
        guard let layer = v.layer,
              let ctx = Bitmap.makeContext(width: Int(v.bounds.width * scale), height: Int(v.bounds.height * scale))
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    func runFixerBChecks(snap: ScreenSnapshot, fakeWindow: WindowInfo) async {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        var stamp: UInt64 = 1_000_000
        func ev(_ t: CGEventType, dx: Int64 = 0, dy: Int64 = 0, _ flags: CGEventFlags = []) -> NSEvent {
            stamp += 1_000_000
            return Self.cgEvent(t, dx: dx, dy: dy, flags: flags, stamp: stamp)!
        }
        /// An overlay that never touches the real pointer; `loc` is where the "mouse" is (global, y-down).
        final class Rig {
            var loc = CGPoint.zero
            var follow: [Bool] = [], hidden: [Bool] = [], warps: [CGPoint] = []
            var mods: NSEvent.ModifierFlags = []
            var outcome: SelectionOverlay.Outcome?
        }
        func rig(_ mode: SelectionOverlay.Mode = .region, snapshot: ScreenSnapshot? = nil) -> (SelectionOverlay, Rig) {
            let r = Rig()
            let o = SelectionOverlay(snapshot: snapshot ?? snap, mode: mode, showMagnifier: false)
            o.pointer = .init(warp: { r.warps.append($0) }, follow: { r.follow.append($0) }, setHidden: { r.hidden.append($0) },
                              location: { CGPoint(x: r.loc.x, y: primaryH - r.loc.y) }, modifiers: { r.mods })
            return (o, r)
        }
        func outcomeText(_ o: SelectionOverlay.Outcome?) -> String {
            switch o {
            case nil: return "none"
            case .cancelled?: return "cancelled"
            case .region(let r)?: return "region \(r)"
            case .window?: return "window"
            }
        }

        // CAPTURE_APP-1: Esc mid-drag, then releasing the button, captures nothing.
        do {
            let (o, r) = rig()
            o.attach { r.outcome = $0 }
            r.loc = CGPoint(x: 300, y: 200) // over the fake window
            o.mouseMoved(ev(.mouseMoved)); o.mouseDown(nil)
            r.loc = CGPoint(x: 420, y: 300); o.mouseDragged(ev(.leftMouseDragged))
            o.keyDown(Self.key(53))
            o.mouseUp(nil)
            check(r.outcome == nil && o.isActive, "B: CAPTURE_APP-1 Esc mid-drag then mouse-up captures nothing (outcome \(outcomeText(r.outcome)))")
            r.loc = CGPoint(x: 150, y: 120); o.mouseDown(nil)
            r.loc = CGPoint(x: 250, y: 220); o.mouseDragged(ev(.leftMouseDragged)); o.mouseUp(nil)
            if case .region(let rect)? = r.outcome {
                check(rect == CGRect(x: 150, y: 120, width: 100, height: 100), "B: CAPTURE_APP-1 the next drag still selects normally (\(rect))")
            } else { check(false, "B: CAPTURE_APP-1 the next drag still selects normally (\(outcomeText(r.outcome)))") }
        }

        // CAPTURE_APP-2: losing focus cancels the overlay and gives the pointer back.
        do {
            let (o, r) = rig()
            o.attach { r.outcome = $0 }
            o.flagsChanged(ev(.flagsChanged, .maskShift))
            let wasPrecise = o.isPrecise
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            try? await Task.sleep(nanoseconds: 100_000_000)
            var cancelled = false
            if case .cancelled? = r.outcome { cancelled = true }
            check(wasPrecise && cancelled && !o.isActive && !o.isPrecise && r.follow.last == true && r.hidden.last == false,
                  "B: CAPTURE_APP-2 app losing focus cancels the overlay and re-attaches/unhides the pointer (outcome \(outcomeText(r.outcome)), follow \(r.follow), hidden \(r.hidden))")
        }

        // CAPTURE_APP-11: ⌃⇧ still held from the hotkey; letting go of ⌃ first must not enter precision.
        do {
            let (o, r) = rig()
            r.mods = [.control, .shift]
            o.attach { r.outcome = $0 }
            o.flagsChanged(ev(.flagsChanged, .maskShift)) // ⌃ released, ⇧ still down
            let afterCtrlUp = o.isPrecise
            o.flagsChanged(ev(.flagsChanged)) // all up
            let afterAllUp = o.isPrecise
            o.flagsChanged(ev(.flagsChanged, .maskShift)) // a real ⇧ press
            let afterShift = o.isPrecise
            o.flagsChanged(ev(.flagsChanged, [.maskShift, .maskCommand]))
            check(!afterCtrlUp && !afterAllUp && afterShift && !o.isPrecise,
                  "B: CAPTURE_APP-11 precision only on a fresh ⇧ alone after the hotkey's modifiers are up (\(afterCtrlUp), \(afterAllUp), \(afterShift), \(o.isPrecise))")
            o.finish(.cancelled)
        }

        // Reviewer's suspicion: the same mouseMoved arriving twice (first responder + tracking area)
        // must not double the precision speed.
        do {
            let (o, r) = rig()
            r.loc = CGPoint(x: 300, y: 200)
            let v = SelectionDrawView(overlay: o, globalRect: snap.frame, frame: CGRect(origin: .zero, size: snap.frame.size))
            v.flagsChanged(with: ev(.flagsChanged, .maskShift))
            let start = o.cursor
            for _ in 0..<4 {
                let e = ev(.mouseMoved, dx: 10, dy: 5, .maskShift)
                v.mouseMoved(with: e) // via acceptsMouseMovedEvents (first responder)
                v.mouseMoved(with: e) // via the .mouseMoved tracking area
            }
            // AppKit may also hand the second path a separate NSEvent copy of the same moment.
            let e1 = ev(.mouseMoved, dx: 8, dy: 0, .maskShift)
            v.mouseMoved(with: e1)
            if let cg = e1.cgEvent?.copy(), let copy = NSEvent(cgEvent: cg) { v.mouseMoved(with: copy) }
            let moved = CGPoint(x: o.cursor.x - start.x, y: o.cursor.y - start.y)
            check(moved == CGPoint(x: 12, y: 5),
                  "B: ⇧ precision stays 25% when each mouse move is delivered twice (moved \(moved), want (12, 5))")
            o.setPrecise(false)
        }

        // CAPTURE_APP-8: the size label is the size of the crop, also at half-pixel edges.
        do {
            let (o, _) = rig()
            o.dragStart = CGPoint(x: 100.25, y: 50.25)
            o.cursor = CGPoint(x: 200.75, y: 80.75)
            let sel = o.selectionRect!
            let crop = snap.crop(sel)
            let label = o.sizeLabel(sel)
            check(label == "\(crop?.width ?? -1) × \(crop?.height ?? -1) px", "B: CAPTURE_APP-8 label '\(label)' matches the crop \(crop?.width ?? -1)×\(crop?.height ?? -1)")
        }

        // CAPTURE_APP-3: mixed DPI keeps each display's native pixels.
        let retina = Self.sampleImage(width: 1600, height: 1000, scale: 2)
        let plain = Self.sampleImage(width: 600, height: 400, scale: 1)
        let mixed = ScreenSnapshot(parts: [DisplayImage(image: retina, frame: CGRect(x: 0, y: 0, width: 800, height: 500), scale: 2),
                                           DisplayImage(image: plain, frame: CGRect(x: 800, y: 0, width: 600, height: 400), scale: 1)],
                                   displays: [], windows: [])
        do {
            let on1x = mixed.capture(CGRect(x: 900, y: 100, width: 200, height: 100))
            let on2x = mixed.capture(CGRect(x: 100, y: 100, width: 200, height: 100))
            let across = mixed.capture(CGRect(x: 700, y: 100, width: 200, height: 100))
            check(on1x?.image.width == 200 && on1x?.scale == 1,
                  "B: CAPTURE_APP-3 crop on the 1x display is native 1x (\(on1x?.image.width ?? -1) px wide, scale \(on1x?.scale ?? -1))")
            check(on2x?.image.width == 400 && on2x?.scale == 2, "B: CAPTURE_APP-3 crop on the 2x display stays 2x (\(on2x?.image.width ?? -1) px)")
            check(across?.image.width == 400 && across?.scale == 2, "B: CAPTURE_APP-3 a crop spanning both is stitched at 2x (\(across?.image.width ?? -1) px)")
            if let img = on1x?.image, let a = PixelReader(img), let b = PixelReader(plain) {
                check(!a[37, 21].differs(from: b[137, 121], by: 0), "B: CAPTURE_APP-3 the 1x crop is the display's own pixels, not resampled")
            }
            if let img = across?.image, let a = PixelReader(img), let b = PixelReader(retina) {
                check(!a[20, 40].differs(from: b[1420, 240], by: 0), "B: CAPTURE_APP-3 the 2x half of a stitched crop is copied 1:1")
            }
            check(mixed.pixelSize(for: CGRect(x: 700, y: 100, width: 200, height: 100)) == CGSize(width: 400, height: 200),
                  "B: CAPTURE_APP-3 pixelSize agrees with the stitched crop")
            let o = SelectionOverlay(snapshot: mixed, mode: .region, showMagnifier: false)
            let screenB = SelectionContainerView(overlay: o, globalRect: CGRect(x: 800, y: 0, width: 600, height: 400),
                                                 frame: CGRect(x: 0, y: 0, width: 600, height: 400))
            let contents = (screenB.layer?.contents as AnyObject?).flatMap { CFGetTypeID($0) == CGImage.typeID ? ($0 as! CGImage) : nil }
            check(contents?.width == 600, "B: CAPTURE_APP-3 the overlay shows the 1x screen from its native picture (\(contents?.width ?? -1) px)")
        }

        // CAPTURE_APP-12: the window fallback reports the display's own scale, and the old guess was wrong.
        do {
            let w = WindowInfo(windowID: 9, frame: CGRect(x: 900, y: 100, width: 120, height: 80), title: "", appName: "x", scWindow: nil)
            check(mixed.capture(w.frame)?.scale == 1, "B: CAPTURE_APP-12 window on a 1x display gets scale 1 (snapshot fallback)")
            let shadowed = CGFloat(120 + 2 * 45) // a 1x capture with its shadow margin
            let oldGuess = min(max(1, (shadowed / w.frame.width).rounded()), mixed.scale)
            note("B: CAPTURE_APP-12 the old width-ratio guess would have said \(oldGuess)x for that window; captureWindow now returns pointPixelScale")
        }

        // CAPTURE_APP-13: only menus/overlays of our own are cut out of captures.
        do {
            let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
            let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
            check(!ScreenCapturer.excludedFromCapture(layer: 0, ownedByUs: true)
                  && !ScreenCapturer.excludedFromCapture(layer: statusLevel, ownedByUs: true)
                  && ScreenCapturer.excludedFromCapture(layer: menuLevel, ownedByUs: true)
                  && ScreenCapturer.excludedFromCapture(layer: Int(CGWindowLevelForKey(.screenSaverWindow)), ownedByUs: true)
                  && !ScreenCapturer.excludedFromCapture(layer: menuLevel, ownedByUs: false),
                  "B: CAPTURE_APP-13 own editor/Preferences/menu-bar icon stay in captures; own menus and overlays don't")
        }

        // CAPTURE_APP-9: the dim is GPU layers, and untouched screens aren't redrawn.
        do {
            let o = SelectionOverlay(snapshot: mixed, mode: .region, showMagnifier: false)
            let a = SelectionContainerView(overlay: o, globalRect: CGRect(x: 0, y: 0, width: 800, height: 500), frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            let b = SelectionContainerView(overlay: o, globalRect: CGRect(x: 800, y: 0, width: 600, height: 400), frame: CGRect(x: 0, y: 0, width: 600, height: 400))
            o.drawViews = [a.drawView, b.drawView]
            o.cursor = CGPoint(x: 100, y: 100); o.refresh()
            let redrawsA = a.drawView.redraws, redrawsB = b.drawView.redraws
            o.dragStart = CGPoint(x: 100, y: 100)
            for i in 1...20 {
                o.cursor = CGPoint(x: 100 + CGFloat(i) * 10, y: 100 + CGFloat(i) * 5)
                o.refresh()
            }
            let aChanged = a.drawView.redraws - redrawsA, bChanged = b.drawView.redraws - redrawsB
            check(aChanged == 20 && bChanged == 0,
                  "B: CAPTURE_APP-9 dragging on one screen redraws only that screen (\(aChanged) / \(bChanged) redraws)")
            if let img = Self.renderLayer(a.dimView, scale: 2), let px = PixelReader(img) {
                // Selection is (100,100)-(300,200) pt, y-down: inside clear, outside 35% black.
                let inside = px[400, 300].a, outside = px[100, 900].a, above = px[400, 100].a
                check(inside == 0 && (80...100).contains(Int(outside)) && (80...100).contains(Int(above)),
                      "B: CAPTURE_APP-9 dim layer clears the selection only (alpha inside \(inside), below \(outside), above \(above))")
            } else { check(false, "B: CAPTURE_APP-9 dim layer renders") }

            // Cost of a drag repaint on a 5K screen (the CPU part only; the dim is composited).
            let big = ScreenSnapshot(image: Self.sampleImage(width: 5120, height: 2880, scale: 2),
                                     frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), scale: 2, displays: [], windows: [])
            let ob = SelectionOverlay(snapshot: big, mode: .region, showMagnifier: true)
            let v = SelectionDrawView(overlay: ob, globalRect: big.frame, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
            func drawCost() -> Double {
                guard let ctx = Bitmap.makeContext(width: 5120, height: 2880) else { return -1 }
                ctx.translateBy(x: 0, y: 2880); ctx.scaleBy(x: 2, y: -2)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                defer { NSGraphicsContext.restoreGraphicsState() }
                v.draw(v.bounds) // warm-up
                return time { for _ in 0..<10 { v.draw(v.bounds) } } / 10
            }
            ob.cursor = CGPoint(x: 1800, y: 900)
            let hover = drawCost()
            ob.dragStart = CGPoint(x: 300, y: 200)
            let drag = drawCost()
            check(drag < hover * 2 + 3, "B: CAPTURE_APP-9 5K drag repaint \(String(format: "%.1f", drag)) ms ≈ hover \(String(format: "%.1f", hover)) ms (was ~19 ms with the CPU dim)")
        }

        // CAPTURE_APP-15: clipboard check without decoding.
        do {
            let pb = NSPasteboard(name: NSPasteboard.Name("shotty-selftest-\(UUID().uuidString)"))
            pb.clearContents()
            pb.writeObjects([NSImage(cgImage: plain, size: NSSize(width: 60, height: 40))])
            let withImage = Output.clipboardHasImage(pb)
            pb.clearContents()
            pb.setString("text only", forType: .string)
            let withText = Output.clipboardHasImage(pb)
            pb.releaseGlobally()
            check(withImage && !withText, "B: CAPTURE_APP-15 clipboard image check (image \(withImage), text \(withText))")
        }

        let ad = AppDelegate()
        let result = CaptureResult(image: plain, scale: 1, title: "Test", date: Date())

        // CAPTURE_APP-16: the ask-each-time menu carries the capture; the app keeps no copy of it.
        do {
            let menu = ad.makeDestinationMenu(result)
            let choices = menu.items.compactMap { $0.representedObject as? AppDelegate.DestinationChoice }
            let holdsCapture = Mirror(reflecting: ad).children.contains {
                ["CaptureResult", "Optional<CaptureResult>"].contains("\(type(of: $0.value))")
            }
            check(choices.count == Destination.allCases.count && choices.allSatisfy { $0.result.image === plain }
                  && choices.last?.destination == nil && !holdsCapture,
                  "B: CAPTURE_APP-16 menu items carry the capture, the app delegate holds none (\(choices.count) choices, holds \(holdsCapture))")
        }

        // CAPTURE_APP-17 (+C1/C4): a Save As file becomes the editor's file.
        do {
            var docs: [EditorDocument] = []
            ad.presentEditor = { docs.append($0) }
            let url = URL(fileURLWithPath: "/tmp/shotty-selftest-saveas.png")
            ad.presentSaveAs = { _, done in done(url) }
            ad.run([.fileAs, .editor], result)
            ad.presentSaveAs = { _, done in done(nil) }
            ad.run([.fileAs, .editor], result)
            ad.run([.editor], result)
            check(docs.count == 3 && docs[0].fileURL == url && docs[0].wasExported,
                  "B: CAPTURE_APP-17 Save As + editor: the editor's file is the one just chosen, and it counts as exported")
            check(docs.count == 3 && docs[1].fileURL == nil && !docs[1].wasExported && !docs[2].wasExported,
                  "B: C4 cancelled Save As / editor only: the capture exists nowhere else (wasExported false)")
        }

        // CAPTURE_APP-18: a remembered region that's on no display falls back to selecting.
        do {
            let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
            let r = CGRect(x: 2000, y: 100, width: 300, height: 200) // was on an unplugged display
            check(AppDelegate.lastRegionPlan(r, displays: screens) == .select
                  && AppDelegate.lastRegionPlan(nil, displays: screens) == .select
                  && AppDelegate.lastRegionPlan(CGRect(x: 10, y: 10, width: 50, height: 50), displays: screens)
                    == .capture(CGRect(x: 10, y: 10, width: 50, height: 50)),
                  "B: CAPTURE_APP-18 last region off every display → region selection instead of nothing")
        }

        // CAPTURE_APP-10: no overlay during an app-modal session (it would get no mouse input).
        do {
            var beeps = 0
            ad.beep = { beeps += 1 }
            let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            var duringModal: (allowed: Bool, modal: Bool) = (true, false)
            let t = Timer(timeInterval: 0.05, repeats: false) { _ in
                MainActor.assumeIsolated {
                    duringModal = (ad.canStartCapture, NSApp.modalWindow != nil)
                    ad.capture(.region)
                    NSApp.stopModal()
                }
            }
            RunLoop.main.add(t, forMode: .modalPanel)
            NSApp.runModal(for: w)
            w.orderOut(nil)
            check(duringModal.modal && !duringModal.allowed && beeps == 1 && ad.canStartCapture,
                  "B: CAPTURE_APP-10 a hotkey during a modal panel beeps instead of opening a dead overlay (modal \(duringModal.modal), beeps \(beeps))")
        }

        // CORE_EDITOR-2: Quit asks each editor with unsaved work, in turn; Cancel stops it.
        do {
            check(ad.applicationShouldTerminate(NSApp) == .terminateNow, "B: CORE_EDITOR-2 no editors → quit right away")
            var asked: [String] = []
            var answer: Bool?
            let a = FakeQuitEditor("a") { asked.append($0) }, b = FakeQuitEditor("b") { asked.append($0) },
                c = FakeQuitEditor("c") { asked.append($0) }
            AppDelegate.reviewForQuit([a, b, c]) { answer = $0 }
            let firstOnly = asked == ["a"] && answer == nil
            a.pending?(true)
            let thenB = asked == ["a", "b"] && answer == nil
            b.pending?(false)
            check(firstOnly && thenB && asked == ["a", "b"] && answer == false,
                  "B: CORE_EDITOR-2 editors asked one at a time; Cancel on one stops the quit (asked \(asked), answer \(String(describing: answer)))")
            asked = []; answer = nil
            AppDelegate.reviewForQuit([a, c]) { answer = $0 }
            a.pending?(true); c.pending?(true)
            check(asked == ["a", "c"] && answer == true, "B: CORE_EDITOR-2 Save / Don't Save on all → quit goes ahead")
            // A real editor of a fresh capture has work to lose; one opened from a file doesn't.
            let fresh = EditorWindowController(document: EditorDocument(image: plain, pixelScale: 1))
            let opened = EditorDocument(image: plain, pixelScale: 1); opened.wasExported = true
            let fromFile = EditorWindowController(document: opened)
            check(fresh.hasUnsavedWork && !fromFile.hasUnsavedWork,
                  "B: CORE_EDITOR-2 a fresh capture's editor needs review, an unedited opened file doesn't")
        }

        // CAPTURE_APP-5 / -7: suspension really releases the keys; duplicates are reported as such.
        do {
            let hm = HotkeyManager.shared
            let hk = Hotkey(keyCode: 80, modifiers: [.control, .option, .shift, .command]) // ⌃⌥⇧⌘F19
            var s = AppSettings()
            s.hotkeys = [HotkeyAction.region.rawValue: hk]
            var resumed: [HotkeyAction: String]?
            hm.onErrors = { resumed = $0 }
            let errs = hm.register(s)
            func canGrab() -> Bool {
                var ref: EventHotKeyRef?
                let st = RegisterEventHotKey(hk.keyCode, hk.modifiers.carbonFlags, EventHotKeyID(signature: 0x5445_5354, id: 99),
                                             GetApplicationEventTarget(), 0, &ref)
                if let ref { UnregisterEventHotKey(ref) }
                return st == noErr
            }
            let heldBefore = !canGrab()
            hm.setSuspended(true)
            let releasedWhileRecording = hm.registeredCount == 0 && canGrab()
            hm.setSuspended(false)
            check(errs.isEmpty && heldBefore && releasedWhileRecording && hm.registeredCount == 1 && resumed?.isEmpty == true,
                  "B: CAPTURE_APP-5 recording releases registered hotkeys (so they can be recorded) and resuming re-registers them")

            s.hotkeys[HotkeyAction.window.rawValue] = hk
            let dupErrs = hm.register(s)
            check(HotkeyManager.duplicates(in: s) == [.window: .region] && dupErrs[.window] == "Same shortcut as Capture Region"
                  && hm.registeredCount == 1,
                  "B: CAPTURE_APP-7 two actions with one shortcut: '\(dupErrs[.window] ?? "-")', not 'used by another app'")
            hm.unregisterAll()
            hm.onErrors = nil
        }

        // CAPTURE_APP-6: recording ends when the window/app loses focus or the field goes away.
        do {
            let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 300, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            w.contentView = content
            let b = RecorderButton()
            b.frame = NSRect(x: 10, y: 10, width: 150, height: 24)
            content.addSubview(b)
            let hm = HotkeyManager.shared
            var results: [String] = []
            func attempt(_ name: String, _ trigger: () -> Void) async {
                b.toggle()
                let started = b.isRecording && hm.isSuspended
                trigger()
                try? await Task.sleep(nanoseconds: 100_000_000)
                results.append("\(name): \(started && !b.isRecording && !hm.isSuspended ? "stopped" : "STILL RECORDING")")
            }
            await attempt("window resigned key") {
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
            }
            await attempt("app resigned active") {
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            }
            await attempt("click elsewhere") {
                if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 250, y: 80), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.sendEvent(e)
                }
            }
            await attempt("removed from the window") { b.removeFromSuperview() }
            check(!results.contains { $0.contains("STILL") }, "B: CAPTURE_APP-6 recording ends on: " + results.joined(separator: ", "))
            hm.setSuspended(false)
            hm.unregisterAll()
        }

        // CAPTURE_APP-19: awaiting approval shows as on, with a hint.
        check(LoginItemUI.isOn(.requiresApproval) && LoginItemUI.hint(.requiresApproval) != nil
              && LoginItemUI.isOn(.enabled) && LoginItemUI.hint(.enabled) == nil && !LoginItemUI.isOn(.notRegistered),
              "B: CAPTURE_APP-19 'requires approval' keeps the toggle on and explains where to approve")

        // CAPTURE_APP-4: banners while frontmost need the delegate's presentation options.
        check(NotificationPresenter.foregroundOptions.contains(.banner),
              "B: CAPTURE_APP-4 foreground notifications are presented as banners (delegate installed at launch)")
    }
}
