import AppKit
import ScreenCaptureKit
import ShottyCore

/// A window that can be captured, in global screen points (y-down from the top of the main display).
struct WindowInfo {
    let windowID: CGWindowID
    let frame: CGRect
    let title: String
    let appName: String
    let scWindow: SCWindow?

    var displayTitle: String {
        if title.isEmpty { return appName }
        if appName.isEmpty || title.contains(appName) { return title }
        return "\(appName) – \(title)"
    }
}

struct DisplayInfo {
    let id: CGDirectDisplayID
    let frame: CGRect // global points
    let name: String
}

/// Every display frozen at one instant, stitched into one image the way Greenshot treats the whole
/// desktop as one surface. Region selection then happens on this still picture, so menus and
/// tooltips stay exactly as they were when you pressed the hotkey.
struct ScreenSnapshot {
    let image: CGImage
    let frame: CGRect // global points covered by `image`
    let scale: CGFloat // image pixels per point
    let displays: [DisplayInfo]
    let windows: [WindowInfo] // front-to-back

    func pixelRect(for global: CGRect) -> CGRect {
        CGRect(x: (global.minX - frame.minX) * scale, y: (global.minY - frame.minY) * scale,
               width: global.width * scale, height: global.height * scale).integral
    }

    func crop(_ global: CGRect) -> CGImage? {
        let r = global.intersection(frame)
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        return image.cropping(to: pixelRect(for: r))
    }

    func window(at p: CGPoint) -> WindowInfo? { windows.first { $0.frame.contains(p) } }
}

struct CaptureResult {
    let image: CGImage
    let scale: CGFloat
    let title: String
    let date: Date
}

enum CaptureError: LocalizedError {
    case noPermission, noDisplays, windowGone

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "ShottyMacShotFace needs Screen Recording permission. Turn it on in System Settings → "
                + "Privacy & Security → Screen & System Audio Recording, then quit and reopen the app."
        case .noDisplays: return "No displays were found to capture."
        case .windowGone: return "That window can't be captured any more (it may have closed)."
        }
    }
}

@MainActor
final class ScreenCapturer {
    var captureCursor = false
    var includeWindowShadow = true

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.hasPermission ? error : CaptureError.noPermission
        }
    }

    func snapshot() async throws -> ScreenSnapshot {
        let content = try await shareableContent()
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }

        var parts: [(image: CGImage, frame: CGRect)] = []
        var maxScale: CGFloat = 1
        for d in content.displays {
            // CGDisplayBounds is the documented global (top-left origin) rect for a display.
            let frame = CGDisplayBounds(d.displayID)
            let filter = SCContentFilter(display: d, excludingWindows: ownWindows)
            let scale = CGFloat(filter.pointPixelScale)
            let cfg = SCStreamConfiguration()
            cfg.width = Int((frame.width * scale).rounded())
            cfg.height = Int((frame.height * scale).rounded())
            cfg.showsCursor = captureCursor
            cfg.captureResolution = .best
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            parts.append((img, frame))
            maxScale = max(maxScale, scale)
        }

        let union = parts.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let composite: CGImage
        if parts.count == 1 {
            composite = parts[0].image
        } else {
            // Mixed-DPI setups: everything is drawn at the highest scale so nothing loses detail.
            guard let c = Bitmap.render(width: Int((union.width * maxScale).rounded()),
                                        height: Int((union.height * maxScale).rounded()),
                                        colorSpace: parts[0].image.colorSpace, { ctx in
                for p in parts {
                    let r = CGRect(x: (p.frame.minX - union.minX) * maxScale, y: (p.frame.minY - union.minY) * maxScale,
                                   width: p.frame.width * maxScale, height: p.frame.height * maxScale)
                    Bitmap.drawImage(p.image, in: r, ctx: ctx)
                }
            }) else { throw CaptureError.noDisplays }
            composite = c
        }

        let displays = content.displays.map {
            DisplayInfo(id: $0.displayID, frame: CGDisplayBounds($0.displayID), name: Self.screenName($0.displayID))
        }
        return ScreenSnapshot(image: composite, frame: union, scale: maxScale, displays: displays,
                              windows: Self.windowList(content, excludingPID: pid))
    }

    /// Captures one window by itself (even the parts hidden behind other windows),
    /// optionally with its macOS drop shadow on a transparent background.
    func captureWindow(_ w: WindowInfo) async throws -> CGImage {
        // Re-fetch so we use a live SCWindow, not one from before the overlay was shown.
        let content = try await shareableContent()
        guard let sc = content.windows.first(where: { $0.windowID == w.windowID }) ?? w.scWindow
        else { throw CaptureError.windowGone }
        let filter = SCContentFilter(desktopIndependentWindow: sc)
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        let rect = filter.contentRect
        cfg.showsCursor = captureCursor
        cfg.ignoreShadowsSingleWindow = !includeWindowShadow
        cfg.captureResolution = .best
        guard includeWindowShadow else {
            cfg.width = Int((rect.width * scale).rounded())
            cfg.height = Int((rect.height * scale).rounded())
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        }
        // contentRect is the window WITHOUT its shadow. Sized to that, ScreenCaptureKit shrank
        // window + shadow to fit (about 8% smaller, so blurry) and left the spare space transparent on
        // the right and bottom. Instead: draw at true size into a canvas with room for the shadow,
        // then trim the empty edges away.
        let room = Self.shadowRoom
        cfg.scalesToFit = false
        cfg.width = Int(((rect.width + room * 2) * scale).rounded())
        cfg.height = Int(((rect.height + room * 2) * scale).rounded())
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return Effects.trimTransparent(img) ?? img
    }

    /// Points of spare canvas around a window for its shadow (macOS shadows reach about 60 pt).
    static let shadowRoom: CGFloat = 100

    /// Normal app windows, front-to-back. CGWindowList gives the stacking order that
    /// SCShareableContent doesn't promise.
    static func windowList(_ content: SCShareableContent, excludingPID pid: pid_t) -> [WindowInfo] {
        var byID: [CGWindowID: SCWindow] = [:]
        for w in content.windows { byID[w.windowID] = w }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        var out: [WindowInfo] = []
        for w in list {
            guard let num = w[kCGWindowNumber as String] as? Int,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let owner = w[kCGWindowOwnerPID as String] as? Int, owner != Int(pid),
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width >= 40, rect.height >= 30,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
            else { continue }
            out.append(WindowInfo(
                windowID: CGWindowID(num), frame: rect,
                title: w[kCGWindowName as String] as? String ?? "",
                appName: w[kCGWindowOwnerName as String] as? String ?? "",
                scWindow: byID[CGWindowID(num)]))
        }
        return out
    }

    static func screenName(_ id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }?
            .localizedName ?? "Display \(id)"
    }
}
