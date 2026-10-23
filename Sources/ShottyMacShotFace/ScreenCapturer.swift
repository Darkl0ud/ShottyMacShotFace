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

/// One display's frozen picture at its own native resolution.
struct DisplayImage {
    let image: CGImage
    let frame: CGRect // global points
    let scale: CGFloat // image pixels per point

    /// Pixel rect inside `image` for a global rect, expanded outward to whole pixels.
    func pixelRect(for global: CGRect) -> CGRect {
        CGRect(x: (global.minX - frame.minX) * scale, y: (global.minY - frame.minY) * scale,
               width: global.width * scale, height: global.height * scale).integral
    }
}

/// Every display frozen at one instant, the way Greenshot treats the whole desktop as one surface.
/// Region selection then happens on this still picture, so menus and tooltips stay exactly as they
/// were when you pressed the hotkey.
///
/// Each display keeps its own native picture. A crop inside one display comes straight from that
/// display's pixels at its own scale; only a crop that really spans displays is stitched, at the
/// highest scale among the displays it touches. (Upscaling a 1x display to match a 2x one only
/// adds interpolated, blurry pixels and wrongly tags the capture as Retina.)
struct ScreenSnapshot {
    let parts: [DisplayImage]
    let frame: CGRect // union of the parts, global points
    let displays: [DisplayInfo]
    let windows: [WindowInfo] // front-to-back

    init(parts: [DisplayImage], displays: [DisplayInfo], windows: [WindowInfo]) {
        self.parts = parts
        frame = parts.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        self.displays = displays
        self.windows = windows
    }

    /// A single picture covering `frame` (the self-test's fake desktop).
    init(image: CGImage, frame: CGRect, scale: CGFloat, displays: [DisplayInfo], windows: [WindowInfo]) {
        self.init(parts: [DisplayImage(image: image, frame: frame, scale: scale)], displays: displays, windows: windows)
    }

    /// The highest display scale (used only to clamp guesses).
    var scale: CGFloat { parts.map(\.scale).max() ?? 1 }

    private func partsTouching(_ r: CGRect) -> [DisplayImage] {
        parts.filter { let i = $0.frame.intersection(r); return !i.isNull && i.width > 0 && i.height > 0 }
    }

    /// The scale a capture of `global` will have: its display's own, or the highest of the
    /// displays it spans.
    func scale(for global: CGRect) -> CGFloat {
        partsTouching(global).map(\.scale).max() ?? scale
    }

    /// Scale of the display under a point (for the magnifier and labels).
    func scale(at p: CGPoint) -> CGFloat { part(at: p)?.scale ?? scale }

    func part(at p: CGPoint) -> DisplayImage? { parts.first { $0.frame.contains(p) } }

    /// Exactly the pixel size `capture(global)` will return, so labels can't promise a different size.
    func pixelSize(for global: CGRect) -> CGSize? {
        let r = global.intersection(frame)
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        let touching = partsTouching(r)
        guard !touching.isEmpty else { return nil } // in a gap between displays
        if touching.count == 1 { return touching[0].pixelRect(for: r.intersection(touching[0].frame)).size }
        return stitchGrid(for: r).pixels.size
    }

    func crop(_ global: CGRect) -> CGImage? { capture(global)?.image }

    /// The pixels of `global` and their scale.
    func capture(_ global: CGRect) -> (image: CGImage, scale: CGFloat)? {
        let r = global.intersection(frame)
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        let touching = partsTouching(r)
        guard !touching.isEmpty else { return nil }
        if touching.count == 1 {
            let p = touching[0]
            guard let img = p.image.cropping(to: p.pixelRect(for: r.intersection(p.frame))) else { return nil }
            return (img, p.scale)
        }
        return stitch(r, touching)
    }

    /// Pixel grid for a stitched crop: whole pixels at scale `s`, aligned to `frame`'s origin.
    private func stitchGrid(for r: CGRect) -> (pixels: CGRect, global: CGRect, scale: CGFloat) {
        let s = scale(for: r)
        let px = CGRect(x: (r.minX - frame.minX) * s, y: (r.minY - frame.minY) * s,
                        width: r.width * s, height: r.height * s).integral
        let g = CGRect(x: frame.minX + px.minX / s, y: frame.minY + px.minY / s, width: px.width / s, height: px.height / s)
        return (px, g, s)
    }

