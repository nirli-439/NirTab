// NirTab — AltTab-style window switcher for macOS (AX + CGWindowList + ScreenCaptureKit).
// Hold ⌘ (configurable), tap Tab to cycle (⇧Tab / ← back, →). While open: W close window, M minimize/restore,
// F maximize/restore, H hide app, Q quit app, ⇧Q force quit; hover a tile for the same as buttons, click to switch.
// Release the hold key to switch (restores minimized/hidden), Esc to cancel.
import AppKit
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement
import SwiftUI

// Window id for an AX window: private but tiny and stable for 10+ years; AltTab relies on it too.
@_silgen_name("_AXUIElementGetWindow") func _AXUIElementGetWindow(_ el: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
// Which app a helper process belongs to (Chrome renderers, XPC services). Activity Monitor groups the same way.
@_silgen_name("responsibility_get_pid_responsible_for_pid") func responsiblePid(_ pid: pid_t) -> pid_t

// MARK: - Preferences (UserDefaults domain com.nir.nirtab; the Settings window edits the same keys)

let defaults = UserDefaults.standard
defaults.register(defaults: ["hold": "cmd", "minimized": "end", "showHidden": true, "showWindowless": true,
                             "previews": true, "size": 260.0, "screen": "mouse", "excluded": "", "memory": true])

enum Prefs {
    static var holdMask: CGEventFlags {
        switch defaults.string(forKey: "hold") {
        case "opt": return .maskAlternate
        case "ctrl": return .maskControl
        default: return .maskCommand
        }
    }
    static var minimized: String { defaults.string(forKey: "minimized") ?? "end" }  // show | end | hide
    static var showHidden: Bool { defaults.bool(forKey: "showHidden") }
    static var showWindowless: Bool { defaults.bool(forKey: "showWindowless") }
    static var previews: Bool { defaults.bool(forKey: "previews") }
    static var memory: Bool { defaults.bool(forKey: "memory") }
    static var size: CGFloat { CGFloat(defaults.double(forKey: "size")) }
    static var screen: String { defaults.string(forKey: "screen") ?? "mouse" }  // mouse | main
    static var excluded: Set<String> {
        Set((defaults.string(forKey: "excluded") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }
}

// MARK: - Windows

struct Win { let app: NSRunningApplication; let ax: AXUIElement?; let wid: CGWindowID; let title: String; let minimized: Bool }  // ax nil = app with no windows

func attr<T>(_ el: AXUIElement, _ a: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success else { return nil }
    return v as? T
}

// Window z-order, front to back, from the window server: gives true most-recently-used order, like AltTab.
func windowZOrder() -> (byWid: [CGWindowID: Int], byPid: [pid_t: Int]) {
    let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var wids: [CGWindowID: Int] = [:], pids: [pid_t: Int] = [:]
    for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
        if let id = w[kCGWindowNumber as String] as? CGWindowID { wids[id] = wids.count }
        if let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids[pid] == nil { pids[pid] = pids.count }
    }
    return (wids, pids)
}

// Every window of every regular app: standard + dialogs, minimized, hidden apps, and apps with no window at all.
// ponytail: current Space only (AX can't see other Spaces). AltTab brute-forces
//           _AXUIElementCreateWithRemoteToken for other Spaces (~1-5s per app measured here) — add if Spaces get used.
func listWindows() -> [Win] {
    let z = windowZOrder()
    let excluded = Prefs.excluded, mini = Prefs.minimized, showHidden = Prefs.showHidden
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated
            && !excluded.contains(($0.localizedName ?? "").lowercased()) && (showHidden || !$0.isHidden)
    }
    var shown: [Win] = [], parked: [Win] = []  // parked = minimized / hidden / windowless, listed last like AltTab
    for app in apps {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)  // a hung app must not freeze the switcher
        let wins: [AXUIElement] = attr(axApp, kAXWindowsAttribute) ?? []
        let real = wins.filter { [kAXStandardWindowSubrole, kAXDialogSubrole].contains(attr($0, kAXSubroleAttribute) as String?) }
        for w in real {
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(w, &wid)
            let win = Win(app: app, ax: w, wid: wid, title: attr(w, kAXTitleAttribute) ?? "",
                          minimized: (attr(w, kAXMinimizedAttribute) as Bool?) == true)
            if win.minimized && mini == "hide" { continue }
            if (win.minimized && mini == "end") || app.isHidden { parked.append(win) } else { shown.append(win) }
        }
        if real.isEmpty && Prefs.showWindowless { parked.append(Win(app: app, ax: nil, wid: 0, title: "", minimized: false)) }
    }
    shown.sort { (z.byWid[$0.wid] ?? .max) < (z.byWid[$1.wid] ?? .max) }
    parked.sort { (z.byPid[$0.app.processIdentifier] ?? .max) < (z.byPid[$1.app.processIdentifier] ?? .max) }
    return shown + parked
}

func focus(_ w: Win) {
    if w.app.isHidden { w.app.unhide() }
    guard let ax = w.ax else {  // no window: reopen, like clicking the Dock icon
        if let url = w.app.bundleURL { NSWorkspace.shared.openApplication(at: url, configuration: .init()) } else { w.app.activate() }
        return
    }
    if w.minimized { AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(w.app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
    w.app.activate()
}

func closeWindow(_ w: Win) {
    guard let ax = w.ax, let button: AXUIElement = attr(ax, kAXCloseButtonAttribute) else { return }
    AXUIElementPerformAction(button, kAXPressAction as CFString)
}

func frame(_ ax: AXUIElement) -> CGRect? {  // AX coordinates: top-left origin of the main screen
    guard let p: AXValue = attr(ax, kAXPositionAttribute), let s: AXValue = attr(ax, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p, .cgPoint, &pt)
    AXValueGetValue(s, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func setFrame(_ ax: AXUIElement, _ r: CGRect) {
    var pt = r.origin, sz = r.size
    AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pt)!)
    AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &sz)!)
    AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pt)!)  // again: apps clamp the move to the old size
}

