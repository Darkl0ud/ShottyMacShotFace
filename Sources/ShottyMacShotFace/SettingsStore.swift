import AppKit
import Combine
import ShottyCore

/// The app's settings, persisted to UserDefaults as one JSON blob (so new fields get defaults
/// instead of breaking old installs — see AppSettings.init(from:)).
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private static let key = "settings.v1"

    @Published var settings: AppSettings {
        didSet { if settings != oldValue { UserDefaults.standard.set(settings.encoded(), forKey: Self.key) } }
    }
    /// Filled in by the hotkey manager so Preferences can say which shortcuts another app owns.
    @Published var hotkeyErrors: [HotkeyAction: String] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            settings = AppSettings.decode(data)
        } else {
            settings = AppSettings()
        }
    }

    /// Next value for ${NUM}; bumps the stored counter.
    func takeFileCounter() -> Int {
        let n = settings.fileCounter
        settings.fileCounter = n + 1
        return n
    }
}
