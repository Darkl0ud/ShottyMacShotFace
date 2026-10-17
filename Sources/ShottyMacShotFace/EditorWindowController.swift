import AppKit
import ShottyCore
import UniformTypeIdentifiers

/// Annotations copied inside the editor. The pasteboard change count tells us whether the
/// system clipboard still holds "our" copy or something newer (like an image from another app).
@MainActor
enum ElementClipboard {
    static var elements: [Element] = []
    static var changeCount = -1
    static let type = NSPasteboard.PasteboardType("com.darkl0ud.shottymacshotface.elements")
}

@MainActor
protocol EditorHost: AnyObject {
    func editorDidClose(_ editor: EditorWindowController)
}

/// One editor window per capture, like Greenshot's image editor.
final class EditorWindowController: NSWindowController, NSWindowDelegate, CanvasDelegate, NSMenuItemValidation {
    let doc: EditorDocument
    let renderer: Renderer
    let canvas: CanvasView
    weak var host: EditorHost?

    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var toolButtons: [(Tool, NSButton)] = []
    private var paletteHeight: CGFloat = 0

    // Property controls
    private let lineWell = NSColorWell(style: .minimal)
    private let fillWell = NSColorWell(style: .minimal)
    private let thicknessPopup = NSPopUpButton()
    private let shadowCheck = NSButton(checkboxWithTitle: "Shadow", target: nil, action: nil)
    private let arrowPopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let fontSizePopup = NSPopUpButton()
    private let boldButton = NSButton()
    private let italicButton = NSButton()
    private let highlightPopup = NSPopUpButton()
    private let obfuscatePopup = NSPopUpButton()
    private let strengthPopup = NSPopUpButton()
    private let magnifyPopup = NSPopUpButton()
    private let zoomPopup = NSPopUpButton()
    private var groups: [String: NSView] = [:]
    private var isUpdatingControls = false

