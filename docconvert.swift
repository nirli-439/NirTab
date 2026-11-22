import AppKit

// Convert a copied document (Finder ⌘C) to Markdown with Firecrawl's anydoc (MIT, https://github.com/firecrawl/anydoc).
// anydoc runs locally; only the explicit OCR option uploads the file to Firecrawl Parse.

let anydocExtensions: Set<String> = ["doc", "docx", "docm", "dotx", "ppt", "pps", "pot", "pptx", "pptm", "ppsx", "ppsm",
                                     "xls", "xlsx", "xlsm", "xlsb", "odt", "ods", "odp", "rtf", "epub", "csv", "pdf"]

enum DocConvertMode: String, CaseIterable {
    case copy, save, saveOpen, ocrCopy
    var title: String {
        switch self {
        case .copy: return "Copy as Markdown"
        case .save: return "Save as .md Next to File"
        case .saveOpen: return "Save as .md and Open"
        case .ocrCopy: return "Scanned PDF → Copy as Markdown (uploads to Firecrawl OCR)"
        }
    }
}

// Supported document files currently on the clipboard.
func copiedDocuments(_ pb: NSPasteboard = .general) -> [URL] {
    let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return urls.filter { anydocExtensions.contains($0.pathExtension.lowercased()) }
}

// GUI apps get a minimal PATH, so look in the usual Node locations; use a global `anydoc` if present, else npx.
func runAnydoc(_ file: URL, ocr: Bool) -> (ok: Bool, markdown: String, error: String) {
    let p = Process(), out = Pipe(), err = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    let script = """
    export PATH="$HOME/.local/bin:$HOME/.volta/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    [ -s "$HOME/.nvm/nvm.sh" ] && ! command -v npx >/dev/null && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
    if command -v anydoc >/dev/null; then exec anydoc "$@"; fi
    if command -v npx >/dev/null; then exec npx -y @firecrawl/anydoc "$@"; fi
    echo "Node.js not found. Install Node (brew install node), or: npm install -g @firecrawl/anydoc" >&2; exit 127
    """
    p.arguments = ["-lc", script, "anydoc", file.path] + (ocr ? ["--ocr", "hosted"] : [])
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (false, "", error.localizedDescription) }
    var stdout = Data()
    let reader = DispatchQueue(label: "anydoc.stdout")
    let group = DispatchGroup()
    group.enter()
    reader.async { stdout = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }  // avoid pipe-buffer deadlock
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    p.waitUntilExit()
    let md = String(data: stdout, encoding: .utf8) ?? ""
    var msg = (String(data: stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if p.terminationStatus == 3 { msg = "This PDF is scanned (image-only). Use the OCR option to convert it.\n\(msg)" }
    return (p.terminationStatus == 0, md, msg)
}

func markdownURL(for file: URL) -> URL {
    let dir = file.deletingLastPathComponent(), base = file.deletingPathExtension().lastPathComponent
    var url = dir.appendingPathComponent(base + ".md"), n = 2
    while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(base) \(n).md"); n += 1 }
    return url
}

func convertCopiedDocuments(_ mode: DocConvertMode, files: [URL]? = nil, done: ((Bool) -> Void)? = nil) {
    let files = files ?? copiedDocuments()
    guard !files.isEmpty else {
        showAlert("No document copied", "Copy a document in Finder (⌘C) first: Word, PowerPoint, Excel, PDF, RTF, EPUB, CSV or OpenDocument.")
        done?(false); return
    }
    DispatchQueue.global(qos: .userInitiated).async {
        var parts: [String] = [], failures: [String] = [], saved: [URL] = []
        for file in files {
            let r = runAnydoc(file, ocr: mode == .ocrCopy)
            guard r.ok else { failures.append("\(file.lastPathComponent): \(r.error.isEmpty ? "conversion failed" : r.error)"); continue }
            if mode == .save || mode == .saveOpen {
                let target = markdownURL(for: file)
                do { try r.markdown.write(to: target, atomically: true, encoding: .utf8); saved.append(target) }
                catch { failures.append("\(file.lastPathComponent): \(error.localizedDescription)") }
            } else {
                parts.append(files.count > 1 ? "<!-- \(file.lastPathComponent) -->\n\n\(r.markdown)" : r.markdown)
            }
        }
        DispatchQueue.main.async {
            switch mode {
            case .copy, .ocrCopy:
                if !parts.isEmpty {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(parts.joined(separator: "\n\n---\n\n"), forType: .string)
                    if defaults.bool(forKey: "clipboardEnabled") { clipboard.poll() }
                }
            case .save:
                if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
            case .saveOpen:
                saved.forEach { NSWorkspace.shared.open($0) }
            }
            let ok = failures.isEmpty
            if ok { NSSound(named: "Glass")?.play() }
            else { showAlert("Couldn't convert \(failures.count == files.count ? "the document" : "some documents")", failures.joined(separator: "\n\n")) }
            done?(ok)
        }
    }
}

// Submenu rebuilt each time it opens, so it reflects what's on the clipboard right now.
final class DocConvertMenu: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let files = copiedDocuments()
        let head = NSMenuItem(title: files.isEmpty ? "Copy a document in Finder first (⌘C)"
                              : files.count == 1 ? "Copied: \(files[0].lastPathComponent)" : "Copied: \(files.count) documents",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if files.isEmpty {
            let hint = NSMenuItem(title: "Word, PowerPoint, Excel, PDF, RTF, EPUB, CSV, OpenDocument", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            return
        }
        menu.addItem(.separator())
        for mode in DocConvertMode.allCases {
            if mode == .ocrCopy {
                guard files.contains(where: { $0.pathExtension.lowercased() == "pdf" }) else { continue }
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: mode.title, action: #selector(convert(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
    }
    @objc func convert(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DocConvertMode(rawValue: raw) else { return }
        convertCopiedDocuments(mode)
    }
}
let docConvertMenu = DocConvertMenu()
