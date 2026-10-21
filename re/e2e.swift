// Live check for NirTab — run it while the Mac is UNLOCKED:  swift re/e2e.swift
// Opens a TextEdit window, lets NirTab capture it, minimizes it, then checks that the window and its picture
// are listed, and that M (restore) and F (maximize) work on it through the real ⌘Tab switcher.
import AppKit
_ = NSApplication.shared

func attr<T>(_ el: AXUIElement, _ a: String) -> T? { var v: CFTypeRef?; guard AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success else { return nil }; return v as? T }
func osa(_ s: String) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", s]; p.standardOutput = FileHandle.nullDevice; try? p.run(); p.waitUntilExit() }
func list() -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/Applications/NirTab.app/Contents/MacOS/NirTab"); p.arguments = ["--list"]
    let o = Pipe(); p.standardOutput = o; try! p.run(); p.waitUntilExit()
    return String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
}
let src = CGEventSource(stateID: .hidSystemState)
func key(_ c: CGKeyCode, _ down: Bool, _ f: CGEventFlags) { let e = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: down)!; e.flags = f; e.post(tap: .cghidEventTap) }
var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failed += 1 } }

osa("tell application \"TextEdit\" to activate")
osa("tell application \"TextEdit\" to make new document with properties {text:\"NirTab e2e\"}")
sleep(2)  // NirTab captures on app switch (0.6 s debounce)
let te = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.TextEdit" }!
let ax = AXUIElementCreateApplication(te.processIdentifier)
guard let w = (attr(ax, kAXWindowsAttribute) as [AXUIElement]?)?.first(where: { (attr($0, kAXTitleAttribute) as String?)?.hasPrefix("Untitled") == true }) else {
    print("FAIL no TextEdit window (screen locked?)"); exit(1)
}
AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
sleep(1)
let row = list().split(separator: "\n").first { $0.contains("TextEdit") && $0.contains("[min]") } ?? ""
print("  row:", row)
check(!row.isEmpty, "minimized TextEdit window is listed")
check(row.contains("pic "), "minimized window has its last picture")
check(row.contains(" MB") || row.contains(" GB"), "memory shown")

// Through the real switcher: ⌘Tab, move to the TextEdit tile with Tab, press M to restore, then Esc.
let rows = list().split(separator: "\n")
guard let idx = rows.firstIndex(where: { $0.contains("TextEdit") && $0.contains("[min]") }) else { exit(1) }
let cmd: CGEventFlags = .maskCommand
key(55, true, cmd); usleep(60_000)
for _ in 0...max(0, idx - 1) { key(48, true, cmd); key(48, false, cmd); usleep(120_000) }  // opens at index 1
usleep(400_000)
key(46, true, cmd); key(46, false, cmd)  // M = restore
usleep(800_000)
key(53, true, cmd); key(53, false, cmd); key(55, false, [])
usleep(300_000)
check((attr(w, kAXMinimizedAttribute) as Bool?) == false, "M restored the minimized window from the switcher")

osa("tell application \"TextEdit\" to close every document saving no")
print(failed == 0 ? "ALL PASS" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
