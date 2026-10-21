import ApplicationServices
import AppKit
import Foundation

let ws = NSWorkspace.shared
let apps = ws.runningApplications.filter { $0.activationPolicy == .regular }
print("regular apps \(apps.count) trusted \(AXIsProcessTrusted())")

func str(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let s = v as? String else { return nil }
    return s
}
func boolAttr(_ el: AXUIElement, _ attr: String) -> Bool? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let b = v as? Bool else { return nil }
    return b
}

var total = 0
for app in apps {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 0.15)
    var wins: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &wins)
    let list = wins as? [AXUIElement] ?? []
    if list.isEmpty { continue }
    print("--- \(app.localizedName ?? "?") pid=\(app.processIdentifier) err=\(err.rawValue) n=\(list.count)")
    for w in list.prefix(6) {
        AXUIElementSetMessagingTimeout(w, 0.1)
        let title = str(w, kAXTitleAttribute) ?? ""
        let sub = str(w, kAXSubroleAttribute) ?? ""
        let role = str(w, kAXRoleAttribute) ?? ""
        let mini = boolAttr(w, kAXMinimizedAttribute)
        let main = boolAttr(w, kAXMainAttribute)
        print("  [\(role)/\(sub)] mini=\(mini.map{String($0)} ?? "-") main=\(main.map{String($0)} ?? "-") \(title)")
        total += 1
    }
}
print("shown \(total)")
