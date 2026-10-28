import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ShottyCore

// MARK: Helpers

struct MissingImage: Error {}

/// #require can't nest, so unwrapping an optional image into pixels gets its own helper.
func pixels(_ img: CGImage?) throws -> PixelReader {
    guard let img, let p = PixelReader(img) else { throw MissingImage() }
    return p
}

func solid(_ w: Int, _ h: Int, _ c: RGBA = .white) -> CGImage { Bitmap.solid(width: w, height: h, color: c)! }

/// Left half black, right half white: handy for checking orientation and filters.
func halves(_ w: Int, _ h: Int) -> CGImage {
    Bitmap.render(width: w, height: h) { ctx in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
    }!
}

/// Top band red: confirms y-down orientation survives every transform.
func topRed(_ w: Int, _ h: Int) -> CGImage {
    Bitmap.render(width: w, height: h) { ctx in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(RGBA.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: 10))
    }!
}

func isRed(_ p: PixelReader.Pixel) -> Bool { p.r > 200 && p.g < 80 && p.b < 80 }
func isWhite(_ p: PixelReader.Pixel) -> Bool { p.r > 240 && p.g > 240 && p.b > 240 }
func isBlack(_ p: PixelReader.Pixel) -> Bool { p.r < 20 && p.g < 20 && p.b < 20 && p.a > 240 }

// MARK: Geometry

@Suite struct GeometryTests {
    @Test func rectFromCornersAnyDirection() {
        #expect(CGRect(corner: CGPoint(x: 10, y: 20), CGPoint(x: 2, y: 4)) == CGRect(x: 2, y: 4, width: 8, height: 16))
    }

    @Test func segmentDistance() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 10, y: 0)
        #expect(Geometry.distance(from: CGPoint(x: 5, y: 3), toSegment: a, b) == 3)
        #expect(Geometry.distance(from: CGPoint(x: -4, y: 3), toSegment: a, b) == 5) // past the end
    }

    @Test func snap45() {
        let p = Geometry.snap45(from: .zero, to: CGPoint(x: 10, y: 1))
        #expect(abs(p.y) < 0.0001)
        let q = Geometry.snap45(from: .zero, to: CGPoint(x: 10, y: 9))
        #expect(abs(q.x - q.y) < 0.0001)
    }

    @Test func resizePastOppositeEdgeFlips() {
        let r = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(Geometry.resize(r, grip: .right, to: CGPoint(x: 0, y: 0)) == CGRect(x: 0, y: 10, width: 10, height: 20))
        #expect(Geometry.resize(r, grip: .topLeft, to: CGPoint(x: 5, y: 5)) == CGRect(x: 5, y: 5, width: 25, height: 25))
    }

    @Test func squareResizeStaysSquare() {
        let f = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(Geometry.squareResize(f, grip: .bottomRight, to: CGPoint(x: 50, y: 40)) == CGRect(x: 10, y: 10, width: 40, height: 40))
        #expect(Geometry.squareResize(f, grip: .topLeft, to: CGPoint(x: 0, y: 5)) == CGRect(x: 0, y: 0, width: 30, height: 30))
        #expect(Geometry.squareResize(f, grip: .right, to: CGPoint(x: 40, y: 99)) == CGRect(x: 10, y: 5, width: 30, height: 30))
        var c = Element(kind: .counter, frame: f)
        c.drag(.grip(.bottom), to: CGPoint(x: 0, y: 50))
        #expect(c.frame.width == c.frame.height && c.frame.height == 40)
    }

    @Test func cocoaFlipIsItsOwnInverse() {
        let r = CGRect(x: 5, y: 100, width: 50, height: 30)
        let f = Geometry.flipRect(r, primaryHeight: 900)
        #expect(f == CGRect(x: 5, y: 770, width: 50, height: 30))
        #expect(Geometry.flipRect(f, primaryHeight: 900) == r)
    }
}

// MARK: Elements & document

@Suite struct DocumentTests {
    func doc() -> EditorDocument { EditorDocument(image: solid(200, 100), pixelScale: 2) }

    @Test func undoRedo() {
        let d = doc()
        #expect(!d.isDirty)
        let id = d.add(Element(kind: .rectangle, frame: CGRect(x: 1, y: 1, width: 10, height: 10)))
        #expect(d.isDirty && d.state.elements.count == 1)
        d.update(id) { $0.frame.origin.x = 50 }
        d.undo()
        #expect(d.state.elements[0].frame.origin.x == 1)
        d.undo()
        #expect(d.state.elements.isEmpty && !d.isDirty)
        d.redo(); d.redo()
        #expect(d.state.elements[0].frame.origin.x == 50)
    }

