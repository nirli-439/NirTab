import AppKit
import Combine
import ImageIO
import SwiftUI

// Experimental clipboard history. File URLs are references; embedded media is copied into Documents/NirTab.
struct Clip: Codable, Identifiable {
    let id: UUID
    let date: Date
    var pinned: Bool
    let items: [[String: Data]]

    var label: String {
        if let file = items.first?.first(where: { $0.key == NSPasteboard.PasteboardType.fileURL.rawValue })?.value,
           let path = String(data: file, encoding: .utf8) { return URL(string: path)?.lastPathComponent ?? "File" }
        if let text = items.first?.first(where: { $0.key == NSPasteboard.PasteboardType.string.rawValue })?.value,
           let value = String(data: text, encoding: .utf8) { return String(value.prefix(180)).replacingOccurrences(of: "\n", with: " ") }
        if items.contains(where: { $0.keys.contains(NSPasteboard.PasteboardType.tiff.rawValue) || $0.keys.contains(NSPasteboard.PasteboardType.png.rawValue) }) { return "Image" }
        return "Media / rich content"
    }
    var symbol: String {
        if items.contains(where: { $0.keys.contains(NSPasteboard.PasteboardType.fileURL.rawValue) }) { return "doc" }
        if items.contains(where: { $0.keys.contains(NSPasteboard.PasteboardType.tiff.rawValue) || $0.keys.contains(NSPasteboard.PasteboardType.png.rawValue) }) { return "photo" }
        return "text.alignleft"
    }
    var thumbnail: NSImage? {
        guard let data = items.first?[NSPasteboard.PasteboardType.png.rawValue]
                ?? items.first?[NSPasteboard.PasteboardType.tiff.rawValue],
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

final class ClipboardHistory: ObservableObject {
    @Published private(set) var clips: [Clip] = []
    @Published private(set) var storageError: String?
    let directory: URL
    let pasteboard: NSPasteboard
    var lastChange: Int
    var timer: Timer?
    // ponytail: 16 MB per copied entry, 50 unpinned and 20 pinned; raise limits if real usage needs more.
    let maxBytes = 16 * 1024 * 1024

    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("NirTab/Clipboard"),
         pasteboard: NSPasteboard = .general) {
        self.directory = directory
        self.pasteboard = pasteboard
        lastChange = pasteboard.changeCount
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            clips = files.compactMap { url in
                guard url.pathExtension == "plist", let data = try? Data(contentsOf: url) else { return nil }
                return try? PropertyListDecoder().decode(Clip.self, from: data)
            }
            sort()
        }
    }

