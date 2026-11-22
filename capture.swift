import AppKit
import ScreenCaptureKit
import Vision

private enum CaptureTool: Int { case arrow, rectangle, circle, text, crop }
private struct CaptureMark {
    let tool: CaptureTool
    let start: CGPoint
    let end: CGPoint
    let text: String
    var width: CGFloat = 6   // stroke width in image pixels
    var shadow = 0           // 0 off, 1 soft, 2 medium, 3 strong
    var color: NSColor = .systemRed
}
// Markup colors, in the order of Apple's Markup palette.
let captureColors: [(String, NSColor)] = [("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
                                          ("Green", .systemGreen), ("Blue", .systemBlue), ("Purple", .systemPurple),
                                          ("Black", .black), ("White", .white)]
let captureWidths: [CGFloat] = [3, 6, 11]
// Shadow (offset, blur, opacity) per level, in image pixels.
let captureShadows: [(CGFloat, CGFloat, CGFloat)] = [(0, 0, 0), (2, 5, 0.45), (5, 12, 0.6), (9, 22, 0.75)]

// Coordinates are image pixels (not preview points), so export never depends on window size.
private final class CaptureCanvas: NSView, NSTextFieldDelegate {
    let image: CGImage
    var tool: CaptureTool = .arrow { didSet { commitText() } }
    var lineWidth: CGFloat = 6
    var shadowLevel = 0
    var color: NSColor = .systemRed
    var onChange: () -> Void = {}
    var marks: [CaptureMark] = [] { didSet { needsDisplay = true; onChange() } }
    // Crop is non-destructive: marks stay in full-image pixels; only export and OCR use the cropped area.
    var crop: CGRect? { didSet { needsDisplay = true; onChange() } }
    // Text is typed in place, like Markup: a borderless field at the click point, committed on Return or the next click.
    private var editor: NSTextField?
    private var editorPixel: CGPoint = .zero
    private var scale: CGFloat { bounds.width / CGFloat(image.width) }
    private func fontSize(_ width: CGFloat) -> CGFloat { 18 + width * 2 }
    func commitText() {
        guard let field = editor else { return }
        editor = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if !text.isEmpty {
            marks.append(CaptureMark(tool: .text, start: editorPixel, end: editorPixel, text: text, width: lineWidth, shadow: shadowLevel, color: color))
        }
    }
    private func beginText(at viewPoint: CGPoint) {
        let field = NSTextField(string: "")
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .boldSystemFont(ofSize: fontSize(lineWidth) * scale)
        field.textColor = color
        field.placeholderString = "Text"
        field.delegate = self
        field.target = self; field.action = #selector(endText)
        let height = ceil(field.font!.ascender - field.font!.descender + 4)
        field.frame = CGRect(x: viewPoint.x - 2, y: viewPoint.y - height / 2, width: max(160, bounds.width - viewPoint.x), height: height)
        // Text draws from its bottom-left in image pixels; keep the field's baseline where the mark will land.
        editorPixel = pixelPoint(CGPoint(x: viewPoint.x, y: field.frame.minY + 2))
        addSubview(field)
        window?.makeFirstResponder(field)
        editor = field
    }
    @objc private func endText() { commitText(); window?.makeFirstResponder(self) }
    var onToolKey: (CaptureTool) -> Void = { _ in }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        let tools: [String: CaptureTool] = ["a": .arrow, "r": .rectangle, "o": .circle, "t": .text, "c": .crop]
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let t = event.charactersIgnoringModifiers.flatMap({ tools[$0.lowercased()] }) { onToolKey(t) }
        else { super.keyDown(with: event) }
    }
    func controlTextDidEndEditing(_ obj: Notification) { commitText() }
    var cropAfterMarks = 0  // marks.count when the crop was set, so Undo removes the newest change first
    var exportRect: CGRect {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return (crop ?? full).integral.intersection(full)
    }
    // exportRect as a CGImage rect (top-left origin), for cropping the raw capture.
    var exportImage: CGImage {
        let r = exportRect
        return image.cropping(to: CGRect(x: r.minX, y: CGFloat(image.height) - r.maxY, width: r.width, height: r.height)) ?? image
    }
    private var dragStart: CGPoint?
    private var provisional: CaptureMark?
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    init(image: CGImage, size: CGSize) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func pixelPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x / bounds.width * CGFloat(image.width), 0), CGFloat(image.width)),
                y: min(max(point.y / bounds.height * CGFloat(image.height), 0), CGFloat(image.height)))
    }
    override func mouseDown(with event: NSEvent) {
        let p = pixelPoint(convert(event.locationInWindow, from: nil))
        if tool == .text {
            if editor != nil { commitText(); window?.makeFirstResponder(self) }
            else { beginText(at: convert(event.locationInWindow, from: nil)) }
        } else { commitText(); dragStart = p }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        provisional = CaptureMark(tool: tool, start: start, end: pixelPoint(convert(event.locationInWindow, from: nil)), text: "",
                                  width: lineWidth, shadow: shadowLevel, color: color)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = pixelPoint(convert(event.locationInWindow, from: nil))
        if tool == .crop {
            let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            if r.width >= 8 && r.height >= 8 { crop = r; cropAfterMarks = marks.count }
        } else if hypot(end.x - start.x, end.y - start.y) > 2 {
            marks.append(CaptureMark(tool: tool, start: start, end: end, text: "", width: lineWidth, shadow: shadowLevel, color: color))
        }
        dragStart = nil; provisional = nil; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        render(in: context, size: bounds.size)
        // Crop overlay (screen only): dim outside the crop, dashed border around it.
        let sx = bounds.width / CGFloat(image.width), sy = bounds.height / CGFloat(image.height)
        let pending = provisional.flatMap { $0.tool == .crop ? $0 : nil }.map {
            CGRect(x: min($0.start.x, $0.end.x), y: min($0.start.y, $0.end.y), width: abs($0.end.x - $0.start.x), height: abs($0.end.y - $0.start.y))
        }
        guard let area = pending ?? crop else { return }
        let r = CGRect(x: area.minX * sx, y: area.minY * sy, width: area.width * sx, height: area.height * sy)
        context.saveGState()
        context.addRect(bounds); context.addRect(r)
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.stroke(r)
        context.restoreGState()
    }
    private func render(in context: CGContext, size: CGSize) {
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.scaleBy(x: size.width / CGFloat(image.width), y: size.height / CGFloat(image.height))
        for mark in marks + (provisional.map { [$0] } ?? []) where mark.tool != .crop {
            context.saveGState()
            context.setStrokeColor(mark.color.cgColor)
            context.setLineWidth(mark.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if mark.shadow > 0 {
                // Shadow values are in device space, so scale them by the current pixel transform.
                let (offset, blur, alpha) = captureShadows[min(mark.shadow, 3)], k = abs(context.ctm.a)
                context.setShadow(offset: CGSize(width: offset * k, height: -offset * k), blur: blur * k,
                                  color: NSColor.black.withAlphaComponent(alpha).cgColor)
            }
            let box = CGRect(x: min(mark.start.x, mark.end.x), y: min(mark.start.y, mark.end.y),
                             width: abs(mark.end.x - mark.start.x), height: abs(mark.end.y - mark.start.y))
            switch mark.tool {
            case .crop:
                break
            case .rectangle:
                context.stroke(box)
            case .circle:
                context.strokeEllipse(in: box)
            case .arrow:
                let angle = atan2(mark.end.y - mark.start.y, mark.end.x - mark.start.x)
                let head = 14 + mark.width * 2.6
                // One path (shaft + open head) so the shadow is drawn once, without dark overlaps.
                context.move(to: mark.start); context.addLine(to: mark.end)
                context.move(to: CGPoint(x: mark.end.x - head * cos(angle - .pi / 6), y: mark.end.y - head * sin(angle - .pi / 6)))
                context.addLine(to: mark.end)
                context.addLine(to: CGPoint(x: mark.end.x - head * cos(angle + .pi / 6), y: mark.end.y - head * sin(angle + .pi / 6)))
                context.strokePath()
            case .text:
                // NSString drawing uses the current AppKit graphics context, including the pixel transform.
                (mark.text as NSString).draw(at: mark.start, withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: fontSize(mark.width)), .foregroundColor: mark.color
                ])
            }
            context.restoreGState()
        }
        context.restoreGState()
    }
    func png() -> Data? {
        let area = exportRect
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(area.width), pixelsHigh: Int(area.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.translateBy(x: -area.minX, y: -area.minY)
        render(in: graphics.cgContext, size: CGSize(width: image.width, height: image.height))
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// A diagonal stroke of the given thickness, for the width picker.
private func lineIcon(_ thickness: CGFloat) -> NSImage {
    let img = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { r in
        let p = NSBezierPath(); p.move(to: CGPoint(x: 4, y: 4)); p.line(to: CGPoint(x: 16, y: 16))
        p.lineWidth = thickness; p.lineCapStyle = .round
        NSColor.black.setStroke(); p.stroke(); return true
    }
    img.isTemplate = true
    return img
}
// A square with a shadow of increasing depth (level 0: square only), for the shadow picker.
private func shadowIcon(_ level: Int) -> NSImage {
    let img = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { _ in
        if level > 0 {
            let d = CGFloat(level) * 1.5
            NSColor.black.withAlphaComponent(0.2 + 0.18 * CGFloat(level)).setFill()
            NSBezierPath(roundedRect: CGRect(x: 4 + d, y: 4 - d + 1, width: 11, height: 11), xRadius: 2.5, yRadius: 2.5).fill()
        }
        let box = NSBezierPath(roundedRect: CGRect(x: 3.5, y: 5.5, width: 11, height: 11), xRadius: 2.5, yRadius: 2.5)
        box.lineWidth = 1.6
        NSColor.black.setStroke(); box.stroke()
        return true
    }
    img.isTemplate = true
    return img
}

// Keeps the image centered in the scroll area, with a margin, at any window size.
private final class CenteringView: NSView {
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        guard let child = subviews.first else { return }
        let visible = enclosingScrollView?.contentSize ?? bounds.size
        let size = CGSize(width: max(visible.width, child.frame.width + 48), height: max(visible.height, child.frame.height + 48))
        if frame.size != size { setFrameSize(size) }
        child.setFrameOrigin(CGPoint(x: ((size.width - child.frame.width) / 2).rounded(), y: ((size.height - child.frame.height) / 2).rounded()))
    }
}

// A filled color swatch, for the color menu and toolbar item.
private func colorDot(_ color: NSColor, size: CGFloat = 16) -> NSImage {
    NSImage(size: CGSize(width: size, height: size), flipped: false) { r in
        let dot = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
        color.setFill(); dot.fill()
        NSColor.separatorColor.setStroke(); dot.lineWidth = 1; dot.stroke()
        return true
    }
}

private final class EditorWindow: NSWindow {
    var onCommand: (String) -> Bool = { _ in false }
    override func cancelOperation(_ sender: Any?) { close() }  // Esc closes, like Markup's Cancel
    // NirTab has no main menu, so ⌘Z / ⌘C / ⌘S are handled here (unless a text field is being edited).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, !(firstResponder is NSText),
           let key = event.charactersIgnoringModifiers?.lowercased(), onCommand(key) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private func zip3<A, B, C>(_ a: [A], _ b: [B], _ c: [C]) -> [(A, B, C)] { zip(a, zip(b, c)).map { ($0, $1.0, $1.1) } }

private extension NSToolbarItem.Identifier {
    static let tools = Self("capture.tools"), style = Self("capture.style"), shadow = Self("capture.shadow"),
               color = Self("capture.color"), undo = Self("capture.undo"), clear = Self("capture.clear"),
               ocr = Self("capture.ocr"), save = Self("capture.save"), copy = Self("capture.copy")
}

// Apple Markup-style editor: native unified toolbar (tools, shape style, shadow, color, undo), title + size subtitle,
// system light/dark, image centered on the under-page background, text typed in place.
private final class CaptureEditor: NSObject, NSWindowDelegate, NSToolbarDelegate {
    let window: NSWindow
    let canvas: CaptureCanvas
    private var toolGroup: NSToolbarItemGroup?
    private var styleItem: NSMenuToolbarItem?
    private var shadowItem: NSMenuToolbarItem?
    private var colorItem: NSMenuToolbarItem?
    private var widthIndex = max(0, min(2, defaults.object(forKey: "captureWidth") as? Int ?? 1))
    private var shadowIndex = max(0, min(3, defaults.object(forKey: "captureShadow") as? Int ?? 0))
    private var colorIndex = max(0, min(captureColors.count - 1, defaults.object(forKey: "captureColor") as? Int ?? 0))

    init(image: CGImage) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? CGSize(width: 1000, height: 700)
        let width = min(1400, max(900, available.width * 0.8)), height = min(900, available.height * 0.85)
        let scale = min((width - 64) / CGFloat(image.width), (height - 116) / CGFloat(image.height), 1)
        canvas = CaptureCanvas(image: image, size: CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
        window = EditorWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Capture"
        window.isReleasedWhenClosed = false  // The editor owns the window until windowWillClose clears it.
        window.delegate = self
        window.minSize = CGSize(width: 820, height: 420)
        let toolbar = NSToolbar(identifier: "NirTabCapture")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.backgroundColor = .underPageBackgroundColor; scroll.drawsBackground = true
        canvas.wantsLayer = true
        canvas.shadow = {
            let s = NSShadow(); s.shadowBlurRadius = 12; s.shadowOffset = CGSize(width: 0, height: -3)
            s.shadowColor = NSColor.black.withAlphaComponent(0.3); return s
        }()
        let holder = CenteringView()
        holder.addSubview(canvas)
        holder.frame.size = CGSize(width: canvas.frame.width + 48, height: canvas.frame.height + 48)
        scroll.documentView = holder
        window.contentView = scroll
        canvas.lineWidth = captureWidths[widthIndex]
        canvas.shadowLevel = shadowIndex
        canvas.color = captureColors[colorIndex].1
        canvas.onChange = { [weak self] in self?.updateSubtitle() }
        (window as? EditorWindow)?.onCommand = { [weak self] key in
            guard let self else { return false }
            switch key {
            case "z": self.undo()
            case "c": self.copyPNG()
            case "s": self.savePNG()
            case "w": self.window.close()
            default: return false
            }
            return true
        }
        canvas.onToolKey = { [weak self] t in self?.canvas.tool = t; self?.toolGroup?.selectedIndex = t.rawValue }
        updateSubtitle()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateSubtitle() {
        let r = canvas.exportRect
        window.subtitle = "\(Int(r.width)) × \(Int(r.height))" + (canvas.crop != nil ? " · cropped" : "")
    }

    // MARK: Toolbar
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.tools, .style, .shadow, .color, .space, .undo, .clear, .flexibleSpace, .ocr, .save, .copy]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func symbol(_ name: String, _ label: String) -> NSImage { NSImage(systemSymbolName: name, accessibilityDescription: label)! }
        func button(_ label: String, _ name: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label; item.toolTip = label; item.image = symbol(name, label)
            item.target = self; item.action = action; item.isBordered = true
            return item
        }
        switch id {
        case .tools:
            let tools = [("Arrow", "arrow.up.right"), ("Rectangle", "rectangle"), ("Oval", "circle"), ("Text", "textformat"), ("Crop", "crop")]
            let group = NSToolbarItemGroup(itemIdentifier: id, images: tools.map { symbol($0.1, $0.0) }, selectionMode: .selectOne,
                                           labels: tools.map(\.0), target: self, action: #selector(selectTool(_:)))
            group.label = "Tools"
            for (sub, t, key) in zip3(group.subitems, tools, ["A", "R", "O", "T", "C"]) { sub.toolTip = "\(t.0) (\(key))" }
            group.selectedIndex = canvas.tool.rawValue
            toolGroup = group
            return group
        case .style:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Shape Style"; item.toolTip = "Line width"
            styleItem = item; refreshMenus()
            return item
        case .shadow:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Shadow"; item.toolTip = "Shadow"
            shadowItem = item; refreshMenus()
            return item
        case .color:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Color"; item.toolTip = "Color"
            colorItem = item; refreshMenus()
            return item
        case .undo: return button("Undo", "arrow.uturn.backward", #selector(undo))
        case .clear: return button("Clear All", "eraser", #selector(reset))
        case .ocr: return button("Copy Text", "text.viewfinder", #selector(copyText))
        case .save: return button("Save…", "square.and.arrow.down", #selector(savePNG))
        case .copy:
            let b = NSButton(title: "Copy", target: self, action: #selector(copyPNG))
            b.bezelStyle = .push; b.controlSize = .large
            b.bezelColor = .controlAccentColor
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = b; item.label = "Copy"; item.toolTip = "Copy image (⌘C)"
            return item
        default: return nil
        }
    }
    private func refreshMenus() {
        func menu(_ entries: [(String, NSImage, Bool)], _ action: Selector) -> NSMenu {
            let m = NSMenu()
            for (i, e) in entries.enumerated() {
                let it = NSMenuItem(title: e.0, action: action, keyEquivalent: "")
                it.image = e.1; it.tag = i; it.target = self; it.state = e.2 ? .on : .off
                m.addItem(it)
            }
            return m
        }
        styleItem?.image = lineIcon(CGFloat([1.5, 3, 5.5][widthIndex]))
        styleItem?.menu = menu((0..<3).map { (["Thin", "Medium", "Thick"][$0], lineIcon(CGFloat([1.5, 3, 5.5][$0])), $0 == widthIndex) },
                               #selector(chooseWidth(_:)))
        shadowItem?.image = shadowIcon(shadowIndex)
        shadowItem?.menu = menu((0...3).map { (["No Shadow", "Soft", "Medium", "Strong"][$0], shadowIcon($0), $0 == shadowIndex) },
                                #selector(chooseShadow(_:)))
        colorItem?.image = colorDot(captureColors[colorIndex].1, size: 18)
        colorItem?.menu = menu(captureColors.enumerated().map { ($0.element.0, colorDot($0.element.1), $0.offset == colorIndex) },
                               #selector(chooseColor(_:)))
    }

    // MARK: Actions
    @objc private func selectTool(_ sender: NSToolbarItemGroup) {
        canvas.tool = CaptureTool(rawValue: toolGroup?.selectedIndex ?? 0) ?? .arrow
        window.makeFirstResponder(canvas)
    }
    @objc private func chooseWidth(_ sender: NSMenuItem) {
        widthIndex = sender.tag; canvas.lineWidth = captureWidths[widthIndex]
        defaults.set(widthIndex, forKey: "captureWidth"); refreshMenus()
    }
    @objc private func chooseShadow(_ sender: NSMenuItem) {
        shadowIndex = sender.tag; canvas.shadowLevel = shadowIndex
        defaults.set(shadowIndex, forKey: "captureShadow"); refreshMenus()
    }
    @objc private func chooseColor(_ sender: NSMenuItem) {
        colorIndex = sender.tag; canvas.color = captureColors[colorIndex].1
        defaults.set(colorIndex, forKey: "captureColor"); refreshMenus()
    }
    @objc func undo() {
        canvas.commitText()
        if canvas.crop != nil && canvas.marks.count <= canvas.cropAfterMarks { canvas.crop = nil }
        else if !canvas.marks.isEmpty { canvas.marks.removeLast() }
    }
    @objc private func reset() { canvas.commitText(); canvas.marks.removeAll(); canvas.crop = nil }
    @objc private func copyPNG() {
        canvas.commitText()
        guard let data = canvas.png() else { captureError("Could not encode the PNG.", window: window); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setData(data, forType: .png) else { captureError("Could not copy the PNG.", window: window); return }
        if defaults.bool(forKey: "clipboardEnabled") { clipboard.poll() }
        window.close()
        showToast("Image copied", symbol: "photo", color: .blue)
    }
    @objc private func copyText() {
        canvas.commitText()
        let image = canvas.exportImage
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard !text.isEmpty else { captureError("No text found in the capture.", window: self.window); return }
                    let board = NSPasteboard.general
                    board.clearContents()
                    if board.setString(text, forType: .string) {
                        if defaults.bool(forKey: "clipboardEnabled") { clipboard.poll() }
                        self.window.close()
                        showToast("Text copied", symbol: "text.viewfinder", color: .blue)
                    } else { captureError("Could not copy recognized text.", window: self.window) }
                }
            } catch {
                DispatchQueue.main.async { captureError("Text recognition failed: \(error.localizedDescription)", window: self?.window) }
            }
        }
    }
    @objc private func savePNG() {
        canvas.commitText()
        guard let data = canvas.png() else { captureError("Could not encode the PNG.", window: window); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Capture.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); self?.window.close() }
            catch { captureError("Could not save PNG: \(error.localizedDescription)", window: self?.window) }
        }
    }
    func windowWillClose(_ notification: Notification) { captureEditor = nil }
}

private var captureEditor: CaptureEditor?
private var captureSelection: CaptureSelection?

// Area selection over a frozen capture of the display: the screen dims a little, a crosshair shows the pointer's
// x, y (points from the display's top-left), dragging shows the selection's width × height, and releasing opens
// the editor with that area. A click or Return takes the whole display; Esc cancels.
private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
private final class SelectionView: NSView {
    var onDone: (CGRect?) -> Void = { _ in }  // nil = cancelled; .zero = whole display
    private var pointer: CGPoint?
    private var anchor: CGPoint?
    private var selection: CGRect? { anchor.flatMap { a in pointer.map { p in
        CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y)) } } }
    override var isFlipped: Bool { true }  // top-left origin, like screen coordinates people read
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    private func point(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width).rounded(), y: min(max(p.y, 0), bounds.height).rounded())
    }
    override func mouseMoved(with event: NSEvent) { pointer = point(event); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { anchor = point(event); pointer = anchor; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { pointer = point(event); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        pointer = point(event)
        guard let r = selection, r.width >= 4, r.height >= 4 else { onDone(.zero); return }
        onDone(r)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onDone(nil)             // esc
        case 36, 76: onDone(.zero)       // return / enter: whole display
        default: super.keyDown(with: event)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Light dim everywhere except the selection.
        ctx.addRect(bounds)
        if let r = selection { ctx.addRect(r) }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.fillPath(using: .evenOdd)
        guard let p = pointer else { return }
        if let r = selection {
            ctx.setShadow(offset: .zero, blur: 6, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(r.insetBy(dx: -0.75, dy: -0.75))
            ctx.setShadow(offset: .zero, blur: 0)
            label("\(Int(r.width)) × \(Int(r.height))", near: CGPoint(x: r.maxX, y: r.maxY))
        } else {
            // Crosshair through the pointer.
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.move(to: CGPoint(x: p.x + 0.5, y: 0)); ctx.addLine(to: CGPoint(x: p.x + 0.5, y: bounds.height))
            ctx.move(to: CGPoint(x: 0, y: p.y + 0.5)); ctx.addLine(to: CGPoint(x: bounds.width, y: p.y + 0.5))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            label("x \(Int(p.x))   y \(Int(p.y))", near: p)
        }
    }
    // Rounded dark pill next to a point, kept inside the screen.
    private func label(_ text: String, near p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var box = CGRect(x: p.x + 14, y: p.y + 14, width: size.width + 16, height: size.height + 8)
        if box.maxX > bounds.maxX - 4 { box.origin.x = p.x - 14 - box.width }
        if box.maxY > bounds.maxY - 4 { box.origin.y = p.y - 14 - box.height }
        let shadow = NSShadow(); shadow.shadowBlurRadius = 6; shadow.shadowColor = .black.withAlphaComponent(0.5)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        (text as NSString).draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attrs)
    }
}
private final class CaptureSelection: NSObject {
    let window: SelectionWindow
    init(screen: NSScreen, image: CGImage) {
        window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        // The frozen capture underneath, so what you select is exactly what you get.
        let frozen = NSImageView(frame: CGRect(origin: .zero, size: screen.frame.size))
        frozen.image = NSImage(cgImage: image, size: screen.frame.size)
        frozen.imageScaling = .scaleAxesIndependently
        let view = SelectionView(frame: frozen.frame)
        frozen.addSubview(view)
        window.contentView = frozen
        let scale = CGFloat(image.width) / screen.frame.width
        view.onDone = { [weak self] rect in
            self?.window.orderOut(nil)
            captureSelection = nil
            guard let rect else { return }
            let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
            let chosen = rect == .zero ? image : (image.cropping(to: pixels) ?? image)
            captureEditor = CaptureEditor(image: chosen)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        if let p = Optional(window.mouseLocationOutsideOfEventStream) {
            view.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 0, pressure: 0)!)
        }
    }
}
private func captureError(_ message: String, window: NSWindow? = nil) {
    let alert = NSAlert()
    alert.messageText = "Capture error"
    alert.informativeText = message
    if let window = window { alert.beginSheetModal(for: window) } else { alert.runModal() }
}

func openCapture() {
    guard captureEditor == nil else { captureEditor?.window.makeKeyAndOrderFront(nil); return }
    guard captureSelection == nil else { return }
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
        captureError("Screen Recording permission is required. Enable NirTab in System Settings → Privacy & Security → Screen & System Audio Recording, then restart NirTab.")
        return
    }
    let location = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    guard let displayID = displayID else { captureError("No display found under the pointer."); return }
    Task { @MainActor in
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                captureError("The selected display is unavailable."); return
            }
            let config = SCStreamConfiguration()
            // Full Retina resolution (CGDisplayPixelsWide is in points on scaled displays).
            let backing = screen?.backingScaleFactor ?? 1
            config.width = Int(CGFloat(CGDisplayPixelsWide(displayID)) * backing)
            config.height = Int(CGFloat(CGDisplayPixelsHigh(displayID)) * backing)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
            guard let screen else { captureEditor = CaptureEditor(image: image); return }
            captureSelection = CaptureSelection(screen: screen, image: image)
        } catch { captureError("Could not capture the display: \(error.localizedDescription)") }
    }
}