    @Test func liveChangeIsOneUndoStep() {
        let d = doc()
        let id = d.add(Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10)))
        d.beginLiveChange()
        for i in 1...20 { d.mutateLive { $0.elements[0].frame.origin.x = CGFloat(i) } }
        d.endLiveChange()
        #expect(d.undoStack.count == 2)
        d.undo()
        #expect(d.element(id)?.frame.origin.x == 0)
    }

    @Test func cancelledLiveChangeLeavesNoTrace() {
        let d = doc()
        d.beginLiveChange()
        d.mutateLive { $0.elements.append(Element(kind: .line, points: [.zero, .zero])) }
        d.cancelLiveChange()
        #expect(d.state.elements.isEmpty && d.undoStack.isEmpty)
    }

    @Test func zOrder() {
        let d = doc()
        let ids = (0..<4).map { _ in d.add(Element(kind: .rectangle)) }
        d.reorder([ids[0]], .front)
        #expect(d.state.elements.map(\.id) == [ids[1], ids[2], ids[3], ids[0]])
        d.reorder([ids[0]], .back)
        #expect(d.state.elements.map(\.id) == ids)
        d.reorder([ids[1]], .forward)
        #expect(d.state.elements.map(\.id) == [ids[0], ids[2], ids[1], ids[3]])
        d.reorder([ids[1]], .backward)
        #expect(d.state.elements.map(\.id) == ids)
        d.reorder([ids[3]], .forward) // already on top: no change, no undo entry
        #expect(d.state.elements.map(\.id) == ids)
    }

    @Test func countersRenumberByOrder() {
        let d = doc()
        d.counterStart = 1
        let a = d.add(Element(kind: .counter)), b = d.add(Element(kind: .counter))
        _ = d.add(Element(kind: .rectangle))
        let c = d.add(Element(kind: .counter))
        #expect(d.counterNumber(for: c) == 3)
        d.remove([b])
        #expect(d.counterNumber(for: a) == 1 && d.counterNumber(for: c) == 2)
    }

    @Test func cropMovesElements() {
        let d = doc()
        let id = d.add(Element(kind: .rectangle, frame: CGRect(x: 50, y: 40, width: 10, height: 10)))
        d.crop(to: CGRect(x: 20, y: 30, width: 100, height: 50))
        #expect(d.state.image.width == 100 && d.state.image.height == 50)
        #expect(d.element(id)?.frame.origin == CGPoint(x: 30, y: 10))
    }

    @Test func duplicateOffsetsCopies() {
        let d = doc()
        let id = d.add(Element(kind: .line, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]))
        let copies = d.duplicate([id], offset: 5)
        #expect(copies.count == 1 && d.state.elements.count == 2)
        #expect(d.element(copies.first!)?.points == [CGPoint(x: 5, y: 5), CGPoint(x: 15, y: 15)])
    }

    @Test func hitTesting() {
        let line = Element(kind: .line, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        #expect(line.hitTest(CGPoint(x: 50, y: 3), tolerance: 3))
        #expect(!line.hitTest(CGPoint(x: 50, y: 20), tolerance: 3))
        let ell = Element(kind: .ellipse, frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(ell.hitTest(CGPoint(x: 50, y: 25), tolerance: 0))
        #expect(!ell.hitTest(CGPoint(x: 2, y: 2), tolerance: 0)) // corner is outside an ellipse
    }

    @Test func handlesDragEndpoints() {
        var e = Element(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)])
        #expect(e.handles().count == 2)
        e.drag(.point(1), to: CGPoint(x: 40, y: 5))
        #expect(e.points[1] == CGPoint(x: 40, y: 5))
        var r = Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(r.handles().count == 8)
        r.drag(.grip(.bottomRight), to: CGPoint(x: 30, y: 20))
        #expect(r.frame == CGRect(x: 0, y: 0, width: 30, height: 20))
    }
}

// MARK: Rendering

@Suite struct RendererTests {
    @Test func rectangleStrokeLandsWhereDrawn() throws {
        let r = Renderer(pixelScale: 1)
        var s = DocState(image: solid(100, 100))
        var e = Element(kind: .rectangle, frame: CGRect(x: 10, y: 10, width: 50, height: 30))
        e.style.shadow = false; e.style.lineWidth = 4
        s.elements = [e]
        let px = try pixels(r.flatten(s))
        #expect(isRed(px[11, 25]))   // left edge, inside the stroke
        #expect(isWhite(px[35, 25])) // hollow middle
        #expect(isWhite(px[5, 5]))   // outside
        #expect(isRed(px[35, 11]))   // top edge: proves y-down (top stays top)
    }

    @Test func pixelScaleWidensStrokes() throws {
        let r = Renderer(pixelScale: 2)
        var s = DocState(image: solid(100, 100))
        var e = Element(kind: .rectangle, frame: CGRect(x: 10, y: 10, width: 60, height: 60))
        e.style.shadow = false; e.style.lineWidth = 3 // 3 pt → 6 px
        s.elements = [e]
        let px = try pixels(r.flatten(s))
        #expect(isRed(px[15, 40]))
        #expect(isWhite(px[17, 40]))
    }

