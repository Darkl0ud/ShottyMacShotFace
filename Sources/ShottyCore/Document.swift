import CoreGraphics
import Foundation

/// Everything that undo needs to restore: the pixels and the annotations on top.
/// CGImage is immutable, so keeping old states around is cheap (no pixel copies).
public struct DocState: Equatable {
    public var image: CGImage
    public var elements: [Element]

    public init(image: CGImage, elements: [Element] = []) {
        self.image = image
        self.elements = elements
    }

    public var size: CGSize { CGSize(width: image.width, height: image.height) }
    public var canvasRect: CGRect { CGRect(origin: .zero, size: size) }

    public static func == (l: DocState, r: DocState) -> Bool {
        l.image === r.image && l.elements == r.elements
    }
}

/// An open capture in the editor, with snapshot-based undo/redo.
public final class EditorDocument {
    public private(set) var state: DocState
    /// Pixels per point of the original capture (2 on Retina). Element sizes are scaled by this.
    public let pixelScale: CGFloat
    public var title: String
    public let captureDate: Date
    public var fileURL: URL?
    public var counterStart: Int = 1
    public var onChange: (() -> Void)?

    public private(set) var undoStack: [DocState] = []
    public private(set) var redoStack: [DocState] = []
    private var savedState: DocState?
    /// The state that last left the editor (saved to a file or copied to the clipboard).
    private var exportedState: DocState?
    private var liveChangeStart: DocState?
    private let undoLimit = 100
    /// Undo keeps every old picture alive, and each effect step on a 5K capture is a new ~59 MB
    /// bitmap, so the history is also capped by the memory its pictures hold (oldest go first).
    public var undoMemoryLimit = 1 << 30

    public init(image: CGImage, pixelScale: CGFloat = 1, title: String = "", captureDate: Date = Date()) {
        self.state = DocState(image: image)
        self.pixelScale = max(1, pixelScale)
        self.title = title
        self.captureDate = captureDate
        self.savedState = state
    }

    /// Differs from the last file save (drives the title bar's edited dot for opened files).
    public var isDirty: Bool { savedState.map { $0 != state } ?? true }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public func markSaved() {
        savedState = state
        exportedState = state
    }

    /// True when the capture already exists outside the editor (saved to a file, or copied to the
    /// clipboard). Setting it records the current state as the exported one, so later edits
    /// still count as unexported work.
    public var wasExported: Bool {
        get { exportedState != nil }
        set { exportedState = newValue ? state : nil }
    }

    /// Closing would lose something: either the capture was never saved or copied anywhere, or
    /// it has changed since it last was. A brand-new capture counts, because with the default
    /// "Open in editor" destination the editor holds the only copy.
    public var hasUnexportedChanges: Bool { exportedState.map { $0 != state } ?? true }

    // MARK: Mutation

    /// One undoable step.
    public func mutate(_ body: (inout DocState) -> Void) {
        // A menu shortcut can arrive mid-drag; committing the drag first keeps the history linear
        // (otherwise the drag's start state would later be restored over this step).
        endLiveChange()
        var next = state
        body(&next)
        guard next != state else { return }
        pushUndo(state)
        state = next
        trimUndoMemory() // after `state` moves on: the old picture now lives only in the history
        onChange?()
    }

    /// Mouse drags change the document many times per second but should undo as one step:
    /// begin → mutateLive (repeated) → end.
    public func beginLiveChange() {
        // A drag whose mouse-up never came must not silently lose its start state.
        endLiveChange()
        liveChangeStart = state
    }

    public var isInLiveChange: Bool { liveChangeStart != nil }

    public func mutateLive(_ body: (inout DocState) -> Void) {
        // Never change the document without a way back: an undo mid-drag ends the live change,
        // and the rest of that drag becomes a new one.
        if liveChangeStart == nil { liveChangeStart = state }
        body(&state)
        onChange?()
    }

    public func endLiveChange() {
        defer { liveChangeStart = nil }
        guard let start = liveChangeStart, start != state else { return }
        pushUndo(start)
        trimUndoMemory()
        onChange?()
    }

    /// Drops whatever a live change did (e.g. a shape too small to keep) without an undo entry.
    public func cancelLiveChange() {
        if let start = liveChangeStart { state = start; onChange?() }
        liveChangeStart = nil
    }

    private func pushUndo(_ s: DocState) {
        undoStack.append(s)
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
        redoStack.removeAll()
    }

