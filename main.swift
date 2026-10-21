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

final class ClosureButton: NSButton {
    var handler: () -> Void = {}
    convenience init(symbol: String, tip: String, _ handler: @escaping () -> Void) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        imageScaling = .scaleProportionallyUpOrDown
        isBordered = false
        toolTip = tip
        contentTintColor = .secondaryLabelColor
        self.handler = handler
        target = self
        action = #selector(fire)
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
    }
    @objc func fire() { handler() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// A tile takes the whole hit area (labels would swallow clicks) except its hover buttons.
final class Tile: NSStackView {
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}
    var buttons: NSView?
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 18
        fx.layer?.masksToBounds = true
        grid.orientation = .vertical
        grid.alignment = .centerX
        grid.spacing = 6
        grid.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        grid.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: fx.leadingAnchor), grid.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            grid.topAnchor.constraint(equalTo: fx.topAnchor), grid.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
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
        panel.orderFrontRegardless()
        captureThumbs(live.subtracting([0])) { [weak self] wid, img in
            self?.previews[wid]?.image = NSImage(cgImage: img, size: .zero)
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
            cols = max(1, min(wins.count, Int((f.width * 0.92 - 32) / (tileW + 6))))
            let rows = (wins.count + cols - 1) / cols
            if CGFloat(rows) * (thumbH + 48) + 32 <= f.height * 0.9 || tileW <= 120 { break }
            tileW -= 10
        }
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        previews = [:]
        tiles = wins.enumerated().map { tile($1, $0) }
        for start in stride(from: 0, to: tiles.count, by: cols) {
            let row = NSStackView(views: Array(tiles[start..<min(start + cols, tiles.count)]))
            row.spacing = 6
            grid.addArrangedSubview(row)
        }
        highlight()
        let size = fx.fittingSize
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }

    // AltTab layout: app icon + title (+ status badge, hover buttons) on top, window preview below.
    func tile(_ w: Win, _ i: Int) -> Tile {
        let icon = NSImageView(image: w.app.icon ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let label = NSTextField(labelWithString: w.ax == nil ? (w.app.localizedName ?? "?")
                                : (w.title.isEmpty ? (w.app.localizedName ?? "?") : w.title))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = "\(w.app.localizedName ?? "?") — \(w.title)"
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var header: [NSView] = [icon, label]
        let status = w.ax == nil ? ("plus.rectangle.on.rectangle", "No open window") : w.minimized ? ("arrow.down.right.and.arrow.up.left", "Minimized")
            : w.app.isHidden ? ("eye.slash", "Hidden") : nil
        if let (symbol, tip) = status, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            let b = NSImageView(image: img)
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = tip
            header.append(b)
        }
        // Memory of the whole app (with helpers); macOS has no per-window figure.
        if let bytes = mem[w.app.processIdentifier], bytes > 0 {
            let m = NSTextField(labelWithString: formatBytes(bytes))
            m.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            m.textColor = bytes >= 2 << 30 ? .systemOrange : .secondaryLabelColor
            m.toolTip = "\(w.app.localizedName ?? "App") uses \(formatBytes(bytes)), helper processes included"
            m.setContentCompressionResistancePriority(.required, for: .horizontal)
            header.append(m)
        }
        // Hover buttons, like AltTab's: close, minimize/restore, maximize, quit, force quit.
        var acts: [NSView] = []
        if w.ax != nil {
            acts.append(ClosureButton(symbol: "xmark.circle.fill", tip: "Close window (W)") { [weak self] in self?.act(13, at: i) })
            acts.append(w.minimized
                ? ClosureButton(symbol: "arrow.up.circle.fill", tip: "Restore (M)") { [weak self] in self?.act(46, at: i) }
                : ClosureButton(symbol: "minus.circle.fill", tip: "Minimize (M)") { [weak self] in self?.act(46, at: i) })
            acts.append(ClosureButton(symbol: "arrow.up.left.and.arrow.down.right.circle.fill", tip: "Maximize / restore size (F)") { [weak self] in self?.act(3, at: i) })
        }
        acts.append(ClosureButton(symbol: "power.circle.fill", tip: "Quit \(w.app.localizedName ?? "app") (Q)") { [weak self] in self?.act(12, at: i) })
        let force = ClosureButton(symbol: "bolt.circle.fill", tip: "Force quit \(w.app.localizedName ?? "app") (⇧Q)") { [weak self] in self?.act(12, at: i, force: true) }
        force.contentTintColor = .systemRed
        acts.append(force)
        let buttons = NSStackView(views: acts)
        buttons.spacing = 4
        buttons.isHidden = true
        header.append(buttons)
        let top = NSStackView(views: header)
        top.spacing = 6
        top.widthAnchor.constraint(equalToConstant: tileW - 16).isActive = true

        let preview = NSImageView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.masksToBounds = true
        preview.widthAnchor.constraint(equalToConstant: tileW - 16).isActive = true
        preview.heightAnchor.constraint(equalToConstant: thumbH).isActive = true
        if Prefs.previews, let img = thumb(w.wid) { preview.image = NSImage(cgImage: img, size: .zero) }
        else { preview.image = w.app.icon }  // no picture yet, previews off, or no Screen Recording grant
        if w.wid != 0 { previews[w.wid] = preview }
        preview.alphaValue = w.ax == nil ? 0.45 : (w.minimized || w.app.isHidden) ? 0.7 : 1  // not currently visible

        let t = Tile(views: [top, preview])
        t.buttons = buttons
        t.orientation = .vertical
        t.spacing = 6
        t.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        t.widthAnchor.constraint(equalToConstant: tileW).isActive = true
        t.wantsLayer = true
        t.layer?.cornerRadius = 12
        t.onHover = { [weak self] in
            guard let self, NSEvent.mouseLocation != self.mouseAtShow, self.sel != i else { return }  // ignore the pointer that was already there
            self.sel = i
            self.highlight()
        }
        t.onClick = { [weak self] in self?.sel = i; self?.open = false; self?.commit() }
        return t
    }

    func highlight() {
        for (i, t) in tiles.enumerated() {
            let on = i == sel
            t.layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : .clear
            t.layer?.borderWidth = on ? 2 : 0
            t.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

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
func relaunch() {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
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

    var body: some View {
        Form {
            Section("Shortcut") {
                Picker("Hold key", selection: $hold) {
                    Text("⌘ Command").tag("cmd"); Text("⌥ Option").tag("opt"); Text("⌃ Control").tag("ctrl")
                }
                Text("Hold it and press Tab. ⇧Tab or ← goes back. While open: W close · M minimize/restore · F maximize · H hide · Q quit · ⇧Q force quit · Esc cancel. Hover a tile for the same as buttons.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Windows") {
                Picker("Minimized windows", selection: $minimized) {
                    Text("Show in order").tag("show"); Text("Show at the end").tag("end"); Text("Don't show").tag("hide")
                }
                Toggle("Show hidden apps", isOn: $showHidden)
                Toggle("Show apps with no open window", isOn: $showWindowless)
                TextField("Exclude apps", text: $excluded, prompt: Text("e.g. Finder, Slack"))
            }
            Section("Appearance") {
                Toggle("Window previews", isOn: $previews)
                Toggle("Show app memory", isOn: $memory)
                LabeledContent("Tile size") { Slider(value: $size, in: 160...360, step: 20).frame(width: 200) }
                Picker("Show on", selection: $screen) { Text("Screen with the mouse").tag("mouse"); Text("Main screen").tag("main") }
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { on in
                    let s = SMAppService.mainApp
                    do { try on ? s.register() : s.unregister() } catch { NSSound.beep() }
                }))
                LabeledContent("Accessibility") {
                    if AXIsProcessTrusted() { Text("Granted ✓") } else { Button("Grant…") { grantAX() } }
                }
                LabeledContent("Screen Recording") {
                    if CGPreflightScreenCaptureAccess() { Text("Granted ✓") } else { Button("Grant…") { grantScreen() } }
                }
                LabeledContent("Version") { Text(appVersion) }
                LabeledContent("Update") { Button(sourceDir != nil ? "Rebuild from source & restart" : "Check for updates") { checkForUpdates() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 680)  // grouped Form scrolls, so it has no natural height; NSWindow would collapse it
    }
}

var settingsWindow: NSWindow?
func openSettings() {
    if settingsWindow == nil {
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        w.title = "NirTab Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        settingsWindow = w
    }
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.center()
    settingsWindow?.makeKeyAndOrderFront(nil)
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

func startTap() -> Bool {
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil) else { return false }
    tap = t
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
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
        if !ax { add(menu, "Grant Accessibility…", #selector(doGrantAX)) }
        if !screen { add(menu, "Grant Screen Recording (previews)…", #selector(doGrantScreen)) }
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
    @objc func doGrantAX() { grantAX() }
    @objc func doGrantScreen() { grantScreen() }
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
if menuBar.ax && !menuBar.screen { CGRequestScreenCaptureAccess() }  // previews; icons are shown until granted
if menuBar.working { captureThumbs(onScreenWids()) }  // first pictures, so minimized-later windows have one

// Pick up grants without a manual restart. ponytail: polls a child every 2s only while something is missing.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
    let needAX = !menuBar.ax, needScreen = !menuBar.screen
    if !needAX && !needScreen { t.invalidate(); return }
    if switcher.open { return }
    if (needAX && childSays("--trusted")) || (needScreen && childSays("--screen")) { relaunch() }
}

app.run()
