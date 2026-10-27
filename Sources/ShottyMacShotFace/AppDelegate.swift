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
    /// Seams for the self-test: how a capture's Save As panel and its editor are shown.
    var presentSaveAs: (CaptureResult, @escaping (URL?) -> Void) -> Void = { r, done in
        Output.saveAs(r.image, pixelScale: r.scale, title: r.title, date: r.date, window: nil, completion: done)
    }
    var presentEditor: ((EditorDocument) -> Void)?
    var beep: () -> Void = { NSSound.beep() }
    /// More seams, so the self-test can deliver a capture without the real clipboard, the capture
    /// folder or a menu popping up on screen.
    var clipboard: NSPasteboard = .general
    var saveWithPattern: (CaptureResult) throws -> URL = { r in
        try Output.saveWithPattern(r.image, title: r.title, date: r.date, pixelScale: r.scale)
    }
    var presentDestinationMenu: ((NSMenu) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = Self.makeAppIcon()
        NSApp.mainMenu = MainMenu.build()
        setupStatusItem()

        HotkeyManager.shared.onHotkey = { [weak self] action in self?.capture(action) }
        HotkeyManager.shared.onErrors = { [weak self] errors in self?.store.hotkeyErrors = errors }
        registerHotkeys()
        // @Published fires before the value is stored, so re-register on the next turn.
        store.$settings
            .map(\.hotkeys)
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotkeys() } }
            .store(in: &cancellables)

        Output.setUpNotifications(askPermission: store.settings.showNotification)
        store.$settings
            .map(\.showNotification)
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { _ in Output.requestNotificationPermission() }
            .store(in: &cancellables)

        // Ask once up front; macOS shows its own prompt and remembers the answer.
        if !ScreenCapturer.hasPermission { CGRequestScreenCaptureAccess() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quit (⌘Q, Dock, status menu, logout) never calls windowShouldClose, so without this every
    /// open capture that exists nowhere else would be thrown away silently.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let pending: [QuitReviewable] = editors.filter(\.hasUnsavedWork)
        guard !pending.isEmpty else { return .terminateNow }
        isReviewingQuit = true // a capture started now would open an editor nobody asks about
        Self.reviewForQuit(pending) { [weak self] ok in
            self?.isReviewingQuit = false
            NSApp.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }

    /// Asks each editor in turn (Save / Cancel / Don't Save); the first Cancel stops the quit.
    static func reviewForQuit(_ items: [QuitReviewable], done: @escaping (Bool) -> Void) {
        guard let first = items.first else { done(true); return }
        first.confirmDiscardForQuit { ok in
            if ok { reviewForQuit(Array(items.dropFirst()), done: done) } else { done(false) }
        }
    }

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
        if !Output.clipboardHasImage() { clip.action = nil }
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

    /// Not while another capture runs, nor during an app-modal panel or alert: AppKit gives a
    /// non-modal window (the overlay) no mouse input then, so it couldn't be used or dismissed.
    /// Settable only so the self-test can stand in for a Quit review without real editors.
    var isReviewingQuit = false
    private var pendingDestinationMenu: NSMenu?
    var canStartCapture: Bool { !busy && overlay == nil && NSApp.modalWindow == nil && !isReviewingQuit }

    func capture(_ action: HotkeyAction) {
        guard canStartCapture else {
            // A busy capture or an open overlay is visible; a modal panel or the Quit sheets may not
            // be (sheets don't count as modalWindow), so say no out loud and show what's waiting.
            if NSApp.modalWindow != nil || isReviewingQuit { beep() }
            if isReviewingQuit { showPendingQuitSheet() }
            return
        }
        busy = true
        capturer.captureCursor = store.settings.captureMousePointer
        capturer.includeWindowShadow = store.settings.windowShadow
        Task { @MainActor in
            defer { busy = false }
            do {
                switch action {
                case .fullScreen:
                    let snap = try await capturer.snapshot()
                    guard let c = snap.capture(snap.frame) else { throw CaptureError.noDisplays }
                    deliver(CaptureResult(image: c.image, scale: c.scale, title: "Full Screen", date: Date()))
                case .lastRegion:
                    switch Self.lastRegionPlan(store.settings.lastRegion, displays: ScreenCapturer.displayFrames()) {
                    case .select:
                        // Nothing remembered yet, or that area is on no display any more.
                        try await interactiveCapture(startIn: .region)
                    case .capture(let r):
                        let snap = try await capturer.snapshot(of: r)
                        guard let c = snap.capture(r) else { try await interactiveCapture(startIn: .region); return }
                        deliver(CaptureResult(image: c.image, scale: c.scale,
                                              title: snap.window(at: r.center)?.displayTitle ?? "Region", date: Date()))
                    }
                case .region, .window:
                    try await interactiveCapture(startIn: action == .region ? .region : .window)
                }
            } catch {
                Output.showError("Capture failed", error)
            }
        }
    }

    /// The editor whose Save / Don't Save sheet the Quit review is waiting on, brought to the front.
    private func showPendingQuitSheet() {
        guard let w = editors.lazy.compactMap(\.window).first(where: { $0.attachedSheet != nil }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    enum LastRegionPlan: Equatable { case select, capture(CGRect) }

    /// Capture Last Region only when some of that area is still on a display; otherwise (display
    /// unplugged or rearranged) fall back to selecting, instead of silently doing nothing.
    static func lastRegionPlan(_ r: CGRect?, displays: [CGRect]) -> LastRegionPlan {
        guard let r else { return .select }
        let visible = displays.contains { let i = $0.intersection(r); return !i.isNull && i.width >= 1 && i.height >= 1 }
        return visible ? .capture(r) : .select
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
            guard let c = snap.capture(r) else { return }
            let title = snap.windows.first { $0.frame.contains(r.center) }?.displayTitle ?? "Region"
            deliver(CaptureResult(image: c.image, scale: c.scale, title: title, date: date))
        case .window(let w):
            let shot: (image: CGImage, scale: CGFloat)
            do {
                shot = try await capturer.captureWindow(w)
            } catch {
                // Fall back to the frozen picture of the window's area.
                guard let crop = snap.capture(w.frame) else { throw error }
                shot = crop
            }
            deliver(CaptureResult(image: shot.image, scale: shot.scale, title: w.displayTitle, date: date))
        }
    }

    private func captureRect(_ rect: CGRect, title: String) {
        guard canStartCapture else { return }
        busy = true
        capturer.captureCursor = store.settings.captureMousePointer
        Task { @MainActor in
            defer { busy = false }
            do {
                // Only the display(s) under the rect, at their own resolution.
                let snap = try await capturer.snapshot(of: rect)
                guard let c = snap.capture(rect) else { return }
                deliver(CaptureResult(image: c.image, scale: c.scale, title: title, date: Date()))
            } catch {
                Output.showError("Capture failed", error)
            }
        }
    }

    // MARK: Destinations

    func deliver(_ r: CaptureResult) {
        Output.playShutter()
        deliver(r, to: store.settings.destinations)
    }

    /// What happens to a capture: `immediate` runs right away; `showsMenu` then asks about the rest.
    struct DeliveryPlan: Equatable {
        var immediate: [Destination]
        var showsMenu: Bool
    }

    /// The ticked destinations are a combination (README), so Ask doesn't cancel the others. The
    /// quick, silent ones (clipboard, save with pattern) still happen; the ones that open a window
    /// (editor, Save As) are left to the menu, which offers them anyway, so the user isn't handed
    /// an editor or a save panel at the same moment as a menu asking what to do.
    static func planDelivery(_ dests: [Destination]) -> DeliveryPlan {
        if dests.isEmpty { return DeliveryPlan(immediate: [.editor], showsMenu: false) }
        guard dests.contains(.ask) else { return DeliveryPlan(immediate: dests, showsMenu: false) }
        return DeliveryPlan(immediate: dests.filter { $0 == .clipboard || $0 == .file }, showsMenu: true)
    }

    func deliver(_ r: CaptureResult, to dests: [Destination]) {
        let plan = Self.planDelivery(dests)
        let done = run(plan.immediate, r)
        if plan.showsMenu { showDestinationMenu(r, after: done) }
    }

    /// What has already happened to a capture, so a later step (a choice from the Ask menu)
    /// doesn't repeat it and an editor opened then knows the capture exists elsewhere (C1/C4).
    struct DeliveryState {
        var done: [Destination] = []
        var savedURL: URL?
        var exported = false
    }

    /// Runs `dests` on top of `prior`; returns the state after the synchronous ones (Save As
    /// answers later and only feeds the editor).
    @discardableResult
    func run(_ dests: [Destination], _ r: CaptureResult, after prior: DeliveryState = DeliveryState()) -> DeliveryState {
        var state = prior
        for d in dests {
            switch d {
            case .clipboard:
                Output.copyToClipboard(r.image, pixelScale: r.scale, to: clipboard)
                state.exported = true
            case .file:
                do { state.savedURL = try saveWithPattern(r); state.exported = true }
                catch {
                    Output.showError("Couldn't save the capture", error)
                    // Not done: the Ask menu keeps offering it, so it can be retried once the
                    // folder is back (an unplugged drive, a permission fixed).
                    continue
                }
            default:
                break
            }
            state.done.append(d)
        }
        let wantsEditor = dests.contains(.editor)
        // Editor last, so a file saved above becomes the editor's file (⌘S updates it). Save As is
        // asynchronous, so the editor waits for its answer.
        guard dests.contains(.fileAs) else {
            if wantsEditor { openEditor(image: r.image, scale: r.scale, title: r.title, date: r.date,
                                        fileURL: state.savedURL, wasExported: state.exported) }
            return state
        }
        let sync = state
        presentSaveAs(r) { [weak self] url in
            guard let self, wantsEditor else { return }
            self.openEditor(image: r.image, scale: r.scale, title: r.title, date: r.date,
                            fileURL: sync.savedURL ?? url, wasExported: sync.exported || url != nil)
        }
        return state
    }

    /// What one "Ask each time" menu item does. The capture travels with the items, so it's freed
    /// with the menu even when the menu is dismissed without a choice.
    final class DestinationChoice: NSObject {
        let destination: Destination?
        let result: CaptureResult
        let prior: DeliveryState
        init(_ d: Destination?, _ r: CaptureResult, prior: DeliveryState = DeliveryState()) {
            destination = d; result = r; self.prior = prior
        }
    }

    /// Leaves out what already happened (a second pattern save would make a second file).
    func makeDestinationMenu(_ r: CaptureResult, after prior: DeliveryState = DeliveryState()) -> NSMenu {
        let menu = NSMenu()
        for d in Destination.allCases where d != .ask && !prior.done.contains(d) {
            let i = NSMenuItem(title: d.title, action: #selector(destinationChosen(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = DestinationChoice(d, r, prior: prior)
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let cancel = NSMenuItem(title: prior.exported ? "Done" : "Discard", action: #selector(destinationChosen(_:)),
                                keyEquivalent: "")
        cancel.target = self
        cancel.representedObject = DestinationChoice(nil, r, prior: prior)
        menu.addItem(cancel)
        return menu
    }

    private func showDestinationMenu(_ r: CaptureResult, after prior: DeliveryState) {
        let menu = makeDestinationMenu(r, after: prior)
        if let presentDestinationMenu { presentDestinationMenu(menu); return }
        NSApp.activate(ignoringOtherApps: true)
        // popUp runs a nested event loop; started from inside the capture Task it would hold the
        // main actor (and busy) for as long as the menu is open. Run it on its own run-loop turn.
        let at = NSEvent.mouseLocation
        pendingDestinationMenu = menu
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let menu = self.pendingDestinationMenu else { return }
                self.pendingDestinationMenu = nil
                menu.popUp(positioning: nil, at: at, in: nil)
            }
        }
    }

    @objc func destinationChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? DestinationChoice, let d = choice.destination else { return }
        run([d], choice.result, after: choice.prior)
    }

    // MARK: Editors

    /// `wasExported`: the capture already exists outside the editor (saved, copied, or opened from
    /// a file), so closing the editor needn't ask (C1/C4).
    func openEditor(image: CGImage, scale: CGFloat, title: String, date: Date, fileURL: URL? = nil,
                    wasExported: Bool = false) {
        let doc = EditorDocument(image: image, pixelScale: scale, title: title, captureDate: date)
        doc.fileURL = fileURL
        doc.wasExported = wasExported
        if let presentEditor { presentEditor(doc); return }
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
            // Upright (EXIF orientation applied), 144 dpi files as 2x (C2).
            guard let loaded = ImageExporter.loadForEditor(from: url) else { continue }
            // The file is the original, so closing unedited needn't ask.
            openEditor(image: loaded.image, scale: loaded.pixelScale, title: url.deletingPathExtension().lastPathComponent,
                       date: Date(), fileURL: nil, wasExported: true)
        }
    }

    @objc func openImageFromClipboard() {
        guard let (img, scale) = Output.imageFromClipboardWithScale() else { NSSound.beep(); return }
        // It came from the clipboard, so it already exists there, like a capture copied there.
        openEditor(image: img, scale: scale, title: "Clipboard", date: Date(), wasExported: true)
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

/// Something that may hold work Quit would lose (an editor, per contract C1).
@MainActor
protocol QuitReviewable: AnyObject {
    var hasUnsavedWork: Bool { get }
    func confirmDiscardForQuit(_ done: @escaping (Bool) -> Void)
}

extension EditorWindowController: QuitReviewable {}

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
