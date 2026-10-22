import AppKit
import ScreenCaptureKit
import Vision

private enum CaptureTool { case arrow, rectangle, text }
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
    private var dragStart: CGPoint?
    private var provisional: CaptureMark?
    override var isFlipped: Bool { false }

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
        if hypot(end.x - start.x, end.y - start.y) > 2 {
            marks.append(CaptureMark(tool: tool, start: start, end: end, text: ""))
        }
        dragStart = nil; provisional = nil; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        render(in: context, size: bounds.size)
    }
    private func render(in context: CGContext, size: CGSize) {
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.scaleBy(x: size.width / CGFloat(image.width), y: size.height / CGFloat(image.height))
        for mark in marks + (provisional.map { [$0] } ?? []) {
            context.saveGState()
            context.setStrokeColor(NSColor.systemRed.cgColor)
            context.setLineWidth(4)
            context.setLineCap(.round)
            switch mark.tool {
            case .rectangle:
                context.stroke(CGRect(x: min(mark.start.x, mark.end.x), y: min(mark.start.y, mark.end.y),
                                    width: abs(mark.end.x - mark.start.x), height: abs(mark.end.y - mark.start.y)))
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
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        render(in: graphics.cgContext, size: CGSize(width: image.width, height: image.height))
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

private final class CaptureEditor: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let window: NSWindow
    let canvas: CaptureCanvas
    private let input = NSTextField(string: "")
    init(image: CGImage) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? CGSize(width: 1000, height: 700)
        let width = min(1100, available.width * 0.85), height = min(780, available.height * 0.85)
        let scale = min((width - 30) / CGFloat(image.width), (height - 100) / CGFloat(image.height), 1)
        canvas = CaptureCanvas(image: image, size: CGSize(width: CGFloat(image.width) * scale,
                                                          height: CGFloat(image.height) * scale))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Capture"
        window.isReleasedWhenClosed = false  // The editor owns the window until windowWillClose clears it.
        window.delegate = self
        window.minSize = CGSize(width: 540, height: 380)
        let stack = NSStackView()
        stack.orientation = .vertical; stack.spacing = 0
        let bar = NSStackView()
        bar.orientation = .horizontal; bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        @discardableResult func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            bar.addArrangedSubview(b)
            return b
        }
        button("Arrow", #selector(arrow))
        button("Rectangle", #selector(rectangle))
        button("Text", #selector(textTool))
        input.placeholderString = "Text to place (then click image)"
        input.delegate = self
        input.widthAnchor.constraint(equalToConstant: 205).isActive = true
        bar.addArrangedSubview(input)
        button("Undo", #selector(undo))
        button("Reset", #selector(reset))
        button("Copy", #selector(copyPNG))
        button("Copy Text", #selector(copyText))
        button("Save…", #selector(savePNG))
        let cancel = button("Cancel", #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.documentView = canvas
        stack.addArrangedSubview(bar); stack.addArrangedSubview(scroll)
        bar.setContentHuggingPriority(.required, for: .vertical)
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
    func controlTextDidChange(_ obj: Notification) { canvas.text = input.stringValue }
    @objc private func arrow() { canvas.tool = .arrow }
    @objc private func rectangle() { canvas.tool = .rectangle }
    @objc private func textTool() { canvas.tool = .text; canvas.text = input.stringValue; window.makeFirstResponder(input) }
    @objc private func undo() { if !canvas.marks.isEmpty { canvas.marks.removeLast() } }
    @objc private func reset() { canvas.marks.removeAll() }
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
        let image = canvas.image
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
    precondition(colored > 50, "Annotations not rendered (\(colored) colored pixels)")
    canvas.marks.removeFirst(2)
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
    print("Capture self-check passed: rectangle, arrow, text, reset, OCR; 160×90 PNG")
}
