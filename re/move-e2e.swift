// Live shortcut check on an unlocked Mac: swift re/move-e2e.swift
import AppKit
_ = NSApplication.shared

func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? T
}
func bounds(_ win: AXUIElement) -> CGRect {
    let p: AXValue = attribute(win, kAXPositionAttribute)!, s: AXValue = attribute(win, kAXSizeAttribute)!
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p, .cgPoint, &point); AXValueGetValue(s, .cgSize, &size)
    return CGRect(origin: point, size: size)
}
func setBounds(_ win: AXUIElement, _ r: CGRect) {
    var p = r.origin, s = r.size
    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
}
func press(_ code: CGKeyCode, control: Bool = false) {
    let src = CGEventSource(stateID: .hidSystemState)
    let flags: CGEventFlags = control ? [.maskControl, .maskAlternate, .maskCommand] : [.maskAlternate, .maskCommand]
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
    usleep(400_000)
}
func check(_ ok: Bool, _ label: String) {
    print(ok ? "PASS \(label)" : "FAIL \(label)")
    if !ok { failures += 1 }
}
var failures = 0
let osa = Process()
osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
osa.arguments = ["-e", "tell application \"TextEdit\" to activate", "-e", "tell application \"TextEdit\" to make new document with properties {text:\"NirTab move e2e\"}"]
osa.standardOutput = FileHandle.nullDevice
try osa.run(); osa.waitUntilExit()
guard osa.terminationStatus == 0, let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextEdit" }) else { fatalError("TextEdit did not open") }
let ax = AXUIElementCreateApplication(app.processIdentifier)
guard let win: AXUIElement = attribute(ax, kAXFocusedWindowAttribute) else { fatalError("No focused TextEdit window (screen locked or AX denied?)") }
let original = bounds(win)
let mainTop = NSScreen.screens[0].frame.maxY
func screen(_ r: CGRect) -> Int {
    let c = CGRect(x: r.minX, y: mainTop - r.maxY, width: r.width, height: r.height)
    return NSScreen.screens.indices.max { a, b in
        let x = c.intersection(NSScreen.screens[a].frame), y = c.intersection(NSScreen.screens[b].frame)
        return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
    }!
}
let start = screen(original)
let vf = NSScreen.screens[start].visibleFrame
if CommandLine.arguments.contains("--rectangle-drag") {
    let source = CGEventSource(stateID: .hidSystemState)
    let from = CGPoint(x: original.minX + min(100, original.width / 3), y: original.minY + 18)
    let to = CGPoint(x: NSScreen.screens[start].frame.minX + 2, y: mainTop - vf.midY)
    for (kind, point) in [(CGEventType.leftMouseDown, from), (.leftMouseDragged, from),
                           (.leftMouseDragged, CGPoint(x: (from.x + to.x)/2, y: (from.y + to.y)/2)),
                           (.leftMouseDragged, to), (.leftMouseUp, to)] {
        let event = CGEvent(mouseEventSource: source, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)!
        event.post(tap: .cghidEventTap)
        usleep(150_000)
    }
    usleep(700_000)
    check(abs(bounds(win).minX - vf.minX) < 40 && abs(bounds(win).width - vf.width/2) < 40,
          "Rectangle drag-to-left-edge snap: \(bounds(win))")
    setBounds(win, original)
    if NSScreen.screens.count > 1, let other = NSScreen.screens.indices.first(where: { $0 != start }) {
        let target = NSScreen.screens[other].frame
        let leftEdge = target.midX < NSScreen.screens[start].frame.midX
        let destination = CGPoint(x: leftEdge ? target.minX + 2 : target.maxX - 2, y: mainTop - target.midY)
        for (kind, point) in [(CGEventType.leftMouseDown, from), (.leftMouseDragged, from),
                               (.leftMouseDragged, CGPoint(x: (from.x + destination.x)/2, y: (from.y + destination.y)/2)),
                               (.leftMouseDragged, destination), (.leftMouseUp, destination)] {
            let event = CGEvent(mouseEventSource: source, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)!
            event.post(tap: .cghidEventTap)
            usleep(150_000)
        }
        usleep(700_000)
        let final = bounds(win), visible = NSScreen.screens[other].visibleFrame
        check(screen(final) == other && abs(final.width - visible.width/2) < 40
              && abs(final.minX - (leftEdge ? visible.minX : visible.midX)) < 40,
              "Rectangle cross-display drag snap: \(final)")
        setBounds(win, original)
    }
}
if CommandLine.arguments.contains("--rectangle-url") {
    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    opener.arguments = ["-g", "nirtab://execute-action?name=left-half"]
    try opener.run(); opener.waitUntilExit()
    usleep(500_000)
    check(opener.terminationStatus == 0 && abs(bounds(win).width - vf.width/2) < 40, "Rectangle URL action")
    setBounds(win, original)
}
if CommandLine.arguments.contains("--rectangle") {
    func rectPress(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)!
            event.flags = [.maskControl, .maskAlternate]
            event.post(tap: .cghidEventTap)
        }
        usleep(400_000)
    }
    rectPress(123)
    check(abs(bounds(win).minX - vf.minX) < 30 && abs(bounds(win).width - vf.width/2) < 40, "Rectangle left half")
    rectPress(124)
    check(abs(bounds(win).minX - vf.midX) < 40 && abs(bounds(win).width - vf.width/2) < 40, "Rectangle right half")
    rectPress(32) // ⌃⌥U: top left
    check(abs(bounds(win).minX - vf.minX) < 30 && abs(bounds(win).minY - (mainTop - vf.maxY)) < 40
          && abs(bounds(win).height - vf.height/2) < 40, "Rectangle top left")
    rectPress(40) // ⌃⌥K: bottom right
    check(abs(bounds(win).minX - vf.midX) < 40 && abs(bounds(win).height - vf.height/2) < 40,
          "Rectangle bottom right")
    rectPress(36) // ⌃⌥Return: maximize
    check(abs(bounds(win).width - vf.width) < 40 && abs(bounds(win).height - vf.height) < 40,
          "Rectangle maximize")
    rectPress(2) // ⌃⌥D: first third
    check(abs(bounds(win).minX - vf.minX) < 30 && abs(bounds(win).width - vf.width/3) < 40,
          "Rectangle first third")
    rectPress(14) // ⌃⌥E: first two thirds
    check(abs(bounds(win).width - vf.width*2/3) < 40, "Rectangle first two thirds")
    rectPress(51) // ⌃⌥Delete: restore original before first layout action
    let restored = bounds(win)
    check(abs(restored.minX - original.minX) < 30 && abs(restored.minY - original.minY) < 30
          && abs(restored.width - original.width) < 40 && abs(restored.height - original.height) < 40,
          "Rectangle restore original")
}
if CommandLine.arguments.contains("--custom") {
    press(18, control: true) // temporary ⌃⌥⌘1 → left half (set customAction1/customKey1 before running)
    let custom = bounds(win)
    check(abs(custom.minX - vf.minX) < 30 && abs(custom.width - vf.width / 2) < 40, "custom shortcut: \(custom)")
}
press(123) // left half
let left = bounds(win)
check(abs(left.minX - vf.minX) < 30 && abs(left.width - vf.width / 2) < 40, "left half: \(left)")
press(124) // right half
let right = bounds(win)
check(abs(right.minX - vf.midX) < 40 && abs(right.width - vf.width / 2) < 40, "right half: \(right)")
press(126) // top half
let top = bounds(win)
check(abs(top.minY - (mainTop - vf.maxY)) < 40 && abs(top.height - vf.height / 2) < 40, "top half: \(top)")
press(125) // bottom half
let bottom = bounds(win)
check(abs(bottom.maxY - (mainTop - vf.minY)) < 40 && abs(bottom.height - vf.height / 2) < 40, "bottom half: \(bottom)")
if NSScreen.screens.count > 1 {
    // The two local displays are side-by-side; exercise both directions.
    let outward: CGKeyCode = start == 0 ? 123 : 124
    press(outward, control: true)
    check(screen(bounds(win)) != start, "moved to other display: \(bounds(win))")
    press(outward == 123 ? 124 : 123, control: true)
    check(screen(bounds(win)) == start, "moved back to original display: \(bounds(win))")
}
setBounds(win, original)
let close = Process()
close.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
close.arguments = ["-e", "tell application \"TextEdit\" to close front document saving no"]
close.standardOutput = FileHandle.nullDevice
try? close.run(); close.waitUntilExit()
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
