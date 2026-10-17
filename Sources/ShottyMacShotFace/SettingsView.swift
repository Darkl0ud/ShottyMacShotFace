import AppKit
import ServiceManagement
import ShottyCore
import SwiftUI

/// View-local state. SwiftUI's @State is a compiler macro whose plugin only ships with full Xcode,
/// so with just the Command Line Tools the state lives in a plain ObservableObject instead.
final class PreferencesUIModel: ObservableObject {
    @Published var loginError: String?
}

/// Preferences window, in SwiftUI because it's mostly forms bound straight to settings.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let ui = PreferencesUIModel()

    var body: some View {
        TabView {
            OutputTab(store: store).tabItem { Label("Output", systemImage: "folder") }
            CaptureTab(store: store, ui: ui).tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            HotkeysTab(store: store).tabItem { Label("Hotkeys", systemImage: "keyboard") }
        }
        .padding(16)
        .frame(width: 560, height: 430)
    }
}

private struct OutputTab: View {
    @ObservedObject var store: SettingsStore

    var preview: String {
        let ctx = FilenameContext(title: "Safari – Example", counter: store.settings.fileCounter)
        return FilenamePattern.expand(store.settings.filenamePattern, ctx) + "." + store.settings.format.fileExtension
    }

    var body: some View {
        Form {
            Section("Save location") {
                HStack {
                    Text(store.settings.outputFolderURL.path)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseFolder() }
                    Button("Show") { NSWorkspace.shared.open(store.settings.outputFolderURL) }
                }
            }
            Section("File name") {
                TextField("Pattern", text: $store.settings.filenamePattern)
                    .font(.system(.body, design: .monospaced))
                Text("Example: \(preview)").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Pattern variables") {
                    ForEach(FilenamePattern.variables, id: \.name) { v in
                        HStack {
                            Text(v.name).font(.system(.caption, design: .monospaced)).frame(width: 90, alignment: .leading)
                            Text(v.meaning).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Use / to make subfolders, e.g. ${YYYY}/${MM}/${title}").font(.caption).foregroundStyle(.secondary)
                }
                Button("Reset to default") { store.settings.filenamePattern = FilenamePattern.defaultPattern }
            }
            Section("Format") {
                Picker("Image format", selection: $store.settings.format) {
                    ForEach(ImageFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if store.settings.format.usesQuality {
                    HStack {
                        Slider(value: $store.settings.jpegQuality, in: 0.1...1) { Text("Quality") }
                        Text("\(Int(store.settings.jpegQuality * 100))%").monospacedDigit().frame(width: 44)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.settings.outputFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.outputFolder = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

private struct CaptureTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var ui: PreferencesUIModel

    private func binding(_ d: Destination) -> Binding<Bool> {
        Binding(
            get: { store.settings.destinations.contains(d) },
            set: { on in
                var list = store.settings.destinations.filter { $0 != d }
                if on { list.append(d) }
                // Keep Greenshot's order so "editor" runs after the quick outputs.
                store.settings.destinations = Destination.allCases.filter { list.contains($0) }
            })
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    ui.loginError = nil
                } catch {
                    ui.loginError = error.localizedDescription
                }
            })
    }

    var body: some View {
        Form {
            Section("After capture") {
                ForEach(Destination.allCases, id: \.self) { d in Toggle(d.title, isOn: binding(d)) }
                if store.settings.destinations.isEmpty {
                    Text("Nothing selected: captures will open in the editor.").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Capture") {
                Toggle("Include the mouse pointer", isOn: $store.settings.captureMousePointer)
                Toggle("Include the window's shadow (window capture)", isOn: $store.settings.windowShadow)
                Toggle("Show magnifier while selecting", isOn: $store.settings.showMagnifier)
                Toggle("Play camera sound", isOn: $store.settings.playSound)
                Toggle("Show a notification after saving", isOn: $store.settings.showNotification)
            }
            Section("Editor") {
                Stepper("Step counter starts at \(store.settings.counterStart)", value: $store.settings.counterStart, in: 0...999)
            }
            Section("System") {
                Toggle("Open at login", isOn: launchAtLogin)
                if let err = ui.loginError { Text(err).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotkeysTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    HStack {
                        Text(action.title).frame(width: 170, alignment: .leading)
                        HotkeyRecorder(hotkey: Binding(
                            get: { store.settings.hotkeys[action.rawValue] },
                            set: { store.settings.hotkeys[action.rawValue] = $0 }))
                            .frame(width: 150, height: 24)
                        Button("Default") { store.settings.hotkeys[action.rawValue] = action.defaultHotkey }
                            .controlSize(.small)
                    }
                    if let err = store.hotkeyErrors[action] {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            } footer: {
                Text("Click a shortcut, then press the new keys. Esc cancels, Delete clears. Shortcuts need "
                    + "⌃, ⌥ or ⌘ (function keys like F13 work alone). The defaults avoid macOS's own ⌘⇧3/4/5.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click-to-record shortcut field.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var hotkey: Hotkey?

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.onChange = { hotkey = $0 }
        b.hotkey = hotkey
        return b
    }

    func updateNSView(_ b: RecorderButton, context: Context) {
        b.onChange = { hotkey = $0 }
        if !b.isRecording { b.hotkey = hotkey }
    }
}

final class RecorderButton: NSButton {
    var onChange: ((Hotkey?) -> Void)?
    var hotkey: Hotkey? { didSet { refreshTitle() } }
    private(set) var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        target = self
        action = #selector(toggle)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    private func refreshTitle() {
        title = isRecording ? "Type shortcut…" : (hotkey?.display ?? "None")
    }

    @objc private func toggle() { isRecording ? stop() : start() }

    private func start() {
        isRecording = true
        // Carbon hotkeys fire before the app sees the keys, so pause them while recording.
        HotkeyManager.shared.setSuspended(true)
        window?.makeFirstResponder(self)
        refreshTitle()
    }

    private func stop() {
        isRecording = false
        HotkeyManager.shared.setSuspended(false)
        refreshTitle()
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stop() }
        return super.resignFirstResponder()
    }

    // ⌘-combinations arrive here rather than in keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        record(event)
    }

    private func record(_ event: NSEvent) {
        switch event.keyCode {
        case 53: stop(); return // Esc
        case 51, 117: hotkey = nil; onChange?(nil); stop(); return // Delete clears
        default: break
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let hk = Hotkey(keyCode: UInt32(event.keyCode), modifiers: HotkeyModifiers(rawValue: flags.rawValue))
        guard hk.isAcceptable else { NSSound.beep(); return }
        hotkey = hk
        onChange?(hk)
        stop()
    }
}
