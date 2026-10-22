import AppKit
import IOKit.pwr_mgt

// Keep this status item independent of NirTab's main menu. No assertions are restored on launch.
final class Caffeinate: NSObject, NSMenuDelegate {
    enum SleepKind: Int, CaseIterable {
        case display, idle, disk, system

        var title: String {
            switch self {
            case .display: return "Prevent display sleep"
            case .idle: return "Prevent idle sleep"
            case .disk: return "Prevent disk sleep"
            case .system: return "Prevent system sleep"
            }
        }
        var assertion: CFString {
            switch self {
            case .display: return kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
            case .idle: return kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
            case .disk: return kIOPMAssertPreventDiskIdle as CFString
            case .system: return kIOPMAssertionTypePreventSystemSleep as CFString
            }
        }
    }

    private(set) var item: NSStatusItem?
    private(set) var selected: Set<SleepKind> = [.display, .idle, .disk, .system]
    private(set) var assertions: [SleepKind: IOPMAssertionID] = [:]
    private(set) var deadline: Date?
    private(set) var minutes: Int? // nil means until manually turned off
    private(set) var error: String?
    private var timer: Timer?
    private let testing: Bool

    init(testing: Bool = false) {
        self.testing = testing
        super.init()
    }

    deinit {
        timer?.invalidate()
        releaseAll()
        if let item { NSStatusBar.system.removeStatusItem(item) }
    }

    // Integration: call setEnabled(true) at startup to show a second cup status item.
    // setEnabled(false) removes it and releases every assertion immediately.
    func setEnabled(_ visible: Bool) {
        if visible {
            guard item == nil else { return }
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.target = self
            item?.button?.action = #selector(statusClick)
            item?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            update()
        } else {
            releaseAll()
            if !assertions.isEmpty { update(); return } // keep the cup and retry path visible on release failure
            deadline = nil
            error = nil
            timer?.invalidate(); timer = nil
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
        }
    }

