import AppKit
import UniformTypeIdentifiers

// MARK: - Settings

enum VideoOutput: String, CaseIterable {
    case sheetAndFrames, sheet, frames

    var title: String {
        switch self {
        case .sheetAndFrames: return "Contact sheet + frames"
        case .sheet: return "Contact sheet only"
        case .frames: return "Frames only"
        }
    }
}

enum VideoForAI: String { case frames, video }

enum Settings {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "showShelfOnDrag": false, // fully automatic: no pop-ups
            "fixClipboardImages": true,
            "convertCopiedFiles": false,
            "videoOutput": VideoOutput.sheetAndFrames.rawValue,
            "frameCount": 8,
            "transcribe": true,
            "maxImageEdge": 4096,
            "jpegQuality": 0.85,
            "autoFix": true,
            "replaceOriginal": false,
            "videoForAI": VideoForAI.video.rawValue, // Claude & co accept video now
            "useICloudOriginals": true,
        ])
    }

    static var showShelfOnDrag: Bool {
        get { d.bool(forKey: "showShelfOnDrag") }
        set { d.set(newValue, forKey: "showShelfOnDrag") }
    }
    /// Adds Claude-readable JPEG/PNG flavors when the clipboard only holds HEIC image data.
    static var fixClipboardImages: Bool {
        get { d.bool(forKey: "fixClipboardImages") }
        set { d.set(newValue, forKey: "fixClipboardImages") }
    }
    /// Replaces copied HEIC *files* (e.g. from Finder) with JPEG copies. Off by default because
    /// it changes what a later paste in Finder produces.
    static var convertCopiedFiles: Bool {
        get { d.bool(forKey: "convertCopiedFiles") }
        set { d.set(newValue, forKey: "convertCopiedFiles") }
    }
    static var videoOutput: VideoOutput {
        get { VideoOutput(rawValue: d.string(forKey: "videoOutput") ?? "") ?? .sheetAndFrames }
        set { d.set(newValue.rawValue, forKey: "videoOutput") }
    }
    static var frameCount: Int {
        get { max(2, min(20, d.integer(forKey: "frameCount"))) }
        set { d.set(newValue, forKey: "frameCount") }
    }
    static var transcribe: Bool {
        get { d.bool(forKey: "transcribe") }
        set { d.set(newValue, forKey: "transcribe") }
    }
    static var maxImageEdge: Int {
        get { max(512, min(8000, d.integer(forKey: "maxImageEdge"))) }
        set { d.set(newValue, forKey: "maxImageEdge") }
    }
    static var jpegQuality: Double { d.double(forKey: "jpegQuality") }
    /// Convert wheel: replace the original (it goes to the Trash) instead of saving a new file next
    /// to it. Holding ⌥ while picking a format does the opposite for that one conversion.
    /// Never applies to the automatic Photos fix, which doesn't touch your files.
    static var replaceOriginal: Bool {
        get { d.bool(forKey: "replaceOriginal") }
        set { d.set(newValue, forKey: "replaceOriginal") }
    }
    /// Zero-touch mode: fix drags from Photos in flight, no shelf.
    static var autoFix: Bool {
        get { d.bool(forKey: "autoFix") }
        set { d.set(newValue, forKey: "autoFix") }
    }
    /// Let macOS fetch originals that only live in your iCloud Photos library (your own data, via
    /// Photos — the same download Photos does when you drag to Finder). Off = this Mac only.
    static var useICloudOriginals: Bool {
        get { d.bool(forKey: "useICloudOriginals") }
        set { d.set(newValue, forKey: "useICloudOriginals") }
    }
    static var videoForAI: VideoForAI {
        get { VideoForAI(rawValue: d.string(forKey: "videoForAI") ?? "") ?? .frames }
        set { d.set(newValue.rawValue, forKey: "videoForAI") }
    }
}

// MARK: - Logging (doubles as a pasteboard probe)

enum Log {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Morphlo/morphlo.log")
    private static let queue = DispatchQueue(label: "morphlo.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        #if DEBUG
        FileHandle.standardError.write(line.data(using: .utf8)!)
        #endif
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            }
        }
    }

    /// Human-readable dump of every item and type on a pasteboard.
    static func describe(_ pb: NSPasteboard) -> String {
        var out: [String] = []
        for (i, item) in (pb.pasteboardItems ?? []).enumerated() {
            var parts: [String] = []
            for t in item.types {
                var s = t.rawValue
                if t == .fileURL || t.rawValue == "public.url" || t.rawValue.contains("suggested-file-name")
                    || t.rawValue.contains("content-type") {
                    if let v = item.string(forType: t) { s += "=\(v)" }
                }
                parts.append(s)
            }
            out.append("  item[\(i)]: " + parts.joined(separator: ", "))
        }
        return out.isEmpty ? "  (no items)" : out.joined(separator: "\n")
    }
}

// MARK: - Work directories

enum WorkDir {
    static let root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("io.github.mocinjay.morphlo", isDirectory: true)

    static func make() -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = root.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Removes job folders older than a day.
    static func cleanOld() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for d in dirs {
            let created = (try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: d) }
        }
    }

    /// `dir/base.ext`, or `dir/base 2.ext` etc. if taken.
    static func unique(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        // open(O_CREAT|O_EXCL) reserves the name atomically, so parallel jobs can't collide.
        while true {
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 { close(fd); return url }
            if errno != EEXIST || n > 9999 { return url }
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
    }
}

// MARK: - Helpers

extension URL {
    var contentType: UTType? {
        if let t = try? resourceValues(forKeys: [.contentTypeKey]).contentType { return t }
        return UTType(filenameExtension: pathExtension)
    }
    var baseName: String { deletingPathExtension().lastPathComponent }
}

extension NSPasteboard.PasteboardType {
    /// Marks pasteboard content Morphlo wrote, so the watchers ignore it.
    static let morphloMarker = NSPasteboard.PasteboardType("io.github.mocinjay.morphlo.converted")
    static let heic = NSPasteboard.PasteboardType(UTType.heic.identifier)
    static let heif = NSPasteboard.PasteboardType(UTType.heif.identifier)
    static let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
}

func formatTime(_ seconds: Double, precise: Bool = false) -> String {
    guard seconds.isFinite else { return "?:??" }
    if precise && seconds < 60 { return String(format: "0:%04.1f", max(0, seconds)) }
    let s = max(0, Int(seconds.rounded(.down)))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
