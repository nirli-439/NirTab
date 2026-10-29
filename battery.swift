import AppKit
import SwiftUI
import IOKit

// Independent battery monitor; no coconutBattery code or bundled application.
struct BatterySnapshot {
    let properties: [String: Any]
    private var data: [String: Any] { properties["BatteryData"] as? [String: Any] ?? [:] }
    private func number(_ key: String) -> Double? { (properties[key] as? NSNumber)?.doubleValue }
    private func capacity(_ key: String) -> Double? { (data[key] as? NSNumber)?.doubleValue ?? number(key) }
    private func positive(_ value: Double?) -> Double? { value.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } }
    var charge: Double? {
        guard let current = number("CurrentCapacity"), current >= 0,
              let max = positive(number("MaxCapacity")) else { return nil }
        return min(100, current / max * 100)
    }
    // Apple Silicon's top-level MaxCapacity is a percentage, not mAh.
    var fullCapacity: Double? { positive(capacity("FullChargeCapacity") ?? number("AppleRawMaxCapacity")) }
    var designCapacity: Double? { positive(capacity("DesignCapacity")) }
    var health: Double? {
        guard let full = fullCapacity, let design = designCapacity else { return nil }
        return full / design * 100
    }
    var status: String {
        if properties["IsCharging"] as? Bool == true { return "Charging" }
        if properties["FullyCharged"] as? Bool == true { return "Fully charged" }
        return properties["ExternalConnected"] as? Bool == true ? "Connected · not charging" : "On battery"
    }
    var rows: [(String, String)] {
        let temperature = positive(number("Temperature")).map { String(format: "%.1f °C", $0 / 100) } ?? "Unavailable"
        let voltage = positive(number("Voltage")).map { String(format: "%.2f V", $0 / 1000) } ?? "Unavailable"
        let adapter = properties["AdapterDetails"] as? [String: Any]
        let watts = (adapter?["Watts"] as? NSNumber)?.doubleValue
        return [
            ("Full charge capacity", fullCapacity.map { String(format: "%.0f mAh", $0) } ?? "Unavailable"),
            ("Design capacity", designCapacity.map { String(format: "%.0f mAh", $0) } ?? "Unavailable"),
            ("Cycle count", number("CycleCount").map { String(format: "%.0f", $0) } ?? "Unavailable"),
            ("Temperature", temperature), ("Voltage", voltage),
            ("Power adapter", properties["ExternalConnected"] as? Bool == true
                ? (watts.map { String(format: "%.0f W", $0) } ?? "Connected") : "Disconnected")
        ]
    }
    static func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var values: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &values, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values else { return nil }
        let properties = values.takeRetainedValue() as NSDictionary as? [String: Any] ?? [:]
        guard properties["BatteryInstalled"] as? Bool != false else { return nil }
        return BatterySnapshot(properties: properties)
    }
}

final class BatteryMonitor: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var snapshot: BatterySnapshot?
    @Published private(set) var updated = Date()
    private(set) var window: NSWindow?
    private(set) var timer: Timer?

    func refresh() { snapshot = BatterySnapshot.read(); updated = Date() }
    func open() {
        refresh()
        if window == nil {
            let panel = NSPanel(contentViewController: NSHostingController(rootView: BatteryView(monitor: self)))
            panel.title = "NirTab · Battery Health"
            panel.styleMask = [.titled, .closable]
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.delegate = self
            window = panel
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 2
        if window?.isVisible != true {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame, let size = window?.frame.size {
                window?.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
}

struct BatteryView: View {
    @ObservedObject var monitor: BatteryMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "battery.100percent").font(.system(size: 32)).foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text("Battery Health").font(.title2.bold())
                    Text(monitor.snapshot?.status ?? "No battery data available").foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let battery = monitor.snapshot {
                meter("Current charge", value: battery.charge, color: .accentColor)
                meter("Battery health", value: battery.health, color: (battery.health ?? 100) < 80 ? .orange : .green)
                Divider()
                ForEach(battery.rows, id: \.0) { row in
                    HStack { Text(row.0).foregroundStyle(.secondary); Spacer(); Text(row.1).monospacedDigit() }
                }
            } else {
                Text("This Mac has no readable built-in battery. Try Refresh if it has just woken from sleep.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Updated \(monitor.updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { monitor.refresh() }
            }
            Text("Live Mac battery data · refreshes every 10 seconds while open")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 380)
    }
    private func meter(_ title: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value.map { String(format: "%.1f%%", $0) } ?? "Unavailable").bold().monospacedDigit()
            }
            if let value { ProgressView(value: min(100, max(0, value)), total: 100).tint(color) }
        }
    }
}

let batteryMonitor = BatteryMonitor()

func testBattery() {
    let sample = BatterySnapshot(properties: ["CurrentCapacity": 75, "MaxCapacity": 100,
        "BatteryData": ["FullChargeCapacity": 5400, "DesignCapacity": 6000], "CycleCount": 129,
        "IsCharging": true, "Temperature": 3050, "Voltage": 12000])
    precondition(sample.charge == 75 && sample.health == 90 && sample.status == "Charging")
    precondition(sample.rows.contains { $0 == ("Temperature", "30.5 °C") })
    let missing = BatterySnapshot(properties: ["MaxCapacity": 100, "DesignCapacity": 0])
    precondition(missing.charge == nil && missing.health == nil && missing.fullCapacity == nil)
    let intel = BatterySnapshot(properties: ["CurrentCapacity": 2000, "MaxCapacity": 4000,
        "AppleRawMaxCapacity": 4000, "DesignCapacity": 5000, "ExternalConnected": true])
    precondition(intel.charge == 50 && intel.health == 80 && intel.status == "Connected · not charging")
    batteryMonitor.open()
    precondition(batteryMonitor.window?.isVisible == true && batteryMonitor.timer != nil)
    let window = batteryMonitor.window!
    batteryMonitor.open()
    precondition(batteryMonitor.window === window)
    window.close()
    precondition(batteryMonitor.timer == nil)
    print("battery PASS: capacities, missing data, Intel fallback, popup reuse, timer cleanup")
    if let live = BatterySnapshot.read() {
        print("Live: \(live.status), charge=\(live.charge.map(String.init(describing:)) ?? "unavailable")%, health=\(live.health.map(String.init(describing:)) ?? "unavailable")%")
    }
}