    func sort() {
        clips.sort { $0.pinned == $1.pinned ? $0.date > $1.date : $0.pinned }
    }
    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: "clipboardEnabled")
        timer?.invalidate(); timer = nil
        if on {
            poll()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        } else { clipboardWindow?.close() }
        clipboardStatus.setVisible(on && defaults.bool(forKey: "clipboardIconEnabled"))
    }
    func poll() {
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        guard let pbItems = pasteboard.pasteboardItems, !pbItems.isEmpty else { return }
        let allTypes = pbItems.flatMap(\.types).map(\.rawValue).joined(separator: " ").lowercased()
        guard !allTypes.contains("concealedtype"), !allTypes.contains("transienttype"), !allTypes.contains("com.agilebits.onepassword") else { return }
        var bytes = 0, entries: [[String: Data]] = []
        for pbItem in pbItems {
            var entry: [String: Data] = [:]
            for type in pbItem.types {
                guard let data = pbItem.data(forType: type) else { continue }
                if bytes + data.count <= maxBytes {
                    bytes += data.count
                    entry[type.rawValue] = data
                } else if type == .tiff || type == .png,
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1600
                          ] as CFDictionary),
                          let compact = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                          bytes + compact.count <= maxBytes {
                    bytes += compact.count
                    entry[NSPasteboard.PasteboardType.png.rawValue] = compact
                }
            }
            if !entry.isEmpty { entries.append(entry) }
        }
        guard !entries.isEmpty, !clips.contains(where: { $0.items == entries }) else { return }
        let clip = Clip(id: UUID(), date: Date(), pinned: false, items: entries)
        guard save(clip) else { return }
        clips.insert(clip, at: clips.firstIndex(where: { !$0.pinned }) ?? clips.count)
        for old in clips.filter({ !$0.pinned }).dropFirst(50) { remove(old) }
    }
    @discardableResult func save(_ clip: Clip) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PropertyListEncoder().encode(clip).write(to: directory.appendingPathComponent("\(clip.id.uuidString).plist"), options: .atomic)
            storageError = nil
            return true
        } catch { storageError = error.localizedDescription; NSLog("NirTab clipboard save: %@", String(describing: error)); return false }
    }
    func remove(_ clip: Clip) {
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("\(clip.id.uuidString).plist"))
            clips.removeAll { $0.id == clip.id }
        } catch { NSLog("NirTab clipboard remove: %@", String(describing: error)) }
    }
    func pin(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }), !(!clip.pinned && clips.filter(\.pinned).count >= 20) else { return }
        var updated = clip; updated.pinned.toggle()
        guard save(updated) else { return }
        clips[index] = updated; sort()
    }
    func copy(_ clip: Clip) -> Bool {
        let objects: [NSPasteboardItem] = clip.items.map { data in
            let item = NSPasteboardItem()
            for (type, value) in data { item.setData(value, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        pasteboard.clearContents()
        let ok = pasteboard.writeObjects(objects)
        lastChange = pasteboard.changeCount
        return ok
    }
}

let clipboard = ClipboardHistory()
var clipboardWindow: NSWindow?

final class ClipboardStatus: NSObject {
    private(set) var item: NSStatusItem?
    func setVisible(_ visible: Bool) {
        if visible {
            guard item == nil else { return }
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard history")
            image?.isTemplate = true
            item?.button?.image = image
            item?.button?.toolTip = "Open Clipboard History (⌥⌘V)"
            item?.button?.target = self
            item?.button?.action = #selector(openHistory)
        } else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
        }
    }
    @objc func openHistory() { openClipboard() }
}
let clipboardStatus = ClipboardStatus()

struct ClipboardView: View {
    @ObservedObject var history: ClipboardHistory
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BrandHeader(symbol: "doc.on.clipboard", color: .orange, title: "Clipboard History",
                        subtitle: "Saved unencrypted in Documents/NirTab · files are referenced, not copied") {
                HStack(spacing: 3) { Keycap(key: "⌥"); Keycap(key: "⌘"); Keycap(key: "V") }
            }
            if let error = history.storageError {
                Label("Couldn't save clipboard: \(error)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if history.clips.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 38)).foregroundStyle(.tertiary)
                    Text("Copy text, an image, or files to get started.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(history.clips) { clip in
                            HStack(spacing: 12) {
                                Group {
                                    if let thumbnail = clip.thumbnail {
                                        Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: 34, height: 34)
                                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    } else { IconTile(symbol: clip.symbol, color: clip.pinned ? .purple : .gray, size: 34) }
                                }
                                Text(clip.label).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Button { history.pin(clip) } label: {
                                    Image(systemName: clip.pinned ? "pin.fill" : "pin").foregroundStyle(clip.pinned ? .purple : .secondary)
                                }.buttonStyle(.borderless).help(clip.pinned ? "Unpin" : "Pin")
                                    .disabled(!clip.pinned && history.clips.filter(\.pinned).count >= 20)
                                Button { history.remove(clip) } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                                    .buttonStyle(.borderless).help("Delete")
                                Button("Copy") { if history.copy(clip) { clipboardWindow?.close() } }
                                    .buttonStyle(.borderedProminent).tint(.purple)
                            }.brandCard(padding: 9)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 20)
        .frame(width: 580, height: 520)
        .brandBackground()
    }
}

func openClipboard() {
    guard defaults.bool(forKey: "clipboardEnabled") else { return }
    clipboard.poll()
    if clipboardWindow == nil {
        clipboardWindow = brandWindow("Clipboard", ClipboardView(history: clipboard))
    }
    NSApp.activate(ignoringOtherApps: true)
    clipboardWindow?.center()
    clipboardWindow?.makeKeyAndOrderFront(nil)
}

func timerText(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(ceil(seconds)))
    return String(format: "%02d:%02d", value / 60, value % 60)
}

