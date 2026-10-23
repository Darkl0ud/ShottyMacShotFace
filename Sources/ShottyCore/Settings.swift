import CoreGraphics
import Foundation

/// Modifier keys, stored with the same bit values as NSEvent.ModifierFlags so the app can
/// convert with a plain rawValue.
public struct HotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let shift = HotkeyModifiers(rawValue: 1 << 17)
    public static let control = HotkeyModifiers(rawValue: 1 << 18)
    public static let option = HotkeyModifiers(rawValue: 1 << 19)
    public static let command = HotkeyModifiers(rawValue: 1 << 20)

    /// Carbon's RegisterEventHotKey uses its own bit layout (cmdKey, shiftKey…).
    public var carbonFlags: UInt32 {
        var f: UInt32 = 0
        if contains(.command) { f |= 1 << 8 }
        if contains(.shift) { f |= 1 << 9 }
        if contains(.option) { f |= 1 << 11 }
        if contains(.control) { f |= 1 << 12 }
        return f
    }

    /// macOS menu order: ⌃⌥⇧⌘.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

public struct Hotkey: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode; self.modifiers = modifiers
    }

    public var display: String { modifiers.symbols + KeyNames.name(for: keyCode) }

    /// Plain letters would hijack typing everywhere, so a global hotkey needs ⌃/⌥/⌘
    /// unless it's a function key.
    public var isAcceptable: Bool {
        !modifiers.intersection([.control, .option, .command]).isEmpty || KeyNames.isFunctionKey(keyCode)
    }
}

/// Names for macOS virtual key codes (Carbon kVK_* values; these are fixed by the hardware layout).
public enum KeyNames {
    static let table: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
        0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
        0x21: "[", 0x22: "I", 0x23: "P", 0x24: "↩", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
        0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "⇥",
        0x31: "Space", 0x32: "`", 0x33: "⌫", 0x35: "⎋",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14",
        0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19",
        0x73: "↖", 0x74: "⇞", 0x75: "⌦", 0x77: "↘", 0x79: "⇟",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
    ]
    static let functionKeys: Set<UInt32> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50,
    ]

    public static func name(for code: UInt32) -> String { table[code] ?? "Key\(code)" }
    public static func isFunctionKey(_ code: UInt32) -> Bool { functionKeys.contains(code) }
}

public enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case region, window, fullScreen, lastRegion

    public var title: String {
        switch self {
        case .region: return "Capture Region"
        case .window: return "Capture Window"
        case .fullScreen: return "Capture Full Screen"
        case .lastRegion: return "Capture Last Region"
        }
    }

    /// ⌃⇧ + digit: free on a stock Mac (the system uses ⌘⇧3/4/5 and ⌃⌘⇧3/4), and the digits
    /// line up with macOS's own screenshot keys.
    public var defaultHotkey: Hotkey {
        let cs: HotkeyModifiers = [.control, .shift]
        switch self {
        case .fullScreen: return Hotkey(keyCode: 0x14, modifiers: cs) // 3
        case .region: return Hotkey(keyCode: 0x15, modifiers: cs) // 4
        case .window: return Hotkey(keyCode: 0x17, modifiers: cs) // 5
        case .lastRegion: return Hotkey(keyCode: 0x16, modifiers: cs) // 6
        }
    }
}

/// What happens to a capture. Several can be on at once, like Greenshot's destination picker.
public enum Destination: String, Codable, CaseIterable, Sendable {
    case editor, clipboard, file, fileAs, ask

    public var title: String {
        switch self {
        case .editor: return "Open in Image Editor"
        case .clipboard: return "Copy to Clipboard"
        case .file: return "Save (using filename pattern)"
        case .fileAs: return "Save As… (ask for name)"
        case .ask: return "Ask Each Time (show menu)"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var outputFolder: String = "~/Desktop"
    public var filenamePattern: String = FilenamePattern.defaultPattern
    public var format: ImageFormat = .png
    public var jpegQuality: Double = 0.9
    public var destinations: [Destination] = [.editor]
    public var captureMousePointer: Bool = false
    public var playSound: Bool = true
    public var showMagnifier: Bool = true
    public var windowShadow: Bool = true
    public var showNotification: Bool = true
    public var hotkeys: [String: Hotkey] = Dictionary(
        uniqueKeysWithValues: HotkeyAction.allCases.map { ($0.rawValue, $0.defaultHotkey) })
    /// Last region, in global screen points (y-down from the top of the main display).
    public var lastRegion: CGRect?
    public var fileCounter: Int = 1
    public var counterStart: Int = 1
    /// Remembered tool styles, so the editor reopens with your last colours and widths.
    public var toolStyles: [String: ElementStyle] = [:]

    public init() {}

    public func hotkey(for a: HotkeyAction) -> Hotkey? { hotkeys[a.rawValue] }
    public func style(for k: ElementKind) -> ElementStyle { toolStyles[k.rawValue] ?? .defaults(for: k) }

    public var outputFolderURL: URL {
        URL(fileURLWithPath: (outputFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    // Hand-written decoding: any key missing from an older settings file falls back to its default
    // instead of throwing the whole file away.
    enum CodingKeys: String, CodingKey {
        case outputFolder, filenamePattern, format, jpegQuality, destinations, captureMousePointer, playSound,
             showMagnifier, windowShadow, showNotification, hotkeys, lastRegion, fileCounter, counterStart, toolStyles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        outputFolder = (try? c.decodeIfPresent(String.self, forKey: .outputFolder)) ?? d.outputFolder
        filenamePattern = (try? c.decodeIfPresent(String.self, forKey: .filenamePattern)) ?? d.filenamePattern
        format = (try? c.decodeIfPresent(ImageFormat.self, forKey: .format)) ?? d.format
        jpegQuality = (try? c.decodeIfPresent(Double.self, forKey: .jpegQuality)) ?? d.jpegQuality
        // One unknown destination (from a newer version) drops only itself, not the whole list.
        if let raw = (try? c.decodeIfPresent([String].self, forKey: .destinations)) ?? nil {
            let known = raw.compactMap(Destination.init(rawValue:))
            destinations = known.isEmpty && !raw.isEmpty ? d.destinations : known
        } else {
            destinations = d.destinations
        }
        captureMousePointer = (try? c.decodeIfPresent(Bool.self, forKey: .captureMousePointer)) ?? d.captureMousePointer
        playSound = (try? c.decodeIfPresent(Bool.self, forKey: .playSound)) ?? d.playSound
        showMagnifier = (try? c.decodeIfPresent(Bool.self, forKey: .showMagnifier)) ?? d.showMagnifier
        windowShadow = (try? c.decodeIfPresent(Bool.self, forKey: .windowShadow)) ?? d.windowShadow
        showNotification = (try? c.decodeIfPresent(Bool.self, forKey: .showNotification)) ?? d.showNotification
        hotkeys = (try? c.decodeIfPresent([String: Hotkey].self, forKey: .hotkeys)) ?? d.hotkeys
        lastRegion = (try? c.decodeIfPresent(CGRect.self, forKey: .lastRegion))
        fileCounter = (try? c.decodeIfPresent(Int.self, forKey: .fileCounter)) ?? d.fileCounter
        counterStart = (try? c.decodeIfPresent(Int.self, forKey: .counterStart)) ?? d.counterStart
        toolStyles = ((try? c.decodeIfPresent(ToolStyles.self, forKey: .toolStyles)) ?? nil)?.styles ?? d.toolStyles
    }

    public static func decode(_ data: Data) -> AppSettings {
        (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
