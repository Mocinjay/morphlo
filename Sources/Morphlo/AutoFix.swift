import AppKit
import ApplicationServices
import Photos

// MARK: - Where is the drag heading?

enum Destination: Equatable {
    case morphlo                 // our own shelf: let it receive the real promise
    case photos                // still inside Photos (dragging into an album etc.): never touch
    case passthrough(String)   // apps that already handle Photos drags properly (Finder, Mail…)
    case aiChat(String)        // Claude, ChatGPT, Gemini… — no video support, so send frames
    case general(String)       // everything else: browsers, Electron apps, upload forms
    case nowhere

    var wantsSwap: Bool {
        switch self {
        case .aiChat, .general: return true
        default: return false
        }
    }
}

enum DestinationDetector {
    /// Apps that fulfil Photos' file promises themselves, so they already get the original.
    static let promiseAware: Set<String> = [
        "com.apple.finder", "com.apple.mail", "com.apple.MobileSMS", "com.apple.Notes", "com.apple.Preview",
        "com.apple.iWork.Pages", "com.apple.iWork.Keynote", "com.apple.iWork.Numbers", "com.apple.TextEdit",
        "com.apple.iMovieApp", "com.apple.FinalCut", "com.apple.freeform", "com.apple.Photos",
    ]
    /// Native AI chat apps.
    static let aiApps: [String: String] = [
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.chat": "ChatGPT",
        "com.openai.chatgpt": "ChatGPT",
        "ai.perplexity.mac": "Perplexity",
        "com.google.GeminiMacOS": "Gemini",
    ]
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.microsoft.edgemac", "com.apple.Safari",
        "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "ai.perplexity.comet",
        "org.chromium.Chromium",
    ]
    /// Matched against a browser window's title (the active tab's title).
    static let aiTitleWords = ["Claude", "ChatGPT", "Gemini", "Grok", "Perplexity", "Copilot", "DeepSeek",
                               "Le Chat", "Mistral", "Poe", "AI Studio", "NotebookLM", "Meta AI"]

    /// `point` is in Cocoa screen coordinates (origin bottom-left of the primary screen).
    static func destination(at point: NSPoint) -> Destination {
        guard let primary = NSScreen.screens.first else { return .nowhere }
        let cg = CGPoint(x: point.x, y: primary.frame.height - point.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return .nowhere }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list { // front to back
            guard let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(cg),
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if pid == me { return .morphlo }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha == 0 { continue }
            // Only normal windows count: the drag image, the Dock's full-screen overlay, menus etc.
            // live on higher layers and must not hide the real target.
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            let windowNumber = (w[kCGWindowNumber as String] as? Int) ?? 0
            return classify(bundle: bundle, pid: pid, window: windowNumber, bounds: bounds)
        }
        return .nowhere
    }

    private static func classify(bundle: String, pid: pid_t, window: Int, bounds: CGRect) -> Destination {
        if bundle == "com.apple.Photos" { return .photos }
        if let name = aiApps[bundle] { return .aiChat(name) }
        if browsers.contains(bundle) {
            if let title = windowTitle(pid: pid, window: window, bounds: bounds),
               let word = aiTitleWords.first(where: { title.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil }) {
                return .aiChat(word)
            }
            return .general(bundle)
        }
        if promiseAware.contains(bundle) { return .passthrough(bundle) }
        return .general(bundle)
    }

    private static var titleCache: [Int: (title: String?, at: Date)] = [:]

    /// Title of the browser window under the cursor, via Accessibility (only if granted).
    /// Matches the AX window by frame against the CG window, with a short IPC timeout, and caches
    /// per window number so the 60 Hz drag tick stays cheap.
    static func windowTitle(pid: pid_t, window: Int, bounds: CGRect) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        if let c = titleCache[window], Date().timeIntervalSince(c.at) < 2 { return c.title }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var title: String?
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for w in windows {
                var posRef: CFTypeRef?, sizeRef: CFTypeRef?
                var pos = CGPoint.zero, size = CGSize.zero
                if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success, let posRef {
                    AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                }
                if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success, let sizeRef {
                    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                }
                if abs(pos.x - bounds.minX) < 4 && abs(pos.y - bounds.minY) < 4 && abs(size.width - bounds.width) < 4 {
                    var t: CFTypeRef?
                    if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success { title = t as? String }
                    break
                }
            }
        }
        titleCache[window] = (title, Date())
        return title
    }
}