    @Test func pixelateMakesUniformBlocks() throws {
        let r = Renderer(pixelScale: 1)
        // A fine checkerboard: every pixel differs from its neighbour until pixelated.
        let checker = Bitmap.render(width: 64, height: 64) { ctx in
            for y in 0..<64 { for x in 0..<64 where (x + y) % 2 == 0 {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            } }
        }!
        var s = DocState(image: checker)
        var e = Element(kind: .obfuscate, frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        e.style.obfuscateMode = .pixelate; e.style.pixelSize = 8
        s.elements = [e]
        let px = try pixels(r.flatten(s))
        // Black-on-transparent averages to half-transparent black, the same in every pixel of a cell.
        #expect(!px[9, 9].differs(from: px[10, 9], by: 3))
        #expect(px[9, 9].a > 100 && px[9, 9].a < 160)
    }

    @Test func pixelateOnOpaqueGivesGrey() throws {
        let r = Renderer(pixelScale: 1)
        var s = DocState(image: halves(64, 64))
        var e = Element(kind: .obfuscate, frame: CGRect(x: 28, y: 0, width: 8, height: 8))
        e.style.obfuscateMode = .pixelate; e.style.pixelSize = 8
        s.elements = [e]
        let px = try pixels(r.flatten(s))
        #expect(!px[29, 3].differs(from: px[34, 3], by: 3))
        #expect(px[30, 3].r > 90 && px[30, 3].r < 170) // half black, half white → grey
    }

    @Test func blurSoftensEdge() throws {
        let r = Renderer(pixelScale: 1)
        var s = DocState(image: halves(100, 40))
        var e = Element(kind: .obfuscate, frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        e.style.obfuscateMode = .blur; e.style.blurRadius = 6
        s.elements = [e]
        let px = try pixels(r.flatten(s))
        let mid = px[50, 20]
        #expect(mid.r > 40 && mid.r < 215)
    }

    @Test func pixelate4IsDefaultObfuscation() {
        let d = ElementStyle.defaults(for: .obfuscate)
        #expect(d.obfuscateMode == .pixelate && d.pixelSize == 4)
    }

    /// The blur fades out past the box (no hard edge) but is total inside it.
    @Test func blurFadesOutsideButNotInside() throws {
        let r = Renderer(pixelScale: 1)
        // Black stripes on white: easy to tell blurred (grey) from untouched (pure black/white).
        let stripes = Bitmap.render(width: 200, height: 100) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for x in stride(from: 0, to: 200, by: 4) { ctx.fill(CGRect(x: x, y: 0, width: 2, height: 100)) }
        }!
        var s = DocState(image: stripes)
        var e = Element(kind: .obfuscate, frame: CGRect(x: 60, y: 30, width: 80, height: 40))
        e.style.obfuscateMode = .blur; e.style.blurRadius = 4 // fade = 8 px
        s.elements = [e]
        let px = try pixels(r.flatten(s))
        func isGrey(_ p: PixelReader.Pixel) -> Bool { p.r > 40 && p.r < 215 }
        // Inside, right up to the edge: fully blurred.
        for x in [60, 61, 100, 138, 139] { #expect(isGrey(px[x, 50]), "x=\(x) inside should be blurred") }
        // Just outside the edge: partly blended, so neither the original black nor white.
        #expect(isGrey(px[57, 50]) || isGrey(px[56, 50]))
        // Well outside the fade: untouched.
        #expect(!isGrey(px[40, 50]) && !isGrey(px[41, 50]))
        #expect(!isGrey(px[100, 15]))
    }

    @Test func textHighlighterKeepsBlackText() throws {
        let r = Renderer(pixelScale: 1)
        var s = DocState(image: halves(100, 40))
        s.elements = [Element(kind: .highlight, frame: CGRect(x: 0, y: 0, width: 100, height: 40))]
        let px = try pixels(r.flatten(s))
        #expect(isBlack(px[10, 20]))                                // multiply: black stays black
        #expect(px[80, 20].r > 230 && px[80, 20].b < 40)             // white turns yellow
    }

    @Test func excludedElementStillCountsForCounters() throws {
        let r = Renderer(pixelScale: 1)
        var s = DocState(image: solid(100, 100))
        let a = Element(kind: .counter, frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        s.elements = [a, Element(kind: .counter, frame: CGRect(x: 50, y: 50, width: 30, height: 30))]
        let px = try pixels(r.flatten(s, excluding: [a.id]))
        #expect(isWhite(px[15, 2]))
        #expect(isRed(px[65, 52]))
    }

    @Test func everyKindRendersWithoutCrashing() throws {
        let r = Renderer(pixelScale: 2)
        var s = DocState(image: halves(300, 200))
        for k in ElementKind.allCases {
            var e = Element(kind: k, frame: CGRect(x: 20, y: 20, width: 120, height: 80),
                            points: k == .speechBubble ? [CGPoint(x: 200, y: 180)] : [CGPoint(x: 5, y: 5), CGPoint(x: 150, y: 120)])
            e.text = "Hello"
            if k == .image { e.image = solid(10, 10, .red) }
            s.elements.append(e)
        }
        for mode in HighlightMode.allCases {
            var e = Element(kind: .highlight, frame: CGRect(x: 100, y: 100, width: 60, height: 40))
            e.style.highlightMode = mode
            s.elements.append(e)
        }
        let img = try #require(r.flatten(s))
        #expect(img.width == 300 && img.height == 200)
    }
}

// MARK: Effects

@Suite struct EffectsTests {
    @Test func borderGrowsCanvas() throws {
        let out = try #require(Effects.border(solid(50, 40), width: 5, color: .red))
        #expect(out.width == 60 && out.height == 50)
        let px = try #require(PixelReader(out))
        #expect(isRed(px[1, 1]) && isWhite(px[30, 25]))
    }

    @Test func shadowAddsMarginAndTransparency() throws {
        let out = try #require(Effects.dropShadow(solid(50, 40), pixelScale: 1))
        #expect(out.width > 50 && out.height > 40)
        let px = try #require(PixelReader(out))
        #expect(px[0, 0].a < 10)
    }

    @Test func rotationKeepsOrientation() throws {
        let cw = try #require(Effects.rotate(topRed(100, 50), clockwise: true))
        #expect(cw.width == 50 && cw.height == 100)
        let px = try #require(PixelReader(cw))
        #expect(isRed(px[45, 50]) && isWhite(px[5, 50])) // top band now on the right
        let ccw = try pixels(Effects.rotate(topRed(100, 50), clockwise: false))
        #expect(isRed(ccw[3, 50]) && isWhite(ccw[45, 50]))  // …or on the left
    }

    @Test func tornEdgesCutTransparentTeeth() throws {
        let out = try #require(Effects.tornEdges(solid(200, 100), pixelScale: 1, sides: .bottom, shadow: false))
        #expect(out.width == 200 && out.height == 100)
        let px = try #require(PixelReader(out))
        #expect(px[100, 2].a == 255)                                // top untouched
        #expect((0..<200).contains { px[$0, 99].a < 20 })           // bottom row has gaps
    }

    @Test func autoCropFindsContent() throws {
        let img = Bitmap.render(width: 100, height: 80) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 20, y: 10, width: 30, height: 40))
        }!
        #expect(Effects.autoCropRect(img) == CGRect(x: 20, y: 10, width: 30, height: 40))
        #expect(Effects.autoCropRect(solid(10, 10)) == nil)
    }