// Fill the screen the window is on (not full-screen Space); press again to go back to the old frame.
var framesBeforeMaximize: [CGWindowID: CGRect] = [:]
func toggleMaximize(_ w: Win) {
    guard let ax = w.ax else { return }
    if w.minimized { AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
    guard let r = frame(ax) else { return }
    let mainH = NSScreen.screens[0].frame.height
    let center = CGPoint(x: r.midX, y: mainH - r.midY)  // to Cocoa coordinates
    let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.screens[0]
    let vf = screen.visibleFrame
    let full = CGRect(x: vf.minX, y: mainH - vf.maxY, width: vf.width, height: vf.height)
    if let old = framesBeforeMaximize[w.wid], abs(r.width - full.width) < 40, abs(r.height - full.height) < 40 {
        setFrame(ax, old)
        framesBeforeMaximize[w.wid] = nil
    } else {
        framesBeforeMaximize[w.wid] = r
        setFrame(ax, full)
    }
}

// AX coordinates have a top-left origin; AppKit screens have a bottom-left origin.
func flipY(_ r: CGRect, mainTop: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: mainTop - r.maxY, width: r.width, height: r.height)
}
func screenIndex(for window: CGRect, in screens: [CGRect]) -> Int {
    screens.indices.max { a, b in
        let x = window.intersection(screens[a]), y = window.intersection(screens[b])
        return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
    } ?? 0
}
func nextScreen(_ source: Int, direction: Int64, in screens: [CGRect]) -> Int? {
    let a = screens[source]
    return screens.indices.filter { i in
        let b = screens[i]
        switch direction {
        case 123: return b.midX < a.midX && abs(b.midX - a.midX) > abs(b.midY - a.midY)
        case 124: return b.midX > a.midX && abs(b.midX - a.midX) > abs(b.midY - a.midY)
        case 126: return b.midY > a.midY && abs(b.midY - a.midY) >= abs(b.midX - a.midX)
        default: return b.midY < a.midY && abs(b.midY - a.midY) >= abs(b.midX - a.midX)
        }
    }.min { i, j in
        let x = screens[i], y = screens[j]
        return hypot(x.midX - a.midX, x.midY - a.midY) < hypot(y.midX - a.midX, y.midY - a.midY)
    }
}
func half(_ f: CGRect, direction: Int64) -> CGRect {
    switch direction {
    case 123: return CGRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height)
    case 124: return CGRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height)
    case 126: return CGRect(x: f.minX, y: f.midY, width: f.width, height: f.height / 2)
    default: return CGRect(x: f.minX, y: f.minY, width: f.width, height: f.height / 2)
    }
}
func moveFrontWindow(_ direction: Int64, toDisplay: Bool) {
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
          let main = NSScreen.screens.first else { return }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, 0.2)
    guard let win: AXUIElement = attr(axApp, kAXFocusedWindowAttribute) ?? attr(axApp, kAXMainWindowAttribute),
          let r = frame(win) else { return }
    let screens = NSScreen.screens.map(\.frame)
    let visible = NSScreen.screens.map(\.visibleFrame)
    let current = flipY(r, mainTop: main.frame.maxY)
    let index = screenIndex(for: current, in: screens)
    if toDisplay {
        guard let dest = nextScreen(index, direction: direction, in: screens) else { return }
        let from = visible[index], to = visible[dest]
        let w = min(current.width, to.width), h = min(current.height, to.height)
        let x = to.minX + (to.width - w) * max(0, min(1, (current.minX - from.minX) / max(1, from.width - current.width)))
        let y = to.minY + (to.height - h) * max(0, min(1, (current.minY - from.minY) / max(1, from.height - current.height)))
        setFrame(win, flipY(CGRect(x: x, y: y, width: w, height: h), mainTop: main.frame.maxY))
    } else {
        setFrame(win, flipY(half(visible[index], direction: direction), mainTop: main.frame.maxY))
    }
}

// Five optional bindings. The keycode is physical so a shortcut still works if the input language changes.
let shortcutFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
let windowActions: [(String, String)] = [
    ("none", "Off"), ("left", "Left half"), ("right", "Right half"), ("top", "Top half"), ("bottom", "Bottom half"),
    ("displayLeft", "Display left"), ("displayRight", "Display right"), ("displayUp", "Display up"), ("displayDown", "Display down")
]
func customAction(_ code: Int64, _ flags: CGEventFlags, in store: UserDefaults = defaults) -> String? {
    for i in 1...5 {
        let action = store.string(forKey: "customAction\(i)") ?? "none"
        guard windowActions.contains(where: { $0.0 == action }), action != "none",
              let saved = store.string(forKey: "customKey\(i)")?.split(separator: ":", maxSplits: 2), saved.count == 3,
              let mask = UInt64(saved[0]), let key = Int64(saved[1]),
              mask & ~CGEventFlags.maskShift.rawValue != 0, mask & ~shortcutFlags.rawValue == 0 else { continue }
        if key == code && flags.intersection(shortcutFlags).rawValue == mask { return action }
    }
    return nil
}
func performWindowAction(_ action: String) {
    let keys: [String: Int64] = ["left": 123, "right": 124, "top": 126, "bottom": 125,
                                  "displayLeft": 123, "displayRight": 124, "displayUp": 126, "displayDown": 125]
    guard let key = keys[action] else { return }
    moveFrontWindow(key, toDisplay: action.hasPrefix("display"))
}

if CommandLine.arguments.contains("--test-layout") {
    let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: -1200, y: 0, width: 1200, height: 900)]
    precondition(nextScreen(0, direction: 123, in: displays) == 1)
    precondition(nextScreen(1, direction: 124, in: displays) == 0)
    precondition(nextScreen(0, direction: 124, in: displays) == nil)
    precondition(screenIndex(for: CGRect(x: -1100, y: 100, width: 400, height: 400), in: displays) == 1)
    precondition(half(displays[0], direction: 123) == CGRect(x: 0, y: 0, width: 500, height: 800))
    precondition(half(displays[0], direction: 124) == CGRect(x: 500, y: 0, width: 500, height: 800))
    precondition(half(displays[0], direction: 126) == CGRect(x: 0, y: 400, width: 1000, height: 400))
    precondition(half(displays[0], direction: 125) == CGRect(x: 0, y: 0, width: 1000, height: 400))
    precondition(flipY(flipY(CGRect(x: -800, y: 50, width: 400, height: 300), mainTop: 800), mainTop: 800) == CGRect(x: -800, y: 50, width: 400, height: 300))
    let test = UserDefaults(suiteName: "nirtab-shortcut-test-\(UUID())")!
    test.set("left", forKey: "customAction1")
    test.set("\(CGEventFlags.maskCommand.rawValue):18:1", forKey: "customKey1")
    precondition(customAction(18, .maskCommand, in: test) == "left")
    precondition(customAction(18, [.maskCommand, .maskShift], in: test) == nil)
    test.set("none", forKey: "customAction1")
    precondition(customAction(18, .maskCommand, in: test) == nil)
    print("layout PASS")
    exit(0)
}

// Memory per app, counting its helper processes (Chrome tabs, Electron renderers, XPC services) like Activity Monitor.
// macOS has no per-window memory: one app process draws all its windows. ~15 ms for ~850 processes measured here.
func appMemory() -> [pid_t: UInt64] {
    var pids = [pid_t](repeating: 0, count: 4096)
    let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var out: [pid_t: UInt64] = [:]
    for pid in pids.prefix(max(0, n)) where pid > 0 {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        if ok == 0 { out[responsiblePid(pid), default: 0] += info.ri_phys_footprint }
    }
    return out
}
func formatBytes(_ b: UInt64) -> String {
    b >= 1 << 30 ? String(format: "%.1f GB", Double(b) / Double(1 << 30)) : "\(b >> 20) MB"
}

// MARK: - Thumbnails
// macOS can't screenshot a minimized window (SCK error -3811), so we keep each window's last picture, taken while it
// was visible: on every app switch, every 20 s for the window in front, right before NirTab minimizes it, and when the
// switcher opens. Pictures are also saved to disk, so they survive NirTab updates and restarts.
var thumbs: [CGWindowID: CGImage] = [:]
// Window ids restart at boot, so pictures are kept per boot; older boots are deleted at launch.
let thumbDir: URL = {
    var boot = timeval(), size = MemoryLayout<timeval>.size
    sysctlbyname("kern.boottime", &boot, &size, nil, 0)
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NirTab/thumbs")
    let dir = root.appendingPathComponent("\(boot.tv_sec)")
    for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where old != dir {
        try? FileManager.default.removeItem(at: old)
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()
func thumb(_ wid: CGWindowID) -> CGImage? {
    if let t = thumbs[wid] { return t }
    guard wid != 0, let src = CGImageSourceCreateWithURL(thumbDir.appendingPathComponent("\(wid).jpg") as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    thumbs[wid] = img
    return img
}
func storeThumb(_ wid: CGWindowID, _ img: CGImage) {
    thumbs[wid] = img
    let url = thumbDir.appendingPathComponent("\(wid).jpg")
    DispatchQueue.global(qos: .utility).async {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dst)
    }
}

func onScreenWids() -> Set<CGWindowID> {
    let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return Set(info.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              regular.contains(pid), pid != getpid() else { return nil }
        return w[kCGWindowNumber as String] as? CGWindowID
    })
}

func captureThumbs(_ wids: Set<CGWindowID>, done: @escaping (CGWindowID, CGImage) -> Void = { _, _ in }) {
    guard Prefs.previews, CGPreflightScreenCaptureAccess(), !wids.isEmpty else { return }
    let maxW = Prefs.size * 2  // 2x for Retina
    Task {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        await withTaskGroup(of: Void.self) { g in
            for sw in content.windows where wids.contains(sw.windowID) && sw.isOnScreen {
                g.addTask {
                    let cfg = SCStreamConfiguration()
                    let scale = min(1, maxW / max(sw.frame.width, 1))
                    cfg.width = Int(sw.frame.width * scale)
                    cfg.height = Int(sw.frame.height * scale)
                    cfg.showsCursor = false
                    guard let img = try? await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg) else { return }
                    await MainActor.run { storeThumb(sw.windowID, img); done(sw.windowID, img) }
                }
            }
        }
    }
}