    static let thicknesses: [CGFloat] = [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20]
    static let fontSizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96]
    static let strengths: [CGFloat] = [2, 3, 4, 6, 8, 10, 12, 16, 20, 30]
    static let magnifications: [CGFloat] = [1.5, 2, 3, 4, 6]
    /// Zoom presets relative to the capture's real size (100% = one image pixel per screen pixel).
    static let zoomLevels: [CGFloat] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    init(document: EditorDocument) {
        doc = document
        renderer = Renderer(pixelScale: document.pixelScale)
        renderer.counterStart = SettingsStore.shared.settings.counterStart
        doc.counterStart = renderer.counterStart
        canvas = CanvasView(document: document, renderer: renderer)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        canvas.delegate = self
        doc.onChange = { [weak self] in self?.documentChanged() }
        buildUI()
        // Hide the property controls the current tool doesn't use BEFORE sizing: while they were all
        // showing, Auto Layout widened the window to fit every one of them (1742 pt for a 1156 pt
        // picture), and a window never shrinks back by itself when they're hidden afterwards.
        updatePropertyBar()
        sizeWindowToFit()
        canvas.zoom = actualSizeZoom
        fitIfTooBig()
        updateToolButtons()
        updatePropertyBar()
        updateTitle()
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let actions = NSStackView(views: [
            iconButton("square.and.arrow.down", "Save (⌘S)", #selector(saveDocument(_:))),
            iconButton("square.and.arrow.down.on.square", "Save As… (⇧⌘S)", #selector(saveDocumentAs(_:))),
            iconButton("doc.on.clipboard", "Copy Image to Clipboard (⇧⌘C)", #selector(copyImage(_:))),
            separator(vertical: true),
            iconButton("arrow.uturn.backward", "Undo (⌘Z)", #selector(editorUndo(_:))),
            iconButton("arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(editorRedo(_:))),
            separator(vertical: true),
            effectsButton(),
            separator(vertical: true),
        ])
        actions.spacing = 4

        buildPropertyControls()
        let props = NSStackView(views: ["line", "fill", "thickness", "shadow", "arrow", "font", "highlight",
                                        "obfuscate", "magnify", "crop"].compactMap { groups[$0] })
        props.spacing = 12
        props.setHuggingPriority(.defaultLow, for: .horizontal)
        // A long property row (e.g. the text tool's font controls) may get clipped in a narrow window,
        // but it must never force the window wider.
        props.setClippingResistancePriority(.defaultLow, for: .horizontal)

        zoomPopup.target = self
        zoomPopup.action = #selector(zoomChosen(_:))
        zoomPopup.controlSize = .small
        for z in Self.zoomLevels { zoomPopup.addItem(withTitle: "\(Int((z * 100).rounded()))%") }
        zoomPopup.addItem(withTitle: "Fit")
        zoomPopup.toolTip = "Zoom (⌘+ / ⌘- / ⌘0 actual size / ⌘9 fit)"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let topBar = NSStackView(views: [actions, props, spacer, zoomPopup])
        topBar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        topBar.spacing = 8

        let palette = NSStackView()
        palette.orientation = .vertical
        palette.spacing = 4
        palette.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        let tools: [(Tool, String, String)] = [
            (.select, "cursorarrow", "Select and move (V / Esc)"),
            (.draw(.rectangle), "rectangle", "Rectangle (R)"),
            (.draw(.ellipse), "circle", "Ellipse (E)"),
            (.draw(.line), "line.diagonal", "Line (L) — hold ⇧ for 45°"),
            (.draw(.arrow), "arrow.up.right", "Arrow (A) — hold ⇧ for 45°"),
            (.draw(.freehand), "scribble", "Freehand (F)"),
            (.draw(.text), "textformat", "Text box (T)"),
            (.draw(.speechBubble), "bubble.left", "Speech bubble (S)"),
            (.draw(.counter), "1.circle", "Step counter (I)"),
            (.draw(.highlight), "highlighter", "Highlight (H)"),
            (.draw(.obfuscate), "eye.slash", "Obfuscate: pixelate / blur (O)"),
            (.crop, "crop", "Crop (C) — drag, then Return"),
        ]
        for (tool, symbol, tip) in tools {
            let b = NSButton(image: symbolImage(symbol, tip), target: self, action: #selector(toolClicked(_:)))
            // Flat buttons that draw their own highlight: system bezels can end up white-on-white
            // for template icons depending on appearance, and this looks the same in light and dark.
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: 34).isActive = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            palette.addArrangedSubview(b)
            toolButtons.append((tool, b))
        }

        paletteHeight = palette.fittingSize.height

        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.32, alpha: 1)
        scrollView.allowsMagnification = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let topSep = separator(vertical: false), sideSep = separator(vertical: true), bottomSep = separator(vertical: false)
        for v in [topBar, topSep, palette, sideSep, scrollView, bottomSep, statusLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 40),
            topSep.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topSep.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topSep.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            palette.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            palette.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            palette.widthAnchor.constraint(equalToConstant: 46),
            // The window can't get so short that the bottom tools are cut off.
            palette.bottomAnchor.constraint(lessThanOrEqualTo: bottomSep.topAnchor),
            sideSep.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            sideSep.bottomAnchor.constraint(equalTo: bottomSep.topAnchor),
            sideSep.leadingAnchor.constraint(equalTo: palette.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: sideSep.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomSep.topAnchor),
            bottomSep.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomSep.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomSep.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -3),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
    }

    private func symbolImage(_ name: String, _ desc: String) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: desc)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: desc)!
        return img.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? img
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: symbolImage(symbol, tip), target: self, action: action)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    private func separator(vertical: Bool) -> NSBox {
        // NSBox picks its orientation from its frame's shape, and a zero frame reads as a horizontal
        // 1 pt line that strongly resists stretching, which shrank the whole window to ~90 pt tall.
        // So give it the right shape and let it stretch along its length.
        let b = NSBox(frame: vertical ? NSRect(x: 0, y: 0, width: 1, height: 100) : NSRect(x: 0, y: 0, width: 100, height: 1))
        b.boxType = .separator
        if vertical {
            b.widthAnchor.constraint(equalToConstant: 1).isActive = true
            b.setContentHuggingPriority(.init(1), for: .vertical)
            b.setContentCompressionResistancePriority(.init(1), for: .vertical)
        } else {
            b.heightAnchor.constraint(equalToConstant: 1).isActive = true
            b.setContentHuggingPriority(.init(1), for: .horizontal)
            b.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        }
        return b
    }

    private func effectsButton() -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: true)
        p.bezelStyle = .regularSquare
        p.isBordered = false
        p.toolTip = "Effects (apply to the whole picture)"
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = symbolImage("wand.and.stars", "Effects")
        p.menu?.addItem(head)
        for item in Self.effectsMenuItems() { p.menu?.addItem(item) }
        return p
    }

    /// Shared by the toolbar button and the Image menu.
    static func effectsMenuItems() -> [NSMenuItem] {
        func item(_ t: String, _ a: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        return [
            item("Drop Shadow", #selector(effectShadow(_:))),
            item("Torn Edges (all sides)", #selector(effectTornAll(_:))),
            item("Torn Edge (bottom only)", #selector(effectTornBottom(_:))),
            item("Border (current line colour and thickness)", #selector(effectBorder(_:))),
            .separator(),
            item("Grayscale", #selector(effectGrayscale(_:))),
            item("Invert Colours", #selector(effectInvert(_:))),
            .separator(),
            item("Rotate Clockwise", #selector(effectRotateCW(_:)), "r", [.command]),
            item("Rotate Counter-clockwise", #selector(effectRotateCCW(_:)), "r", [.command, .shift]),
            item("Resize…", #selector(effectResize(_:))),
            .separator(),
            item("Auto Crop", #selector(autoCrop(_:))),
        ]
    }

    private func labeled(_ title: String, _ views: [NSView]) -> NSStackView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        let s = NSStackView(views: [l] + views)
        s.spacing = 4
        return s
    }

    private func setupPopup(_ p: NSPopUpButton, _ titles: [String], _ action: Selector) {
        p.removeAllItems()
        p.addItems(withTitles: titles)
        p.controlSize = .small
        p.font = .systemFont(ofSize: 11)
        p.target = self
        p.action = action
    }

    private func buildPropertyControls() {
        NSColorPanel.shared.showsAlpha = true
        for w in [lineWell, fillWell] {
            w.target = self
            w.widthAnchor.constraint(equalToConstant: 38).isActive = true
            w.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        lineWell.action = #selector(lineColorChanged(_:))
        fillWell.action = #selector(fillColorChanged(_:))
        lineWell.toolTip = "Line / text colour"
        fillWell.toolTip = "Fill / background colour (set opacity to 0 in the colour panel for none)"
        let noFill = NSButton(title: "None", target: self, action: #selector(clearFill(_:)))
        noFill.controlSize = .small
        noFill.bezelStyle = .push
        noFill.font = .systemFont(ofSize: 10)
        noFill.toolTip = "No fill"
        groups["line"] = labeled("Line", [lineWell])
        groups["fill"] = labeled("Fill", [fillWell, noFill])

        setupPopup(thicknessPopup, Self.thicknesses.map { "\(Int($0)) pt" }, #selector(thicknessChanged(_:)))
        groups["thickness"] = labeled("Width", [thicknessPopup])

        shadowCheck.target = self
        shadowCheck.action = #selector(shadowChanged(_:))
        shadowCheck.controlSize = .small
        shadowCheck.font = .systemFont(ofSize: 11)
        groups["shadow"] = shadowCheck

        setupPopup(arrowPopup, ["No heads", "Start", "End", "Both ends"], #selector(arrowChanged(_:)))
        groups["arrow"] = labeled("Heads", [arrowPopup])

        setupPopup(fontPopup, NSFontManager.shared.availableFontFamilies, #selector(fontChanged(_:)))
        setupPopup(fontSizePopup, Self.fontSizes.map { "\(Int($0))" }, #selector(fontSizeChanged(_:)))
        for (b, title, sel) in [(boldButton, "B", #selector(boldChanged(_:))), (italicButton, "I", #selector(italicChanged(_:)))] {
            b.title = title
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .push
            b.controlSize = .small
            b.font = title == "B" ? .boldSystemFont(ofSize: 11)
                : NSFontManager.shared.convert(.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)
            b.target = self
            b.action = sel
        }
        fontPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        groups["font"] = labeled("Font", [fontPopup, fontSizePopup, boldButton, italicButton])

        setupPopup(highlightPopup, ["Text marker", "Area (dim the rest)", "Grayscale the rest", "Magnify"],
                   #selector(highlightModeChanged(_:)))
        groups["highlight"] = labeled("Mode", [highlightPopup])

        setupPopup(obfuscatePopup, ["Pixelate", "Blur"], #selector(obfuscateModeChanged(_:)))
        setupPopup(strengthPopup, Self.strengths.map { "\(Int($0))" }, #selector(strengthChanged(_:)))
        groups["obfuscate"] = labeled("Mode", [obfuscatePopup, strengthPopup])

        setupPopup(magnifyPopup, Self.magnifications.map { "\($0.formatted())×" }, #selector(magnificationChanged(_:)))
        groups["magnify"] = labeled("Zoom", [magnifyPopup])

        let apply = NSButton(title: "Crop", target: self, action: #selector(applyCrop(_:)))
        apply.bezelStyle = .push
        apply.keyEquivalent = "\r"
        apply.controlSize = .small
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCrop(_:)))
        cancel.bezelStyle = .push
        cancel.controlSize = .small
        groups["crop"] = labeled("Drag over the picture, then", [apply, cancel])
    }

    // MARK: Window sizing / zoom

    /// For the self-test: tool button frames in content-view coordinates (y-down from the top).
    func toolButtonFrames() -> [CGRect] {
        guard let content = window?.contentView else { return [] }
        return toolButtons.map { b in
            let r = b.1.convert(b.1.bounds, to: content)
            return CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
        }
    }

    /// For the self-test: top of the status bar, y-down from the top of the content view.
    func statusBarTop() -> CGFloat? {
        guard let content = window?.contentView else { return nil }
        let r = scrollView.convert(scrollView.bounds, to: content)
        return content.bounds.height - r.minY
    }

    /// Zoom at which one image pixel is one screen pixel.
    private var actualSizeZoom: CGFloat { 1 / (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

    private func sizeWindowToFit() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        let img = doc.state.size
        let scale = screen.backingScaleFactor
        let chrome = NSSize(width: 46 + 2 + 20, height: 40 + 1 + 24 + 20)
        // Tall enough for the whole tool palette: top bar + palette + status bar.
        let minHeight = 40 + 1 + paletteHeight + 1 + 28
        window.contentMinSize = NSSize(width: 640, height: minHeight)
        let w = min(max(img.width / scale + chrome.width, 640), vis.width * 0.9)
        let h = min(max(img.height / scale + chrome.height, minHeight), vis.height * 0.9)
        window.setContentSize(NSSize(width: w, height: h))
        window.center()
    }

    private func fitIfTooBig() {
        window?.layoutIfNeeded()
        let avail = scrollView.contentSize
        let img = doc.state.size
        if img.width * canvas.zoom > avail.width || img.height * canvas.zoom > avail.height { zoomToFit() }
    }

    private func zoomToFit() {
        window?.layoutIfNeeded()
        let avail = scrollView.contentSize
        let img = doc.state.size
        guard img.width > 0, img.height > 0 else { return }
        canvas.zoom = max(0.02, min((avail.width - 16) / img.width, (avail.height - 16) / img.height, actualSizeZoom * 8))
    }

    private func setRelativeZoom(_ level: CGFloat) { canvas.zoom = level * actualSizeZoom }
    private var relativeZoom: CGFloat { canvas.zoom / actualSizeZoom }

    @objc func zoomChosen(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        if i < Self.zoomLevels.count { setRelativeZoom(Self.zoomLevels[i]) } else { zoomToFit() }
    }

    @objc func zoomIn(_ sender: Any?) {
        setRelativeZoom(Self.zoomLevels.first { $0 > relativeZoom + 0.001 } ?? Self.zoomLevels.last!)
    }

    @objc func zoomOut(_ sender: Any?) {
        setRelativeZoom(Self.zoomLevels.last { $0 < relativeZoom - 0.001 } ?? Self.zoomLevels.first!)
    }

    @objc func zoomActual(_ sender: Any?) { setRelativeZoom(1) }
    @objc func zoomFit(_ sender: Any?) { zoomToFit() }

    // MARK: State → UI

    private func documentChanged() {
        canvas.documentChanged()
        updateTitle()
        updateStatus()
        updatePropertyBar()
    }

    private func updateTitle() {
        let base = doc.fileURL?.lastPathComponent ?? (doc.title.isEmpty ? "Capture" : doc.title)
        window?.title = base
        window?.subtitle = "\(doc.state.image.width) × \(doc.state.image.height) px"
        window?.isDocumentEdited = doc.isDirty
        window?.representedURL = doc.fileURL
    }

    private func updateStatus() {
        let n = doc.state.elements.count
        var parts = ["\(doc.state.image.width) × \(doc.state.image.height) px",
                     "\(Int((relativeZoom * 100).rounded()))%",
                     "\(n) object\(n == 1 ? "" : "s")"]
        if !canvas.selection.isEmpty { parts.append("\(canvas.selection.count) selected") }
        if let c = canvas.cropRect { parts.append("crop \(Int(c.width)) × \(Int(c.height))") }
        switch canvas.tool {
        case .select: parts.append("Click to select · drag to move · Delete removes · double-click text to edit")
        case .crop: parts.append("Drag the area to keep · Return applies · Esc cancels")
        case .draw(.counter): parts.append("Click to place the next number")
        case .draw(let k) where k.hasText: parts.append("Drag a box or click, then type · Esc finishes")
        case .draw: parts.append("Drag to draw · ⇧ constrains · Esc returns to Select")
        }
        statusLabel.stringValue = parts.joined(separator: "   ·   ")
        if let i = Self.zoomLevels.firstIndex(where: { abs($0 - relativeZoom) < 0.005 }) {
            zoomPopup.selectItem(at: i)
        } else {
            zoomPopup.selectItem(withTitle: "Fit")
            zoomPopup.setTitle("\(Int((relativeZoom * 100).rounded()))%")
        }
    }

    private func updateToolButtons() {
        for (t, b) in toolButtons {
            let on = t == canvas.tool
            // White on solid accent: an accent-tinted icon on an accent background disappears.
            b.contentTintColor = on ? .white : .labelColor
            b.layer?.backgroundColor = on ? NSColor.controlAccentColor.cgColor : nil
        }
    }

    /// The kind whose properties the bar is showing: the active drawing tool, else the selection.
    private var propertyKind: ElementKind? {
        if let k = canvas.tool.kind { return k }
        if canvas.tool == .select { return canvas.selectedElements.last?.kind }
        return nil
    }

    private var shownStyle: ElementStyle? {
        if let k = canvas.tool.kind { return style(for: k) }
        return canvas.selectedElements.last?.style
    }

    private func updatePropertyBar() {
        let kind = propertyKind
        var visible: Set<String> = []
        if canvas.tool == .crop { visible = ["crop"] }
        if let kind {
            switch kind {
            case .rectangle, .ellipse: visible = ["line", "fill", "thickness", "shadow"]
            case .line, .freehand: visible = ["line", "thickness", "shadow"]
            case .arrow: visible = ["line", "thickness", "shadow", "arrow"]
            case .text: visible = ["line", "fill", "thickness", "font", "shadow"]
            case .speechBubble: visible = ["line", "fill", "thickness", "font", "shadow"]
            case .counter: visible = ["line", "fill", "font", "shadow"]
            case .highlight:
                visible = ["highlight"]
                let mode = shownStyle?.highlightMode ?? .text
                if mode == .text { visible.insert("fill") }
                if mode == .magnify { visible.insert("magnify") }
            case .obfuscate: visible = ["obfuscate"]
            case .image: visible = ["line", "thickness", "shadow"]
            }
        }
        for (name, v) in groups { v.isHidden = !visible.contains(name) }

        guard let st = shownStyle else { return }
        isUpdatingControls = true
        defer { isUpdatingControls = false }
        lineWell.color = NSColor(cgColor: st.stroke.cgColor) ?? .red
        fillWell.color = NSColor(cgColor: st.fill.cgColor) ?? .clear
        thicknessPopup.selectItem(at: Self.nearestIndex(Self.thicknesses, st.lineWidth))
        shadowCheck.state = st.shadow ? .on : .off
        arrowPopup.selectItem(at: ArrowHeads.allCases.firstIndex(of: st.arrowHeads) ?? 2)
        if fontPopup.itemTitles.contains(st.fontName) { fontPopup.selectItem(withTitle: st.fontName) }
        else { fontPopup.setTitle(st.fontName) }
        fontSizePopup.selectItem(at: Self.nearestIndex(Self.fontSizes, st.fontSize))
        boldButton.state = st.bold ? .on : .off
        italicButton.state = st.italic ? .on : .off
        highlightPopup.selectItem(at: HighlightMode.allCases.firstIndex(of: st.highlightMode) ?? 0)
        obfuscatePopup.selectItem(at: ObfuscateMode.allCases.firstIndex(of: st.obfuscateMode) ?? 0)
        let strength = st.obfuscateMode == .pixelate ? st.pixelSize : st.blurRadius
        strengthPopup.selectItem(at: Self.nearestIndex(Self.strengths, strength))
        strengthPopup.toolTip = st.obfuscateMode == .pixelate ? "Block size (pt)" : "Blur radius (pt)"
        magnifyPopup.selectItem(at: Self.nearestIndex(Self.magnifications, st.magnification))
    }

    static func nearestIndex(_ values: [CGFloat], _ v: CGFloat) -> Int {
        values.indices.min { abs(values[$0] - v) < abs(values[$1] - v) } ?? 0
    }

    // MARK: CanvasDelegate

    func canvasSelectionChanged() { updatePropertyBar(); updateStatus() }
    func canvasToolChanged() { updateToolButtons(); updatePropertyBar(); updateStatus() }
    func canvasCropChanged() { updateStatus() }
    func canvasZoomChanged() { updateStatus() }
    func canvasSmartZoom() { if abs(relativeZoom - 1) < 0.01 { zoomToFit() } else { setRelativeZoom(1) } }

    func style(for kind: ElementKind) -> ElementStyle { SettingsStore.shared.settings.style(for: kind) }

    // MARK: Property changes

    /// A property edit updates the remembered style of the current tool (or of the selected
    /// elements' kinds) and the selected elements themselves.
    private func changeStyle(_ change: (inout ElementStyle) -> Void) {
        guard !isUpdatingControls else { return }
        var kinds: Set<ElementKind> = []
        if let k = canvas.tool.kind { kinds.insert(k) }
        for e in canvas.selectedElements { kinds.insert(e.kind) }
        for k in kinds {
            var s = style(for: k)
            change(&s)
            SettingsStore.shared.settings.toolStyles[k.rawValue] = s
        }
        canvas.applyStyleToSelection(change)
        updatePropertyBar()
    }

    private static func rgba(_ c: NSColor) -> RGBA {
        let s = c.usingColorSpace(.sRGB) ?? .black
        return RGBA(Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent), Double(s.alphaComponent))
    }

    @objc func lineColorChanged(_ sender: NSColorWell) { let c = Self.rgba(sender.color); changeStyle { $0.stroke = c } }
    @objc func fillColorChanged(_ sender: NSColorWell) { let c = Self.rgba(sender.color); changeStyle { $0.fill = c } }
    @objc func clearFill(_ sender: Any?) { changeStyle { $0.fill = .clear } }
    @objc func thicknessChanged(_ sender: NSPopUpButton) {
        let v = Self.thicknesses[sender.indexOfSelectedItem]; changeStyle { $0.lineWidth = v }
    }
    @objc func shadowChanged(_ sender: NSButton) { let on = sender.state == .on; changeStyle { $0.shadow = on } }
    @objc func arrowChanged(_ sender: NSPopUpButton) {
        let h = ArrowHeads.allCases[sender.indexOfSelectedItem]; changeStyle { $0.arrowHeads = h }
    }
    @objc func fontChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem else { return }
        changeStyle { $0.fontName = name }
    }
    @objc func fontSizeChanged(_ sender: NSPopUpButton) {
        let v = Self.fontSizes[sender.indexOfSelectedItem]; changeStyle { $0.fontSize = v }
    }
    @objc func boldChanged(_ sender: NSButton) { let on = sender.state == .on; changeStyle { $0.bold = on } }
    @objc func italicChanged(_ sender: NSButton) { let on = sender.state == .on; changeStyle { $0.italic = on } }
    @objc func highlightModeChanged(_ sender: NSPopUpButton) {
        let m = HighlightMode.allCases[sender.indexOfSelectedItem]; changeStyle { $0.highlightMode = m }
    }
    @objc func obfuscateModeChanged(_ sender: NSPopUpButton) {
        let m = ObfuscateMode.allCases[sender.indexOfSelectedItem]; changeStyle { $0.obfuscateMode = m }
    }
    @objc func strengthChanged(_ sender: NSPopUpButton) {
        let v = Self.strengths[sender.indexOfSelectedItem]
        changeStyle { if $0.obfuscateMode == .pixelate { $0.pixelSize = v } else { $0.blurRadius = v } }
    }
    @objc func magnificationChanged(_ sender: NSPopUpButton) {
        let v = Self.magnifications[sender.indexOfSelectedItem]; changeStyle { $0.magnification = v }
    }

    @objc func toolClicked(_ sender: NSButton) {
        if let t = toolButtons.first(where: { $0.1 === sender })?.0 { canvas.tool = t }
        updateToolButtons()
        window?.makeFirstResponder(canvas)
    }

    @objc func applyCrop(_ sender: Any?) { canvas.applyCrop() }
    @objc func cancelCrop(_ sender: Any?) { canvas.cancelCrop() }

    // MARK: Output

    private func flattened() -> CGImage? {
        canvas.endTextEdit()
        return renderer.flatten(doc.state)
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let img = flattened() else { return }
        do {
            if let url = doc.fileURL {
                try Output.write(img, to: url)
            } else {
                doc.fileURL = try Output.saveWithPattern(img, title: doc.title, date: doc.captureDate)
            }
            doc.markSaved()
            updateTitle()
        } catch {
            Output.showError("Couldn't save the image", error)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let img = flattened() else { return }
        Output.saveAs(img, title: doc.title, date: doc.captureDate, window: window) { [weak self] url in
            guard let self, let url else { return }
            self.doc.fileURL = url
            self.doc.markSaved()
            self.updateTitle()
        }
    }

    @objc func copyImage(_ sender: Any?) {
        guard let img = flattened() else { return }
        Output.copyToClipboard(img, pixelScale: doc.pixelScale)
        flashStatus("Copied the image to the clipboard")
    }

    private func flashStatus(_ text: String) {
        statusLabel.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.updateStatus() }
    }

    // MARK: Edit menu

    @objc func editorUndo(_ sender: Any?) {
        if let tv = canvas.activeTextView { tv.undoManager?.undo(); return }
        doc.undo()
    }

    @objc func editorRedo(_ sender: Any?) {
        if let tv = canvas.activeTextView { tv.undoManager?.redo(); return }
        doc.redo()
    }

    /// ⌘C copies the selected annotations if there are any, otherwise the whole picture.
    @objc func copy(_ sender: Any?) {
        let sel = canvas.selectedElements
        guard !sel.isEmpty else { copyImage(sender); return }
        ElementClipboard.elements = sel
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(Data(), forType: ElementClipboard.type)
        // Also put a picture of the full capture there, so pasting in other apps still does something.
        if let img = renderer.flatten(doc.state), let png = try? ImageExporter.data(for: img, format: .png) {
            pb.setData(png, forType: .png)
        }
        ElementClipboard.changeCount = pb.changeCount
    }

    @objc func cut(_ sender: Any?) {
        guard !canvas.selection.isEmpty else { return }
        copy(sender)
        canvas.deleteSelection()
    }

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pb.changeCount == ElementClipboard.changeCount, !ElementClipboard.elements.isEmpty {
            let offset = 10 * doc.pixelScale
            let copies = ElementClipboard.elements.map { e -> Element in
                var c = e
                c.id = UUID()
                c.move(by: CGPoint(x: offset, y: offset))
                return c
            }
            ElementClipboard.elements = copies // pasting again cascades instead of stacking
            doc.mutate { $0.elements.append(contentsOf: copies) }
            canvas.tool = .select
            canvas.setSelection(Set(copies.map(\.id)))
        } else if let img = Output.imageFromClipboard() {
            insertImage(img)
        } else {
            NSSound.beep()
        }
    }

    @objc func delete(_ sender: Any?) { canvas.deleteSelection() }
    @objc override func selectAll(_ sender: Any?) { canvas.selectAll() }
    @objc func duplicateSelection(_ sender: Any?) { canvas.duplicateSelection() }
    @objc func bringToFront(_ sender: Any?) { canvas.reorder(.front) }
    @objc func bringForward(_ sender: Any?) { canvas.reorder(.forward) }
    @objc func sendBackward(_ sender: Any?) { canvas.reorder(.backward) }
    @objc func sendToBack(_ sender: Any?) { canvas.reorder(.back) }

    @objc func insertImageFromFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let img = ImageExporter.load(from: url) else { return }
            self?.insertImage(img)
        }
    }

    /// Drops an image in as a movable, resizable object, scaled down to fit if needed.
    func insertImage(_ img: CGImage) {
        let canvasSize = doc.state.size
        var size = CGSize(width: img.width, height: img.height)
        let fit = min(1, canvasSize.width * 0.8 / size.width, canvasSize.height * 0.8 / size.height)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        var e = Element(kind: .image, frame: CGRect(x: (canvasSize.width - size.width) / 2,
                                                    y: (canvasSize.height - size.height) / 2,
                                                    width: size.width, height: size.height))
        e.image = img
        doc.add(e)
        canvas.tool = .select
        canvas.setSelection([e.id])
    }

    // MARK: Effects

    /// Whole-picture effects bake the annotations into the pixels first, so the result looks
    /// exactly like what you saw (undo brings the editable annotations back).
    private func applyEffect(_ f: (CGImage) -> CGImage?) {
        guard let flat = flattened(), let out = f(flat) else { NSSound.beep(); return }
        canvas.setSelection([])
        doc.replaceImage(out)
    }

    @objc func effectShadow(_ sender: Any?) { applyEffect { Effects.dropShadow($0, pixelScale: doc.pixelScale) } }
    @objc func effectTornAll(_ sender: Any?) { applyEffect { Effects.tornEdges($0, pixelScale: doc.pixelScale) } }
    @objc func effectTornBottom(_ sender: Any?) {
        applyEffect { Effects.tornEdges($0, pixelScale: doc.pixelScale, sides: .bottom) }
    }
    @objc func effectBorder(_ sender: Any?) {
        let st = style(for: .rectangle)
        let w = max(1, Int((st.lineWidth * doc.pixelScale).rounded()))
        applyEffect { Effects.border($0, width: w, color: st.stroke) }
    }
    @objc func effectGrayscale(_ sender: Any?) { applyEffect { Effects.grayscale($0) } }
    @objc func effectInvert(_ sender: Any?) { applyEffect { Effects.invert($0) } }
    @objc func effectRotateCW(_ sender: Any?) { applyEffect { Effects.rotate($0, clockwise: true) } }
    @objc func effectRotateCCW(_ sender: Any?) { applyEffect { Effects.rotate($0, clockwise: false) } }

    @objc func autoCrop(_ sender: Any?) {
        guard let flat = flattened(), let r = Effects.autoCropRect(flat) else {
            flashStatus("Nothing to auto-crop: the edges aren't a plain colour")
            return
        }
        doc.crop(to: r)
    }

    @objc func effectResize(_ sender: Any?) {
        let w0 = doc.state.image.width, h0 = doc.state.image.height
        let alert = NSAlert()
        alert.messageText = "Resize picture"
        alert.informativeText = "Currently \(w0) × \(h0) pixels."
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        let wField = NSTextField(string: "\(w0)"), hField = NSTextField(string: "\(h0)")
        let lock = NSButton(checkboxWithTitle: "Keep proportions", target: nil, action: nil)
        lock.state = .on
        let linker = AspectLinker(w: wField, h: hField, lock: lock, ratio: CGFloat(w0) / CGFloat(max(1, h0)))
        wField.delegate = linker
        hField.delegate = linker
        for f in [wField, hField] { f.widthAnchor.constraint(equalToConstant: 80).isActive = true }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Width:"), wField],
                                      [NSTextField(labelWithString: "Height:"), hField], [NSView(), lock]])
        grid.frame = NSRect(x: 0, y: 0, width: 240, height: 80)
        alert.accessoryView = grid
        alert.beginSheetModal(for: window!) { [weak self] resp in
            _ = linker
            guard resp == .alertFirstButtonReturn, let self else { return }
            let w = Int(wField.stringValue) ?? w0, h = Int(hField.stringValue) ?? h0
            guard w > 0, h > 0, w <= 30000, h <= 30000, w != w0 || h != h0 else { return }
            self.applyEffect { Effects.resize($0, width: w, height: h) }
        }
    }

    // MARK: Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(editorUndo(_:)): return canvas.activeTextView != nil || doc.canUndo
        case #selector(editorRedo(_:)): return canvas.activeTextView != nil || doc.canRedo
        case #selector(cut(_:)), #selector(delete(_:)), #selector(duplicateSelection(_:)),
             #selector(bringToFront(_:)), #selector(bringForward(_:)), #selector(sendBackward(_:)),
             #selector(sendToBack(_:)):
            return !canvas.selection.isEmpty
        case #selector(applyCrop(_:)): return canvas.cropRect != nil
        default: return true
        }
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.endTextEdit()
        guard doc.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to this capture?"
        alert.informativeText = "If you don't save, the capture and your annotations are lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: sender) { [weak self] resp in
            guard let self else { return }
            switch resp {
            case .alertFirstButtonReturn:
                self.saveDocument(nil)
                if !self.doc.isDirty { sender.close() }
            case .alertThirdButtonReturn:
                self.doc.markSaved()
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        host?.editorDidClose(self)
    }
}

/// Keeps width and height in proportion in the resize dialog.
@MainActor
final class AspectLinker: NSObject, NSTextFieldDelegate {
    let w: NSTextField, h: NSTextField, lock: NSButton, ratio: CGFloat

    init(w: NSTextField, h: NSTextField, lock: NSButton, ratio: CGFloat) {
        self.w = w; self.h = h; self.lock = lock; self.ratio = ratio
    }

    func controlTextDidChange(_ note: Notification) {
        guard lock.state == .on, let field = note.object as? NSTextField, let v = Double(field.stringValue) else { return }
        if field === w { h.stringValue = "\(Int((CGFloat(v) / ratio).rounded()))" }
        else { w.stringValue = "\(Int((CGFloat(v) * ratio).rounded()))" }
    }
}
