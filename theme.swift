import AppKit
import SwiftUI

// NirTab's one look, shared by every window, popup, toast and the menu:
// purple→blue wash, rounded gradient titles, colored icon tiles, dark glass for transient HUDs.

enum Brand {
    static let gradient = LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing)
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
}

// Big icon tile + gradient title + secondary subtitle: the top of every NirTab window.
struct BrandHeader<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 44)
                .shadow(color: color.opacity(0.45), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Brand.title(22)).foregroundStyle(Brand.gradient)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}
extension BrandHeader where Trailing == EmptyView {
    init(symbol: String, color: Color, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, color: color, title: title, subtitle: subtitle) { EmptyView() }
    }
}

extension View {
    // The purple→blue wash behind window content (same as Settings and Setup).
    func brandBackground() -> some View {
        background(alignment: .top) {
            LinearGradient(stops: [.init(color: .purple.opacity(0.26), location: 0), .init(color: .blue.opacity(0.10), location: 0.25),
                                   .init(color: .clear, location: 0.55)], startPoint: .topLeading, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
    // A grouped row / panel, matching the grouped Form rows in Settings.
    func brandCard(padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

// Title-less, full-bleed window chrome used by Settings and Setup, for any NirTab window or popup.
func brandWindow<V: View>(_ title: String, _ root: V, panel: Bool = false, floating: Bool = false) -> NSWindow {
    let host = NSHostingController(rootView: root)
    let w: NSWindow = panel ? NSPanel(contentViewController: host) : NSWindow(contentViewController: host)
    w.title = "NirTab · \(title)"
    w.styleMask = panel ? [.titled, .closable, .fullSizeContentView, .nonactivatingPanel] : [.titled, .closable, .fullSizeContentView]
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.isMovableByWindowBackground = true
    w.isReleasedWhenClosed = false
    if floating { w.level = .floating; w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary] }
    return w
}

func centerOnMouseScreen(_ w: NSWindow) {
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    guard let f = screen?.visibleFrame else { w.center(); return }
    w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
}

// Centered popup (coffee break, Pomodoro): big tile, gradient title, one prominent button.
struct BrandPopup: View {
    let symbol: String
    let color: Color
    let title: String
    let message: String
    let button: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            IconTile(symbol: symbol, color: color, size: 56).shadow(color: color.opacity(0.5), radius: 14, y: 5)
            Text(title).font(Brand.title(24)).foregroundStyle(Brand.gradient)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(button, action: action).buttonStyle(.borderedProminent).tint(.purple).controlSize(.large)
                .keyboardShortcut(.defaultAction).padding(.top, 4)
        }
        .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 22)
        .frame(width: 340)
        .brandBackground()
    }
}
func showBrandPopup(symbol: String, color: Color, title: String, message: String, button: String, action: (() -> Void)? = nil) -> NSWindow {
    var window: NSWindow?
    let w = brandWindow(title, BrandPopup(symbol: symbol, color: color, title: title, message: message, button: button) {
        window?.close(); action?()
    }, panel: true, floating: true)
    window = w
    centerOnMouseScreen(w)
    w.orderFrontRegardless()
    return w
}

// MARK: - Toast: dark glass capsule like the switcher, top-center of the screen with the mouse.

private var toastPanel: NSPanel?
private var toastHide: DispatchWorkItem?

struct ToastView: View {
    let symbol: String
    let color: Color
    let text: String
    let busy: Bool
    var body: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small).frame(width: 26, height: 26) }
            else { IconTile(symbol: symbol, color: color, size: 26) }
            Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
        }
        .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 8)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(LinearGradient(colors: [.purple.opacity(0.28), .blue.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .padding(12)  // room for the shadow
    }
}

// `duration: nil` keeps it up until the next toast (use for "working…").
func showToast(_ text: String, symbol: String = "checkmark", color: Color = .green, busy: Bool = false, duration: Double? = 1.8) {
    toastHide?.cancel()
    let host = NSHostingView(rootView: ToastView(symbol: symbol, color: color, text: text, busy: busy))
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    let panel = toastPanel ?? {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .statusBar; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.appearance = NSAppearance(named: .darkAqua)
        toastPanel = p
        return p
    }()
    panel.contentView = host
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    if let f = screen?.visibleFrame {
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 8, width: size.width, height: size.height), display: true)
    }
    if !panel.isVisible { panel.alphaValue = 0; panel.orderFrontRegardless() }
    NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    guard let duration else { return }
    let hide = DispatchWorkItem {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) { panel.orderOut(nil) }
    }
    toastHide = hide
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: hide)
}

// MARK: - Menu

// Menu-bar menu header: app icon, gradient name + version, and what to press (or what's missing).
struct MenuHeaderView: View {
    let working: Bool
    let key: String
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                .shadow(color: .purple.opacity(0.4), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("NirTab").font(Brand.title(15)).foregroundStyle(Brand.gradient)
                    Text(appVersion.split(separator: " ").first.map(String.init) ?? appVersion).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle().fill(working ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(working ? "Hold \(key) and press Tab" : "Needs Accessibility to work")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(width: 300, height: 50, alignment: .leading)
    }
}

// Template SF Symbol for a menu item (follows menu highlight and light/dark like system menus).
func menuSymbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
}

// Debug: --snapshot-ui <dir> renders each NirTab window/popup/toast in light and dark mode to PNGs (look-and-feel review).
func snapshotUI(_ dir: String) {
    let items: [(String, AnyView)] = [
        ("battery", AnyView(BatteryView(monitor: batteryMonitor))),
        ("clipboard", AnyView(ClipboardView(history: clipboard))),
        ("popup", AnyView(BrandPopup(symbol: "cup.and.saucer.fill", color: .brown, title: "Break's over",
                                     message: "Ready when you are. No focus timer starts.", button: "Done") {})),
        ("toast", AnyView(ToastView(symbol: "doc.on.clipboard", color: .purple, text: "Markdown copied", busy: false))),
        ("menuheader", AnyView(MenuHeaderView(working: true, key: "⌘").background(Color(nsColor: .windowBackgroundColor)))),
        ("settings", AnyView(SettingsView())),
        ("setup", AnyView(SetupView())),
    ]
    batteryMonitor.refresh()
    for (name, view) in items {
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let w = brandWindow(name, view)
            w.appearance = NSAppearance(named: appearance)
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let v = w.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(mode).png"))
            w.close()
        }
    }
    print("snapshots in \(dir)")
}