// MARK: - Switcher UI
// Look: dark glass panel with a soft purple glow, rounded cards, a gradient ring + accent glow on the selected card,
// tinted pills (memory, status, key hints) and traffic-light hover buttons.

// Rounded "pill" label: memory, status, key hints.
func pill(_ text: String, symbol: String? = nil, fg: NSColor = .labelColor,
          bg: NSColor = NSColor.white.withAlphaComponent(0.12), size: CGFloat = 10) -> NSView {
    var views: [NSView] = []
    if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size - 1, weight: .semibold)) {
        let iv = NSImageView(image: img)
        iv.contentTintColor = fg
        views.append(iv)
    }
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: .semibold)
    l.textColor = fg
    views.append(l)
    let s = NSStackView(views: views)
    s.spacing = 3
    s.edgeInsets = NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
    s.wantsLayer = true
    s.layer?.backgroundColor = bg.cgColor
    s.layer?.cornerRadius = (size + 7) / 2
    s.setContentCompressionResistancePriority(.required, for: .horizontal)
    s.setContentHuggingPriority(.required, for: .horizontal)
    return s
}

func memoryColor(_ b: UInt64) -> NSColor {
    b >= 4 << 30 ? .systemRed : b >= 2 << 30 ? .systemOrange : b >= 1 << 30 ? .systemYellow : .systemGreen
}

// Round, colored hover button (traffic-light style).
final class ClosureButton: NSButton {
    var handler: () -> Void = {}
    convenience init(symbol: String, tip: String, color: NSColor, size: CGFloat = 22, _ handler: @escaping () -> Void) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: size == 22 ? 9 : 13, weight: .bold))
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        toolTip = tip
        contentTintColor = .white
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = size / 2
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        self.handler = handler
        target = self
        action = #selector(fire)
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    @objc func fire() { handler() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// A card. Takes the whole hit area (labels would swallow clicks) except its hover buttons.
final class Tile: NSStackView {
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}
    var buttons: NSView?
    let ring = CAGradientLayer()      // gradient outline when selected
    let ringMask = CAShapeLayer()
    var isSelected = false { didSet { if oldValue != isSelected { applySelection() } } }

    func setup() {
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        layer?.shadowColor = NSColor.controlAccentColor.cgColor
        layer?.shadowRadius = 16
        layer?.shadowOffset = .zero
        layer?.shadowOpacity = 0
        ring.colors = [NSColor.controlAccentColor, .systemPurple, .systemPink].map(\.cgColor)
        ring.startPoint = CGPoint(x: 0, y: 1)
        ring.endPoint = CGPoint(x: 1, y: 0)
        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.black.cgColor
        ringMask.lineWidth = 2.5
        ring.mask = ringMask
        ring.opacity = 0
        layer?.addSublayer(ring)
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ringMask.path = CGPath(roundedRect: bounds.insetBy(dx: 1.25, dy: 1.25), cornerWidth: 15, cornerHeight: 15, transform: nil)
        CATransaction.commit()
    }
    func applySelection() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            ring.opacity = isSelected ? 1 : 0
            layer?.shadowOpacity = isSelected ? 0.55 : 0
            layer?.backgroundColor = NSColor.white.withAlphaComponent(isSelected ? 0.13 : 0.05).cgColor
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        if let v = super.hitTest(point), v is NSButton { return v }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { buttons?.isHidden = false; onHover() }
    override func mouseMoved(with event: NSEvent) { onHover() }
    override func mouseExited(with event: NSEvent) { buttons?.isHidden = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick() }
}

final class Switcher {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let fx = NSVisualEffectView()
    let grid = NSStackView()
    var wins: [Win] = []
    var tiles: [Tile] = []
    var previews: [CGWindowID: NSImageView] = [:]
    var previewIcons: [CGWindowID: NSView] = [:]
    var sel = 0
    var open = false
    var mouseAtShow = NSPoint.zero
    var tileW: CGFloat = 260
    var thumbH: CGFloat { (tileW * 0.6).rounded() }
    var refreshWork: DispatchWorkItem?
    var mem: [pid_t: UInt64] = [:]