    @Test func trimTransparentEdges() throws {
        let img = Bitmap.render(width: 100, height: 80) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.05)); ctx.fill(CGRect(x: 10, y: 5, width: 60, height: 50)) // faint shadow counts
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 20, y: 15, width: 30, height: 20))
        }!
        let t = try #require(Effects.trimTransparent(img))
        #expect(t.width == 60 && t.height == 50)
        #expect(Effects.trimTransparent(solid(10, 10)) == nil)                                  // nothing to trim
        #expect(Effects.trimTransparent(Bitmap.solid(width: 5, height: 5, color: .clear)!) == nil) // all empty
    }

    @Test func grayscaleAndInvert() throws {
        let g = try pixels(Effects.grayscale(solid(10, 10, .red)))
        #expect(abs(Int(g[5, 5].r) - Int(g[5, 5].g)) < 4)
        let i = try pixels(Effects.invert(solid(10, 10, .white)))
        #expect(isBlack(i[5, 5]))
    }
}

// MARK: Export

@Suite struct ExportTests {
    @Test(arguments: ImageFormat.allCases)
    func roundTrips(_ f: ImageFormat) throws {
        let data = try ImageExporter.data(for: topRed(40, 30), format: f)
        #expect(data.count > 0)
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let back = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(back.width == 40 && back.height == 30)
        let px = try #require(PixelReader(back))
        #expect(isRed(px[20, 2]))
    }

    @Test func jpegGetsWhiteNotBlackBackground() throws {
        let clear = Bitmap.solid(width: 10, height: 10, color: .clear)!
        let data = try ImageExporter.data(for: clear, format: .jpeg)
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let px = try pixels(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(isWhite(px[5, 5]))
    }

    @Test func formatFromExtension() {
        #expect(ImageFormat.from(extension: "JPG") == .jpeg)
        #expect(ImageFormat.from(extension: "tif") == .tiff)
        #expect(ImageFormat.from(extension: "xyz") == nil)
    }
}

// MARK: Filename patterns

@Suite struct FilenameTests {
    let ctx = FilenameContext(
        date: Date(timeIntervalSince1970: 1_760_000_000), // 2025-10-09 08:53:20 UTC
        title: "Safari: Apple / News", user: "warren", host: "mbp", counter: 7,
        timeZone: TimeZone(identifier: "UTC")!)

    @Test func defaultPattern() {
        #expect(FilenamePattern.expand(FilenamePattern.defaultPattern, ctx) == "2025-10-09 08.53.20 Safari- Apple - News")
    }

    @Test func emptyTitleLeavesNoTrailingJunk() {
        var c = ctx; c.title = ""
        #expect(FilenamePattern.expand("${YYYY}-${MM}-${DD} ${title}", c) == "2025-10-09")
    }

    @Test func subfoldersButNoEscape() {
        #expect(FilenamePattern.expand("${YYYY}/${MM}/shot_${NUM}", ctx) == "2025/10/shot_000007")
        #expect(FilenamePattern.expand("../../etc/${user}", ctx) == "etc/warren")
        #expect(FilenamePattern.expand("${title}", ctx).contains("/") == false)
    }

    @Test func unknownVariablesSurviveAndEmptyFallsBack() {
        #expect(FilenamePattern.expand("x ${nope}", ctx) == "x ${nope}")
        #expect(FilenamePattern.expand("", ctx) == "Screenshot")
        #expect(FilenamePattern.expand("unterminated ${YYYY", ctx) == "unterminated ${YYYY")
    }

    @Test func uniqueNames() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/a.png", "/tmp/x/a (2).png"]
        let u = FilenamePattern.uniqueURL(in: dir, relativeName: "a", ext: "png") { taken.contains($0.path) }
        #expect(u.lastPathComponent == "a (3).png")
    }
}

// MARK: Settings

@Suite struct SettingsTests {
    @Test func roundTrip() {
        var s = AppSettings()
        s.format = .jpeg; s.destinations = [.clipboard, .file]; s.lastRegion = CGRect(x: 1, y: 2, width: 3, height: 4)
        s.toolStyles["arrow"] = ElementStyle.defaults(for: .arrow)
        #expect(AppSettings.decode(s.encoded()) == s)
    }

