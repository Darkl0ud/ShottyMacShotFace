import AppKit
import ImageIO
import ShottyCore
import UniformTypeIdentifiers
import UserNotifications

/// Where finished pictures go: clipboard, files, and the little confirmations around that.
@MainActor
enum Output {
    static var lastSavedURL: URL?

    static func copyToClipboard(_ image: CGImage, pixelScale: CGFloat, to pb: NSPasteboard = .general) {
        pb.clearContents()
        let item = NSPasteboardItem()
        // The PNG carries the scale as its resolution, like the TIFF's point size below, so apps
        // that only read the PNG (and our own paste) know a Retina copy is Retina.
        if let png = try? ImageExporter.data(for: image, format: .png, pixelScale: pixelScale) {
            item.setData(png, forType: .png)
        }
        // TIFF too, for older apps that only look for it. Sized in points so Retina captures
        // paste at their on-screen size.
        let ns = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / pixelScale,
                                                      height: CGFloat(image.height) / pixelScale))
        if let tiff = ns.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }

    /// Whether the clipboard holds a picture, without reading it: right after a capture it holds a
    /// PNG plus an uncompressed TIFF (tens of MB), and this runs every time the status menu opens.
    static func clipboardHasImage(_ pb: NSPasteboard = .general) -> Bool {
        pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func imageFromClipboard() -> CGImage? { imageFromClipboardWithScale()?.image }

    /// The clipboard image and its pixels-per-point. Our own copies carry a TIFF sized in points (and
    /// so do most Mac apps'), which tells a Retina image apart; the PNG alone always reads as 1x.
    /// The TIFF's resolution goes through the same rule as Open Image from File, so an image opens
    /// at the same size either way.
    static func imageFromClipboardWithScale(_ pb: NSPasteboard = .general) -> (image: CGImage, scale: CGFloat)? {
        guard let ns = NSImage(pasteboard: pb) else { return nil }
        var r = CGRect(origin: .zero, size: ns.size)
        guard let img = ns.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return nil }
        var scale: CGFloat = 1
        // Only when the TIFF is this very picture: an app may put a full-size PNG next to a smaller
        // TIFF, whose resolution says nothing about the PNG.
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           rep.size.width > 0, rep.pixelsWide == img.width {
            scale = ImageExporter.pixelScale(dpi: 72 * CGFloat(rep.pixelsWide) / rep.size.width)
        } else if let png = pb.data(forType: .png), let src = CGImageSourceCreateWithData(png as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == img.width,
                  let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue {
            // A PNG on its own (the picture copied beside annotations) says its scale as a file does.
            scale = ImageExporter.pixelScale(dpi: CGFloat(dpi))
        }
        return (img, scale)
    }

    static func patternURL(title: String, date: Date, format: ImageFormat) -> URL {
        let store = SettingsStore.shared
        let ctx = FilenameContext(date: date, title: title, counter: store.takeFileCounter())
        let name = FilenamePattern.expand(store.settings.filenamePattern, ctx)
        return FilenamePattern.uniqueURL(in: store.settings.outputFolderURL, relativeName: name, ext: format.fileExtension)
    }

    /// Saves to the output folder using the filename pattern; returns where it went.
    /// `pixelScale` is the capture's pixels per point; every save stores it as the file's dpi.
    @discardableResult
    static func saveWithPattern(_ image: CGImage, title: String, date: Date, pixelScale: CGFloat) throws -> URL {
        let s = SettingsStore.shared.settings
        let url = patternURL(title: title, date: date, format: s.format)
        try write(image, to: url, format: s.format, pixelScale: pixelScale)
        return url
    }

    static func write(_ image: CGImage, to url: URL, pixelScale: CGFloat) throws {
        let format = ImageFormat.from(extension: url.pathExtension) ?? SettingsStore.shared.settings.format
        try write(image, to: url, format: format, pixelScale: pixelScale)
    }

    /// The one place a picture is written to a file, so no save path can forget the scale.
    private static func write(_ image: CGImage, to url: URL, format: ImageFormat, pixelScale: CGFloat) throws {
        try ImageExporter.write(image, to: url, format: format, quality: SettingsStore.shared.settings.jpegQuality,
                                pixelScale: pixelScale)
        didSave(url)
    }

    /// Save panel with a format menu. Calls back with the saved URL, or nil if cancelled/failed.
    static func saveAs(_ image: CGImage, pixelScale: CGFloat, title: String, date: Date, window: NSWindow?,
                       completion: @escaping (URL?) -> Void) {
        let s = SettingsStore.shared.settings
        let panel = NSSavePanel()
        panel.directoryURL = s.outputFolderURL
        let suggested = FilenamePattern.expand(s.filenamePattern, FilenameContext(date: date, title: title,
                                                                                    counter: s.fileCounter))
        panel.nameFieldStringValue = (suggested as NSString).lastPathComponent + "." + s.format.fileExtension
        panel.allowedContentTypes = [s.format.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let popup = NSPopUpButton()
        for f in ImageFormat.allCases { popup.addItem(withTitle: f.displayName) }
        popup.selectItem(at: ImageFormat.allCases.firstIndex(of: s.format) ?? 0)
        let handler = FormatPopupHandler(panel: panel)
        popup.target = handler
        popup.action = #selector(FormatPopupHandler.changed(_:))
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = row

        let finish: (NSApplication.ModalResponse) -> Void = { resp in
            _ = handler // keep the popup's target alive while the panel is up
            guard resp == .OK, let url = panel.url else { completion(nil); return }
            do {
                try write(image, to: url, pixelScale: pixelScale)
                completion(url)
            } catch {
                showError("Couldn't save the image", error)
                completion(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        // Never runModal here: callers run inside main-actor Tasks, and a modal loop inside one
        // stalls every other main-actor job (hotkeys included) until the panel closes.
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    static func didSave(_ url: URL) {
        lastSavedURL = url
        if SettingsStore.shared.settings.showNotification {
            notify(title: "Screenshot saved", body: url.lastPathComponent)
        }
    }

    static func playShutter() {
        guard SettingsStore.shared.settings.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        (NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink"))?.play()
    }

    /// UNUserNotificationCenter crashes in a process without a bundle id (e.g. the raw binary).
    static var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// At launch: install the delegate that lets banners show while the app is in front (without
    /// one, macOS silences every notification of a foreground app, i.e. every editor save), and
    /// ask for permission once, only if the user wants notifications.
    static func setUpNotifications(askPermission: Bool) {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        if askPermission { requestNotificationPermission() }
    }

    static func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Without permission this simply isn't shown.
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Seam for the self-test: receives errors instead of an alert appearing on screen.
    static var showErrorForTesting: ((String, Error) -> Void)?

    /// Shown from a run-loop callback rather than right away: callers are often inside a main-actor
    /// Task, and a modal alert run there blocks every other main-actor job until it's dismissed.
    static func showError(_ message: String, _ error: Error) {
        if let showErrorForTesting { showErrorForTesting(message, error); return }
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { presentError(message, error) }
        }
    }

    private static func presentError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        if case CaptureError.noPermission = error {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Lets "Screenshot saved" banners appear while the app is frontmost (saving from the editor).
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    static let foregroundOptions: UNNotificationPresentationOptions = [.banner, .list]

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.foregroundOptions)
    }
}

/// Keeps the save panel's file type in step with the format menu.
@MainActor
final class FormatPopupHandler: NSObject {
    weak var panel: NSSavePanel?
    init(panel: NSSavePanel) { self.panel = panel }

    @objc func changed(_ sender: NSPopUpButton) {
        let f = ImageFormat.allCases[sender.indexOfSelectedItem]
        panel?.allowedContentTypes = [f.utType]
        if let panel {
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + "." + f.fileExtension
        }
    }
}