// MARK: - Photos library access

enum PhotoLibrary {
    static let assetRefType = NSPasteboard.PasteboardType("com.apple.photos.object-reference.asset")

    static var status: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    static var canRead: Bool { status == .authorized || status == .limited }

    static func requestAccess() async -> Bool {
        if status == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return canRead
    }

    /// The asset IDs Photos puts on every drag it starts.
    static func localIdentifiers(in pb: NSPasteboard) -> [String] {
        (pb.pasteboardItems ?? []).compactMap { item in
            guard let data = item.data(forType: assetRefType),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return plist["localIdentifier"] as? String
        }
    }

    enum Kind { case photo, video }

    /// Writes the asset's current version (edits included) at full quality into `dir`.
    /// Downloads from iCloud if needed.
    static func exportOriginal(localIdentifier: String, to dir: URL) async throws -> (URL, Kind) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            throw ConvertError.unreadable("Photos item")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let isVideo = asset.mediaType == .video
        let preferred: [PHAssetResourceType] = isVideo ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo, .alternatePhoto]
        guard let resource = preferred.lazy.compactMap({ t in resources.first { $0.type == t } }).first else {
            throw ConvertError.unreadable("Photos item")
        }
        // Name it after the original (an edited resource is called "FullSizeRender").
        let original = resources.first { $0.type == (isVideo ? .video : .photo) } ?? resource
        let base = (original.originalFilename as NSString).deletingPathExtension
        let ext = (resource.originalFilename as NSString).pathExtension
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(base).appendingPathExtension(ext.isEmpty ? (isVideo ? "mov" : "jpg") : ext)
        try? FileManager.default.removeItem(at: out) // writeData refuses to overwrite

        let options = PHAssetResourceRequestOptions()
        // Morphlo never goes online itself. An original that only lives in iCloud fails here, and
        // the shelf takes over (Photos fulfils the drag's promise, downloading it if needed).
        options.isNetworkAccessAllowed = false
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: out, options: options) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        return (out, isVideo ? .video : .photo)
    }
}

// MARK: - Zero-touch session

extension NSPasteboard.PasteboardType {
    /// Marks drags AutoFix rewrote. Unlike `morphloMarker`, the shelf still accepts these.
    static let autoFixMarker = NSPasteboard.PasteboardType("io.github.mocinjay.morphlo.autofix")
}

/// Handles one drag that started in Photos: fetches the originals as soon as the drag begins,
/// converts them, and swaps the drag's contents as soon as the cursor leaves Photos, so the
/// destination reads fixed files when the cursor enters it.
@MainActor
final class AutoFix {
    struct Prepared {
        let kind: PhotoLibrary.Kind
        let original: URL      // full-quality original, for apps that handle originals fine
        let converted: URL     // JPEG for photos, the real video for videos
        let frames: [URL]      // videos only: contact sheet + frames, for AI chats
    }

    enum Payload: Equatable { case originals, converted, forAI }

    private final class Session {
        let ids: [String]
        let workDir = WorkDir.make()
        var prepared: [Prepared]?
        var failed = false
        var payload: Payload?
        var assetRefs: [Data] = []
        var leftPhotosAt: Date?
        var fellBack = false
        var task: Task<Void, Never>?
        init(ids: [String]) { self.ids = ids }
    }

    private var session: Session?
    private let pb = NSPasteboard(name: .drag)
    var onOwnWrite: (() -> Void)?
    var onFallback: (() -> Void)?

    static var isEnabled: Bool { Settings.autoFix && PhotoLibrary.canRead }