    @Test func missingKeysUseDefaults() {
        let s = AppSettings.decode(Data(#"{"format":"tiff","playSound":false}"#.utf8))
        #expect(s.format == .tiff && !s.playSound)
        #expect(s.filenamePattern == FilenamePattern.defaultPattern)
        #expect(s.hotkey(for: .region) == HotkeyAction.region.defaultHotkey)
    }

    @Test func garbageGivesDefaults() {
        #expect(AppSettings.decode(Data("nope".utf8)) == AppSettings())
    }

    @Test func hotkeyFlagsAndDisplay() {
        let hk = HotkeyAction.region.defaultHotkey
        #expect(hk.display == "⌃⇧4")
        #expect(hk.modifiers.carbonFlags == (1 << 9) | (1 << 12))
        #expect(!Hotkey(keyCode: 0x00, modifiers: [.shift]).isAcceptable)
        #expect(Hotkey(keyCode: 0x69, modifiers: []).isAcceptable) // F13 alone is fine
    }

    @Test func defaultHotkeysAreDistinct() {
        let all = HotkeyAction.allCases.map(\.defaultHotkey)
        #expect(Set(all).count == all.count)
    }
}

// MARK: Review round 1 (CORE_EDITOR findings)

/// Decodes encoded data back to the first image, without any orientation handling.
func decodeFirst(_ data: Data) throws -> PixelReader {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw MissingImage() }
    return try pixels(CGImageSourceCreateImageAtIndex(src, 0, nil))
}

func tempURL(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

@Suite struct TextFitTests {
    /// CORE_EDITOR-1: a click-made box is one line tall (240 × fontSize·2.4 pt); drawText clips
    /// to it, so line two used to vanish from the saved picture.
    @Test func secondLineIsRenderedAfterFitting() throws {
        let r = Renderer(pixelScale: 1)
        var e = Element(kind: .text, frame: CGRect(x: 10, y: 10, width: 240, height: 18 * 2.4))
        e.style.stroke = .black
        e.text = "first line\nsecond line"
        var fitted = e
        fitted.frame = Renderer.frameFittingText(e, pixelScale: 1)
        #expect(fitted.frame.height > e.frame.height)
        // Ink in the band where line two goes: below the first line's height.
        let oneLine = Renderer.textHeight("first line", style: e.style, pixelScale: 1, width: 232)
        func inkInSecondLine(_ el: Element) throws -> Int {
            var s = DocState(image: solid(300, 200))
            s.elements = [el]
            let px = try pixels(r.flatten(s))
            var n = 0
            for y in (12 + Int(oneLine))..<Int(fitted.frame.maxY) { for x in 10..<250 where px[x, y].r < 128 { n += 1 } }
            return n
        }
        #expect(try inkInSecondLine(e) == 0)       // the bug: the one-line box drops line two entirely
        #expect(try inkInSecondLine(fitted) > 20)  // fitted: line two is in the picture
    }

    @Test func wrappedSentenceFitsAndBoxNeverShrinks() {
        var e = Element(kind: .text, frame: CGRect(x: 0, y: 0, width: 240, height: 43.2))
        e.text = "a sentence that is clearly longer than two hundred and forty points at eighteen points"
        let f = Renderer.frameFittingText(e, pixelScale: 1)
        let need = Renderer.textHeight(e.text, style: e.style, pixelScale: 1, width: 240 - 8)
        #expect(f.height - 4 >= need && f.width == 240 && f.origin == e.frame.origin)
        var big = e
        big.frame.size.height = 500
        #expect(Renderer.frameFittingText(big, pixelScale: 1).height == 500)
    }

    @Test func bubbleFitUsesItsLargerInset() {
        var e = Element(kind: .speechBubble, frame: CGRect(x: 0, y: 0, width: 200, height: 40), points: [CGPoint(x: 10, y: 120)])
        e.text = "one\ntwo\nthree"
        let f = Renderer.frameFittingText(e, pixelScale: 2)
        let need = Renderer.textHeight(e.text, style: e.style, pixelScale: 2, width: 200 - 32, center: true)
        #expect(f.height - 24 >= need)
    }
}

@Suite struct ExportedStateTests {
    /// CORE_EDITOR-3: a brand-new capture with no file and no clipboard copy must count as unsaved.
    @Test func newCaptureHasUnexportedChanges() {
        let d = EditorDocument(image: solid(10, 10))
        #expect(!d.isDirty)            // nothing edited…
        #expect(d.hasUnexportedChanges) // …but it exists nowhere else
        #expect(!d.wasExported)
    }

    @Test func exportCoversCurrentStateOnly() {
        let d = EditorDocument(image: solid(10, 10))
        d.wasExported = true
        #expect(!d.hasUnexportedChanges)
        d.add(Element(kind: .rectangle))
        #expect(d.hasUnexportedChanges && d.wasExported)
        d.markSaved()
        #expect(!d.hasUnexportedChanges && !d.isDirty)
        d.undo()
        #expect(d.hasUnexportedChanges)
    }
}

@Suite struct LiveChangeSafetyTests {
    /// CORE_EDITOR-7: undo in the middle of a create-drag used to make the previous state unreachable.
    @Test func undoMidDragKeepsHistoryReachable() {
        let d = EditorDocument(image: solid(100, 100))
        d.add(Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10)))
        d.beginLiveChange()
        d.mutateLive { $0.elements.append(Element(kind: .line, points: [.zero, CGPoint(x: 5, y: 5)])) }
        d.undo()
        d.cancelLiveChange() // what mouseUp does for a shape that vanished
        while d.canUndo { d.undo() }
        #expect(d.state.elements.isEmpty, "the empty starting state must still be reachable")
    }

    @Test func deleteMidMoveDoesNotInventSteps() {
        let d = EditorDocument(image: solid(100, 100))
        let id = d.add(Element(kind: .rectangle, frame: CGRect(x: 1, y: 0, width: 10, height: 10)))
        d.beginLiveChange()
        d.mutateLive { $0.elements[0].frame.origin.x = 30 }
        d.remove([id])
        #expect(!d.isInLiveChange)
        d.undo()
        #expect(d.element(id)?.frame.origin.x == 30) // the move was committed as its own step
        d.undo()
        #expect(d.element(id)?.frame.origin.x == 1)
        d.undo()
        #expect(d.state.elements.isEmpty && !d.canUndo)
    }

    @Test func danglingLiveChangeIsCommittedNotLost() {
        let d = EditorDocument(image: solid(100, 100))
        d.beginLiveChange()
        d.mutateLive { $0.elements.append(Element(kind: .rectangle)) }
        d.beginLiveChange() // the mouse-up never came
        d.mutateLive { $0.elements[0].frame.size.width = 50 }
        d.endLiveChange()
        d.undo(); d.undo()
        #expect(d.state.elements.isEmpty)
    }

    @Test func mutateLiveWithoutBeginIsStillUndoable() {
        let d = EditorDocument(image: solid(100, 100))
        d.mutateLive { $0.elements.append(Element(kind: .rectangle)) }
        d.endLiveChange()
        #expect(d.canUndo)
    }
}

@Suite struct UndoMemoryTests {
    /// CORE_EDITOR-13: every effect step keeps a full bitmap; the history is capped by bytes too.
    @Test func imageStepsAreCappedByMemory() {
        let d = EditorDocument(image: solid(500, 500)) // ~1 MB per picture
        d.undoMemoryLimit = 5 * 1_000_000
        for i in 0..<20 { d.replaceImage(solid(500, 500, RGBA(Double(i) / 20, 0, 0))) }
        #expect(d.undoImageBytes <= d.undoMemoryLimit)
        #expect(d.undoStack.count >= 3 && d.undoStack.count < 20)
    }

    @Test func annotationStepsCostNothingExtra() {
        let d = EditorDocument(image: solid(500, 500))
        d.undoMemoryLimit = 1
        for i in 0..<150 { d.add(Element(kind: .rectangle, frame: CGRect(x: i, y: 0, width: 5, height: 5))) }
        #expect(d.undoStack.count == 100) // only the count limit applies: they share one picture
    }
}

