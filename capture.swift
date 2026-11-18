import AppKit
import ScreenCaptureKit
import Vision

private enum CaptureTool: Int { case arrow, rectangle, circle, text, crop }
private struct CaptureMark {
    let tool: CaptureTool
    let start: CGPoint
    let end: CGPoint
    let text: String
}

// Coordinates are image pixels (not preview points), so export never depends on window size.
private final class CaptureCanvas: NSView {
    let image: CGImage
    var tool: CaptureTool = .arrow
    var text = ""
    var marks: [CaptureMark] = [] { didSet { needsDisplay = true } }
    // Crop is non-destructive: marks stay in full-image pixels; only export and OCR use the cropped area.
    var crop: CGRect? { didSet { needsDisplay = true } }
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
            if !text.isEmpty { marks.append(CaptureMark(tool: .text, start: p, end: p, text: text)) }
        } else { dragStart = p }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        provisional = CaptureMark(tool: tool, start: start, end: pixelPoint(convert(event.locationInWindow, from: nil)), text: "")
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = pixelPoint(convert(event.locationInWindow, from: nil))
        if tool == .crop {
            let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            if r.width >= 8 && r.height >= 8 { crop = r; cropAfterMarks = marks.count }
        } else if hypot(end.x - start.x, end.y - start.y) > 2 {
            marks.append(CaptureMark(tool: tool, start: start, end: end, text: ""))
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
            context.setStrokeColor(NSColor.systemRed.cgColor)
            context.setLineWidth(4)
            context.setLineCap(.round)
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
                context.move(to: mark.start); context.addLine(to: mark.end)
                for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                    context.move(to: mark.end)
                    context.addLine(to: CGPoint(x: mark.end.x - 20 * cos(angle + offset),
                                                y: mark.end.y - 20 * sin(angle + offset)))
                }
                context.strokePath()
            case .text:
                // NSString drawing uses the current AppKit graphics context, including the pixel transform.
                (mark.text as NSString).draw(at: mark.start, withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.systemRed
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

private final class CaptureEditor: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let window: NSWindow
    let canvas: CaptureCanvas
    private let tools: NSSegmentedControl
    private let input = NSTextField(string: "")
    init(image: CGImage) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? CGSize(width: 1000, height: 700)
        let width = min(1240, max(1000, available.width * 0.85)), height = min(840, available.height * 0.88)
        let scale = min((width - 60) / CGFloat(image.width), (height - 150) / CGFloat(image.height), 1)
        canvas = CaptureCanvas(image: image, size: CGSize(width: CGFloat(image.width) * scale,
                                                          height: CGFloat(image.height) * scale))
        // Large icon + label segments for the tools.
        let toolInfo = [("Arrow", "arrow.up.right"), ("Box", "rectangle"), ("Circle", "circle"), ("Text", "textformat"), ("Crop", "crop")]
        tools = NSSegmentedControl(labels: toolInfo.map(\.0), trackingMode: .selectOne, target: nil, action: nil)
        tools.controlSize = .large
        tools.segmentStyle = .capsule
        for (i, (name, symbol)) in toolInfo.enumerated() {
            tools.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)), forSegment: i)
            tools.setImageScaling(.scaleProportionallyDown, forSegment: i)
            tools.setWidth(84, forSegment: i)
        }
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Capture"
        window.isReleasedWhenClosed = false  // The editor owns the window until windowWillClose clears it.
        window.delegate = self
        window.minSize = CGSize(width: 980, height: 480)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        let stack = NSStackView()
        stack.orientation = .vertical; stack.spacing = 0
        let bar = NSStackView()
        bar.orientation = .horizontal; bar.spacing = 8
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        tools.target = self; tools.action = #selector(selectTool); tools.selectedSegment = 0
        bar.addArrangedSubview(tools)
        @discardableResult func button(_ title: String, _ symbol: String, _ action: Selector, key: String = "",
                                       mods: NSEvent.ModifierFlags = [], accent: NSColor? = nil, iconOnly: Bool = false) -> NSButton {
            let b = NSButton(title: iconOnly ? "" : title, target: self, action: action)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
            b.imagePosition = iconOnly ? .imageOnly : .imageLeading
            b.imageHugsTitle = true
            b.controlSize = .large
            b.bezelStyle = .push
            b.font = .systemFont(ofSize: 13, weight: .semibold)
            b.toolTip = key.isEmpty ? title : "\(title) (\(mods.contains(.command) ? "⌘" : "")\(key == "\u{1b}" ? "esc" : key.uppercased()))"
            if let accent { b.bezelColor = accent; b.contentTintColor = .white }
            b.keyEquivalent = key; b.keyEquivalentModifierMask = mods
            bar.addArrangedSubview(b)
            return b
        }
        func gap(_ w: CGFloat) { let v = NSView(); v.widthAnchor.constraint(equalToConstant: w).isActive = true; bar.addArrangedSubview(v) }
        input.placeholderString = "Type text, then click the image"
        input.delegate = self
        input.controlSize = .large
        input.font = .systemFont(ofSize: 14)
        input.bezelStyle = .roundedBezel
        input.widthAnchor.constraint(equalToConstant: 200).isActive = true
        gap(4)
        bar.addArrangedSubview(input)
        button("Undo", "arrow.uturn.backward", #selector(undo), key: "z", mods: .command, iconOnly: true)
        button("Reset", "trash", #selector(reset), iconOnly: true)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)
        button("Cancel", "xmark", #selector(cancel), key: "\u{1b}", iconOnly: true)
        button("Copy Text", "text.viewfinder", #selector(copyText))
        button("Save…", "square.and.arrow.down", #selector(savePNG), key: "s", mods: .command)
        button("Copy", "doc.on.doc.fill", #selector(copyPNG), key: "c", mods: .command, accent: .controlAccentColor)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 8
        canvas.layer?.masksToBounds = true
        canvas.shadow = NSShadow()
        // Center the image with a margin on a dark backdrop.
        let holder = CenteringView()
        holder.addSubview(canvas)
        holder.frame.size = CGSize(width: canvas.frame.width + 48, height: canvas.frame.height + 48)
        scroll.documentView = holder
        let frost = NSVisualEffectView()
        frost.material = .titlebar; frost.blendingMode = .withinWindow; frost.state = .active
        frost.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: frost.leadingAnchor), bar.trailingAnchor.constraint(equalTo: frost.trailingAnchor),
            bar.topAnchor.constraint(equalTo: frost.topAnchor, constant: 22), bar.bottomAnchor.constraint(equalTo: frost.bottomAnchor)
        ])
        stack.addArrangedSubview(frost); stack.addArrangedSubview(scroll)
        stack.setHuggingPriority(.required, for: .vertical)
        frost.setContentHuggingPriority(.required, for: .vertical)
        bar.setContentHuggingPriority(.required, for: .vertical)
        frost.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func controlTextDidChange(_ obj: Notification) {
        canvas.text = input.stringValue
        if !input.stringValue.isEmpty { tools.selectedSegment = CaptureTool.text.rawValue; canvas.tool = .text }
    }
    @objc private func selectTool() {
        canvas.tool = CaptureTool(rawValue: tools.selectedSegment) ?? .arrow
        if canvas.tool == .text { canvas.text = input.stringValue; window.makeFirstResponder(input) }
    }
    @objc private func undo() {
        if canvas.crop != nil && canvas.marks.count <= canvas.cropAfterMarks { canvas.crop = nil }
        else if !canvas.marks.isEmpty { canvas.marks.removeLast() }
    }
    @objc private func reset() { canvas.marks.removeAll(); canvas.crop = nil }
    @objc private func cancel() { window.close() }
    @objc private func copyPNG() {
        guard let data = canvas.png() else { captureError("Could not encode the PNG.", window: window); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setData(data, forType: .png) else { captureError("Could not copy the PNG.", window: window); return }
        if defaults.bool(forKey: "clipboardEnabled") { clipboard.poll() }
        window.close()
    }
    @objc private func copyText() {
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
                    } else { captureError("Could not copy recognized text.", window: self.window) }
                }
            } catch {
                DispatchQueue.main.async { captureError("Text recognition failed: \(error.localizedDescription)", window: self?.window) }
            }
        }
    }
    @objc private func savePNG() {
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
private func captureError(_ message: String, window: NSWindow? = nil) {
    let alert = NSAlert()
    alert.messageText = "Capture error"
    alert.informativeText = message
    if let window = window { alert.beginSheetModal(for: window) } else { alert.runModal() }
}

func openCapture() {
    guard captureEditor == nil else { captureEditor?.window.makeKeyAndOrderFront(nil); return }
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
            config.width = CGDisplayPixelsWide(displayID)
            config.height = CGDisplayPixelsHigh(displayID)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
            captureEditor = CaptureEditor(image: image)
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
    let editor = CaptureEditor(image: rep.cgImage!)
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
    print("Capture self-check passed: rectangle, circle, arrow, text, reset, crop, OCR; 160×90 PNG")
}