final class Pomodoro: NSObject, NSMenuDelegate {
    var item: NSStatusItem?
    var phase = "idle"
    var deadline: Date?
    var paused: TimeInterval?
    var timer: Timer?
    var popup: NSWindow?

    override init() {
        phase = defaults.string(forKey: "timerPhase") ?? "idle"
        deadline = defaults.object(forKey: "timerDeadline") as? Date
        paused = defaults.object(forKey: "timerPaused") as? Double
        super.init()
    }
    func persist() {
        guard item != nil else { return }
        defaults.set(phase, forKey: "timerPhase")
        defaults.set(deadline, forKey: "timerDeadline")
        defaults.set(paused, forKey: "timerPaused")
    }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: "pomodoroEnabled")
        timer?.invalidate(); timer = nil
        if on {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu(); menu.delegate = self; item?.menu = menu
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            tick()
        } else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            reset(); item = nil
        }
    }
    func tick(showPopup: Bool = true) {
        if let deadline, deadline <= Date() {
            if phase == "focus" {
                phase = "break"
                self.deadline = Date().addingTimeInterval(Double(max(1, min(60, defaults.integer(forKey: "breakMinutes")))) * 60)
                if showPopup { breakPopup() }
            } else { reset() }
        }
        persist(); update()
    }
    func update() {
        let remaining = deadline?.timeIntervalSinceNow ?? paused ?? Double(max(1, defaults.integer(forKey: "focusMinutes"))) * 60
        item?.button?.title = timerText(remaining)
        let image = NSImage(systemSymbolName: phase == "break" ? "cup.and.saucer.fill" : "timer", accessibilityDescription: "Pomodoro \(phase)")
        image?.isTemplate = true
        item?.button?.image = image
    }
    @objc func startFocus() {
        phase = "focus"; paused = nil
        deadline = Date().addingTimeInterval(Double(max(1, min(180, defaults.integer(forKey: "focusMinutes")))) * 60)
        popup?.close(); persist(); update()
    }
    @objc func pauseResume() {
        if let deadline { paused = max(0, deadline.timeIntervalSinceNow); self.deadline = nil }
        else if let paused { deadline = Date().addingTimeInterval(paused); self.paused = nil }
        persist(); update()
    }
    @objc func startBreak() {
        phase = "break"; paused = nil
        deadline = Date().addingTimeInterval(Double(max(1, min(60, defaults.integer(forKey: "breakMinutes")))) * 60)
        popup?.close(); persist(); update()
    }
    @objc func reset() { phase = "idle"; deadline = nil; paused = nil; popup?.close(); persist(); update() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: phase == "idle" ? "Pomodoro · ready" : "\(phase.capitalized) · \(timerText(deadline?.timeIntervalSinceNow ?? paused ?? 0))"))
        for (name, symbol, action) in [("Start Focus", "brain.head.profile", #selector(startFocus)),
                                       (deadline == nil ? "Resume" : "Pause", deadline == nil ? "play.fill" : "pause.fill", #selector(pauseResume)),
                                       ("Start Break", "cup.and.saucer", #selector(startBreak)), ("Reset", "arrow.counterclockwise", #selector(reset))] {
            let row = NSMenuItem(title: name, action: action, keyEquivalent: "")
            row.target = self; row.isEnabled = name != "Resume" || paused != nil
            row.image = menuSymbol(symbol)
            menu.addItem(row)
        }
    }
    func breakPopup() {
        popup?.close()
        popup = showBrandPopup(symbol: "cup.and.saucer.fill", color: .brown, title: "Break time",
                               message: "Focus session done. Your break timer is running.", button: "Dismiss")
    }
}

let pomodoro = Pomodoro()

// One-shot coffee breaks, independent of Pomodoro and keep-awake assertions.
final class CoffeeBreak: NSObject, NSMenuDelegate {
    private(set) var item: NSStatusItem?
    private(set) var deadline: Date?
    private(set) var paused: TimeInterval?
    private(set) var timer: Timer?
    private(set) var popup: NSWindow?

    @objc func start(_ sender: NSMenuItem) { start(minutes: sender.tag) }
    func start(minutes: Int, now: Date = Date()) {
        guard (1...60).contains(minutes) else { return }
        cancel()
        deadline = now.addingTimeInterval(Double(minutes) * 60)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; item?.menu = menu
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        update(now: now)
    }
    func tick(now: Date = Date(), showPopup: Bool = true) {
        if let deadline, now >= deadline {
            cancel()
            if showPopup { finishedPopup(); NSSound.beep() }
        } else { update(now: now) }
    }
    @objc func menuPauseResume() { pauseResume(now: Date()) }
    func pauseResume(now: Date) {
        if let deadline {
            guard now < deadline else { tick(now: now); return }
            paused = deadline.timeIntervalSince(now); self.deadline = nil
        } else if let paused {
            deadline = now.addingTimeInterval(paused); self.paused = nil
        }
        update(now: now)
    }
    @objc func cancel() {
        timer?.invalidate(); timer = nil
        deadline = nil; paused = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        popup?.close(); popup = nil
    }
    private func update(now: Date) {
        let image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Coffee break timer")
        image?.isTemplate = true
        item?.button?.image = image
        item?.button?.title = " " + timerText(deadline?.timeIntervalSince(now) ?? paused ?? 0) + (paused == nil ? "" : " ⏸")
        item?.button?.toolTip = "Coffee break — click to pause, resume, restart or cancel"
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if item != nil {
            menu.addItem(.sectionHeader(title: "Coffee break · " + (paused == nil ? "running" : "paused")))
            let pause = NSMenuItem(title: paused == nil ? "Pause" : "Resume", action: #selector(menuPauseResume), keyEquivalent: "")
            pause.target = self; pause.image = menuSymbol(paused == nil ? "pause.fill" : "play.fill"); menu.addItem(pause)
            let stop = NSMenuItem(title: "Cancel break", action: #selector(cancel), keyEquivalent: "")
            stop.target = self; stop.image = menuSymbol("xmark"); menu.addItem(stop)
            menu.addItem(.separator())
        }
        for minutes in [5, 10, 15] {
            let row = NSMenuItem(title: "\(minutes)-minute coffee break", action: #selector(start(_:)), keyEquivalent: "")
            row.tag = minutes; row.target = self; row.image = menuSymbol("\(minutes).circle"); menu.addItem(row)
        }
    }
    private func finishedPopup() {
        popup = showBrandPopup(symbol: "cup.and.saucer.fill", color: .brown, title: "Break's over",
                               message: "Ready when you are. No focus timer starts.", button: "Done") { [weak self] in self?.cancel() }
    }
}
let coffeeBreak = CoffeeBreak()

func testCoffeeBreak() {
    let clock = CoffeeBreak(), menu = NSMenu(), now = Date()
    defer { clock.cancel() }
    clock.menuNeedsUpdate(menu)
    precondition(menu.items.count == 3)
    clock.start(minutes: 0); precondition(clock.item == nil)
    menu.performActionForItem(at: 0)
    precondition(clock.item?.button?.image != nil && clock.timer?.isValid == true)
    clock.start(minutes: 5, now: now)
    precondition(clock.item?.button?.title == " 05:00")
    clock.pauseResume(now: now.addingTimeInterval(30))
    precondition(clock.deadline == nil && clock.paused == 270)
    clock.tick(now: now.addingTimeInterval(600))
    precondition(clock.paused == 270 && clock.popup == nil)
    clock.menuNeedsUpdate(menu)
    precondition(menu.item(withTitle: "Resume") != nil)
    clock.pauseResume(now: now.addingTimeInterval(600))
    precondition(clock.deadline == now.addingTimeInterval(870) && clock.paused == nil)
    clock.tick(now: now.addingTimeInterval(870), showPopup: false)
    precondition(clock.item == nil && clock.timer == nil && clock.deadline == nil)
    clock.start(minutes: 10, now: now)
    clock.start(minutes: 15, now: now)
    precondition(clock.item?.button?.title == " 15:00")
    clock.menuNeedsUpdate(menu)
    menu.performActionForItem(at: menu.index(of: menu.item(withTitle: "Pause")!))
    precondition(clock.paused != nil && clock.deadline == nil)
    clock.menuNeedsUpdate(menu)
    menu.performActionForItem(at: menu.index(of: menu.item(withTitle: "Resume")!))
    precondition(clock.paused == nil && clock.deadline != nil)
    menu.performActionForItem(at: menu.index(of: menu.item(withTitle: "Cancel break")!))
    precondition(clock.item == nil && clock.timer == nil)
    clock.start(minutes: 1, now: now.addingTimeInterval(-60))
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    precondition(clock.popup?.isVisible == true && clock.item == nil && clock.deadline == nil)
    if let view = clock.popup?.contentView,
       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let path = directory.appendingPathComponent("nirtab-coffee-break.png")
        try! rep.representation(using: .png, properties: [:])!.write(to: path)
        print("coffee popup: \(path.path)")
    }
    clock.cancel(); precondition(clock.popup == nil)
    print("coffee break PASS: presets, countdown, pause/resume, restart, cancel, completion popup, cleanup")
}

func testExtras() {
    let icon = ClipboardStatus()
    icon.setVisible(true)
    let first = icon.item
    precondition(first?.button?.image != nil && first?.button?.target === icon)
    icon.setVisible(true)
    precondition(icon.item === first)
    let oldEnabled = defaults.object(forKey: "clipboardEnabled")
    let oldIcon = defaults.object(forKey: "clipboardIconEnabled")
    defer {
        clipboardWindow?.close()
        clipboard.setEnabled(oldEnabled as? Bool ?? false)
        defaults.set(oldEnabled, forKey: "clipboardEnabled")
        defaults.set(oldIcon, forKey: "clipboardIconEnabled")
        clipboardStatus.setVisible((oldEnabled as? Bool ?? false) && (oldIcon as? Bool ?? false))
    }
    defaults.set(true, forKey: "clipboardEnabled")
    icon.item?.button?.performClick(nil)
    precondition(clipboardWindow?.isVisible == true)
    defaults.set(true, forKey: "clipboardIconEnabled")
    clipboard.setEnabled(false)
    precondition(clipboardStatus.item == nil && defaults.bool(forKey: "clipboardIconEnabled"))
    clipboard.setEnabled(true)
    precondition(clipboardStatus.item?.button?.image != nil)
    icon.setVisible(false)
    precondition(icon.item == nil)
    precondition(timerText(61) == "01:01" && timerText(0) == "00:00")
    let clock = Pomodoro()
    clock.phase = "focus"; clock.deadline = Date().addingTimeInterval(-1)
    clock.tick(showPopup: false)
    precondition(clock.phase == "break" && (clock.deadline?.timeIntervalSinceNow ?? 0) > 0)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nirtab-clips-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let pb = NSPasteboard(name: NSPasteboard.Name("nirtab-test-\(UUID().uuidString)"))
    let store = ClipboardHistory(directory: directory, pasteboard: pb)
    pb.clearContents(); pb.setString("clipboard check", forType: .string); store.poll()
    precondition(store.clips.count == 1 && store.clips[0].label == "clipboard check")
    store.pin(store.clips[0])
    let img = NSImage(contentsOfFile: "icons/AppIcon.icns")!.tiffRepresentation!
    pb.clearContents(); pb.setData(img, forType: .tiff); store.poll()
    precondition(store.clips.count == 2 && store.clips.contains { $0.symbol == "photo" })
    pb.clearContents(); precondition(pb.writeObjects([URL(fileURLWithPath: "/tmp/nirtab-check.txt") as NSURL])); store.poll()
    precondition(store.clips.count == 3 && store.clips.contains { $0.symbol == "doc" })
    let again = ClipboardHistory(directory: directory, pasteboard: pb)
    precondition(again.clips.count == 3 && again.clips.first?.pinned == true)
    precondition(again.copy(again.clips.first!) && pb.string(forType: .string) == "clipboard check")
    precondition(again.copy(again.clips.first { $0.symbol == "photo" }!) && pb.data(forType: .tiff) == img)
    precondition(again.copy(again.clips.first { $0.symbol == "doc" }!) && pb.data(forType: .fileURL) != nil)
    again.poll()  // copying an entry must not create another entry
    precondition(again.clips.count == 3)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2100, pixelsHigh: 2100, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    var seed: UInt32 = 1
    for i in 0..<(rep.bytesPerRow * rep.pixelsHigh) {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        rep.bitmapData![i] = UInt8(truncatingIfNeeded: seed >> 16)
    }
    let large = rep.representation(using: .tiff, properties: [:])!
    precondition(large.count > store.maxBytes)
    pb.clearContents(); pb.setData(large, forType: .tiff); again.poll()
    precondition(again.clips.count == 4 && again.clips.contains { $0.items.first?[NSPasteboard.PasteboardType.png.rawValue] != nil })
    print("extras PASS: clipboard icon click, hide/restore, text, image, file, pin, persistence, copy, timer")
}

// MARK: - AI apps: optional menu-bar icons that open Claude, ChatGPT, Gemini and ArtCraft.
// Each opens the installed Mac app (or a Chrome web app of that name). If it's missing, NirTab offers to download and
// install it (checked by Gatekeeper first), then opens it; apps with no Mac download open their website.
struct AIApp {
    let name: String; let bundles: [String]; let names: [String]; let web: String
    let download: (() async throws -> URL)?  // official .dmg; nil = website only
}
let aiApps = [
    AIApp(name: "Claude", bundles: ["com.anthropic.claudefordesktop"], names: ["Claude"], web: "https://claude.ai",
          download: { URL(string: "https://claude.ai/api/desktop/darwin/universal/dmg/latest/redirect")! }),
    AIApp(name: "ChatGPT", bundles: ["com.openai.chat"], names: ["ChatGPT"], web: "https://chatgpt.com",
          download: { URL(string: "https://persistent.oaistatic.com/sidekick/public/ChatGPT.dmg")! }),
    AIApp(name: "Gemini", bundles: ["com.google.GeminiMacOS", "com.google.gemini"], names: ["Gemini"],
          web: "https://gemini.google.com", download: nil),
    AIApp(name: "ArtCraft", bundles: ["ai.storyteller.artcraft-launcher", "ai.artcraft.app"], names: ["ArtCraft Launcher", "ArtCraft"],
          web: "https://getartcraft.com/download", download: {
        // Latest release from the project's GitHub, the same file getartcraft.com/download links to.
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/storytold/artcraft/releases/latest")!)
        let assets = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["assets"] as? [[String: Any]] ?? []
        guard let link = assets.compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.hasSuffix("_universal.dmg") }),
              let url = URL(string: link) else { throw URLError(.fileDoesNotExist) }
        return url
    }),
]
func aiAppURL(_ app: AIApp) -> URL? {
    for id in app.bundles { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url } }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for dir in ["/Applications", "\(home)/Applications", "\(home)/Applications/Chrome Apps.localized"] {
        for name in app.names where FileManager.default.fileExists(atPath: "\(dir)/\(name).app") {
            return URL(fileURLWithPath: "\(dir)/\(name).app")
        }
    }
    return nil
}

