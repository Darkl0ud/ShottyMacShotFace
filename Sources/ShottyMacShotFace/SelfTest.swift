import AppKit
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
            let v = SelectionDrawView(overlay: o, globalRect: snap.frame, frame: CGRect(x: 0, y: 0, width: 800, height: 500))
            let layer = snapshotView(v)
            save(Bitmap.render(width: 1600, height: 1000) { ctx in
                Bitmap.drawImage(snapImage, in: CGRect(x: 0, y: 0, width: 1600, height: 1000), ctx: ctx)
                if let layer { Bitmap.drawImage(layer, in: CGRect(x: 0, y: 0, width: 1600, height: 1000), ctx: ctx) }
            }, name)
        }
        let probe = SelectionOverlay(snapshot: snap, mode: .region, showMagnifier: false)
        do {
            var warped: CGPoint?
            probe.warp = { warped = $0 } // never move the real mouse during the test
            probe.cursor = CGPoint(x: 300, y: 200)
            func moved(dx: Int64, dy: Int64, shift: Bool) -> NSEvent? {
                guard let cg = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                       mouseCursorPosition: .zero, mouseButton: .left) else { return nil }
                cg.setIntegerValueField(.mouseEventDeltaX, value: dx)
                cg.setIntegerValueField(.mouseEventDeltaY, value: dy)
                if shift { cg.flags = .maskShift }
                return NSEvent(cgEvent: cg)
            }
            probe.track(moved(dx: 40, dy: 20, shift: true))
            check(probe.cursor == CGPoint(x: 310, y: 205) && warped == probe.cursor,
                  "⇧ moves the selection cursor at 25% speed (40,20 → +\(probe.cursor.x - 300),+\(probe.cursor.y - 200)) and puts the pointer there")
            probe.track(moved(dx: -3000, dy: 0, shift: true)) // delta field is 16-bit, keep it realistic
            check(probe.cursor.x == snap.frame.minX, "⇧ movement stops at the screen edge (x = \(probe.cursor.x))")
        }
        check(snap.crop(CGRect(x: 100, y: 80, width: 520, height: 320))?.width == 1040, "region crop maps points → pixels")
        check(probe.snapshot.window(at: CGPoint(x: 300, y: 200))?.windowID == 1, "window hit-test under cursor")

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
            note("displays: " + shot.displays.map { "\($0.name) \(Int($0.frame.width))×\(Int($0.frame.height))pt @\($0.frame.origin)" }.joined(separator: ", "))
            check(shot.image.width == Int(shot.frame.width * shot.scale), "full-screen capture \(shot.image.width)×\(shot.image.height) px, scale \(shot.scale), \(ms) ms")
            save(Effects.resize(shot.image, width: shot.image.width / 3, height: shot.image.height / 3), "06-fullscreen-third.png")
            note("windows found: \(shot.windows.count): " + shot.windows.prefix(6).map(\.displayTitle).joined(separator: " | "))
            if let w = shot.windows.first(where: { $0.scWindow != nil }) {
                cap.includeWindowShadow = true
                let img = try await cap.captureWindow(w)
                save(img, "06-window-shadow.png")
                let corner = PixelReader(img)?[0, 0]
                note("window '\(w.displayTitle)' frame \(w.frame.size) → \(img.width)×\(img.height) px, corner alpha \(corner?.a ?? 255)")
                cap.includeWindowShadow = false
                let plain = try await cap.captureWindow(w)
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