    init() {
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: .darkAqua)  // dark glass in both light and dark mode
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 26
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        // Soft purple/blue glow over the glass.
        let glow = CAGradientLayer()
        glow.colors = [NSColor.systemPurple.withAlphaComponent(0.22), NSColor.systemBlue.withAlphaComponent(0.10), .clear].map(\.cgColor)
        glow.startPoint = CGPoint(x: 0, y: 1)
        glow.endPoint = CGPoint(x: 1, y: 0)
        let tint = NSView()
        tint.layer = glow
        tint.wantsLayer = true
        grid.orientation = .vertical
        grid.alignment = .centerX
        grid.spacing = 10
        grid.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 16, right: 22)
        for v in [tint, grid] {
            v.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: fx.leadingAnchor), v.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                v.topAnchor.constraint(equalTo: fx.topAnchor), v.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            ])
        }
        panel.contentView = fx
        let nc = NSWorkspace.shared.notificationCenter
        // Live refresh: apps quitting/launching (from here, the Dock, anywhere) update the open switcher at once.
        for n in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        }
        // Keep last pictures fresh so windows minimized later still have a preview.
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleThumbRefresh()
        }
        // The window you're working in changes without any app switch; refresh just the frontmost app's windows.
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard self?.open == false, let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            captureThumbs(Set(info.compactMap { w in
                (w[kCGWindowOwnerPID as String] as? pid_t) == front && (w[kCGWindowLayer as String] as? Int) == 0
                    ? w[kCGWindowNumber as String] as? CGWindowID : nil
            }))
        }
    }

    func scheduleThumbRefresh() {
        guard Prefs.previews, !open else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in if self?.open == false { captureThumbs(onScreenWids()) } }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func show(back: Bool) {
        refreshWork?.cancel()
        wins = listWindows()
        guard !wins.isEmpty else { open = false; return }
        let live = Set(wins.map(\.wid))
        mem = Prefs.memory ? appMemory() : [:]
        sel = wins.count == 1 ? 0 : (back ? wins.count - 1 : 1)  // index 0 is the window you're already in
        mouseAtShow = NSEvent.mouseLocation
        render()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        captureThumbs(live.subtracting([0])) { [weak self] wid, img in
            self?.previews[wid]?.image = NSImage(cgImage: img, size: .zero)
            self?.previewIcons[wid]?.isHidden = true
        }
    }

    // Re-read windows while open, keeping the same window selected if it still exists.
    func reload() {
        guard open, !wins.isEmpty else { return }
        let current = selected
        wins = listWindows()
        if Prefs.memory { mem = appMemory() }
        guard !wins.isEmpty else { cancel(); open = false; return }
        sel = current.flatMap { c in wins.firstIndex { $0.app == c.app && $0.wid == c.wid } }
            ?? current.flatMap { c in wins.firstIndex { $0.app == c.app } }
            ?? min(sel, wins.count - 1)
        render()
    }

    func render() {
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let screen = Prefs.screen == "main" ? NSScreen.screens[0] : (mouseScreen ?? NSScreen.screens[0])
        let f = screen.visibleFrame
        // Shrink tiles until everything fits on screen (AltTab does the same).
        tileW = Prefs.size
        var cols = 1
        while true {
            cols = max(1, min(wins.count, Int((f.width * 0.92 - 44) / (tileW + 10))))
            let rows = (wins.count + cols - 1) / cols
            if CGFloat(rows) * (thumbH + 70) + 80 <= f.height * 0.9 || tileW <= 120 { break }
            tileW -= 10
        }
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        previews = [:]
        previewIcons = [:]
        tiles = wins.enumerated().map { tile($1, $0) }
        for start in stride(from: 0, to: tiles.count, by: cols) {
            let row = NSStackView(views: Array(tiles[start..<min(start + cols, tiles.count)]))
            row.spacing = 10
            grid.addArrangedSubview(row)
        }
        grid.addArrangedSubview(hints())
        grid.setCustomSpacing(16, after: grid.arrangedSubviews[grid.arrangedSubviews.count - 2])
        highlight()
        let size = fx.fittingSize
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }

    // Key hints under the cards, like a keyboard legend.
    func hints() -> NSView {
        let hold = ["opt": "⌥", "ctrl": "⌃"][defaults.string(forKey: "hold") ?? ""] ?? "⌘"
        let items = [("\(hold)⇥", "Next"), ("W", "Close"), ("M", "Minimize"), ("F", "Maximize"), ("H", "Hide"), ("Q", "Quit"), ("⇧Q", "Force quit"), ("esc", "Cancel")]
        let views = items.map { k, t -> NSView in
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 10.5, weight: .medium)
            l.textColor = .secondaryLabelColor
            let s = NSStackView(views: [pill(k, fg: .labelColor, bg: NSColor.white.withAlphaComponent(0.14)), l])
            s.spacing = 5
            return s
        }
        let s = NSStackView(views: views)
        s.spacing = 14
        return s
    }

    // Card: app icon, title and app name, memory pill on top; preview with status chip and hover buttons below.
    func tile(_ w: Win, _ i: Int) -> Tile {
        let name = w.app.localizedName ?? "?"
        let icon = NSImageView(image: w.app.icon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let title = NSTextField(labelWithString: w.ax == nil || w.title.isEmpty ? name : w.title)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.toolTip = "\(name) — \(w.title)"
        var texts: [NSView] = [title]
        if w.ax != nil, !w.title.isEmpty, w.title != name {
            let sub = NSTextField(labelWithString: name)
            sub.font = .systemFont(ofSize: 10.5)
            sub.textColor = .secondaryLabelColor
            texts.append(sub)
        }
        for case let t as NSTextField in texts {
            t.lineBreakMode = .byTruncatingTail
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let textStack = NSStackView(views: texts)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var header: [NSView] = [icon, textStack]
        // Memory of the whole app (with helpers); macOS has no per-window figure.
        if let bytes = mem[w.app.processIdentifier], bytes > 0 {
            let c = memoryColor(bytes)
            let m = pill(formatBytes(bytes), symbol: "memorychip", fg: c, bg: c.withAlphaComponent(0.18))
            m.toolTip = "\(name) uses \(formatBytes(bytes)), helper processes included"
            header.append(m)
        }
        let top = NSStackView(views: header)
        top.spacing = 8
        top.widthAnchor.constraint(equalToConstant: tileW - 20).isActive = true

        // Preview area
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.masksToBounds = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        box.widthAnchor.constraint(equalToConstant: tileW - 20).isActive = true
        box.heightAnchor.constraint(equalToConstant: thumbH).isActive = true
        // Big centered app icon underneath; the window picture covers it once there is one.
        let bigIcon = NSImageView(image: w.app.icon ?? NSImage())
        bigIcon.imageScaling = .scaleProportionallyUpOrDown
        bigIcon.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(bigIcon)
        let side = min(88, thumbH * 0.55)
        NSLayoutConstraint.activate([
            bigIcon.centerXAnchor.constraint(equalTo: box.centerXAnchor), bigIcon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            bigIcon.widthAnchor.constraint(equalToConstant: side), bigIcon.heightAnchor.constraint(equalToConstant: side),
        ])
        let preview = NSImageView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        if Prefs.previews, let img = thumb(w.wid) {
            preview.image = NSImage(cgImage: img, size: .zero)
            bigIcon.isHidden = true
        }
        if w.wid != 0 { previews[w.wid] = preview; previewIcons[w.wid] = bigIcon }
        let dim: CGFloat = w.ax == nil ? 0.55 : (w.minimized || w.app.isHidden) ? 0.75 : 1  // not currently visible
        preview.alphaValue = dim
        bigIcon.alphaValue = dim
        var overlays: [(NSView, Bool)] = [(preview, false)]  // (view, pinned top-right instead of filling)

        let status = w.ax == nil ? ("plus.rectangle.on.rectangle", "No windows") : w.minimized ? ("arrow.down.right.and.arrow.up.left", "Minimized")
            : w.app.isHidden ? ("eye.slash", "Hidden") : nil
        var chip: NSView?
        if let (symbol, text) = status {
            chip = pill(text, symbol: symbol, fg: .white, bg: NSColor.black.withAlphaComponent(0.6))
        }

        // Put the destructive action above the other hover controls, away from Close and Quit.
        var acts: [NSView] = []
        if w.ax != nil {
            acts.append(ClosureButton(symbol: "xmark", tip: "Close window (W)", color: .systemRed) { [weak self] in self?.act(13, at: i) })
            acts.append(w.minimized
                ? ClosureButton(symbol: "arrow.up", tip: "Restore (M)", color: .systemYellow) { [weak self] in self?.act(46, at: i) }
                : ClosureButton(symbol: "minus", tip: "Minimize (M)", color: .systemYellow) { [weak self] in self?.act(46, at: i) })
            acts.append(ClosureButton(symbol: "arrow.up.left.and.arrow.down.right", tip: "Maximize / restore size (F)", color: .systemGreen) { [weak self] in self?.act(3, at: i) })
        }
        acts.append(ClosureButton(symbol: "power", tip: "Quit \(name) (Q)", color: NSColor(white: 0.42, alpha: 1)) { [weak self] in self?.act(12, at: i) })
        let forceQuit = ClosureButton(symbol: "bolt.fill", tip: "Force quit \(name) (⇧Q) — unsaved work is lost", color: .systemRed, size: 30) { [weak self] in self?.act(12, at: i, force: true) }
        let row = NSStackView(views: acts)
        row.spacing = 6
        let buttons = NSStackView(views: [row, NSView(), forceQuit])
        buttons.spacing = 6
        buttons.widthAnchor.constraint(equalToConstant: tileW - 36).isActive = true
        buttons.isHidden = true
        overlays.append((buttons, true))

        for (v, corner) in overlays {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
            if corner {
                v.topAnchor.constraint(equalTo: box.topAnchor, constant: 8).isActive = true
                v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8).isActive = true
            } else {
                NSLayoutConstraint.activate([
                    v.leadingAnchor.constraint(equalTo: box.leadingAnchor), v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                    v.topAnchor.constraint(equalTo: box.topAnchor), v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                ])
            }
        }
        if let chip {
            chip.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(chip)
            chip.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8).isActive = true
            chip.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8).isActive = true
        }

        let t = Tile(views: [top, box])
        t.setup()
        t.buttons = buttons
        t.orientation = .vertical
        t.spacing = 8
        t.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        t.widthAnchor.constraint(equalToConstant: tileW).isActive = true
        t.onHover = { [weak self] in
            guard let self, NSEvent.mouseLocation != self.mouseAtShow, self.sel != i else { return }  // ignore the pointer that was already there
            self.sel = i
            self.highlight()
        }
        t.onClick = { [weak self] in self?.sel = i; self?.open = false; self?.commit() }
        return t
    }

    func highlight() { for (i, t) in tiles.enumerated() { t.isSelected = i == sel } }

    var selected: Win? { wins.indices.contains(sel) ? wins[sel] : nil }
    func move(_ d: Int) { guard !wins.isEmpty else { return }; sel = (sel + d + wins.count) % wins.count; highlight() }
    func commit() { panel.orderOut(nil); if let w = selected { focus(w) }; wins = [] }
    func cancel() { panel.orderOut(nil); wins = [] }

    func act(_ key: Int64, at i: Int, force: Bool = false) { sel = i; highlight(); act(key, force: force) }

    // W close, M minimize/restore, F maximize/restore, H hide, Q quit, ⇧Q force quit — on the selected tile,
    // without leaving the switcher.
    func act(_ key: Int64, force: Bool = false) {
        guard let w = selected else { return }
        switch key {
        case 12 where force: w.app.forceTerminate()  // like Force Quit: unsaved work is lost
        case 12: w.app.terminate()  // polite quit: apps with unsaved work may ask first; reload() runs when it really exits
        case 13: closeWindow(w)
        case 46:
            guard let ax = w.ax else { return }
            if !w.minimized { captureThumbs([w.wid]) }  // last picture before it goes away
            let delay = w.minimized ? 0 : 0.15
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, w.minimized ? kCFBooleanFalse : kCFBooleanTrue)
            }
        case 3: toggleMaximize(w)
        case 4: w.app.hide()
        default: return
        }
        // Window changes arrive without a notification; re-read once they land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reload() }
    }
}