    /// Bytes held by pictures that only the history keeps alive (each distinct image once;
    /// annotation-only steps share the same image and cost nothing extra).
    public var undoImageBytes: Int {
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(state.image)]
        var total = 0
        for s in undoStack + redoStack where seen.insert(ObjectIdentifier(s.image)).inserted {
            total += s.image.bytesPerRow * s.image.height
        }
        return total
    }

    private func trimUndoMemory() {
        while !undoStack.isEmpty, undoImageBytes > undoMemoryLimit { undoStack.removeFirst() }
    }

    public func undo() {
        endLiveChange()
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(state)
        state = prev
        onChange?()
    }

    public func redo() {
        endLiveChange()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        onChange?()
    }

    // MARK: Queries

    public func element(_ id: UUID) -> Element? { state.elements.first { $0.id == id } }
    public func index(of id: UUID) -> Int? { state.elements.firstIndex { $0.id == id } }

    /// Topmost element under the point.
    public func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Element? {
        state.elements.last { $0.hitTest(p, tolerance: tolerance, pixelScale: pixelScale) }
    }

    /// Step counters number themselves by stacking order, so deleting #2 renumbers the rest —
    /// the same behaviour as Greenshot.
    public func counterNumber(for id: UUID) -> Int? {
        var n = counterStart
        for e in state.elements where e.kind == .counter {
            if e.id == id { return n }
            n += 1
        }
        return nil
    }

    // MARK: Editing operations

    @discardableResult
    public func add(_ e: Element) -> UUID {
        mutate { $0.elements.append(e) }
        return e.id
    }

    public func remove(_ ids: Set<UUID>) {
        mutate { $0.elements.removeAll { ids.contains($0.id) } }
    }

    public func update(_ id: UUID, _ body: (inout Element) -> Void) {
        mutate { s in
            if let i = s.elements.firstIndex(where: { $0.id == id }) { body(&s.elements[i]) }
        }
    }

    /// Copies keep their style but get new ids, offset so they don't hide the originals.
    @discardableResult
    public func duplicate(_ ids: Set<UUID>, offset: CGFloat) -> Set<UUID> {
        var newIDs = Set<UUID>()
        mutate { s in
            let copies: [Element] = s.elements.filter { ids.contains($0.id) }.map {
                var c = $0
                c.id = UUID()
                c.move(by: CGPoint(x: offset, y: offset))
                newIDs.insert(c.id)
                return c
            }
            s.elements.append(contentsOf: copies)
        }
        return newIDs
    }

    public enum ZOrder: Sendable { case front, back, forward, backward }

    public func reorder(_ ids: Set<UUID>, _ z: ZOrder) {
        mutate { s in
            switch z {
            case .front:
                let moving = s.elements.filter { ids.contains($0.id) }
                s.elements.removeAll { ids.contains($0.id) }
                s.elements.append(contentsOf: moving)
            case .back:
                let moving = s.elements.filter { ids.contains($0.id) }
                s.elements.removeAll { ids.contains($0.id) }
                s.elements.insert(contentsOf: moving, at: 0)
            case .forward:
                // Walk from the top so a block of selected elements moves up together.
                var i = s.elements.count - 2
                while i >= 0 {
                    if ids.contains(s.elements[i].id), !ids.contains(s.elements[i + 1].id) {
                        s.elements.swapAt(i, i + 1)
                    }
                    i -= 1
                }
            case .backward:
                var i = 1
                while i < s.elements.count {
                    if ids.contains(s.elements[i].id), !ids.contains(s.elements[i - 1].id) {
                        s.elements.swapAt(i, i - 1)
                    }
                    i += 1
                }
            }
        }
    }

    /// Crops the picture; annotations stay where they were relative to the content.
    public func crop(to rect: CGRect) {
        let r = rect.integral.intersection(state.canvasRect)
        guard !r.isNull, r.width >= 1, r.height >= 1, r != state.canvasRect,
              let cropped = state.image.cropping(to: r) else { return }
        mutate { s in
            s.image = cropped
            for i in s.elements.indices { s.elements[i].move(by: CGPoint(x: -r.minX, y: -r.minY)) }
        }
    }

    /// Replaces everything with a new flat image (used by whole-picture effects).
    public func replaceImage(_ image: CGImage, keepElements: Bool = false) {
        mutate { s in
            s.image = image
            if !keepElements { s.elements = [] }
        }
    }
}
