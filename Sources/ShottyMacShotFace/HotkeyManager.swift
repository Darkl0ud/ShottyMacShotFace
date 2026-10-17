import AppKit
import Carbon.HIToolbox
import ShottyCore

/// Global hotkeys via Carbon's RegisterEventHotKey: still the standard way for a Mac app to own a
/// system-wide shortcut, and unlike an event tap it needs no Accessibility permission.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onHotkey: ((HotkeyAction) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var idToAction: [UInt32: HotkeyAction] = [:]
    private var handlerInstalled = false
    /// While the user records a new shortcut in Preferences, the old one must not fire.
    private(set) var isSuspended = false

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

    /// Registers every configured hotkey; returns the ones macOS refused (usually: another app owns it).
    @discardableResult
    func register(_ settings: AppSettings) -> [HotkeyAction: String] {
        installHandler()
        unregisterAll()
        var errors: [HotkeyAction: String] = [:]
        for (i, action) in HotkeyAction.allCases.enumerated() {
            guard let hk = settings.hotkey(for: action) else { continue }
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

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        idToAction.removeAll()
    }

    func setSuspended(_ s: Bool) { isSuspended = s }
}