@discardableResult
func runTool(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardOutput = pipe; p.standardError = pipe
    guard (try? p.run()) != nil else { return (-1, "") }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, out)
}

// Downloads the .dmg, mounts it, verifies the app with Gatekeeper (signed + notarized), copies it to /Applications
// (or ~/Applications if that isn't writable) and returns the installed app.
func installAIApp(_ app: AIApp) async throws -> URL {
    guard let download = app.download else { throw URLError(.unsupportedURL) }
    let (file, response) = try await URLSession.shared.download(from: try await download())
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("nirtab-install-\(UUID())")
    let mount = work.appendingPathComponent("mnt"), dmg = work.appendingPathComponent("app.dmg")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: file, to: dmg)
    defer {
        runTool("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
        try? FileManager.default.removeItem(at: work)
    }
    guard runTool("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]).0 == 0,
          let bundle = try FileManager.default.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") })
    else { throw CocoaError(.fileReadCorruptFile) }
    let source = mount.appendingPathComponent(bundle)
    let check = runTool("/usr/sbin/spctl", ["--assess", "--type", "execute", source.path])
    guard check.0 == 0 else { throw NSError(domain: "NirTab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Gatekeeper rejected \(bundle): \(check.1)"]) }
    let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    let dir = FileManager.default.isWritableFile(atPath: "/Applications") ? URL(fileURLWithPath: "/Applications") : user
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let target = dir.appendingPathComponent(bundle)
    guard runTool("/usr/bin/ditto", [source.path, target.path]).0 == 0 else { throw CocoaError(.fileWriteUnknown) }
    return target
}