// MARK: - Process helpers

if CommandLine.arguments.contains("--list") {  // smoke check: what the switcher would show
    let mem = appMemory()
    for w in listWindows() {
        let state = w.ax == nil ? "[no windows]" : (w.minimized ? "[min] " : "") + w.title
        let pic = thumb(w.wid).map { "pic \($0.width)x\($0.height)" } ?? "no pic"
        print("\(w.app.localizedName ?? "?")\twid=\(w.wid)\t\(formatBytes(mem[w.app.processIdentifier] ?? 0))\t\(pic)\t\(state)")
    }
    exit(0)
}
// macOS caches permission answers per process, so a fresh grant is only visible to a NEW process. Ask a child.
if CommandLine.arguments.contains("--update") { updateFromSource(); exit(0) }  // dev builds: same path as the menu item
if CommandLine.arguments.contains("--trusted") { exit(AXIsProcessTrusted() ? 0 : 1) }
if CommandLine.arguments.contains("--screen") { exit(CGPreflightScreenCaptureAccess() ? 0 : 1) }
func childSays(_ flag: String) -> Bool {
    let p = Process()
    p.executableURL = Bundle.main.executableURL
    p.arguments = [flag]
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}
func relaunch() { relaunch(setup: setupWindow?.isVisible == true) }
func relaunch(setup: Bool) {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
    if setup { cfg.arguments = ["--setup"] }
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in exit(0) }
}
let appVersion = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "dev"))"

// Two ways to update, both keep the Accessibility / Screen Recording grants as long as the new copy has the same
// bundle id, the same signing identity and the same path (/Applications/NirTab.app):
//  - built from source: rebuild from the folder recorded at build time (NirTabSourceDir, local builds only)
//  - downloaded release: fetch the latest GitHub release zip and swap it in
let repo = "nirli-439/NirTab"
let sourceDir: String? = {
    guard let d = Bundle.main.object(forInfoDictionaryKey: "NirTabSourceDir") as? String,
          FileManager.default.fileExists(atPath: d + "/build.sh") else { return nil }
    return d
}()

func updateFromSource() {
    guard let dir = sourceDir else { NSSound.beep(); return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", "cd \"$0\" && nohup ./build.sh > /tmp/nirtab-update.log 2>&1 &", dir]
    try? p.run()
}

func alert(_ title: String, _ text: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.runModal()
}

// Compares "0.10" > "0.9" correctly.
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
        return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
    }
    return false
}