    private func stitch(_ r: CGRect, _ touching: [DisplayImage]) -> (image: CGImage, scale: CGFloat)? {
        let grid = stitchGrid(for: r)
        let s = grid.scale, g = grid.global
        let img = Bitmap.render(width: Int(grid.pixels.width), height: Int(grid.pixels.height),
                                colorSpace: touching[0].image.colorSpace) { ctx in
            for p in touching {
                let inter = g.intersection(p.frame)
                guard !inter.isNull, inter.width > 0, inter.height > 0,
                      let src = p.image.cropping(to: p.pixelRect(for: inter)) else { continue }
                // Same-scale pieces land on whole pixels and copy 1:1; only lower-scale ones are resampled.
                ctx.interpolationQuality = p.scale == s ? .none : .high
                Bitmap.drawImage(src, in: CGRect(x: (inter.minX - g.minX) * s, y: (inter.minY - g.minY) * s,
                                                 width: inter.width * s, height: inter.height * s), ctx: ctx)
            }
        }
        return img.map { ($0, s) }
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

    /// Our own windows that must not appear in a capture: menus, tooltips and overlays (the status
    /// menu can still be fading out when its item fires). Editors, Preferences and the menu-bar icon
    /// stay in, like any other app's windows, so they can be captured too.
    nonisolated static func excludedFromCapture(layer: Int, ownedByUs: Bool) -> Bool {
        ownedByUs && layer >= Int(CGWindowLevelForKey(.popUpMenuWindow))
    }

    /// Global rects of the attached displays (no permission needed).
    static func displayFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Freezes the displays that `area` touches (all of them when nil). They're captured
    /// concurrently, so every display shows the same moment and the delay doesn't grow per display.
    func snapshot(of area: CGRect? = nil) async throws -> ScreenSnapshot {
        let content = try await shareableContent()
        let pid = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter {
            Self.excludedFromCapture(layer: $0.windowLayer, ownedByUs: $0.owningApplication?.processID == pid)
        }
        let wanted = content.displays.filter { d in
            guard let area else { return true }
            let i = CGDisplayBounds(d.displayID).intersection(area)
            return !i.isNull && i.width > 0 && i.height > 0
        }
        guard !wanted.isEmpty else { throw CaptureError.noDisplays }

        let showsCursor = captureCursor
        let parts = try await withThrowingTaskGroup(of: (Int, DisplayImage).self) { group in
            for (i, d) in wanted.enumerated() {
                // CGDisplayBounds is the documented global (top-left origin) rect for a display.
                let frame = CGDisplayBounds(d.displayID)
                let filter = SCContentFilter(display: d, excludingWindows: excluded)
                let scale = CGFloat(filter.pointPixelScale)
                let cfg = SCStreamConfiguration()
                cfg.width = Int((frame.width * scale).rounded())
                cfg.height = Int((frame.height * scale).rounded())
                cfg.showsCursor = showsCursor
                cfg.captureResolution = .best
                group.addTask {
                    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    return (i, DisplayImage(image: img, frame: frame, scale: scale))
                }
            }
            var out: [(Int, DisplayImage)] = []
            for try await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }

        let displays = wanted.map {
            DisplayInfo(id: $0.displayID, frame: CGDisplayBounds($0.displayID), name: Self.screenName($0.displayID))
        }
        return ScreenSnapshot(parts: parts, displays: displays, windows: Self.windowList(content))
    }

    /// Captures one window by itself (even the parts hidden behind other windows), optionally with
    /// its macOS drop shadow on a transparent background. Returns the display's real pixel scale:
    /// guessing it from image width ÷ window width counts the shadow margin and goes wrong.
    func captureWindow(_ w: WindowInfo) async throws -> (image: CGImage, scale: CGFloat) {
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
            return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg), scale)
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
        return (Effects.trimTransparent(img) ?? img, scale)
    }

    /// Points of spare canvas around a window for its shadow (macOS shadows reach about 60 pt).
    static let shadowRoom: CGFloat = 100

    /// Normal app windows, front-to-back, our own editors and Preferences included. CGWindowList
    /// gives the stacking order that SCShareableContent doesn't promise.
    static func windowList(_ content: SCShareableContent) -> [WindowInfo] {
        var byID: [CGWindowID: SCWindow] = [:]
        for w in content.windows { byID[w.windowID] = w }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        var out: [WindowInfo] = []
        for w in list {
            guard let num = w[kCGWindowNumber as String] as? Int,
                  (w[kCGWindowLayer as String] as? Int) == 0,
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
