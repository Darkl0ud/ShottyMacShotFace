import CoreGraphics
import Foundation

public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var isClear: Bool { a <= 0.001 }

    public static let red = RGBA(0.90, 0.11, 0.11)
    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
    public static let yellow = RGBA(1, 0.93, 0.0)
    public static let clear = RGBA(0, 0, 0, 0)
}

/// Every annotation the editor can place, mirroring Greenshot's tool set.
public enum ElementKind: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse, line, arrow, freehand, text, speechBubble, counter, highlight, obfuscate, image

    /// Filters read the pixels beneath them, so they can't be drawn on top of a cached background.
    public var isFilter: Bool { self == .highlight || self == .obfuscate }
    /// Kinds whose geometry is a list of points rather than a rectangle.
    public var isPointBased: Bool { self == .line || self == .arrow || self == .freehand }
    public var hasText: Bool { self == .text || self == .speechBubble }
}

public enum ArrowHeads: String, Codable, CaseIterable, Sendable { case none, start, end, both }
public enum HighlightMode: String, Codable, CaseIterable, Sendable { case text, area, grayscale, magnify }
public enum ObfuscateMode: String, Codable, CaseIterable, Sendable { case pixelate, blur }

/// Sizes are in *points*; the renderer multiplies by the document's pixel scale, so a 2 pt line
/// looks the same on a Retina capture as on a 1x one.
public struct ElementStyle: Codable, Hashable, Sendable {
    public var stroke: RGBA = .red
    public var fill: RGBA = .clear
    public var lineWidth: CGFloat = 2
    public var shadow: Bool = true
    public var arrowHeads: ArrowHeads = .end
    public var fontName: String = "Helvetica"
    public var fontSize: CGFloat = 18
    public var bold: Bool = false
    public var italic: Bool = false
    public var highlightMode: HighlightMode = .text
    public var obfuscateMode: ObfuscateMode = .pixelate
    public var pixelSize: CGFloat = 8
    public var blurRadius: CGFloat = 6
    public var magnification: CGFloat = 2

    public init() {}

    /// Greenshot-like starting styles per tool.
    public static func defaults(for kind: ElementKind) -> ElementStyle {
        var s = ElementStyle()
        switch kind {
        case .text:
            s.lineWidth = 0; s.shadow = false
        case .speechBubble:
            s.stroke = .black; s.fill = .white; s.lineWidth = 2
        case .counter:
            s.stroke = .white; s.fill = .red; s.lineWidth = 0; s.fontSize = 14
        case .highlight:
            s.fill = .yellow; s.shadow = false; s.lineWidth = 0
        case .obfuscate:
            s.shadow = false; s.lineWidth = 0; s.obfuscateMode = .pixelate; s.pixelSize = 4
        case .image:
            s.lineWidth = 0
        case .freehand:
            s.lineWidth = 3
        default:
            break
        }
        return s
    }

    // Hand-written decoding, like AppSettings: a key missing from an older (or newer) settings
    // file, or an enum value this version doesn't know, falls back to the default for that one
    // field instead of throwing away the whole style.
    enum CodingKeys: String, CodingKey {
        case stroke, fill, lineWidth, shadow, arrowHeads, fontName, fontSize, bold, italic, highlightMode,
             obfuscateMode, pixelSize, blurRadius, magnification
    }

    public init(from decoder: Decoder) throws {
        self = try ElementStyle.decode(from: decoder.container(keyedBy: CodingKeys.self), base: ElementStyle())
    }

    /// Fills in whatever keys are present on top of `base` (the tool's own defaults when known).
    static func decode(from c: KeyedDecodingContainer<CodingKeys>, base: ElementStyle) -> ElementStyle {
        var s = base
        func get<T: Decodable>(_ k: CodingKeys, _ t: T.Type) -> T? { (try? c.decodeIfPresent(t, forKey: k)) ?? nil }
        s.stroke = get(.stroke, RGBA.self) ?? s.stroke
        s.fill = get(.fill, RGBA.self) ?? s.fill
        s.lineWidth = get(.lineWidth, CGFloat.self) ?? s.lineWidth
        s.shadow = get(.shadow, Bool.self) ?? s.shadow
        s.arrowHeads = get(.arrowHeads, ArrowHeads.self) ?? s.arrowHeads
        s.fontName = get(.fontName, String.self) ?? s.fontName
        s.fontSize = get(.fontSize, CGFloat.self) ?? s.fontSize
        s.bold = get(.bold, Bool.self) ?? s.bold
        s.italic = get(.italic, Bool.self) ?? s.italic
        s.highlightMode = get(.highlightMode, HighlightMode.self) ?? s.highlightMode
        s.obfuscateMode = get(.obfuscateMode, ObfuscateMode.self) ?? s.obfuscateMode
        s.pixelSize = get(.pixelSize, CGFloat.self) ?? s.pixelSize
        s.blurRadius = get(.blurRadius, CGFloat.self) ?? s.blurRadius
        s.magnification = get(.magnification, CGFloat.self) ?? s.magnification
        return s
    }
}

