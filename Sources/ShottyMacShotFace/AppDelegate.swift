import AppKit
import Combine
import ImageIO
import ShottyCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, EditorHost {
    let store = SettingsStore.shared
    let capturer = ScreenCapturer()
    private var statusItem: NSStatusItem!
    private var editors: [EditorWindowController] = []
    private var settingsWindow: NSWindow?
    private var overlay: SelectionOverlay?
    private var busy = false
    private var cancellables = Set<AnyCancellable>()
    private var registeredHotkeys: [String: Hotkey] = [:]
    private var pendingResult: CaptureResult?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = Self.makeAppIcon()
        NSApp.mainMenu = MainMenu.build()
        setupStatusItem()

        HotkeyManager.shared.onHotkey = { [weak self] action in self?.capture(action) }
        registerHotkeys()
        // @Published fires before the value is stored, so re-register on the next turn.
        store.$settings
            .map(\.hotkeys)
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotkeys() } }
            .store(in: &cancellables)

        // Ask once up front; macOS shows its own prompt and remembers the answer.
        if !ScreenCapturer.hasPermission { CGRequestScreenCaptureAccess() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func registerHotkeys() {
        guard store.settings.hotkeys != registeredHotkeys || registeredHotkeys.isEmpty else { return }
        registeredHotkeys = store.settings.hotkeys
        store.hotkeyErrors = HotkeyManager.shared.register(store.settings)
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ShottyMacShotFace")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = "ShottyMacShotFace"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt each time it opens, so hotkeys, displays and toggles are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menu.removeAllItems()
        let s = store.settings

        func item(_ title: String, _ action: Selector, hotkey: HotkeyAction? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            if let hotkey, let hk = s.hotkey(for: hotkey) { Self.showHotkey(hk, on: i) }
            return i
        }

        menu.addItem(item("Capture Region", #selector(menuRegion), hotkey: .region))
        let last = item("Capture Last Region", #selector(menuLastRegion), hotkey: .lastRegion)
        if s.lastRegion == nil { last.action = nil }
        menu.addItem(last)
        menu.addItem(item("Capture Window", #selector(menuWindow), hotkey: .window))
        let full = item("Capture Full Screen", #selector(menuFullScreen), hotkey: .fullScreen)
        menu.addItem(full)
        if NSScreen.screens.count > 1 {
            let sub = NSMenu()
            let all = NSMenuItem(title: "All Screens", action: #selector(menuFullScreen), keyEquivalent: "")
            all.target = self
            sub.addItem(all)
            for (i, screen) in NSScreen.screens.enumerated() {
                let it = NSMenuItem(title: screen.localizedName, action: #selector(menuOneScreen(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                sub.addItem(it)
            }
            let parent = NSMenuItem(title: "Capture Screen", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Image from File…", #selector(openImageFile)))
        let clip = item("Open Image from Clipboard", #selector(openImageFromClipboard))
        if NSImage(pasteboard: .general) == nil { clip.action = nil }
        menu.addItem(clip)
        let reveal = item("Show Last Capture in Finder", #selector(revealLastCapture))
        if Output.lastSavedURL == nil { reveal.action = nil }
        menu.addItem(reveal)
        menu.addItem(item("Open Capture Folder", #selector(openCaptureFolder)))
        menu.addItem(.separator())

        let quick = NSMenu()
        let header = NSMenuItem(title: "After capture:", action: nil, keyEquivalent: "")
        quick.addItem(header)
        for d in Destination.allCases {
            let i = NSMenuItem(title: d.title, action: #selector(toggleDestination(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = d.rawValue
            i.state = s.destinations.contains(d) ? .on : .off
            i.indentationLevel = 1
            quick.addItem(i)
        }
        quick.addItem(.separator())
        for (title, key) in [("Capture Mouse Pointer", "pointer"), ("Window Shadow", "shadow"),
                             ("Magnifier", "magnifier"), ("Camera Sound", "sound")] {
            let i = NSMenuItem(title: title, action: #selector(toggleQuickSetting(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = key
            switch key {
            case "pointer": i.state = s.captureMousePointer ? .on : .off
            case "shadow": i.state = s.windowShadow ? .on : .off
            case "magnifier": i.state = s.showMagnifier ? .on : .off
            default: i.state = s.playSound ? .on : .off
            }
            quick.addItem(i)
        }
        let quickItem = NSMenuItem(title: "Quick Preferences", action: nil, keyEquivalent: "")
        quickItem.submenu = quick
        menu.addItem(quickItem)
        let prefs = item("Preferences…", #selector(showPreferences(_:)))
        prefs.keyEquivalent = ","
        menu.addItem(prefs)
        if !ScreenCapturer.hasPermission {
            menu.addItem(item("⚠︎ Grant Screen Recording Permission…", #selector(openPermissionSettings)))
        }
        menu.addItem(.separator())
        menu.addItem(item("About ShottyMacShotFace", #selector(showAbout(_:))))
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Menus can only display a shortcut whose key is a character; others go in the title.
    static func showHotkey(_ hk: Hotkey, on item: NSMenuItem) {
        let name = KeyNames.name(for: hk.keyCode)
        if name.count == 1, name.rangeOfCharacter(from: .alphanumerics) != nil {
            item.keyEquivalent = name.lowercased()
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: hk.modifiers.rawValue)
        } else {
            item.title += "    \(hk.display)"
        }
    }

    @objc private func menuRegion() { capture(.region) }
    @objc private func menuLastRegion() { capture(.lastRegion) }
    @objc private func menuWindow() { capture(.window) }
    @objc private func menuFullScreen() { capture(.fullScreen) }
    @objc private func menuOneScreen(_ sender: NSMenuItem) {
        guard NSScreen.screens.indices.contains(sender.tag) else { return }
        let h = NSScreen.screens.first?.frame.height ?? 0
        let rect = Geometry.flipRect(NSScreen.screens[sender.tag].frame, primaryHeight: h)
        captureRect(rect, title: NSScreen.screens[sender.tag].localizedName)
    }

    @objc private func toggleDestination(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let d = Destination(rawValue: raw) else { return }
        var list = store.settings.destinations
        if list.contains(d) { list.removeAll { $0 == d } } else { list.append(d) }
        store.settings.destinations = Destination.allCases.filter { list.contains($0) }
    }

    @objc private func toggleQuickSetting(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "pointer": store.settings.captureMousePointer.toggle()
        case "shadow": store.settings.windowShadow.toggle()
        case "magnifier": store.settings.showMagnifier.toggle()
        default: store.settings.playSound.toggle()
        }
    }

    @objc private func openPermissionSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func revealLastCapture() {
        if let url = Output.lastSavedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func openCaptureFolder() {
        let url = store.settings.outputFolderURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ShottyMacShotFace",
            .credits: NSAttributedString(string: "A Greenshot-style screenshot tool for macOS."),
        ])
    }

    // MARK: Capturing

    func capture(_ action: HotkeyAction) {
        guard !busy, overlay == nil else { return }
        busy = true
        capturer.captureCursor = store.settings.captureMousePointer
        capturer.includeWindowShadow = store.settings.windowShadow
        Task { @MainActor in
            defer { busy = false }
            do {
                switch action {
                case .fullScreen:
                    let snap = try await capturer.snapshot()
                    deliver(CaptureResult(image: snap.image, scale: snap.scale, title: "Full Screen", date: Date()))
                case .lastRegion:
                    guard let r = store.settings.lastRegion else {
                        try await interactiveCapture(startIn: .region) // nothing remembered yet
                        return
                    }
                    let snap = try await capturer.snapshot()
                    guard let img = snap.crop(r) else { return }
                    deliver(CaptureResult(image: img, scale: snap.scale, title: snap.window(at: r.center)?.displayTitle ?? "Region",
                                          date: Date()))
                case .region, .window:
                    try await interactiveCapture(startIn: action == .region ? .region : .window)
                }
            } catch {
                Output.showError("Capture failed", error)
            }
        }
    }

    private func interactiveCapture(startIn mode: SelectionOverlay.Mode) async throws {
        let snap = try await capturer.snapshot()
        let date = Date()
        let o = SelectionOverlay(snapshot: snap, mode: mode, showMagnifier: store.settings.showMagnifier)
        overlay = o
        let outcome = await withCheckedContinuation { cont in o.begin { cont.resume(returning: $0) } }
        overlay = nil
        switch outcome {
        case .cancelled:
            return
        case .region(let r):
            store.settings.lastRegion = r
            guard let img = snap.crop(r) else { return }
            let title = snap.windows.first { $0.frame.contains(r.center) }?.displayTitle ?? "Region"
            deliver(CaptureResult(image: img, scale: snap.scale, title: title, date: date))
        case .window(let w):
            let img: CGImage
            do {
                img = try await capturer.captureWindow(w)
            } catch {
                // Fall back to the frozen picture of the window's area.
                guard let crop = snap.crop(w.frame) else { throw error }
                img = crop
            }
            let scale = max(1, (CGFloat(img.width) / max(1, w.frame.width)).rounded())
            deliver(CaptureResult(image: img, scale: min(scale, snap.scale), title: w.displayTitle, date: date))
        }
    }

    private func captureRect(_ rect: CGRect, title: String) {
        guard !busy else { return }
        busy = true
        capturer.captureCursor = store.settings.captureMousePointer
        Task { @MainActor in
            defer { busy = false }
            do {
                let snap = try await capturer.snapshot()
                guard let img = snap.crop(rect) else { return }
                deliver(CaptureResult(image: img, scale: snap.scale, title: title, date: Date()))
            } catch {
                Output.showError("Capture failed", error)
            }
        }
    }

    // MARK: Destinations

    func deliver(_ r: CaptureResult) {
        Output.playShutter()
        var dests = store.settings.destinations
        if dests.isEmpty { dests = [.editor] }
        if dests.contains(.ask) {
            showDestinationMenu(r)
        } else {
            run(dests, r)
        }
    }

    private func run(_ dests: [Destination], _ r: CaptureResult) {
        var savedURL: URL?
        for d in dests where d != .editor && d != .ask {
            switch d {
            case .clipboard:
                Output.copyToClipboard(r.image, pixelScale: r.scale)
            case .file:
                do { savedURL = try Output.saveWithPattern(r.image, title: r.title, date: r.date) }
                catch { Output.showError("Couldn't save the capture", error) }
            case .fileAs:
                Output.saveAs(r.image, title: r.title, date: r.date, window: nil) { _ in }
            default:
                break
            }
        }
        // Editor last, so a file saved above becomes the editor's file (⌘S updates it).
        if dests.contains(.editor) {
            openEditor(image: r.image, scale: r.scale, title: r.title, date: r.date, fileURL: savedURL)
        }
    }

    private func showDestinationMenu(_ r: CaptureResult) {
        pendingResult = r
        let menu = NSMenu()
        for d in Destination.allCases where d != .ask {
            let i = NSMenuItem(title: d.title, action: #selector(destinationChosen(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = d.rawValue
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let cancel = NSMenuItem(title: "Discard", action: #selector(destinationChosen(_:)), keyEquivalent: "")
        cancel.target = self
        menu.addItem(cancel)
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func destinationChosen(_ sender: NSMenuItem) {
        guard let r = pendingResult else { return }
        pendingResult = nil
        guard let raw = sender.representedObject as? String, let d = Destination(rawValue: raw) else { return }
        run([d], r)
    }

    // MARK: Editors

    func openEditor(image: CGImage, scale: CGFloat, title: String, date: Date, fileURL: URL? = nil) {
        let doc = EditorDocument(image: image, pixelScale: scale, title: title, captureDate: date)
        doc.fileURL = fileURL
        let ed = EditorWindowController(document: doc)
        ed.host = self
        editors.append(ed)
        // An editor needs a Dock icon and menu bar; the app goes back to menu-bar-only when they close.
        NSApp.setActivationPolicy(.regular)
        ed.showWindow(nil)
        ed.window?.makeKeyAndOrderFront(nil)
        ed.window?.makeFirstResponder(ed.canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    func editorDidClose(_ editor: EditorWindowController) {
        editors.removeAll { $0 === editor }
        DispatchQueue.main.async { self.updateActivationPolicy() }
    }

    private func updateActivationPolicy() {
        let needsDock = !editors.isEmpty || settingsWindow?.isVisible == true
        NSApp.setActivationPolicy(needsDock ? .regular : .accessory)
    }

    @objc func openImageFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            // 144 dpi files are Retina screenshots: treat them as 2x so annotations are sized right.
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let dpi = props?[kCGImagePropertyDPIWidth] as? Double ?? 72
            let scale: CGFloat = dpi >= 140 ? 2 : 1
            openEditor(image: img, scale: scale, title: url.deletingPathExtension().lastPathComponent,
                       date: Date(), fileURL: nil)
        }
    }

    @objc func openImageFromClipboard() {
        guard let img = Output.imageFromClipboard() else { NSSound.beep(); return }
        openEditor(image: img, scale: 1, title: "Clipboard", date: Date())
    }

    // MARK: Preferences

    @objc func showPreferences(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            w.title = "ShottyMacShotFace Preferences"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            settingsWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            HotkeyManager.shared.setSuspended(false)
            DispatchQueue.main.async { self.updateActivationPolicy() }
        }
    }

    // MARK: Icon

    /// Drawn at launch, so the project needs no image assets.
    static func makeAppIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 40, dy: 40), xRadius: 90, yRadius: 90)
            NSGradient(colors: [NSColor(red: 0.13, green: 0.55, blue: 0.33, alpha: 1),
                                NSColor(red: 0.05, green: 0.33, blue: 0.22, alpha: 1)])?.draw(in: bg, angle: -90)
            if let sym = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 250, weight: .semibold)) {
                let tinted = NSImage(size: sym.size, flipped: false) { r in
                    sym.draw(in: r)
                    NSColor.white.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let s = tinted.size
                tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}

/// The menu bar shown while an editor or Preferences is in front.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
            return m
        }

        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }

        _ = add("ShottyMacShotFace", [
            item("About ShottyMacShotFace", #selector(AppDelegate.showAbout(_:))),
            .separator(),
            item("Preferences…", #selector(AppDelegate.showPreferences(_:)), ","),
            .separator(),
            item("Hide ShottyMacShotFace", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit ShottyMacShotFace", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = add("File", [
            item("Open Image…", #selector(AppDelegate.openImageFile), "o"),
            item("Open Image from Clipboard", #selector(AppDelegate.openImageFromClipboard)),
            .separator(),
            item("Save", #selector(EditorWindowController.saveDocument(_:)), "s"),
            item("Save As…", #selector(EditorWindowController.saveDocumentAs(_:)), "s", [.command, .shift]),
            item("Copy Image to Clipboard", #selector(EditorWindowController.copyImage(_:)), "c", [.command, .shift]),
            .separator(),
            item("Insert Image from File…", #selector(EditorWindowController.insertImageFromFile(_:)), "i", [.command, .shift]),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        _ = add("Edit", [
            item("Undo", #selector(EditorWindowController.editorUndo(_:)), "z"),
            item("Redo", #selector(EditorWindowController.editorRedo(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(EditorWindowController.cut(_:)), "x"),
            item("Copy", #selector(EditorWindowController.copy(_:)), "c"),
            item("Paste", #selector(EditorWindowController.paste(_:)), "v"),
            item("Duplicate", #selector(EditorWindowController.duplicateSelection(_:)), "d"),
            item("Delete", #selector(EditorWindowController.delete(_:)), "", []),
            item("Select All", #selector(EditorWindowController.selectAll(_:)), "a"),
        ])
        _ = add("Object", [
            item("Bring to Front", #selector(EditorWindowController.bringToFront(_:)), "]", [.command, .shift]),
            item("Bring Forward", #selector(EditorWindowController.bringForward(_:)), "]"),
            item("Send Backward", #selector(EditorWindowController.sendBackward(_:)), "["),
            item("Send to Back", #selector(EditorWindowController.sendToBack(_:)), "[", [.command, .shift]),
        ])
        _ = add("Image", [item("Apply Crop", #selector(EditorWindowController.applyCrop(_:))), .separator()]
            + EditorWindowController.effectsMenuItems())
        _ = add("View", [
            item("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "+"),
            item("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "="),
            item("Zoom Out", #selector(EditorWindowController.zoomOut(_:)), "-"),
            item("Actual Size", #selector(EditorWindowController.zoomActual(_:)), "0"),
            item("Zoom to Fit", #selector(EditorWindowController.zoomFit(_:)), "9"),
        ])
        // The duplicate "=" item lets ⌘= zoom without Shift; hide it from the menu itself.
        if let view = main.items.last?.submenu, view.items.count > 1 { view.items[1].isHidden = true; view.items[1].allowsKeyEquivalentWhenHidden = true }
        let window = add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = window
        return main
    }
}
