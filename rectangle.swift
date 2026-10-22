import AppKit
import SwiftUI

// Independent geometry for Rectangle-style sizes. Rects are in AppKit (bottom-left) coordinates.
let rectangleActions: [(String, String)] = [
    ("left-half", "Left Half"), ("right-half", "Right Half"), ("center-half", "Center Half"),
    ("top-half", "Top Half"), ("bottom-half", "Bottom Half"),
    ("top-left", "Top Left"), ("top-right", "Top Right"), ("bottom-left", "Bottom Left"), ("bottom-right", "Bottom Right"),
    ("first-third", "First Third"), ("center-third", "Center Third"), ("last-third", "Last Third"),
    ("first-two-thirds", "First Two Thirds"), ("center-two-thirds", "Center Two Thirds"), ("last-two-thirds", "Last Two Thirds"),
    ("maximize", "Maximize"), ("almost-maximize", "Almost Maximize"), ("maximize-height", "Maximize Height"),
    ("smaller", "Smaller"), ("larger", "Larger"), ("center", "Center"), ("center-prominently", "Center Prominently"),
    ("restore", "Restore"), ("next-display", "Next Display"), ("previous-display", "Previous Display"),
    ("move-left", "Move Left"), ("move-right", "Move Right"), ("move-up", "Move Up"), ("move-down", "Move Down"),
    ("first-fourth", "First Fourth"), ("second-fourth", "Second Fourth"), ("third-fourth", "Third Fourth"),
    ("last-fourth", "Last Fourth"), ("first-three-fourths", "First Three Fourths"),
    ("center-three-fourths", "Center Three Fourths"), ("last-three-fourths", "Last Three Fourths"),
    ("top-left-sixth", "Top Left Sixth"), ("top-center-sixth", "Top Center Sixth"), ("top-right-sixth", "Top Right Sixth"),
    ("bottom-left-sixth", "Bottom Left Sixth"), ("bottom-center-sixth", "Bottom Center Sixth"), ("bottom-right-sixth", "Bottom Right Sixth"),
    ("top-left-ninth", "Top Left Ninth"), ("top-center-ninth", "Top Center Ninth"), ("top-right-ninth", "Top Right Ninth"),
    ("middle-left-ninth", "Middle Left Ninth"), ("middle-center-ninth", "Middle Center Ninth"), ("middle-right-ninth", "Middle Right Ninth"),
    ("bottom-left-ninth", "Bottom Left Ninth"), ("bottom-center-ninth", "Bottom Center Ninth"), ("bottom-right-ninth", "Bottom Right Ninth"),
    ("top-left-third", "Top Left Third"), ("top-right-third", "Top Right Third"),
    ("bottom-left-third", "Bottom Left Third"), ("bottom-right-third", "Bottom Right Third"),
    ("top-left-eighth", "Top Left Eighth"), ("top-center-left-eighth", "Top Center Left Eighth"),
    ("top-center-right-eighth", "Top Center Right Eighth"), ("top-right-eighth", "Top Right Eighth"),
    ("bottom-left-eighth", "Bottom Left Eighth"), ("bottom-center-left-eighth", "Bottom Center Left Eighth"),
    ("bottom-center-right-eighth", "Bottom Center Right Eighth"), ("bottom-right-eighth", "Bottom Right Eighth"),
    ("tile-all", "Tile All"), ("tile-rows", "Tile Rows"), ("tile-columns", "Tile Columns"),
    ("cascade-all", "Cascade All"), ("cascade-active-app", "Cascade Active App"),
    ("reverse-all", "Reverse All"), ("cycle-stacked-windows", "Cycle Stacked Windows"),
    ("cycle-stacked-windows-backward", "Cycle Stacked Windows Backward"), ("specified", "Specified Size")
] + """
left-todo right-todo double-height-up double-height-down double-width-left double-width-right
halve-height-up halve-height-down halve-width-left halve-width-right
larger-width smaller-width larger-height smaller-height tile-active-app
top-vertical-third middle-vertical-third bottom-vertical-third top-vertical-two-thirds bottom-vertical-two-thirds
top-left-twelfth top-center-left-twelfth top-center-right-twelfth top-right-twelfth
middle-left-twelfth middle-center-left-twelfth middle-center-right-twelfth middle-right-twelfth
bottom-left-twelfth bottom-center-left-twelfth bottom-center-right-twelfth bottom-right-twelfth
top-left-sixteenth top-center-left-sixteenth top-center-right-sixteenth top-right-sixteenth
upper-middle-left-sixteenth upper-middle-center-left-sixteenth upper-middle-center-right-sixteenth upper-middle-right-sixteenth
lower-middle-left-sixteenth lower-middle-center-left-sixteenth lower-middle-center-right-sixteenth lower-middle-right-sixteenth
bottom-left-sixteenth bottom-center-left-sixteenth bottom-center-right-sixteenth bottom-right-sixteenth
display-one display-two display-three display-four display-five display-six display-seven display-eight display-nine
first-vertical-eighth second-vertical-eighth third-vertical-eighth fourth-vertical-eighth
fifth-vertical-eighth sixth-vertical-eighth seventh-vertical-eighth last-vertical-eighth
first-vertical-sixth second-vertical-sixth third-vertical-sixth fourth-vertical-sixth fifth-vertical-sixth last-vertical-sixth
""".split(whereSeparator: \.isWhitespace).map { id in
    (String(id), id.split(separator: "-").map { $0.capitalized }.joined(separator: " "))
}