/// Decodes a `[String: ElementStyle]` one entry at a time, so one unreadable entry only drops
/// itself, and missing keys fall back to that tool's own defaults (not the generic ones).
struct ToolStyles: Decodable {
    var styles: [String: ElementStyle] = [:]

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        for k in c.allKeys {
            guard let entry = try? c.nestedContainer(keyedBy: ElementStyle.CodingKeys.self, forKey: k) else { continue }
            let base = ElementKind(rawValue: k.stringValue).map(ElementStyle.defaults(for:)) ?? ElementStyle()
            styles[k.stringValue] = ElementStyle.decode(from: entry, base: base)
        }
    }
}

/// One annotation. A plain value type: the whole document state is just an image plus an array of
/// these, which makes undo a matter of keeping old copies of that array.
public struct Element: Identifiable {
    public var id = UUID()
    public var kind: ElementKind
    /// Rect-based kinds (and the bubble body). Document pixels, y-down.
    public var frame: CGRect = .zero
    /// Line/arrow: [start, end]. Freehand: the stroke. Speech bubble: [tail tip].
    public var points: [CGPoint] = []
    public var style: ElementStyle
    public var text: String = ""
    public var image: CGImage?

    public init(kind: ElementKind, frame: CGRect = .zero, points: [CGPoint] = [], style: ElementStyle? = nil) {
        self.kind = kind
        self.frame = frame
        self.points = points
        self.style = style ?? .defaults(for: kind)
    }

    /// Area the element touches, used for rubber-band selection and handles.
    public var bounds: CGRect {
        switch kind {
        case .line, .arrow, .freehand:
            return Geometry.boundingBox(points)
        case .speechBubble:
            return points.first.map { frame.union(CGRect(origin: $0, size: .zero)) } ?? frame
        default:
            return frame
        }
    }

    public func hitTest(_ p: CGPoint, tolerance: CGFloat, pixelScale: CGFloat = 1) -> Bool {
        let half = style.lineWidth * pixelScale / 2
        switch kind {
        case .line, .arrow:
            guard points.count == 2 else { return false }
            return Geometry.distance(from: p, toSegment: points[0], points[1]) <= tolerance + half
        case .freehand:
            return Geometry.distance(from: p, toPolyline: points) <= tolerance + half
        case .ellipse:
            let r = frame.insetBy(dx: -tolerance, dy: -tolerance)
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
            return nx * nx + ny * ny <= 1
        case .speechBubble:
            if frame.insetBy(dx: -tolerance, dy: -tolerance).contains(p) { return true }
            guard let tip = points.first else { return false }
            return Geometry.distance(from: p, toSegment: frame.center, tip) <= tolerance + 4 * pixelScale
        default:
            return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    public mutating func move(by d: CGPoint) {
        frame = frame.offsetBy(dx: d.x, dy: d.y)
        points = points.map { $0 + d }
    }
}

extension Element: Equatable {
    public static func == (l: Element, r: Element) -> Bool {
        l.id == r.id && l.kind == r.kind && l.frame == r.frame && l.points == r.points
            && l.style == r.style && l.text == r.text && l.image === r.image
    }
}

/// Something the user can grab on a selected element.
public enum Handle: Hashable, Sendable {
    case grip(Grip)
    case point(Int)
}

public extension Element {
    func handles() -> [(Handle, CGPoint)] {
        switch kind {
        case .line, .arrow:
            return points.enumerated().map { (.point($0.offset), $0.element) }
        case .freehand:
            return []
        case .speechBubble:
            var h = Grip.allCases.map { (Handle.grip($0), $0.position(in: frame)) }
            if let tip = points.first { h.append((.point(0), tip)) }
            return h
        default:
            return Grip.allCases.map { (Handle.grip($0), $0.position(in: frame)) }
        }
    }

    mutating func drag(_ handle: Handle, to p: CGPoint) {
        switch handle {
        case .grip(let g):
            // Counters are circles: resizing keeps them round instead of stretching to an oval.
            frame = kind == .counter ? Geometry.squareResize(frame, grip: g, to: p) : Geometry.resize(frame, grip: g, to: p)
        case .point(let i):
            if points.indices.contains(i) { points[i] = p }
        }
    }
}
