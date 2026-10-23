import AppKit
import Carbon.HIToolbox
import ShottyCore

/// Global hotkeys via Carbon's RegisterEventHotKey: still the standard way for a Mac app to own a
/// system-wide shortcut, and unlike an event tap it needs no Accessibility permission.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onHotkey: ((HotkeyAction) -> Void)?
    /// Registration results after a suspension ends (register() itself returns them directly).
    var onErrors: (([HotkeyAction: String]) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var idToAction: [UInt32: HotkeyAction] = [:]
    private var handlerInstalled = false
    /// The settings last asked for, re-registered when a suspension ends.
    private var wanted: AppSettings?
    /// While the user records a new shortcut in Preferences, the hotkeys are released.
    private(set) var isSuspended = false

    var registeredCount: Int { refs.count }

    private init() {}

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // A C callback can't capture anything, so it reaches the manager through the singleton.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if status == noErr {
                let id = hk.id
                Task { @MainActor in HotkeyManager.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) {
        guard !isSuspended, let action = idToAction[id] else { return }
        onHotkey?(action)
    }

    /// Actions whose shortcut equals an earlier action's, mapped to that earlier action. macOS
    /// would refuse the second registration as "exists", which reads like another app owns it.
    static func duplicates(in settings: AppSettings) -> [HotkeyAction: HotkeyAction] {
        var firstUse: [Hotkey: HotkeyAction] = [:]
        var dups: [HotkeyAction: HotkeyAction] = [:]
        for action in HotkeyAction.allCases {
            guard let hk = settings.hotkey(for: action) else { continue }
            if let earlier = firstUse[hk] { dups[action] = earlier } else { firstUse[hk] = action }
        }
        return dups
    }

    /// Registers every configured hotkey; returns the ones that couldn't be (a duplicate within the
    /// app, or macOS refused: usually another app owns it). While suspended it only remembers them.
    @discardableResult
    func register(_ settings: AppSettings) -> [HotkeyAction: String] {
        wanted = settings
        guard !isSuspended else { return [:] }
        installHandler()
        releaseAll()
        var errors: [HotkeyAction: String] = [:]
        let dups = Self.duplicates(in: settings)
        for (i, action) in HotkeyAction.allCases.enumerated() {
            guard let hk = settings.hotkey(for: action) else { continue }
            if let other = dups[action] {
                errors[action] = "Same shortcut as \(other.title)"
                continue
            }
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(hk.keyCode, hk.modifiers.carbonFlags,
                                             EventHotKeyID(signature: OSType(0x534D_5346), id: id), // 'SMSF'
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                idToAction[id] = action
            } else {
                errors[action] = status == eventHotKeyExistsErr
                    ? "\(hk.display) is already used by another app"
                    : "macOS refused \(hk.display) (error \(status))"
            }
        }
        return errors
    }

    /// Releases every hotkey and forgets the settings (nothing comes back after a suspension).
    func unregisterAll() {
        releaseAll()
        wanted = nil
    }

    private func releaseAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        idToAction.removeAll()
    }

    /// A registered hotkey is swallowed by the system before any window sees it, so the recorder
    /// could never record (say) the shortcut of another action. Suspending really unregisters
    /// them; resuming registers the latest settings again.
    func setSuspended(_ s: Bool) {
        guard s != isSuspended else { return }
        isSuspended = s
        if s {
            releaseAll()
        } else if let wanted {
            onErrors?(register(wanted))
        }
    }
}