// Rectangle's recommended defaults; the Spectacle preset is also available.
let rectangleRecommended: [String: (CGEventFlags, Int64)] = {
    let ca: CGEventFlags = [.maskControl, .maskAlternate]
    let cas: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
    let cac: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    return ["left-half": (ca, 123), "right-half": (ca, 124), "top-half": (ca, 126), "bottom-half": (ca, 125),
            "top-left": (ca, 32), "top-right": (ca, 34), "bottom-left": (ca, 38), "bottom-right": (ca, 40),
            "maximize": (ca, 36), "maximize-height": (cas, 126), "previous-display": (cac, 123),
            "next-display": (cac, 124), "larger": (ca, 24), "smaller": (ca, 27), "center": (ca, 8),
            "restore": (ca, 51), "first-third": (ca, 2), "first-two-thirds": (ca, 14),
            "center-third": (ca, 3), "last-two-thirds": (ca, 17), "last-third": (ca, 5),
            "center-two-thirds": (ca, 15)]
}()
let rectangleSpectacle: [String: (CGEventFlags, Int64)] = {
    let co: CGEventFlags = [.maskCommand, .maskAlternate]
    let cas: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]
    let cac: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    let ccs: CGEventFlags = [.maskControl, .maskCommand, .maskShift]
    let cc: CGEventFlags = [.maskControl, .maskCommand]
    return ["left-half": (co, 123), "right-half": (co, 124), "top-half": (co, 126), "bottom-half": (co, 125),
            "maximize": (co, 3), "maximize-height": (cas, 126), "previous-display": (cac, 123),
            "next-display": (cac, 124), "larger": (cas, 124), "smaller": (cas, 123), "center": (co, 8),
            "top-left": (cc, 123), "top-right": (cc, 124), "bottom-left": (ccs, 123),
            "bottom-right": (ccs, 124), "restore": ([.maskControl, .maskAlternate], 51)]
}()
func rectangleDefaultShortcut(_ action: String, in store: UserDefaults = defaults) -> String {
    guard let (flags, key) = (store.bool(forKey: "rectangleSpectacle") ? rectangleSpectacle : rectangleRecommended)[action]
    else { return "" }
    let label: String = [123: "←", 124: "→", 125: "↓", 126: "↑", 36: "↩", 51: "⌫"][key]
        ?? [32: "U", 34: "I", 38: "J", 40: "K", 24: "=", 27: "-", 3: "F", 8: "C", 2: "D", 14: "E", 17: "T", 5: "G", 15: "R"][key] ?? "?"
    return "\(flags.rawValue):\(key):\(label)"
}
func rectangleActionURL(_ url: URL) -> String? {
    guard url.scheme == "nirtab", url.host == "execute-action",
          let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "name" })?.value,
          rectangleActions.contains(where: { $0.0 == name }) else { return nil }
    return name
}
func rectangleShortcut(_ code: Int64, _ flags: CGEventFlags, in store: UserDefaults = defaults) -> String? {
    for (action, _) in rectangleActions {
        let value = store.string(forKey: "rectKey.\(action)") ?? "default"
        let saved = value == "default" ? rectangleDefaultShortcut(action, in: store) : value
        let parts = saved.split(separator: ":", maxSplits: 2)
        if parts.count == 3, let mask = UInt64(parts[0]), let key = Int64(parts[1]),
           key == code && flags.intersection(shortcutFlags).rawValue == mask { return action }
    }
    return nil
}
struct RectangleShortcutRow: View {
    let action: String
    let title: String
    @AppStorage var custom: String
    init(_ action: String, _ title: String) {
        self.action = action; self.title = title
        _custom = AppStorage(wrappedValue: "default", "rectKey.\(action)")
    }
    var body: some View {
        HStack {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            ShortcutRecorder(value: Binding(get: { custom == "default" ? rectangleDefaultShortcut(action) : custom },
                                            set: { custom = $0 })).frame(width: 145, height: 26)
            Button("Reset") { custom = "default" }.disabled(custom == "default")
            Button("Clear") { custom = "" }.disabled(custom.isEmpty)
        }
    }
}