// Run via a temporary entry-point hook; never asks for Screen Recording permission.
func testCapture() {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 90,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 160, height: 90).fill()
    NSGraphicsContext.restoreGraphicsState()
    let canvas = CaptureCanvas(image: rep.cgImage!, size: CGSize(width: 80, height: 45))
    canvas.marks = [CaptureMark(tool: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 60), text: ""),
                    CaptureMark(tool: .circle, start: CGPoint(x: 95, y: 10), end: CGPoint(x: 150, y: 65), text: ""),
                    CaptureMark(tool: .arrow, start: CGPoint(x: 15, y: 20), end: CGPoint(x: 100, y: 70), text: ""),
                    CaptureMark(tool: .text, start: CGPoint(x: 30, y: 30), end: CGPoint(x: 30, y: 30), text: "Test")]
    guard let png = canvas.png(), png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
          let output = NSBitmapImageRep(data: png) else { preconditionFailure("Capture PNG export failed") }
    precondition(output.pixelsWide == 160 && output.pixelsHigh == 90, "Capture lost native dimensions")
    let colored = (0..<90).reduce(0) { count, y in
        count + (0..<160).filter { x in
            guard let c = output.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.redComponent > c.greenComponent + 0.2
        }.count
    }
    precondition(colored > 80, "Annotations not rendered (\(colored) colored pixels)")
    canvas.marks.removeFirst(3)
    guard let textPNG = canvas.png(), let textImage = NSBitmapImageRep(data: textPNG) else {
        preconditionFailure("Text PNG export failed")
    }
    let textPixels = (0..<90).reduce(0) { count, y in
        count + (0..<160).filter { x in
            guard let c = textImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.redComponent > c.greenComponent + 0.2
        }.count
    }
    precondition(textPixels > 10, "Text annotation not rendered")
    canvas.marks.removeAll()
    precondition(canvas.marks.isEmpty, "Reset failed")
    // Crop: export is only the cropped area, OCR image matches, and marks keep full-image coordinates.
    canvas.marks = [CaptureMark(tool: .rectangle, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 160, y: 90), text: "")]
    canvas.crop = CGRect(x: 20, y: 10, width: 60.4, height: 30.2)
    guard let croppedPNG = canvas.png(), let cropped = NSBitmapImageRep(data: croppedPNG) else { preconditionFailure("Crop export failed") }
    precondition(cropped.pixelsWide == 61 && cropped.pixelsHigh == 31, "Crop size \(cropped.pixelsWide)x\(cropped.pixelsHigh)")
    precondition(canvas.exportImage.width == 61 && canvas.exportImage.height == 31, "Crop OCR image size")
    canvas.crop = nil; canvas.marks.removeAll()
    // Width + shadow: a thick arrow with a strong shadow paints more red and adds gray shadow pixels.
    func count(_ test: (NSColor) -> Bool) -> Int {
        guard let data = canvas.png(), let out = NSBitmapImageRep(data: data) else { return 0 }
        return (0..<90).reduce(0) { n, y in n + (0..<160).filter { x in out.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB).map(test) ?? false }.count }
    }
    let red = { (c: NSColor) in c.redComponent > c.greenComponent + 0.2 }
    let gray = { (c: NSColor) in abs(c.redComponent - c.blueComponent) < 0.05 && c.redComponent < 0.9 }
    canvas.marks = [CaptureMark(tool: .arrow, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 130, y: 60), text: "", width: 3)]
    let thinRed = count(red), plainGray = count(gray)
    canvas.marks = [CaptureMark(tool: .arrow, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 130, y: 60), text: "", width: 11, shadow: 3)]
    precondition(count(red) > thinRed * 2, "Thick line not wider")
    precondition(count(gray) > plainGray + 50, "Shadow not rendered")
    canvas.marks.removeAll()
    let editor = CaptureEditor(image: rep.cgImage!)
    // In-place text: click with the Text tool, type, commit → one text mark in the chosen color.
    editor.canvas.tool = .text
    editor.canvas.color = .systemBlue
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: editor.canvas.convert(CGPoint(x: 20, y: 20), to: nil), modifierFlags: [],
                                   timestamp: 0, windowNumber: editor.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    editor.canvas.mouseDown(with: click)
    guard let field = editor.canvas.subviews.compactMap({ $0 as? NSTextField }).first else { preconditionFailure("Text field not shown") }
    field.stringValue = "Hello"
    editor.canvas.commitText()
    precondition(editor.canvas.marks.count == 1 && editor.canvas.marks[0].text == "Hello" && editor.canvas.marks[0].color == .systemBlue,
                 "In-place text not committed")
    precondition(editor.window.subtitle == "160 × 90", "subtitle \(editor.window.subtitle)")
    editor.window.close()
    let ocrRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 160,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: ocrRep)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 640, height: 160).fill()
    ("NIRTAB CHECK" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [
        .font: NSFont.boldSystemFont(ofSize: 70), .foregroundColor: NSColor.black
    ])
    NSGraphicsContext.restoreGraphicsState()
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try! VNImageRequestHandler(cgImage: ocrRep.cgImage!).perform([request])
    precondition((request.results ?? []).contains { $0.topCandidates(1).first?.string.contains("NIRTAB") == true }, "OCR failed")
    print("Capture self-check passed: rectangle, circle, arrow, text, reset, crop, width, shadow, OCR; 160×90 PNG")
}
// Selection overlay: a drag reports the rectangle in top-left points; a click means the whole display.
func testCaptureSelection() {
    let v = SelectionView(frame: CGRect(x: 0, y: 0, width: 1200, height: 750))
    let w = NSWindow(contentRect: v.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.contentView = v
    func ev(_ t: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    var result: CGRect?
    v.onDone = { result = $0 }
    v.mouseMoved(with: ev(.mouseMoved, 400, 450))
    v.mouseDown(with: ev(.leftMouseDown, 250, 550)); v.mouseDragged(with: ev(.leftMouseDragged, 800, 300))
    v.mouseUp(with: ev(.leftMouseUp, 800, 300))
    precondition(result == CGRect(x: 250, y: 200, width: 550, height: 250), "selection rect \(String(describing: result))")
    v.mouseDown(with: ev(.leftMouseDown, 300, 300)); v.mouseUp(with: ev(.leftMouseUp, 301, 300))
    precondition(result == .zero, "click should select the whole display")
    print("Capture selection PASS")
}

// Debug (--snapshot-ui): the editor with sample marks and the selection overlay, on a made-up image (no screen capture).
func snapshotCapture(_ dir: String) {
    let w = 1600, h = 1000
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(colors: [.systemTeal, .systemIndigo])!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -35)
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: 200, y: 200, width: 1200, height: 600), xRadius: 24, yRadius: 24).fill()
    ("Sample window" as NSString).draw(at: CGPoint(x: 260, y: 700), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 56), .foregroundColor: NSColor.darkGray])
    NSGraphicsContext.restoreGraphicsState()
    let editor = CaptureEditor(image: rep.cgImage!)
    editor.canvas.marks = [CaptureMark(tool: .arrow, start: CGPoint(x: 300, y: 300), end: CGPoint(x: 700, y: 600), text: "", width: 6, shadow: 2),
                           CaptureMark(tool: .rectangle, start: CGPoint(x: 900, y: 300), end: CGPoint(x: 1300, y: 560), text: "", width: 6, shadow: 2),
                           CaptureMark(tool: .text, start: CGPoint(x: 900, y: 600), end: .zero, text: "Look here", width: 6, shadow: 2, color: .systemBlue)]
    func shot(_ win: NSWindow, _ name: String) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let v = win.contentView?.superview ?? win.contentView, let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: r)
        try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
    for (mode, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        editor.window.appearance = NSAppearance(named: look)
        shot(editor.window, "capture-editor-\(mode)")
    }
    editor.window.close()
    let sel = SelectionView(frame: CGRect(x: 0, y: 0, width: 900, height: 560))
    let frozen = NSImageView(frame: sel.frame)
    frozen.image = NSImage(cgImage: rep.cgImage!, size: sel.frame.size); frozen.imageScaling = .scaleAxesIndependently
    frozen.addSubview(sel)
    let sw = NSWindow(contentRect: sel.frame, styleMask: .borderless, backing: .buffered, defer: false)
    sw.contentView = frozen; sw.orderFrontRegardless()
    func ev(_ t: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: t, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: sw.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    sel.mouseMoved(with: ev(.mouseMoved, 200, 400))
    shot(sw, "capture-crosshair")
    sel.mouseDown(with: ev(.leftMouseDown, 150, 420)); sel.mouseDragged(with: ev(.leftMouseDragged, 620, 160))
    shot(sw, "capture-selection")
    sw.close()
}