@Suite struct ExportFixTests {
    func pixel(alpha: Double) -> CGImage { Bitmap.solid(width: 8, height: 8, color: RGBA(0, 0, 0, alpha))! }

    /// CORE_EDITOR-6: GIF has 1-bit transparency; partly transparent pixels came out opaque black.
    @Test func gifNeverTurnsSoftShadowBlack() throws {
        let faint = try decodeFirst(ImageExporter.data(for: pixel(alpha: 0.3), format: .gif))[4, 4]
        #expect(faint.a == 0, "30% shadow → transparent, got \(faint)")
        let strong = try decodeFirst(ImageExporter.data(for: pixel(alpha: 0.7), format: .gif))[4, 4]
        #expect(strong.a == 255 && strong.r > 50 && strong.r < 110, "70% black over white → grey, got \(strong)")
        let clear = try decodeFirst(ImageExporter.data(for: pixel(alpha: 0), format: .gif))[4, 4]
        #expect(clear.a == 0)
        let opaque = try decodeFirst(ImageExporter.data(for: topRed(20, 20), format: .gif))
        #expect(isRed(opaque[10, 2]) && isWhite(opaque[10, 15]))
    }

    @Test func pngAndHeicKeepPartialAlpha() throws {
        let png = try decodeFirst(ImageExporter.data(for: pixel(alpha: 0.3), format: .png))[4, 4]
        #expect(png.a > 60 && png.a < 95)
        #expect(!ImageFormat.gif.supportsAlpha && ImageFormat.heic.supportsAlpha)
    }

    /// CORE_EDITOR-14: a JPEG stored 40×20 with EXIF orientation 6 displays 20×40.
    @Test func loadAppliesExifOrientation() throws {
        let url = tempURL("rotated.jpg")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, topRed(40, 20), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let img = try #require(ImageExporter.load(from: url))
        #expect(img.width == 20 && img.height == 40)
        // Orientation 6 = rotate 90° clockwise to display: the stored top band ends up on the right.
        let px = try pixels(img)
        #expect(isRed(px[17, 20]) && !isRed(px[2, 20]))
        let ed = try #require(ImageExporter.loadForEditor(from: url))
        #expect(ed.image.width == 20 && ed.pixelScale == 1)
    }

    @Test func loadForEditorReadsRetinaDPI() throws {
        let url = tempURL("retina.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, topRed(30, 30), [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let r = try #require(ImageExporter.loadForEditor(from: url))
        #expect(r.pixelScale == 2 && r.image.width == 30)
        let plain = tempURL("plain.png")
        try ImageExporter.write(topRed(30, 30), to: plain, format: .png)
        #expect(ImageExporter.loadForEditor(from: plain)?.pixelScale == 1)
    }
}

@Suite struct TolerantStyleDecodingTests {
    func json(_ s: AppSettings) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: s.encoded()) as? [String: Any])
    }

    func encode(_ obj: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: obj) }

    /// CORE_EDITOR-15: one style missing one key used to wipe every remembered tool style.
    @Test func missingKeyDropsNothing() throws {
        var s = AppSettings()
        var rect = ElementStyle.defaults(for: .rectangle); rect.stroke = .black
        var arrow = ElementStyle.defaults(for: .arrow); arrow.lineWidth = 7
        s.toolStyles = ["rectangle": rect, "arrow": arrow]
        var obj = try json(s)
        var styles = try #require(obj["toolStyles"] as? [String: Any])
        var a = try #require(styles["arrow"] as? [String: Any])
        a.removeValue(forKey: "magnification")
        a["highlightMode"] = "neon" // a case from a newer version
        styles["arrow"] = a
        styles["bogus"] = 42         // an entry that isn't a style at all
        obj["toolStyles"] = styles
        let back = AppSettings.decode(try encode(obj))
        #expect(Set(back.toolStyles.keys) == ["rectangle", "arrow"])
        #expect(back.toolStyles["rectangle"] == rect)
        #expect(back.toolStyles["arrow"]?.lineWidth == 7 && back.toolStyles["arrow"]?.magnification == 2)
        #expect(back.toolStyles["arrow"]?.highlightMode == .text)
    }

    @Test func missingKeyUsesThatToolsDefault() throws {
        var s = AppSettings()
        s.toolStyles = ["obfuscate": ElementStyle.defaults(for: .obfuscate)]
        var obj = try json(s)
        var styles = try #require(obj["toolStyles"] as? [String: Any])
        var o = try #require(styles["obfuscate"] as? [String: Any])
        o.removeValue(forKey: "pixelSize")
        styles["obfuscate"] = o
        obj["toolStyles"] = styles
        #expect(AppSettings.decode(try encode(obj)).toolStyles["obfuscate"]?.pixelSize == 4) // not the generic 8
    }

    @Test func unknownDestinationDropsOnlyItself() throws {
        var obj = try json(AppSettings())
        obj["destinations"] = ["clipboard", "upload", "file"]
        #expect(AppSettings.decode(try encode(obj)).destinations == [.clipboard, .file])
        obj["destinations"] = ["upload"]
        #expect(AppSettings.decode(try encode(obj)).destinations == [.editor])
    }

    @Test func styleRoundTrips() throws {
        var st = ElementStyle.defaults(for: .speechBubble)
        st.bold = true; st.highlightMode = .magnify; st.fontName = "Menlo"
        let back = try JSONDecoder().decode(ElementStyle.self, from: JSONEncoder().encode(st))
        #expect(back == st)
    }
}

