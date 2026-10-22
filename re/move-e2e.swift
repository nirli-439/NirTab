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