func rectangleTarget(_ action: String, screen f: CGRect, current r: CGRect) -> CGRect? {
    func area(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: f.minX + f.width * x, y: f.minY + f.height * y, width: f.width * w, height: f.height * h)
    }
    let parts = action.split(separator: "-").map(String.init)
    if action.hasSuffix("-twelfth") || action.hasSuffix("-sixteenth") {
        let cols = 4, rows = action.hasSuffix("-twelfth") ? 3 : 4
        let col = action.contains("-center-left-") ? 1 : action.contains("-center-right-") ? 2 : action.contains("-right-") ? 3 : 0
        let row = action.hasPrefix("top-") ? rows - 1 : action.hasPrefix("upper-middle-") ? 2
            : action.hasPrefix("lower-middle-") || action.hasPrefix("middle-") ? 1 : 0
        return area(CGFloat(col) / CGFloat(cols), CGFloat(row) / CGFloat(rows), 1 / CGFloat(cols), 1 / CGFloat(rows))
    }
    if action.contains("-vertical-eighth") || action.contains("-vertical-sixth") {
        let n = action.hasSuffix("eighth") ? 8 : 6
        let names = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "last"]
        let i = names.firstIndex(of: parts[0]) ?? n - 1
        return area(0, CGFloat(n - 1 - i) / CGFloat(n), 1, 1 / CGFloat(n))
    }
    if action.hasSuffix("-eighth"), action.hasPrefix("top-") || action.hasPrefix("bottom-") {
        let col = action.contains("-center-left-") ? 1 : action.contains("-center-right-") ? 2 : action.contains("-right-") ? 3 : 0
        return area(CGFloat(col) / 4, action.hasPrefix("top-") ? 0.5 : 0, 0.25, 0.5)
    }
    if parts.count >= 2, let place = ["left": 0, "center": 1, "right": 2].first(where: { parts.contains($0.key) })?.value,
       let row = ["top": 2, "middle": 1, "bottom": 0].first(where: { parts.contains($0.key) })?.value {
        if parts.contains("sixth") { return area(CGFloat(place) / 3, CGFloat(row == 2 ? 1 : 0) / 2, 1/3, 1/2) }
        if parts.contains("ninth") { return area(CGFloat(place) / 3, CGFloat(row) / 3, 1/3, 1/3) }
        if parts.contains("third") { return area(CGFloat(place == 2 ? 1 : 0) / 2, CGFloat(row == 2 ? 2 : 0) / 3, 1/2, 1/3) }
    }
    if parts.count == 2, let x = ["left": 0.0, "right": 0.5].first(where: { parts.contains($0.key) })?.value,
       let y = ["top": 0.5, "bottom": 0.0].first(where: { parts.contains($0.key) })?.value { return area(x, y, 0.5, 0.5) }
    let wide = f.width >= f.height
    func band(_ x: CGFloat, _ w: CGFloat) -> CGRect { wide ? area(x, 0, w, 1) : area(0, 1 - x - w, 1, w) }
    switch action {
    case "left-half": return area(0, 0, 0.5, 1)
    case "right-half": return area(0.5, 0, 0.5, 1)
    case "center-half": return area(0.25, 0, 0.5, 1)
    case "top-half": return area(0, 0.5, 1, 0.5)
    case "bottom-half": return area(0, 0, 1, 0.5)
    case "first-third": return band(0, 1/3)
    case "center-third": return band(1/3, 1/3)
    case "last-third": return band(2/3, 1/3)
    case "first-two-thirds": return band(0, 2/3)
    case "center-two-thirds": return band(1/6, 2/3)
    case "last-two-thirds": return band(1/3, 2/3)
    case "top-vertical-third": return area(0, 2/3, 1, 1/3)
    case "middle-vertical-third": return area(0, 1/3, 1, 1/3)
    case "bottom-vertical-third": return area(0, 0, 1, 1/3)
    case "top-vertical-two-thirds": return area(0, 1/3, 1, 2/3)
    case "bottom-vertical-two-thirds": return area(0, 0, 1, 2/3)
    case "first-fourth": return band(0, 0.25)
    case "second-fourth": return band(0.25, 0.25)
    case "third-fourth": return band(0.5, 0.25)
    case "last-fourth": return band(0.75, 0.25)
    case "first-three-fourths": return band(0, 0.75)
    case "center-three-fourths": return band(0.125, 0.75)
    case "last-three-fourths": return band(0.25, 0.75)
    case "maximize": return f
    case "left-todo": return area(0, 0, 0.2, 1)
    case "right-todo": return area(0.8, 0, 0.2, 1)
    case "almost-maximize": return f.insetBy(dx: f.width * 0.04, dy: f.height * 0.04)
    case "maximize-height": return CGRect(x: r.minX, y: f.minY, width: r.width, height: f.height)
    case "center": return CGRect(x: f.midX - r.width / 2, y: f.midY - r.height / 2, width: r.width, height: r.height)
    case "center-prominently": return CGRect(x: f.midX - r.width / 2, y: f.minY + f.height * 0.57 - r.height / 2, width: r.width, height: r.height)
    case "move-left": return CGRect(x: f.minX, y: r.minY, width: r.width, height: r.height)
    case "move-right": return CGRect(x: f.maxX - r.width, y: r.minY, width: r.width, height: r.height)
    case "move-up": return CGRect(x: r.minX, y: f.maxY - r.height, width: r.width, height: r.height)
    case "move-down": return CGRect(x: r.minX, y: f.minY, width: r.width, height: r.height)
    case "smaller", "larger":
        let factor: CGFloat = action == "smaller" ? 0.85 : 1.15
        let w = min(f.width, r.width * factor), h = min(f.height, r.height * factor)
        return CGRect(x: max(f.minX, min(r.midX - w / 2, f.maxX - w)),
                      y: max(f.minY, min(r.midY - h / 2, f.maxY - h)), width: w, height: h)
    case "larger-width", "smaller-width", "larger-height", "smaller-height":
        let factor: CGFloat = action.hasPrefix("larger") ? 1.15 : 0.85
        if action.hasSuffix("width") {
            let w = min(f.width, r.width * factor)
            return CGRect(x: max(f.minX, min(r.midX - w/2, f.maxX - w)), y: r.minY, width: w, height: r.height)
        }
        let h = min(f.height, r.height * factor)
        return CGRect(x: r.minX, y: max(f.minY, min(r.midY - h/2, f.maxY - h)), width: r.width, height: h)
    case "double-height-up", "double-height-down", "halve-height-up", "halve-height-down":
        let h = min(f.height, r.height * (action.hasPrefix("double") ? 2 : 0.5))
        let y = action.hasSuffix("up") ? max(f.minY, min(r.minY, f.maxY - h)) : min(f.maxY - h, max(f.minY, r.maxY - h))
        return CGRect(x: r.minX, y: y, width: r.width, height: h)
    case "double-width-left", "double-width-right", "halve-width-left", "halve-width-right":
        let w = min(f.width, r.width * (action.hasPrefix("double") ? 2 : 0.5))
        let x = action.hasSuffix("left") ? min(f.maxX - w, max(f.minX, r.maxX - w)) : max(f.minX, min(r.minX, f.maxX - w))
        return CGRect(x: x, y: r.minY, width: w, height: r.height)
    default: return nil
    }
}