    @objc private func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.delegate = self
            item?.popUpMenu(menu)
        } else { toggle() }
    }

    func toggle() {
        if !assertions.isEmpty {
            error = nil
            releaseAll()
            if assertions.isEmpty { deadline = nil }
        }
        else {
            error = nil
            guard !selected.isEmpty else { error = "Select at least one sleep type"; update(); NSSound.beep(); return }
            applySelection()
            if !assertions.isEmpty { deadline = minutes.map { Date().addingTimeInterval(Double($0) * 60) } }
        }
        update()
    }

    private func release(_ kind: SleepKind) {
        guard let id = assertions[kind] else { return }
        if !testing {
            let result = IOPMAssertionRelease(id)
            if result != kIOReturnSuccess { error = "Could not release \(kind.title) (IOKit \(result))"; NSSound.beep(); return }
        }
        assertions.removeValue(forKey: kind)
    }

    private func releaseAll() {
        for kind in Array(assertions.keys) { release(kind) }
    }

    private func applySelection() {
        for kind in Array(assertions.keys) where !selected.contains(kind) { release(kind) }
        var failures: [String] = []
        for kind in SleepKind.allCases where selected.contains(kind) && assertions[kind] == nil {
            if testing { assertions[kind] = IOPMAssertionID(kind.rawValue + 1); continue }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kind.assertion, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                       "NirTab Caffeinate" as CFString, &id)
            if result == kIOReturnSuccess { assertions[kind] = id }
            else { failures.append("\(kind.title) (IOKit \(result))") }
        }
        if !failures.isEmpty {
            error = "Could not enable: " + failures.joined(separator: ", ")
            NSSound.beep()
        }
    }

    func tick(now: Date = Date()) {
        if let deadline, now >= deadline {
            releaseAll()
            if assertions.isEmpty { self.deadline = nil }
        }
        update(now: now)
    }

    private func update(now: Date = Date()) {
        guard let button = item?.button else { return }
        let active = !assertions.isEmpty
        let image = NSImage(systemSymbolName: active ? "cup.and.saucer.fill" : "cup.and.saucer",
                            accessibilityDescription: active ? "Caffeinate on" : "Caffeinate off")
        image?.isTemplate = true
        button.image = image
        button.title = active && deadline != nil ? " " + countdown(deadline!.timeIntervalSince(now)) : ""
        button.toolTip = error ?? (active ? "Caffeinate on — click to turn off; right-click for settings" :
                                    "Caffeinate off — click to turn on; right-click for settings")
    }

    private func countdown(_ seconds: TimeInterval) -> String {
        let remaining = max(0, Int(ceil(seconds)))
        return String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: assertions.isEmpty ? "Caffeinate · off" :
            "Caffeinate · " + (deadline.map { countdown($0.timeIntervalSinceNow) + " left" } ?? "on until disabled"),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false; menu.addItem(header)
        if let error {
            let warning = NSMenuItem(title: "⚠︎ " + error, action: nil, keyEquivalent: "")
            warning.isEnabled = false; menu.addItem(warning)
        }
        menu.addItem(.separator())
        for kind in SleepKind.allCases {
            let row = NSMenuItem(title: kind.title, action: #selector(toggleKind(_:)), keyEquivalent: "")
            row.target = self; row.tag = kind.rawValue; row.state = selected.contains(kind) ? .on : .off
            menu.addItem(row)
        }
        menu.addItem(.separator())
        for (title, value) in [("Until turned off", 0), ("15 minutes", 15), ("30 minutes", 30),
                               ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)] {
            let row = NSMenuItem(title: title, action: #selector(chooseMinutes(_:)), keyEquivalent: "")
            row.target = self; row.tag = value; row.state = minutes == (value == 0 ? nil : value) ? .on : .off
            menu.addItem(row)
        }
        let custom = NSMenuItem(title: "Custom minutes…", action: #selector(customMinutes), keyEquivalent: "")
        custom.target = self; menu.addItem(custom)
        let toggleItem = NSMenuItem(title: assertions.isEmpty ? "Turn on" : "Turn off", action: #selector(menuToggle), keyEquivalent: "")
        toggleItem.target = self; menu.addItem(.separator()); menu.addItem(toggleItem)
    }

    @objc private func menuToggle() { toggle() }
    @objc private func toggleKind(_ sender: NSMenuItem) {
        guard let kind = SleepKind(rawValue: sender.tag) else { return }
        if selected.contains(kind) { selected.remove(kind) } else { selected.insert(kind) }
        error = nil
        if !assertions.isEmpty {
            applySelection()
            if assertions.isEmpty { deadline = nil }
        }
        update()
    }
    @objc private func chooseMinutes(_ sender: NSMenuItem) { setMinutes(sender.tag == 0 ? nil : sender.tag) }

    @discardableResult
    func setMinutes(_ value: Int?) -> Bool {
        guard value == nil || (1...10080).contains(value!) else { return false }
        minutes = value
        if !assertions.isEmpty { deadline = value.map { Date().addingTimeInterval(Double($0) * 60) } }
        update()
        return true
    }

    @objc private func customMinutes() {
        let prompt = NSAlert()
        prompt.messageText = "Turn off Caffeinate after how many minutes?"
        prompt.informativeText = "Enter a whole number from 1 to 10080."
        let field = NSTextField(string: minutes.map(String.init) ?? "60")
        field.placeholderString = "Minutes"
        prompt.accessoryView = field
        prompt.addButton(withTitle: "Set timer")
        prompt.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        if let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), setMinutes(value) { error = nil }
        else { error = "Enter a whole number of minutes (1–10080)"; NSSound.beep() }
        update()
    }
}

let caffeinate = Caffeinate()

// Pure in-memory assertions: this check never calls IOPMAssertionCreateWithName.
func testCaffeinate() {
    let cup = Caffeinate(testing: true)
    cup.setEnabled(true)
    precondition(cup.item != nil && cup.assertions.isEmpty)
    cup.toggle()
    precondition(Set(cup.assertions.keys) == Set(Caffeinate.SleepKind.allCases))
    let menu = NSMenu(); cup.menuNeedsUpdate(menu)
    precondition(menu.item(withTitle: "Prevent disk sleep")?.state == .on)
    precondition(menu.item(withTitle: "Prevent system sleep")?.state == .on)
    menu.performActionForItem(at: menu.index(of: menu.item(withTitle: "Prevent disk sleep")!))
    menu.performActionForItem(at: menu.index(of: menu.item(withTitle: "Prevent system sleep")!))
    precondition(Set(cup.assertions.keys) == Set([.display, .idle]))
    cup.menuNeedsUpdate(menu)
    menu.performActionForItem(at: menu.index(of: menu.item(withTitle: "Prevent display sleep")!))
    precondition(cup.assertions[.display] == nil && cup.assertions.count == 1)
    cup.setMinutes(15)
    precondition(cup.deadline != nil && cup.item?.button?.title.contains(":") == true)
    precondition(!cup.setMinutes(0) && cup.minutes == 15)
    cup.tick(now: cup.deadline!.addingTimeInterval(1))
    precondition(cup.assertions.isEmpty && cup.deadline == nil)
    cup.toggle(); precondition(!cup.assertions.isEmpty)
    cup.setEnabled(false)
    precondition(cup.assertions.isEmpty && cup.item == nil)
    print("caffeinate PASS")
}