// The `<link rel="icon">` of a web page, resolved against the page URL.
func pageIconURL(_ html: String, base: URL) -> URL? {
    for tag in html.components(separatedBy: "<link").dropFirst() {
        let t = String(tag.prefix { $0 != ">" })
        guard t.contains("rel=\"icon\"") || t.contains("apple-touch-icon"), let r = t.range(of: "href=\"") else { continue }
        return URL(string: String(t[r.upperBound...].prefix { $0 != "\"" }), relativeTo: base)?.absoluteURL
    }
    return nil
}
// App icon if installed; else the website's own icon (downloaded once, cached); a sparkle until that arrives.
func aiIcon(_ app: AIApp, update: @escaping (NSImage) -> Void) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    if let url = aiAppURL(app) {
        let icon = NSWorkspace.shared.icon(forFile: url.path); icon.size = size; return icon
    }
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NirTab")
    let cache = dir.appendingPathComponent("ai-\(app.name).png")
    if let icon = NSImage(contentsOf: cache) { icon.size = size; return icon }
    let page = URL(string: app.web)!
    URLSession.shared.dataTask(with: page) { data, _, _ in
        guard let html = data.flatMap({ String(data: $0, encoding: .utf8) }), let iconURL = pageIconURL(html, base: page) else { return }
        URLSession.shared.dataTask(with: iconURL) { data, _, _ in
            guard let data, let icon = NSImage(data: data) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: cache)
            DispatchQueue.main.async { icon.size = size; update(icon) }
        }.resume()
    }.resume()
    let placeholder = NSImage(systemSymbolName: "sparkle", accessibilityDescription: app.name)!
    placeholder.isTemplate = true
    return placeholder
}

