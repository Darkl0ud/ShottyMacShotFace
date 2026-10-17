import CoreGraphics

public extension CGRect {
    /// Rect spanning two arbitrary corners, so a drag works in any direction.
    init(corner a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

public extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
    static func * (l: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: l.x * k, y: l.y * k) }

    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}

/// The eight resize grips around a rectangle, clockwise from top-left
/// (document space is y-down, like image pixels).
public enum Grip: Int, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public func position(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }
}

public enum Geometry {
    public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    public static func distance(from p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .infinity }
        guard pts.count > 1 else { return p.distance(to: first) }
        var best = CGFloat.infinity
        for i in 1..<pts.count {
            best = min(best, distance(from: p, toSegment: pts[i - 1], pts[i]))
        }
        return best
    }

    public static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .zero }
        var minX = f.x, minY = f.y, maxX = f.x, maxY = f.y
        for p in pts {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Cocoa screen space is y-up from the bottom of the primary display; Quartz/ScreenCaptureKit
    /// "global" space is y-down from its top. The same formula converts both ways.
    public static func flipRect(_ r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    public static func flipPoint(_ p: CGPoint, primaryHeight h: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: h - p.y)
    }

    /// Shift-drag for lines: snap the end point to the nearest 45° direction.
    public static func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return b }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }

    /// Shift-drag for shapes: make the dragged corner produce a square.
    public static func squareCorner(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let side = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGPoint(x: a.x + (b.x >= a.x ? side : -side), y: a.y + (b.y >= a.y ? side : -side))
    }

    /// Like `resize`, but the result stays square. Corner grips grow from the opposite corner by the
    /// larger of the two drag distances; edge grips size by that edge and stay centred on the other axis.
    public static func squareResize(_ f: CGRect, grip: Grip, to p: CGPoint) -> CGRect {
        // Grips are listed clockwise, so +4 is the one directly opposite.
        let fixed = Grip(rawValue: (grip.rawValue + 4) % 8)!.position(in: f)
        let dx = p.x - fixed.x, dy = p.y - fixed.y
        switch grip {
        case .left, .right:
            let s = abs(dx)
            return CGRect(x: dx >= 0 ? fixed.x : fixed.x - s, y: f.midY - s / 2, width: s, height: s)
        case .top, .bottom:
            let s = abs(dy)
            return CGRect(x: f.midX - s / 2, y: dy >= 0 ? fixed.y : fixed.y - s, width: s, height: s)
        default:
            let s = max(abs(dx), abs(dy))
            return CGRect(x: dx >= 0 ? fixed.x : fixed.x - s, y: dy >= 0 ? fixed.y : fixed.y - s, width: s, height: s)
        }
    }

    /// Moves the edges a grip controls to `p`; the result is normalised so dragging a grip past the
    /// opposite edge flips the rectangle instead of producing a negative size.
    public static func resize(_ r: CGRect, grip: Grip, to p: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch grip {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return CGRect(corner: CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
    }
}