var rectangleOriginalFrames: [CGWindowID: CGRect] = [:]
var rectangleTileStep: [String: Int] = [:]
var rectangleDragStart: CGPoint?
var rectangleDragTarget: String?
var rectangleDragScreen: CGRect?
var rectangleDragThird: String?
var rectangleDragWindow: CGWindowID = 0
var rectangleDragOriginal: CGRect?
var rectangleFootprint: NSPanel?

func rectangleSnapAction(_ point: CGPoint, screen f: CGRect) -> String? {
    let edge: CGFloat = 18, corner: CGFloat = min(f.width, f.height) * 0.09
    let nearLeft = point.x <= f.minX + edge, nearRight = point.x >= f.maxX - edge
    let nearTop = point.y >= f.maxY - edge, nearBottom = point.y <= f.minY + edge
    if nearLeft || nearRight {
        if point.y >= f.maxY - corner { return nearLeft ? "top-left" : "top-right" }
        if point.y <= f.minY + corner { return nearLeft ? "bottom-left" : "bottom-right" }
        if point.y >= f.maxY - corner * 2 { return "top-half" }
        if point.y <= f.minY + corner * 2 { return "bottom-half" }
        return nearLeft ? "left-half" : "right-half"
    }
    if nearTop { return "maximize" }
    if nearBottom {
        if point.x < f.minX + f.width / 3 { return "first-third" }
        if point.x > f.minX + f.width * 2 / 3 { return "last-third" }
        return "center-third"
    }
    return nil
}