final class AIStatus: NSObject {
    private(set) var items: [NSStatusItem] = []
    func setVisible(_ visible: Bool) {
        items.forEach { NSStatusBar.system.removeStatusItem($0) }
        items = []
        guard visible else { return }
        for (i, app) in aiApps.enumerated().reversed() {  // status items fill right to left; keep the list order
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = aiIcon(app) { [weak item] icon in item?.button?.image = icon }
            item.button?.toolTip = "Open \(app.name)"
            item.button?.tag = i
            item.button?.target = self
            item.button?.action = #selector(open(_:))
            items.append(item)
        }
    }
    private var installing: Set<String> = []
    @objc func open(_ sender: NSStatusBarButton) {
        let app = aiApps[sender.tag]
        if let url = aiAppURL(app) { NSWorkspace.shared.openApplication(at: url, configuration: .init()); return }
        guard app.download != nil else { NSWorkspace.shared.open(URL(string: app.web)!); return }
        guard !installing.contains(app.name) else { return }
        let ask = NSAlert()
        ask.messageText = "\(app.name) isn't installed"
        ask.informativeText = "Download \(app.name) from its official site, install it in Applications and open it?"
        ask.addButton(withTitle: "Install"); ask.addButton(withTitle: "Open Website"); ask.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch ask.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn: NSWorkspace.shared.open(URL(string: app.web)!); return
        default: return
        }
        installing.insert(app.name)
        let icon = sender.image
        sender.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Installing \(app.name)")
        sender.toolTip = "Installing \(app.name)…"
        Task {
            let result = await Task.detached { () -> Result<URL, Error> in
                do { return .success(try await installAIApp(app)) } catch { return .failure(error) }
            }.value
            await MainActor.run {
                self.installing.remove(app.name)
                sender.toolTip = "Open \(app.name)"
                switch result {
                case .success(let url):
                    let installed = NSWorkspace.shared.icon(forFile: url.path)
                    installed.size = NSSize(width: 18, height: 18)
                    sender.image = installed
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                case .failure(let error):
                    sender.image = icon
                    let fail = NSAlert()
                    fail.messageText = "Couldn't install \(app.name)"
                    fail.informativeText = "\(error.localizedDescription)\n\nOpening the download page instead."
                    fail.runModal()
                    NSWorkspace.shared.open(URL(string: app.web.hasSuffix("/download") ? app.web : app.web + "/download")!)
                }
            }
        }
    }
}
let aiStatus = AIStatus()
