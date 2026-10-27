import Foundation

/// Values a filename pattern can refer to.
public struct FilenameContext: Sendable {
    public var date: Date
    public var title: String
    public var user: String
    public var host: String
    public var counter: Int
    public var timeZone: TimeZone

    public init(date: Date = Date(), title: String = "", user: String = NSUserName(),
                host: String = ProcessInfo.processInfo.hostName, counter: Int = 1,
                timeZone: TimeZone = .current) {
        self.date = date; self.title = title; self.user = user
        self.host = host; self.counter = counter; self.timeZone = timeZone
    }
}

/// Greenshot-style `${...}` filename patterns. A `/` in the pattern makes subfolders.
public enum FilenamePattern {
    public static let defaultPattern = "${YYYY}-${MM}-${DD} ${hh}.${mm}.${ss} ${title}"

    public static let variables: [(name: String, meaning: String)] = [
        ("${YYYY}", "year, 4 digits"), ("${YY}", "year, 2 digits"), ("${MM}", "month"),
        ("${DD}", "day"), ("${hh}", "hour (24h)"), ("${mm}", "minute"), ("${ss}", "second"),
        ("${title}", "window title"), ("${user}", "user name"), ("${hostname}", "computer name"),
        ("${NUM}", "6-digit counter"),
    ]

    /// Returns a relative path (no extension). Never empty, never escapes the output folder.
    public static func expand(_ pattern: String, _ c: FilenameContext) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = c.timeZone
        let d = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: c.date)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        let values: [String: String] = [
            "YYYY": String(format: "%04d", d.year ?? 0),
            "YY": two((d.year ?? 0) % 100),
            "MM": two(d.month), "DD": two(d.day),
            "hh": two(d.hour), "mm": two(d.minute), "ss": two(d.second),
            "title": c.title, "user": c.user, "hostname": c.host,
            "NUM": String(format: "%06d", c.counter),
        ]

        var out = ""
        var rest = Substring(pattern)
        while let start = rest.range(of: "${") {
            out += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: "}") else { out += rest[start.lowerBound...]; rest = ""; break }
            let name = String(after[..<end])
            if let v = values[name] {
                // Values must not create folders or escape, so slashes inside them are replaced here.
                out += sanitizeComponent(v)
            } else {
                out += "${\(name)}"
            }
            rest = after[after.index(after: end)...]
        }
        out += rest

        let parts = out.split(separator: "/").map { sanitizeComponent(String($0)) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        let joined = parts.joined(separator: "/")
        return joined.isEmpty ? "Screenshot" : joined
    }

    /// Strips characters Finder or other tools choke on, and tidies separators left behind by
    /// empty variables (e.g. a trailing " " when there's no window title).
    public static func sanitizeComponent(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters).union(.newlines)
        var cleaned = String(s.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
        while cleaned.contains("  ") { cleaned = cleaned.replacingOccurrences(of: "  ", with: " ") }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
        return truncated(cleaned, maxBytes: maxComponentBytes)
    }

    /// File systems limit a name, not a title: 255 UTF-16 units on APFS/HFS+/exFAT, 255 UTF-8 bytes
    /// on most network servers. UTF-8 bytes are never fewer than UTF-16 units, so a byte cap fits
    /// both. 230 leaves room for " (9999)" and ".heic" added by uniqueURL. A Character cap didn't:
    /// 200 emoji (or flags, or family emoji) are far more than 255 units, and the save failed.
    public static let maxComponentBytes = 230

    /// The longest start of `s` within `maxBytes` of UTF-8, cut between Characters (never inside
    /// an emoji or an accented letter).
    static func truncated(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var out = ""
        var bytes = 0
        for ch in s {
            let n = String(ch).utf8.count
            if bytes + n > maxBytes { break }
            out.append(ch)
            bytes += n
        }
        // A cut can leave a separator dangling at the end, as an empty variable would.
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
    }

    /// "name.png", then "name (2).png", "name (3).png"… — never overwrite an earlier capture.
    public static func uniqueURL(in dir: URL, relativeName: String, ext: String,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = dir.appendingPathComponent(relativeName).appendingPathExtension(ext)
        if !exists(first) { return first }
        var n = 2
        while true {
            let u = dir.appendingPathComponent("\(relativeName) (\(n))").appendingPathExtension(ext)
            if !exists(u) { return u }
            n += 1
        }
    }
}
