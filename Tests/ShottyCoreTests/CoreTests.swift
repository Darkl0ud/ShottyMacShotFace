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
