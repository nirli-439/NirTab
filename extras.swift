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

struct ClipboardView: View {
    @ObservedObject var history: ClipboardHistory
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clipboard history").font(.title2.bold())
                Spacer()
                Text("⌥⌘V").foregroundStyle(.secondary)
            }
            Text("Saved in Documents/NirTab · not encrypted · file entries reference their original files")
                .font(.caption).foregroundStyle(.secondary)
            if let error = history.storageError { Text("Couldn't save clipboard: \(error)").foregroundStyle(.red) }
            if history.clips.isEmpty { Spacer(); Text("Copy text, an image, or files to get started.").foregroundStyle(.secondary); Spacer() }
            else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(history.clips) { clip in
                            HStack(spacing: 10) {
                                if let thumbnail = clip.thumbnail {
                                    Image(nsImage: thumbnail).resizable().scaledToFit().frame(width: 32, height: 32)
                                } else { Image(systemName: clip.symbol).frame(width: 32) }
                                Text(clip.label).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Button("Copy") { if history.copy(clip) { clipboardWindow?.close() } }
                                Button { history.pin(clip) } label: {
                                    Image(systemName: clip.pinned ? "pin.fill" : "pin")
                                }.help(clip.pinned ? "Unpin" : "Pin")
                                    .disabled(!clip.pinned && history.clips.filter(\.pinned).count >= 20)
                                Button { history.remove(clip) } label: { Image(systemName: "trash") }.help("Delete")
                            }.padding(9).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }
        }.padding(20).frame(width: 560, height: 500)
    }
}

func openClipboard() {
    guard defaults.bool(forKey: "clipboardEnabled") else { return }
    clipboard.poll()
    if clipboardWindow == nil {
        let w = NSWindow(contentViewController: NSHostingController(rootView: ClipboardView(history: clipboard)))
        w.title = "NirTab Clipboard"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        clipboardWindow = w
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
    var popup: NSPanel?

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
        let title = NSMenuItem(title: phase == "idle" ? "Pomodoro · ready" : "\(phase.capitalized) · \(timerText(deadline?.timeIntervalSinceNow ?? paused ?? 0))", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        for (name, action) in [("Start Focus", #selector(startFocus)), (deadline == nil ? "Resume" : "Pause", #selector(pauseResume)), ("Start Break ☕", #selector(startBreak)), ("Reset", #selector(reset))] {
            let row = NSMenuItem(title: name, action: action, keyEquivalent: "")
            row.target = self; row.isEnabled = name != "Resume" || paused != nil
            menu.addItem(row)
        }
    }
    func breakPopup() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 170), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "NirTab · Coffee break"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: VStack(spacing: 12) {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 34)).foregroundStyle(.brown)
            Text("Break time!").font(.title2.bold())
            Text("Take a break. Your timer is running.").foregroundStyle(.secondary)
            Button("Dismiss") { panel.close() }
        }.frame(width: 340, height: 150))
        popup = panel
        panel.center(); panel.orderFrontRegardless()
    }
}

let pomodoro = Pomodoro()

func testExtras() {
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
    print("extras PASS: text, image, file, pin, persistence, copy, timer")
}