@Suite struct LayeredRenderTests {
    /// CORE_EDITOR-12: drawing the top of the stack over a cached base must equal a full render,
    /// filters and counter numbers included.
    @Test func layeredEqualsFull() throws {
        let r = Renderer(pixelScale: 1)
        var s = DocState(image: halves(120, 80))
        s.elements = [
            Element(kind: .counter, frame: CGRect(x: 5, y: 5, width: 20, height: 20)),
            Element(kind: .rectangle, frame: CGRect(x: 30, y: 10, width: 40, height: 30)),
            { var e = Element(kind: .obfuscate, frame: CGRect(x: 40, y: 20, width: 50, height: 40)); e.style.obfuscateMode = .blur; return e }(),
            Element(kind: .counter, frame: CGRect(x: 90, y: 50, width: 20, height: 20)),
        ]
        let full = try pixels(r.flatten(s))
        for start in 0...s.elements.count {
            let base = try #require(r.flattenPrefix(s, count: start))
            let layered = try pixels(r.flatten(s, over: base, from: start))
            var diff = 0
            for y in 0..<80 { for x in 0..<120 where full[x, y].differs(from: layered[x, y], by: 1) { diff += 1 } }
            #expect(diff == 0, "start \(start): \(diff) px differ")
        }
    }
}

// MARK: Review round 3 (editor)

struct Round3EditorTests {
    func box(_ kind: ElementKind, _ text: String, _ frame: CGRect, s: CGFloat = 2) -> Element {
        var e = Element(kind: kind, frame: frame)
        e.text = text
        return Renderer.fittingText(e, pixelScale: s)
    }

    func fits(_ e: Element, _ s: CGFloat = 2) -> Bool {
        let inner = Renderer.textRect(for: e, pixelScale: s)
        return inner.height + 0.5 >= Renderer.textHeight(e.text, style: e.style, pixelScale: s, width: inner.width,
                                                         center: e.kind == .speechBubble)
    }

    @Test func pixelScaleFromDPI() {
        #expect(ImageExporter.pixelScale(dpi: 72) == 1)
        #expect(ImageExporter.pixelScale(dpi: 139.9) == 1)
        #expect(ImageExporter.pixelScale(dpi: 144) == 2)
        #expect(ImageExporter.pixelScale(dpi: 199.9) == 2)
        #expect(ImageExporter.pixelScale(dpi: 216) == 3)
        #expect(ImageExporter.pixelScale(dpi: 600) == 3)
    }

    /// CORE_EDITOR-R3-1: every event works from the drag-start element, so the growth goes away again.
    @Test func gripResizeIsReversible() {
        let start = box(.text, "A sentence that is long enough to need two lines", CGRect(x: 100, y: 100, width: 480, height: 40))
        let grip = Grip.right.position(in: start.frame)
        let narrow = Renderer.resizedFittingText(start, .grip(.right), to: CGPoint(x: 130, y: grip.y), pixelScale: 2)
        #expect(narrow.frame.height > start.frame.height * 2 && fits(narrow))
        let back = Renderer.resizedFittingText(start, .grip(.right), to: grip, pixelScale: 2)
        #expect(back.frame == start.frame)
    }

    /// CORE_EDITOR-R3-1: a top grip squash grows the box upwards, keeping its bottom edge.
    @Test func topGripGrowsUpwards() {
        let start = box(.text, "Hello", CGRect(x: 100, y: 100, width: 480, height: 86))
        let e = Renderer.resizedFittingText(start, .grip(.top), to: CGPoint(x: 340, y: start.frame.maxY - 4), pixelScale: 2)
        #expect(e.frame.maxY == start.frame.maxY && e.frame.height > 4 && fits(e))
        let side = Renderer.resizedFittingText(start, .grip(.bottom), to: CGPoint(x: 340, y: 104), pixelScale: 2)
        #expect(side.frame.minY == start.frame.minY && fits(side))
    }

    /// CORE_EDITOR-R3-2: pulling a bubble's bottom up past its text leaves the tip where it was.
    @Test func bubbleTipDoesNotDrift() {
        var start = box(.speechBubble, "one\ntwo\nthree", CGRect(x: 200, y: 100, width: 400, height: 160))
        start.points = [CGPoint(x: 300, y: start.frame.maxY + 100)]
        let e = Renderer.resizedFittingText(start, .grip(.bottom), to: CGPoint(x: 400, y: start.frame.maxY - 60), pixelScale: 2)
        #expect(e.points[0] == start.points[0] && fits(e))
        // Narrowing (the body grows down past its old bottom) still carries the tail along.
        let n = Renderer.resizedFittingText(start, .grip(.right), to: CGPoint(x: 260, y: 180), pixelScale: 2)
        #expect(n.frame.maxY > start.frame.maxY && n.points[0].y - n.frame.maxY == start.points[0].y - start.frame.maxY)
    }

    /// CORE_EDITOR-R3-3: a frame squashed under its own inset still grows enough for every line.
    @Test func squashedFrameFitsAllLines() {
        for kind in [ElementKind.text, .speechBubble] {
            var e = Element(kind: kind, frame: CGRect(x: 100, y: 100, width: 400, height: 1))
            e.text = "one\ntwo\nthree"
            e.frame = Renderer.frameFittingText(e, pixelScale: 2)
            #expect(fits(e), "\(kind)")
        }
    }
}

// MARK: Review round 4

struct Round4Tests {
    func fitted(_ kind: ElementKind, _ text: String, _ frame: CGRect) -> Element {
        var e = Element(kind: kind, frame: frame)
        e.text = text
        return Renderer.fittingText(e, pixelScale: 2)
    }

    func fits(_ e: Element) -> Bool {
        let inner = Renderer.textRect(for: e, pixelScale: 2)
        return inner.height + 0.5 >= Renderer.textHeight(e.text, style: e.style, pixelScale: 2, width: inner.width,
                                                         center: e.kind == .speechBubble)
    }