func rectangleDragBegin(_ point: CGPoint) {
    rectangleDragStart = nil
    rectangleDragTarget = nil
    rectangleDragScreen = nil
    rectangleDragThird = nil
    rectangleDragOriginal = nil
    guard defaults.bool(forKey: "rectangleDragSnap"), let app = NSWorkspace.shared.frontmostApplication,
          app.processIdentifier != getpid() else { return }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, 0.2)
    guard let ax: AXUIElement = attr(axApp, kAXFocusedWindowAttribute), let r = frame(ax),
          r.contains(point), point.y < r.minY + 42 else { return }
    _ = _AXUIElementGetWindow(ax, &rectangleDragWindow)
    rectangleDragOriginal = r
    rectangleDragStart = point
}

func rectangleDragMove(_ point: CGPoint) {
    guard let start = rectangleDragStart, hypot(point.x - start.x, point.y - start.y) > 25,
          let main = NSScreen.screens.first else { return }
    let cocoaPoint = CGPoint(x: point.x, y: main.frame.height - point.y)
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) }) else { return }
    var action = rectangleSnapAction(cocoaPoint, screen: screen.frame)
    if action == "first-third" || action == "last-third" { rectangleDragThird = action }
    if action == "center-third" && rectangleDragThird != nil {
        action = rectangleDragThird == "first-third" ? "first-two-thirds" : "last-two-thirds"
    }
    rectangleDragTarget = action
    rectangleDragScreen = action == nil ? nil : screen.frame
    guard let action, let preview = rectangleTarget(action, screen: screen.visibleFrame, current: screen.visibleFrame) else {
        rectangleFootprint?.orderOut(nil); return
    }
    if rectangleFootprint == nil {
        let panel = NSPanel(contentRect: preview, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.22)
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 8
        panel.contentView?.layer?.borderColor = NSColor.systemBlue.cgColor
        panel.contentView?.layer?.borderWidth = 2
        rectangleFootprint = panel
    }
    rectangleFootprint?.setFrame(preview, display: true)
    rectangleFootprint?.orderFrontRegardless()
}