    /// Returns true if this drag is being handled (so the shelf shouldn't pop up yet).
    func dragStarted(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        guard !types.contains(.morphloMarker), !types.contains(.autoFixMarker) else { return false }
        let ids = PhotoLibrary.localIdentifiers(in: pasteboard)
        guard !ids.isEmpty else { return false }
        guard Self.isEnabled else {
            Log.write("AutoFix: off (setting=\(Settings.autoFix), photos access=\(PhotoLibrary.status.rawValue))")
            return false
        }
        let s = Session(ids: ids)
        s.assetRefs = (pasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: PhotoLibrary.assetRefType) }
        session = s
        Log.write("AutoFix: drag of \(ids.count) item(s) from Photos, preparing")
        let started = Date()
        s.task = Task.detached(priority: .userInitiated) {
            var results: [Prepared] = []
            var failures = 0
            for (i, id) in ids.enumerated() {
                if Task.isCancelled { return }
                do {
                    let dir = s.workDir.appendingPathComponent("item-\(i)")
                    let (original, kind) = try await PhotoLibrary.exportOriginal(localIdentifier: id, to: dir.appendingPathComponent("original"))
                    let out = dir.appendingPathComponent("out")
                    switch kind {
                    case .photo:
                        // Full resolution (within Claude's 8000px / 10 MB limits) — uploads elsewhere
                        // shouldn't be downscaled.
                        let jpeg = try ImageConverter.convert(original, outDir: out, maxEdge: ImageConverter.maxEdge)
                        results.append(Prepared(kind: .photo, original: original, converted: jpeg, frames: []))
                    case .video:
                        let frames = (try? await VideoConverter.convert(original, outDir: out, transcribe: false)) ?? []
                        results.append(Prepared(kind: .video, original: original, converted: original, frames: frames))
                    }
                } catch {
                    failures += 1
                    Log.write("AutoFix: couldn't prepare \(id): \(error.localizedDescription)")
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            let done = results
            let anyFailed = failures > 0
            await MainActor.run {
                // All-or-nothing: never silently drop items from a multi-item drag.
                if anyFailed || done.isEmpty { s.failed = true } else { s.prepared = done }
                Log.write(String(format: "AutoFix: prepared %d/%d in %.2fs", done.count, ids.count, elapsed))
            }
        }
        return true
    }

    /// Called every poll tick while the mouse button is held.
    func dragMoved(to point: NSPoint) {
        guard let s = session else { return }
        let dest = DestinationDetector.destination(at: point)

        if case .photos = dest {
            if s.payload != nil { restoreForPhotos(s) }
            return
        }
        if s.leftPhotosAt == nil { s.leftPhotosAt = Date() }
        if s.fellBack { return } // the shelf is handling this drag now

        if s.failed {
            fallBack(s, reason: "preparation failed")
            return
        }
        guard let prepared = s.prepared else {
            if let left = s.leftPhotosAt, Date().timeIntervalSince(left) > 0.35, dest.wantsSwap {
                fallBack(s, reason: "not ready in time")
            }
            return
        }
        // Swap as early as possible (even over empty desktop), then only switch payloads.
        let payload: Payload
        switch dest {
        case .passthrough, .morphlo: payload = .originals // Finder & co. and our shelf want the real original
        case .aiChat: payload = Settings.videoForAI == .frames ? .forAI : .converted
        default: payload = .converted
        }
        if payload != s.payload { write(s, prepared, payload: payload, dest: dest) }
    }

    func dragEnded() {
        guard let s = session else { return }
        session = nil
        Log.write("AutoFix: drag ended (payload \(String(describing: s.payload)))")
        if s.payload == nil {
            // Never used (dragged within Photos, or fell back): stop work and clean up.
            s.task?.cancel()
            let dir = s.workDir
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { try? FileManager.default.removeItem(at: dir) }
        }
    }

    private func fallBack(_ s: Session, reason: String) {
        guard !s.fellBack else { return }
        s.fellBack = true
        if s.payload != nil { restoreForPhotos(s) }
        Log.write("AutoFix: \(reason), showing shelf")
        onFallback?()
    }

    private func write(_ s: Session, _ prepared: [Prepared], payload: Payload, dest: Destination) {
        let urls = prepared.flatMap { p -> [URL] in
            switch payload {
            case .originals: return [p.original]
            case .converted: return [p.converted]
            case .forAI: return p.kind == .video && !p.frames.isEmpty ? p.frames : [p.converted]
            }
        }
        pb.clearContents()
        pb.writeObjects(urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString("1", forType: .autoFixMarker)
            return item
        })
        onOwnWrite?()
        s.payload = payload
        Log.write("AutoFix: drag now carries \(payload) for \(dest) -> \(urls.map(\.lastPathComponent))")
    }

    /// Back over Photos: put the asset references back so drops into albums keep working.
    /// (Photos' file promises can't be recreated, so only the references go back.)
    private func restoreForPhotos(_ s: Session) {
        pb.clearContents()
        pb.writeObjects(s.assetRefs.map { ref in
            let item = NSPasteboardItem()
            item.setData(ref, forType: PhotoLibrary.assetRefType)
            return item
        })
        onOwnWrite?()
        s.payload = nil
        Log.write("AutoFix: over Photos, restored asset references")
    }
}
