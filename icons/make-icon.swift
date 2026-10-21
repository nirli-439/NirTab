// Draws NirTab's app icon: two stacked windows on an indigo→blue tile. Original artwork, no third-party assets.
// Regenerate:  swift icons/make-icon.swift && iconutil -c icns icons/AppIcon.iconset -o icons/AppIcon.icns && rm -r icons/AppIcon.iconset
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024  // design on a 1024 grid; macOS icon body is 824 wide with a 100 margin
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Tile + soft shadow
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(red: 0.20, green: 0.22, blue: 0.62, alpha: 1),
               ending: NSColor(red: 0.18, green: 0.55, blue: 0.96, alpha: 1))!.draw(in: tile, angle: 60)

    // Back window (translucent), front window (white) with traffic lights
    NSColor.white.withAlphaComponent(0.35).setFill()
    NSBezierPath(roundedRect: r(330, 400, 460, 340), xRadius: 40 * s, yRadius: 40 * s).fill()
    let front = r(234, 284, 460, 340)
    NSGraphicsContext.saveGraphicsState()
    let fs = NSShadow()
    fs.shadowColor = NSColor.black.withAlphaComponent(0.25)
    fs.shadowOffset = NSSize(width: 0, height: -8 * s)
    fs.shadowBlurRadius = 20 * s
    fs.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: front, xRadius: 40 * s, yRadius: 40 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 0.9, alpha: 1).setFill()
    NSBezierPath(rect: r(234, 560, 460, 2)).fill()  // title bar line
    for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        c.setFill()
        NSBezierPath(ovalIn: r(270 + CGFloat(i) * 46, 578, 28, 28)).fill()
    }
    // Tab arrow (→|) in the front window: the switcher
    let arrow = NSBezierPath()
    arrow.lineWidth = 34 * s
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 330 * s, y: 420 * s)); arrow.line(to: NSPoint(x: 560 * s, y: 420 * s))
    arrow.move(to: NSPoint(x: 490 * s, y: 490 * s)); arrow.line(to: NSPoint(x: 560 * s, y: 420 * s)); arrow.line(to: NSPoint(x: 490 * s, y: 350 * s))
    arrow.move(to: NSPoint(x: 610 * s, y: 340 * s)); arrow.line(to: NSPoint(x: 610 * s, y: 500 * s))
    NSColor(red: 0.20, green: 0.30, blue: 0.80, alpha: 1).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! draw(pt * scale).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
print("wrote \(dir.path)")