func rectangleDragEnd(_ point: CGPoint) {
    defer { rectangleDragStart = nil; rectangleDragTarget = nil; rectangleDragScreen = nil; rectangleDragThird = nil; rectangleDragOriginal = nil; rectangleFootprint?.orderOut(nil) }
    guard let start = rectangleDragStart, hypot(point.x - start.x, point.y - start.y) > 25,
          let action = rectangleDragTarget, rectangleDragWindow != 0,
          let app = NSWorkspace.shared.frontmostApplication else { return }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let ax: AXUIElement = attr(axApp, kAXFocusedWindowAttribute) else { return }
    var id: CGWindowID = 0
    _ = _AXUIElementGetWindow(ax, &id)
    if id == rectangleDragWindow {
        if rectangleOriginalFrames[id] == nil { rectangleOriginalFrames[id] = rectangleDragOriginal }
        rectanglePerform(action, snapScreen: rectangleDragScreen)
    }
}

func rectangleScreenIndex(for current: CGRect, snapScreen: CGRect?, in screens: [CGRect]) -> Int {
    screenIndex(for: snapScreen ?? current, in: screens)
}

func rectanglePerform(_ action: String, snapScreen: CGRect? = nil) {
    guard let active = NSWorkspace.shared.frontmostApplication,
          active.processIdentifier != getpid(), let main = NSScreen.screens.first else { NSSound.beep(); return }
    let screens = NSScreen.screens
    let mainTop = main.frame.height
    let activeApp = AXUIElementCreateApplication(active.processIdentifier)
    AXUIElementSetMessagingTimeout(activeApp, 0.2)
    guard let ax: AXUIElement = attr(activeApp, kAXFocusedWindowAttribute), let raw = frame(ax) else { NSSound.beep(); return }
    let cocoa = flipY(raw, mainTop: mainTop)
    let index = rectangleScreenIndex(for: cocoa, snapScreen: snapScreen, in: screens.map(\.frame))
    let gap = CGFloat(min(60, max(0, defaults.double(forKey: "rectangleGap"))))
    let work = screens[index].visibleFrame.insetBy(dx: gap, dy: gap)
    guard work.width > 0, work.height > 0 else { return }
    var wid: CGWindowID = 0
    _ = _AXUIElementGetWindow(ax, &wid)

    if action == "restore" {
        if let original = rectangleOriginalFrames.removeValue(forKey: wid) { setFrame(ax, original) }
        else { NSSound.beep() }
        return
    }
    if action == "cycle-stacked-windows" || action == "cycle-stacked-windows-backward" {
        let sameSize = defaults.bool(forKey: "rectangleStackSameSize")
        let stack = listWindows(includeExcluded: true).filter { w in
            guard let a = w.ax, !w.minimized, let r = frame(a) else { return false }
            return abs(r.minX - raw.minX) <= 24 && abs(r.minY - raw.minY) <= 24
                && (!sameSize || (abs(r.width - raw.width) <= 24 && abs(r.height - raw.height) <= 24))
        }
        if stack.count > 1, let target = action.hasSuffix("backward") ? stack.dropFirst().first : stack.last { focus(target) }
        else { NSSound.beep() }
        return
    }
    if ["tile-all", "tile-active-app", "tile-rows", "tile-columns", "cascade-all", "cascade-active-app", "reverse-all"].contains(action) {
        let windows = listWindows(includeExcluded: true).filter { w in
            guard let window = w.ax, !w.minimized, !w.app.isHidden, let r = frame(window) else { return false }
            return screenIndex(for: flipY(r, mainTop: mainTop), in: screens.map(\.frame)) == index
                && (!action.hasSuffix("active-app") || w.app.processIdentifier == active.processIdentifier)
                && (attr(window, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
        }
        guard !windows.isEmpty else { NSSound.beep(); return }
        if action == "reverse-all" { windows.forEach(focus); return }
        let ordered = windows.sorted {
            guard let a = $0.ax.flatMap(frame), let b = $1.ax.flatMap(frame) else { return false }
            return abs(a.minY - b.minY) > 24 ? a.minY < b.minY : a.minX < b.minX
        }
        let count = ordered.count
        let limit = min(count, max(1, defaults.integer(forKey: action == "tile-rows" ? "rectangleMaxPerRow" : "rectangleMaxPerColumn")))
        var groupSize = 1
        if action == "tile-rows" || action == "tile-columns" {
            let sizes = (1...limit).filter { size in (1..<size).allSatisfy { (count + $0 - 1) / $0 != (count + size - 1) / size } }
            let step = rectangleTileStep[action, default: 0] % sizes.count
            groupSize = sizes[step]
            rectangleTileStep[action] = step + 1
        }
        let isGrid = action == "tile-all" || action == "tile-active-app"
        let cols = isGrid ? Int(ceil(sqrt(Double(count)))) : action == "tile-columns" ? (count + groupSize - 1) / groupSize : 1
        let rows = isGrid ? (count + cols - 1) / cols : action == "tile-rows" ? (count + groupSize - 1) / groupSize : 1
        for (i, w) in ordered.enumerated() {
            guard let el = w.ax else { continue }
            let target: CGRect
            if action.hasPrefix("cascade") {
                let shift = CGFloat(i % 12) * 30
                target = CGRect(x: work.minX + shift, y: work.maxY - work.height * 0.7 - shift,
                                width: work.width * 0.7, height: work.height * 0.7)
            } else if action == "tile-columns" {
                let col = i / groupSize, row = i % groupSize
                let inColumn = min(groupSize, count - col * groupSize)
                target = CGRect(x: work.minX + CGFloat(col) * work.width / CGFloat(cols),
                                y: work.maxY - CGFloat(row + 1) * work.height / CGFloat(inColumn),
                                width: work.width / CGFloat(cols), height: work.height / CGFloat(inColumn))
            } else if action == "tile-rows" {
                let row = i / groupSize, col = i % groupSize
                let inRow = min(groupSize, count - row * groupSize)
                target = CGRect(x: work.minX + CGFloat(col) * work.width / CGFloat(inRow),
                                y: work.maxY - CGFloat(row + 1) * work.height / CGFloat(rows),
                                width: work.width / CGFloat(inRow), height: work.height / CGFloat(rows))
            } else {
                target = CGRect(x: work.minX + CGFloat(i % cols) * work.width / CGFloat(cols),
                                y: work.maxY - CGFloat(i / cols + 1) * work.height / CGFloat(rows),
                                width: work.width / CGFloat(cols), height: work.height / CGFloat(rows))
            }
            if let before = frame(el), w.wid != 0, rectangleOriginalFrames[w.wid] == nil { rectangleOriginalFrames[w.wid] = before }
            setFrame(el, flipY(target, mainTop: mainTop))
        }
        return
    }
    let target: CGRect
    if action.hasPrefix("display-") {
        let labels = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        guard let label = action.split(separator: "-").last,
              let destination = labels.firstIndex(of: String(label)), screens.indices.contains(destination) else { NSSound.beep(); return }
        let other = screens[destination].visibleFrame.insetBy(dx: gap, dy: gap)
        target = CGRect(x: other.midX - min(other.width, cocoa.width) / 2,
                        y: other.midY - min(other.height, cocoa.height) / 2,
                        width: min(other.width, cocoa.width), height: min(other.height, cocoa.height))
    } else if action == "next-display" || action == "previous-display" {
        let sorted = screens.indices.sorted { screens[$0].frame.minX < screens[$1].frame.minX }
        guard sorted.count > 1, let i = sorted.firstIndex(of: index) else { NSSound.beep(); return }
        let next = sorted[(i + (action == "next-display" ? 1 : sorted.count - 1)) % sorted.count]
        let other = screens[next].visibleFrame.insetBy(dx: gap, dy: gap)
        let x = (cocoa.minX - work.minX) / max(work.width - cocoa.width, 1)
        let y = (cocoa.minY - work.minY) / max(work.height - cocoa.height, 1)
        target = CGRect(x: other.minX + max(0, min(1, x)) * max(0, other.width - cocoa.width),
                        y: other.minY + max(0, min(1, y)) * max(0, other.height - cocoa.height),
                        width: min(other.width, cocoa.width), height: min(other.height, cocoa.height))
    } else if action == "specified" {
        let w = min(work.width, max(100, CGFloat(defaults.integer(forKey: "rectangleWidth"))))
        let h = min(work.height, max(100, CGFloat(defaults.integer(forKey: "rectangleHeight"))))
        target = CGRect(x: work.midX - w/2, y: work.midY - h/2, width: w, height: h)
    } else {
        guard let r = rectangleTarget(action, screen: work, current: cocoa) else { NSSound.beep(); return }
        target = r
    }
    if wid != 0 && rectangleOriginalFrames[wid] == nil { rectangleOriginalFrames[wid] = raw }
    setFrame(ax, flipY(target, mainTop: mainTop))
}

func testRectangleGeometry() {
    let f = CGRect(x: -1200, y: 25, width: 1200, height: 900)
    let r = CGRect(x: -1000, y: 100, width: 400, height: 300)
    precondition(rectangleTarget("left-half", screen: f, current: r) == CGRect(x: -1200, y: 25, width: 600, height: 900))
    precondition(rectangleTarget("top-right", screen: f, current: r) == CGRect(x: -600, y: 475, width: 600, height: 450))
    precondition(rectangleTarget("bottom-center-sixth", screen: f, current: r) == CGRect(x: -800, y: 25, width: 400, height: 450))
    for row in ["top", "bottom"] {
        for (col, name) in ["left", "center-left", "center-right", "right"].enumerated() {
            let expected = CGRect(x: f.minX + CGFloat(col) * f.width / 4,
                                  y: row == "top" ? f.midY : f.minY, width: f.width / 4, height: f.height / 2)
            precondition(rectangleTarget("\(row)-\(name)-eighth", screen: f, current: r) == expected,
                         "wrong eighth column \(row)-\(name)")
        }
    }
    precondition(rectangleSnapAction(CGPoint(x: f.minX, y: f.midY), screen: f) == "left-half")
    precondition(rectangleSnapAction(CGPoint(x: f.maxX, y: f.maxY), screen: f) == "top-right")
    precondition(rectangleSnapAction(CGPoint(x: f.midX, y: f.minY), screen: f) == "center-third")
    let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800), f]
    let sourceWindow = CGRect(x: 100, y: 100, width: 400, height: 300)
    let destination = rectangleScreenIndex(for: sourceWindow, snapScreen: f, in: displays)
    precondition(destination == 1, "drag snap must use cursor display")
    precondition(rectangleTarget("left-half", screen: displays[destination], current: sourceWindow)
                 == CGRect(x: -1200, y: 25, width: 600, height: 900))
    precondition(rectangleScreenIndex(for: sourceWindow, snapScreen: nil, in: displays) == 0,
                 "keyboard snap must use window display")
    precondition(rectangleActionURL(URL(string: "nirtab://execute-action?name=left-half")!) == "left-half")
    precondition(rectangleActionURL(URL(string: "nirtab://execute-action?name=not-an-action")!) == nil)
    for (action, _) in rectangleActions where !["tile-all", "tile-active-app", "tile-rows", "tile-columns", "cascade-all", "cascade-active-app", "reverse-all", "cycle-stacked-windows", "cycle-stacked-windows-backward", "specified", "restore", "next-display", "previous-display"].contains(action) && !action.hasPrefix("display-") {
        let target = rectangleTarget(action, screen: f, current: r)
        precondition(target != nil && target!.width > 0 && target!.height > 0, "missing geometry for \(action)")
    }
    print("rectangle geometry PASS")
}