    /// CORE_EDITOR-R4-1: a top corner grip grows the box upwards only as far as the picture's top;
    /// the rest goes below. With room above, it still keeps the bottom edge (R3-1).
    @Test func topGripGrowthStopsAtThePictureTop() {
        let caption = "A caption sentence that is long enough to wrap when narrowed"
        let start = fitted(.text, caption, CGRect(x: 100, y: 10, width: 480, height: 40))
        let e = Renderer.resizedFittingText(start, .grip(.topRight), to: CGPoint(x: 300, y: 10), pixelScale: 2)
        #expect(e.frame.minY >= 0 && e.frame.height > start.frame.height && fits(e), "\(e.frame)")
        let roomy = fitted(.text, caption, CGRect(x: 100, y: 400, width: 480, height: 40))
        let up = Renderer.resizedFittingText(roomy, .grip(.topRight), to: CGPoint(x: 300, y: 400), pixelScale: 2)
        #expect(up.frame.maxY == roomy.frame.maxY && up.frame.minY < roomy.frame.minY && fits(up))
        // A box already partly above the picture isn't pulled down by the fit, nor pushed further up.
        let off = fitted(.text, caption, CGRect(x: 100, y: -20, width: 480, height: 40))
        let o = Renderer.resizedFittingText(off, .grip(.topLeft), to: CGPoint(x: 380, y: -20), pixelScale: 2)
        #expect(o.frame.minY == -20 && fits(o))
    }

    /// CORE_EDITOR-R4-1: a bubble whose tail points up keeps the tip outside the body when a top grip
    /// makes the body grow upwards.
    @Test func upTailMovesWithTheBody() {
        var start = fitted(.speechBubble, "Some words in a bubble that wrap", CGRect(x: 300, y: 300, width: 400, height: 100))
        start.points = [CGPoint(x: 350, y: 240)]
        let e = Renderer.resizedFittingText(start, .grip(.topRight), to: CGPoint(x: 430, y: 300), pixelScale: 2)
        #expect(e.frame.minY < start.frame.minY && fits(e))
        #expect(e.points[0].y < e.frame.minY && !e.frame.contains(e.points[0]), "\(e.frame) tip \(e.points[0])")
        #expect(start.frame.minY - start.points[0].y == e.frame.minY - e.points[0].y)
    }

    /// CORE_EDITOR-R4-3: long titles are cut to a byte length every file system takes, between
    /// Characters, and the file can really be created (with uniqueURL's " (n)" and extension).
    @Test func longTitlesStillMakeAFile() throws {
        let dir = tempURL("x").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = FilenameContext(date: Date(timeIntervalSince1970: 1_760_000_000), title: "",
                                  timeZone: TimeZone(identifier: "UTC")!)
        for unit in ["中", "😀", "🇯🇵", "a"] {
            var c = ctx
            c.title = String(repeating: unit, count: 300)
            let name = FilenamePattern.expand(FilenamePattern.defaultPattern, c)
            #expect(name.utf8.count <= FilenamePattern.maxComponentBytes, "\(unit): \(name.utf8.count) bytes")
            #expect(name.hasPrefix("2025-10-09 08.53.20 \(unit)") && name.hasSuffix(unit), "\(unit) cut inside a Character")
            // The first name is taken, so the file gets " (2)", as a second capture in the same second would.
            let first = FilenamePattern.uniqueURL(in: dir, relativeName: name, ext: "heic")
            try Data().write(to: first)
            let second = FilenamePattern.uniqueURL(in: dir, relativeName: name, ext: "heic")
            #expect(second.lastPathComponent.contains(" (2)"))
            try Data().write(to: second)
        }
        #expect(FilenamePattern.truncated("ab😀", maxBytes: 5) == "ab")
    }

    /// CAPTURE_APP-R4-1: a saved 2x capture records 144 dpi, so it reopens (and is inserted) as 2x.
    @Test func savedScaleRoundTrips() throws {
        for format in [ImageFormat.png, .jpeg, .tiff, .heic] {
            let url = tempURL("retina.\(format.fileExtension)")
            try ImageExporter.write(topRed(40, 40), to: url, format: format, pixelScale: 2)
            #expect(ImageExporter.loadForEditor(from: url)?.pixelScale == 2, "\(format)")
            let plain = tempURL("plain.\(format.fileExtension)")
            try ImageExporter.write(topRed(40, 40), to: plain, format: format)
            #expect(ImageExporter.loadForEditor(from: plain)?.pixelScale == 1, "\(format)")
        }
        let png = try ImageExporter.data(for: topRed(40, 40), format: .png, pixelScale: 2)
        let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        #expect((props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue == 144)
    }
}

// MARK: Review round 5

struct Round5Tests {
    /// CORE_EDITOR-R5-1 / CAPTURE_APP-R5-1: GIF has no resolution field, so ImageIO drops the
    /// 144 dpi and a 2x GIF reopens at 1x — the README says so. BMP does store it (as pixels per
    /// meter, 143.99 dpi, still past the 140 threshold). This test pins both, so if an ImageIO
    /// update ever changes either, it fails and the README line gets revisited.
    @Test func gifCannotStoreScaleButBMPCan() throws {
        let gif = tempURL("r5-scale.gif")
        try ImageExporter.write(topRed(40, 40), to: gif, format: .gif, pixelScale: 2)
        #expect(ImageExporter.loadForEditor(from: gif)?.pixelScale == 1)
        let src = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyDPIWidth] == nil, "GIF grew a resolution field: revisit the README's GIF caveat")
        let bmp = tempURL("r5-scale.bmp")
        try ImageExporter.write(topRed(40, 40), to: bmp, format: .bmp, pixelScale: 2)
        #expect(ImageExporter.loadForEditor(from: bmp)?.pixelScale == 2)
    }

    /// CORE_EDITOR-R5-2: the write side stores 72 dpi per point for ANY scale, so the read side
    /// must give 3x back for a 3x file instead of quantizing everything dense to 2x.
    @Test func threeXScaleRoundTrips() throws {
        let url = tempURL("r5-3x.png")
        try ImageExporter.write(topRed(40, 40), to: url, format: .png, pixelScale: 3)
        #expect(ImageExporter.loadForEditor(from: url)?.pixelScale == 3)
    }
}