func updateFromGitHub(quiet: Bool = false) {
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: req) { data, _, _ in
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let asset = (json["assets"] as? [[String: Any]])?.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let url = (asset["browser_download_url"] as? String).flatMap(URL.init) else {
            if !quiet { DispatchQueue.main.async { alert("Couldn't check for updates", "No release found at github.com/\(repo).") } }
            return
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(latest, than: current) else {
            if !quiet { DispatchQueue.main.async { alert("NirTab is up to date", "You have \(current), the latest version.") } }
            return
        }
        URLSession.shared.downloadTask(with: url) { file, _, _ in
            guard let file else { return }
            // Unzip next to the app, then swap and relaunch from a detached shell once this process has exited.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nirtab-update-\(latest)")
            try? FileManager.default.removeItem(at: tmp)
            let zip = tmp.appendingPathExtension("zip")
            try? FileManager.default.removeItem(at: zip)
            try? FileManager.default.moveItem(at: file, to: zip)
            let app = Bundle.main.bundlePath
            let script = """
            set -e
            /usr/bin/ditto -x -k "$1" "$2"
            /usr/bin/codesign --verify --deep "$2/NirTab.app"
            while /bin/kill -0 "$4" 2>/dev/null; do sleep 0.2; done
            /bin/rm -rf "$3"
            /usr/bin/ditto "$2/NirTab.app" "$3"
            /usr/bin/xattr -dr com.apple.quarantine "$3" 2>/dev/null || true
            /usr/bin/open "$3"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", script, "nirtab-update", zip.path, tmp.path, app, "\(getpid())"]
            p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            try? p.run()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }.resume()
    }.resume()
}

func checkForUpdates() { sourceDir != nil ? updateFromSource() : updateFromGitHub() }

func grantAX() {
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}
func grantScreen() {
    CGRequestScreenCaptureAccess()
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
}

// MARK: - Settings window
// System Settings-style rows with colored icon tiles, under a gradient hero header with live permission pills.

struct IconTile: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.8), color], startPoint: .top, endPoint: .bottom)))
    }
}

func rowLabel(_ title: String, _ symbol: String, _ color: Color) -> some View {
    Label { Text(title) } icon: { IconTile(symbol: symbol, color: color) }
}

struct Keycap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(minWidth: 24, minHeight: 22)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.tertiary, lineWidth: 0.5))
    }
}

struct StatusPill: View {
    let title: String
    let ok: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                Text(ok ? title : "\(title) — Grant")
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(ok ? Color.green : Color.orange)
            .background(Capsule().fill((ok ? Color.green : Color.orange).opacity(0.15)))
        }
        .buttonStyle(.plain)
        .disabled(ok)
    }
}

var recordingShortcut = false
final class ShortcutButton: NSButton {
    var save: (String) -> Void = { _ in }
    var shortcut = "" { didSet { if !recordingShortcut { showShortcut() } } }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard window?.makeFirstResponder(self) == true else { return }
        recordingShortcut = true
        title = "Press shortcut (Esc cancels)"
    }
    override func resignFirstResponder() -> Bool {
        recordingShortcut = false
        showShortcut()
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty, event.keyCode != 48 else {
            NSSound.beep(); return // don't steal typing (including ⇧ letters) or switcher Tab
        }
        let label = [123: "←", 124: "→", 125: "↓", 126: "↑"][Int(event.keyCode)]
            ?? (event.charactersIgnoringModifiers?.uppercased() ?? "")
        guard !label.isEmpty, label.count <= 2, !label.contains(":") else { NSSound.beep(); return }
        let mask = CGEventFlags(rawValue: UInt64(flags.rawValue) & shortcutFlags.rawValue)
        save("\(mask.rawValue):\(event.keyCode):\(label)")
        window?.makeFirstResponder(nil)
    }
    func showShortcut() {
        guard let saved = shortcut.split(separator: ":", maxSplits: 2).first.flatMap({ UInt64($0) }),
              let label = shortcut.split(separator: ":", maxSplits: 2).last, shortcut.contains(":") else {
            title = "Record…"; return
        }
        let flags = CGEventFlags(rawValue: saved)
        title = "\(flags.contains(.maskControl) ? "⌃" : "")\(flags.contains(.maskAlternate) ? "⌥" : "")\(flags.contains(.maskShift) ? "⇧" : "")\(flags.contains(.maskCommand) ? "⌘" : "")\(label)"
    }
}
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: String
    func makeNSView(context: Context) -> ShortcutButton {
        let b = ShortcutButton(title: "Record…", target: nil, action: nil)
        b.bezelStyle = .rounded
        return b
    }
    func updateNSView(_ b: ShortcutButton, context: Context) {
        b.save = { value = $0 }
        b.shortcut = value
    }
}
if CommandLine.arguments.contains("--test-recorder") {
    _ = NSApplication.shared
    let button = ShortcutButton(title: "Record…", target: nil, action: nil)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: .titled, backing: .buffered, defer: false)
    window.contentView?.addSubview(button)
    var recorded = ""
    button.save = { recorded = $0 }
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    button.mouseDown(with: click)
    precondition(recordingShortcut && window.firstResponder === button)
    let keys: NSEvent.ModifierFlags = [.control, .option, .command]
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: keys, timestamp: 0,
                                 windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1",
                                 isARepeat: false, keyCode: 18)!
    button.keyDown(with: event)
    precondition(recorded == "\(CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue):18:1")
    precondition(!recordingShortcut)
    button.shortcut = recorded
    precondition(button.title == "⌃⌥⌘1")
    print("recorder PASS")
    exit(0)
}
struct CustomShortcutRow: View {
    let index: Int
    @AppStorage var action: String
    @AppStorage var shortcut: String
    init(_ index: Int) {
        self.index = index
        _action = AppStorage(wrappedValue: "none", "customAction\(index)")
        _shortcut = AppStorage(wrappedValue: "", "customKey\(index)")
    }
    var body: some View {
        HStack {
            Text("\(index).").frame(width: 24, alignment: .leading)
            Picker("Action", selection: $action) {
                ForEach(windowActions, id: \.0) { id, name in Text(name).tag(id) }
            }.labelsHidden().frame(maxWidth: .infinity)
            ShortcutRecorder(value: $shortcut).frame(width: 160, height: 26)
            Button("Clear") { shortcut = ""; action = "none" }.disabled(shortcut.isEmpty && action == "none")
        }
    }
}

struct SettingsView: View {
    @AppStorage("hold") var hold = "cmd"
    @AppStorage("minimized") var minimized = "end"
    @AppStorage("showHidden") var showHidden = true
    @AppStorage("showWindowless") var showWindowless = true
    @AppStorage("previews") var previews = true
    @AppStorage("memory") var memory = true
    @AppStorage("size") var size = 260.0
    @AppStorage("screen") var screen = "mouse"
    @AppStorage("excluded") var excluded = ""

    @ObservedObject var h = health
    var holdKey: String { ["opt": "⌥", "ctrl": "⌃"][hold] ?? "⌘" }
    let keys = [("W", "Close window"), ("M", "Minimize"), ("F", "Maximize"), ("H", "Hide app"), ("Q", "Quit app"), ("⇧Q", "Force quit")]

    var header: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
                .shadow(color: .purple.opacity(0.45), radius: 14, y: 5)
            VStack(alignment: .leading, spacing: 6) {
                Text("NirTab")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing))
                Text("Every window, one keystroke away · \(appVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    StatusPill(title: "Accessibility", ok: h.ax, action: openSetup)
                    StatusPill(title: "Screen Recording", ok: h.screen, action: openSetup)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 30)
        .padding(.top, 40)
        .padding(.bottom, 6)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("Shortcut") {
                    Picker(selection: $hold) {
                        Text("⌘ Command").tag("cmd"); Text("⌥ Option").tag("opt"); Text("⌃ Control").tag("ctrl")
                    } label: { rowLabel("Hold key", "command", .blue) }
                    LabeledContent {
                        HStack(spacing: 4) { Keycap(key: holdKey); Text("+").foregroundStyle(.secondary); Keycap(key: "⇥") }
                    } label: { rowLabel("Open switcher", "rectangle.on.rectangle", .indigo) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                        ForEach(keys, id: \.0) { k, t in
                            HStack(spacing: 6) { Keycap(key: k); Text(t).font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Move front window") {
                    LabeledContent("Between displays") { Text("⌃⌥⌘ + ← → ↑ ↓").font(.callout) }
                    LabeledContent("Left / right / top / bottom half") { Text("⌥⌘ + ← → ↑ ↓").font(.callout) }
                }
                Section("Custom shortcuts") {
                    ForEach(1...5, id: \.self) { CustomShortcutRow($0) }
                    Text("Choose an action, click Record, then press its shortcut. Custom shortcuts take priority over built-in ones; the first matching slot wins.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Windows") {
                    Picker(selection: $minimized) {
                        Text("Show in order").tag("show"); Text("Show at the end").tag("end"); Text("Don't show").tag("hide")
                    } label: { rowLabel("Minimized windows", "arrow.down.right.and.arrow.up.left", .orange) }
                    Toggle(isOn: $showHidden) { rowLabel("Show hidden apps", "eye.slash", .gray) }
                    Toggle(isOn: $showWindowless) { rowLabel("Show apps with no window", "plus.rectangle.on.rectangle", .teal) }
                    TextField(text: $excluded, prompt: Text("Finder, Slack")) { rowLabel("Exclude apps", "nosign", .red) }
                }
                Section("Appearance") {
                    Toggle(isOn: $previews) { rowLabel("Window previews", "photo.on.rectangle", .pink) }
                    Toggle(isOn: $memory) { rowLabel("Show app memory", "memorychip", .green) }
                    LabeledContent {
                        Slider(value: $size, in: 160...360, step: 20).frame(width: 200)
                    } label: { rowLabel("Card size", "square.resize", .purple) }
                    Picker(selection: $screen) {
                        Text("Screen with the mouse").tag("mouse"); Text("Main screen").tag("main")
                    } label: { rowLabel("Show on", "display", .blue) }
                }
                Section("General") {
                    Toggle(isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { on in
                        let s = SMAppService.mainApp
                        do { try on ? s.register() : s.unregister() } catch { NSSound.beep() }
                    })) { rowLabel("Launch at login", "power", .gray) }
                    LabeledContent {
                        Button(sourceDir != nil ? "Rebuild & Restart" : "Check for Updates") { checkForUpdates() }
                            .buttonStyle(.borderedProminent)
                    } label: { rowLabel("Updates", "arrow.triangle.2.circlepath", .blue) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 540, height: 780)  // grouped Form scrolls, so it has no natural height; NSWindow would collapse it
        .background(alignment: .top) {
            LinearGradient(stops: [.init(color: .purple.opacity(0.30), location: 0), .init(color: .blue.opacity(0.12), location: 0.22),
                                   .init(color: .clear, location: 0.45)], startPoint: .topLeading, endPoint: .bottom)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

var settingsWindow: NSWindow?
func openSettings() {
    if settingsWindow == nil {
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        w.title = "NirTab Settings"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        settingsWindow = w
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.center()
    settingsWindow?.makeKeyAndOrderFront(nil)
}

// Debug: render the switcher and Settings to PNGs without showing them (layout checks, screenshots).
// --snapshot <prefix> [--demo]: --demo uses made-up windows (no real titles/previews) for public screenshots.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    _ = NSApplication.shared
    let out = CommandLine.arguments.count > i + 1 && !CommandLine.arguments[i + 1].hasPrefix("--") ? CommandLine.arguments[i + 1] : "/tmp/nirtab"
    func save(_ v: NSView, _ name: String, backdrop: Bool) {
        v.layoutSubtreeIfNeeded()
        let b = v.bounds
        guard let rep = v.bitmapImageRepForCachingDisplay(in: b) else { return }
        v.cacheDisplay(in: b, to: rep)
        let img = NSImage(size: b.size)
        img.lockFocus()
        if backdrop {  // stand-in for the blurred desktop behind the glass
            NSGradient(colors: [NSColor(red: 0.12, green: 0.13, blue: 0.24, alpha: 1), NSColor(red: 0.22, green: 0.12, blue: 0.30, alpha: 1)])!
                .draw(in: NSRect(origin: .zero, size: b.size), angle: -45)
        }
        rep.draw(in: NSRect(origin: .zero, size: b.size))
        img.unlockFocus()
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try? png.write(to: URL(fileURLWithPath: "\(out)-\(name).png"))
        print("wrote \(out)-\(name).png")
    }
    let s = Switcher()
    s.wins = listWindows()
    s.mem = appMemory()
    if CommandLine.arguments.contains("--demo") {
        // No window titles or pictures: titles become the app name, previews fall back to the app icon.
        s.wins = Array(s.wins.filter { $0.ax != nil }.prefix(6)).enumerated().map { j, w in
            Win(app: w.app, ax: w.ax, wid: 0, title: w.app.localizedName ?? "", minimized: j == 4)
        }
    }
    s.sel = min(1, max(0, s.wins.count - 1))
    s.open = true
    s.render()
    if s.tiles.indices.contains(s.sel) { s.tiles[s.sel].buttons?.isHidden = false }
    save(s.fx, "switcher", backdrop: true)
    // SwiftUI Form controls don't draw offscreen, so show the real Settings window briefly and capture it with
    // ScreenCaptureKit (needs the app's Screen Recording grant: run via `open -n NirTab.app --args --snapshot ...`).
    func capture(_ window: NSWindow?, _ name: String) {
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))  // let the checklist's first refresh land
        let wid = CGWindowID(window?.windowNumber ?? 0)
        var done = false
        Task {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let sw = content.windows.first(where: { $0.windowID == wid }) {
                let cfg = SCStreamConfiguration()
                cfg.width = Int(sw.frame.width * 2)
                cfg.height = Int(sw.frame.height * 2)
                cfg.showsCursor = false
                cfg.ignoreShadowsSingleWindow = true
                cfg.scalesToFit = true
                if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg) {
                    let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
                    try? png.write(to: URL(fileURLWithPath: "\(out)-\(name).png"))
                    print("wrote \(out)-\(name).png")
                }
            } else { print("\(name) capture failed (Screen Recording?)") }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        window?.orderOut(nil)
    }
    startedTap = true  // snapshot process doesn't own the tap; show the checklist as the running app sees it
    openSettings(); capture(settingsWindow, "settings")
    openSetup(); capture(setupWindow, "setup")
    exit(0)
}

// MARK: - Setup checklist
// Opens at launch whenever something is missing, and stays open until every item is green. Each item is checked by a
// fresh child process, because a running process keeps its first answer, and because System Settings can show a
// switch as on while the grant is tied to an older signature. Only a new process sees what macOS really enforces.

final class Health: ObservableObject {
    @Published var ax = AXIsProcessTrusted()
    @Published var screen = CGPreflightScreenCaptureAccess()
    @Published var tap = false
    @Published var inApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")
    @Published var login = SMAppService.mainApp.status == .enabled
    var required: Bool { ax && screen && tap }
    var everything: Bool { required && inApplications && login }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ax = childSays("--trusted"), screen = childSays("--screen")
            DispatchQueue.main.async {
                self.ax = ax
                self.screen = screen
                self.tap = startedTap
                self.inApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")
                self.login = SMAppService.mainApp.status == .enabled
            }
        }
    }
}
enum Shared { static let health = Health() }  // static = lazy: safe to touch from code that runs earlier in this file
var health: Health { Shared.health }

struct CheckRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let ok: Bool
    let required: Bool
    let fixTitle: String
    let fix: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if !required {
                        Text("Optional").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(.quaternary))
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if ok {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(fixTitle, action: fix)
                    .buttonStyle(.borderedProminent)
                    .tint(required ? .orange : .blue)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(ok ? Color.green.opacity(0.35) : (required ? Color.orange.opacity(0.45) : Color.clear), lineWidth: 1))
        .animation(.spring(duration: 0.35), value: ok)
    }
}

var holdKeySymbol: String { ["opt": "⌥", "ctrl": "⌃"][defaults.string(forKey: "hold") ?? ""] ?? "⌘" }

struct SetupView: View {
    @ObservedObject var h = health
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var done: Int { [h.ax, h.screen, h.tap, h.inApplications, h.login].filter { $0 }.count }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    .shadow(color: .purple.opacity(0.45), radius: 12, y: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(h.required ? "You're all set" : "Set up NirTab")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing))
                    Text(h.required ? "Hold \(holdKeySymbol) and press Tab to see every window." : "Turn these on to let NirTab work. This window updates by itself.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            // Progress: custom bar, because ProgressView ignores .tint on macOS.
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: h.required ? [.green, .mint] : [.purple, .blue], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * CGFloat(done) / 5)
                }
            }
            .frame(height: 6)
            .animation(.spring(duration: 0.4), value: done)

            VStack(spacing: 10) {
                CheckRow(symbol: "hand.raised.fill", color: .blue, title: "Accessibility",
                         detail: "Lists windows, switches and moves them, and catches \(holdKeySymbol)Tab.",
                         ok: h.ax, required: true, fixTitle: "Open Settings", fix: grantAX)
                CheckRow(symbol: "rectangle.dashed.badge.record", color: .pink, title: "Screen Recording",
                         detail: "Live previews of each window. Images stay on this Mac.",
                         ok: h.screen, required: true, fixTitle: "Open Settings", fix: grantScreen)
                CheckRow(symbol: "keyboard", color: .indigo, title: "Keyboard shortcut active",
                         detail: h.tap ? "Listening for \(holdKeySymbol)Tab." : h.ax ? "Restart NirTab once to start listening." : "Starts after Accessibility is on.",
                         ok: h.tap, required: true, fixTitle: "Restart", fix: relaunch)
                CheckRow(symbol: "folder.fill", color: .teal, title: "Installed in Applications",
                         detail: "Keeps permissions and updates working.",
                         ok: h.inApplications, required: false, fixTitle: "Move", fix: moveToApplications)
                CheckRow(symbol: "power", color: .gray, title: "Launch at login",
                         detail: "Start NirTab automatically when you log in.",
                         ok: h.login, required: false, fixTitle: "Turn On", fix: {
                             try? SMAppService.mainApp.register()
                             health.refresh()
                         })
            }

            HStack {
                if !h.required {
                    Text("A switch that's already on but still shows here? Turn it off and on again: macOS may be holding a grant for an older copy.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(h.required ? "Done" : "Finish later") { setupWindow?.close() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(h.required ? .green : .gray)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(width: 560)
        .background(alignment: .top) {
            LinearGradient(stops: [.init(color: .purple.opacity(0.25), location: 0), .init(color: .clear, location: 0.5)],
                           startPoint: .topLeading, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .onReceive(timer) { _ in health.refresh() }
        .onAppear { health.refresh() }
    }
}

func moveToApplications() {
    let dest = "/Applications/NirTab.app"
    let src = Bundle.main.bundlePath
    guard src != dest else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", "while /bin/kill -0 \"$3\" 2>/dev/null; do sleep 0.2; done; /bin/rm -rf \"$2\" && /usr/bin/ditto \"$1\" \"$2\" && /usr/bin/open \"$2\"",
                   "move", src, dest, "\(getpid())"]
    try? p.run()
    NSApp.terminate(nil)
}

var setupWindow: NSWindow?
func openSetup() {
    if setupWindow == nil {
        let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView()))
        w.title = "NirTab Setup"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        setupWindow = w
    }
    NSApp.activate(ignoringOtherApps: true)
    setupWindow?.center()
    setupWindow?.makeKeyAndOrderFront(nil)
}

// MARK: - Keyboard

let switcher = Switcher()
var tap: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let held = event.flags.contains(Prefs.holdMask)
    let modifiers = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
    if recordingShortcut && settingsWindow?.isKeyWindow == true { return Unmanaged.passUnretained(event) }
    recordingShortcut = false
    if !switcher.open, let action = customAction(code, modifiers), type == .keyDown || type == .keyUp {
        if type == .keyDown { DispatchQueue.main.async { performWindowAction(action) } }
        return nil
    }
    if !switcher.open && [123, 124, 125, 126].contains(code),
       modifiers == [.maskAlternate, .maskCommand] || modifiers == [.maskControl, .maskAlternate, .maskCommand] {
        if type == .keyDown {
            let display = modifiers.contains(.maskControl)
            DispatchQueue.main.async { moveFrontWindow(code, toDisplay: display) }
        }
        if type == .keyDown || type == .keyUp { return nil }
    }
    // State flips here, synchronously; heavy AX work goes to the next runloop turn so the tap never times out.
    switch type {
    case .keyDown where code == 48 && held:  // hold+Tab
        let back = event.flags.contains(.maskShift)
        if switcher.open {
            DispatchQueue.main.async { switcher.move(back ? -1 : 1) }
        } else {
            switcher.open = true
            DispatchQueue.main.async { switcher.show(back: back) }
        }
        return nil
    case .keyUp where code == 48 && held:
        return nil
    case .keyDown where switcher.open && (code == 123 || code == 124):  // ← →
        DispatchQueue.main.async { switcher.move(code == 123 ? -1 : 1) }
        return nil
    case .keyDown where switcher.open && [12, 13, 46, 3, 4].contains(code):  // Q W M F H → act on selected, never the frontmost app
        let force = event.flags.contains(.maskShift)
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { DispatchQueue.main.async { switcher.act(code, force: force) } }
        return nil
    case .keyUp where switcher.open && [12, 13, 46, 3, 4, 123, 124].contains(code):
        return nil
    case .keyDown where code == 53 && switcher.open:  // Esc
        switcher.open = false
        DispatchQueue.main.async { switcher.cancel() }
        return nil
    case .flagsChanged where !held && switcher.open:  // hold key released
        switcher.open = false
        DispatchQueue.main.async { switcher.commit() }
    default: break
    }
    return Unmanaged.passUnretained(event)
}

var startedTap = false
func startTap() -> Bool {
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil) else { return false }
    tap = t
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    startedTap = true
    return true
}

// MARK: - Menu bar (always present, even before permissions)

final class MenuBar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let ax = AXIsProcessTrusted()
    let screen = CGPreflightScreenCaptureAccess()
    var working = false

    override init() {
        super.init()
        let icon = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "NirTab")
        icon?.isTemplate = true  // follows light/dark menu bar
        item.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let key = ["opt": "⌥", "ctrl": "⌃"][defaults.string(forKey: "hold") ?? ""] ?? "⌘"
        let head = NSMenuItem(title: working ? "NirTab \(appVersion) — hold \(key), press Tab" : "NirTab — needs Accessibility to work", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(settings), key: ",")
        let check = add(menu, health.required ? "Setup Checklist ✓" : "⚠︎ Finish Setup…", #selector(setup))
        if !health.required { check.attributedTitle = NSAttributedString(string: "⚠︎ Finish Setup…", attributes: [.foregroundColor: NSColor.systemOrange]) }
        let login = add(menu, "Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add(menu, sourceDir != nil ? "Update (rebuild from source)" : "Check for Updates…", #selector(update))
        add(menu, "Restart NirTab", #selector(restart))
        add(menu, "Quit NirTab", #selector(quit), key: "q")
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
        return i
    }

    @objc func settings() { openSettings() }
    @objc func setup() { openSetup() }
    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do { try s.status == .enabled ? s.unregister() : s.register() } catch { NSSound.beep(); print("NirTab: login item: \(error)") }
    }
    @objc func update() { checkForUpdates() }
    @objc func restart() { relaunch() }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Start

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// One instance only: a relaunch or double-open replaces the old copy instead of fighting it for the shortcut.
for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "") where other != .current { other.forceTerminate() }

let menuBar = MenuBar()
menuBar.working = menuBar.ax && startTap()
if !menuBar.ax {
    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    print("NirTab: waiting for Accessibility (System Settings → Privacy & Security)…")
}
if menuBar.working { captureThumbs(onScreenWids()) }  // first pictures, so minimized-later windows have one
health.tap = startedTap
// Show the checklist whenever a required item is missing (verified by a fresh process, not the cached answer).
DispatchQueue.global().async {
    let ok = childSays("--trusted") && childSays("--screen")
    DispatchQueue.main.async { if !ok || !startedTap || CommandLine.arguments.contains("--setup") { openSetup() } }
}

// Pick up grants without a manual restart. ponytail: polls a child every 2s only while something is missing.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
    let needAX = !menuBar.ax, needScreen = !menuBar.screen
    if !needAX && !needScreen { t.invalidate(); return }
    if switcher.open { return }
    // Relaunch (with the checklist reopened) once a missing grant lands, so this process picks it up.
    if (needAX && childSays("--trusted")) || (needScreen && childSays("--screen")) { relaunch(setup: true) }
}

app.run()
