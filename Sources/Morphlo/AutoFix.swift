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

    struct Plan {
        let resource: PHAssetResource
        let kind: Kind
        let base: String
        let ext: String
    }

    /// Instant (metadata only): which file a drag will need, and what it's called.
    static func plan(localIdentifier: String) -> Plan? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        let isVideo = asset.mediaType == .video
        let preferred: [PHAssetResourceType] = isVideo ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo, .alternatePhoto]
        guard let resource = preferred.lazy.compactMap({ t in resources.first { $0.type == t } }).first else { return nil }
        // Name it after the original (an edited resource is called "FullSizeRender").
        let original = resources.first { $0.type == (isVideo ? .video : .photo) } ?? resource
        let base = (original.originalFilename as NSString).deletingPathExtension
        var ext = (resource.originalFilename as NSString).pathExtension
        if ext.isEmpty { ext = isVideo ? "mov" : "jpg" }
        return Plan(resource: resource, kind: isVideo ? .video : .photo, base: base, ext: ext)
    }

    /// Writes the asset's current version (edits included) at full quality to `url` (must not exist).
    /// If the original only lives in iCloud, macOS downloads it from the user's own iCloud Photos
    /// library (the same thing Photos does when you drag to Finder), unless that's turned off.
    static func write(_ plan: Plan, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url) // writeData refuses to overwrite
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = Settings.useICloudOriginals
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: plan.resource, toFile: url, options: options) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
}

// MARK: - Zero-touch session

extension NSPasteboard.PasteboardType {
    /// Marks drags AutoFix rewrote. Unlike `morphloMarker`, the shelf still accepts these.
    static let autoFixMarker = NSPasteboard.PasteboardType("io.github.mocinjay.morphlo.autofix")
}

/// Fixes drags in flight, with no UI. As soon as a drag starts (from Photos, or files like HEIC
/// from Finder), Morphlo decides the final file names and creates them as placeholders. The moment
/// the drag leaves its source window it swaps those paths into the drag — so the destination
/// (which reads the paths when the cursor enters it) always sees the fixed files — and fills them
/// in while you're still moving. Photos and Finder themselves get the untouched originals.
@MainActor
final class AutoFix {
    struct Item {
        let kind: PhotoLibrary.Kind
        let original: URL   // full-quality original (for Finder, Mail…)
        let converted: URL  // what browsers, Electron apps and AI chats get
    }

    enum Payload: Equatable { case originals, converted, forAI }

    private final class Session {
        let fromPhotos: Bool
        let workDir = WorkDir.make()
        var items: [Item] = []
        var frames: [URL] = []           // optional AI mode for videos
        var ready = false
        var failed = false
        var payload: Payload?
        var assetRefs: [Data] = []
        var sourceURLs: [URL] = []       // what the drag carried before we touched it
        var task: Task<Void, Never>?
        init(fromPhotos: Bool) { self.fromPhotos = fromPhotos }
    }

    private var session: Session?
    private let pb = NSPasteboard(name: .drag)
    var onOwnWrite: (() -> Void)?

    static var isEnabled: Bool { Settings.autoFix && PhotoLibrary.canRead }

    /// Returns true if this drag is being handled.
    func dragStarted(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        guard Settings.autoFix, !types.contains(.morphloMarker), !types.contains(.autoFixMarker) else { return false }
        let ids = PhotoLibrary.localIdentifiers(in: pasteboard)
        if !ids.isEmpty {
            guard PhotoLibrary.canRead else {
                Log.write("AutoFix: Photos access not granted (status \(PhotoLibrary.status.rawValue))")
                return false
            }
            return startPhotos(ids, pasteboard)
        }
        let urls = DropIntake.fileURLs(pasteboard)
        guard !urls.isEmpty, urls.count <= 50,
              urls.contains(where: { ImageConverter.needsConversion($0, maxEdge: ImageConverter.maxEdge) }) else { return false }
        return startFiles(urls)
    }

    private func touch(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    /// Drag from Photos: plan names now (metadata only), create placeholders, fetch in the background.
    private func startPhotos(_ ids: [String], _ pasteboard: NSPasteboard) -> Bool {
        let plans = ids.map { PhotoLibrary.plan(localIdentifier: $0) }
        guard plans.allSatisfy({ $0 != nil }) else { Log.write("AutoFix: some Photos items unavailable"); return false }
        let s = Session(fromPhotos: true)
        s.assetRefs = (pasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: PhotoLibrary.assetRefType) }
        s.sourceURLs = DropIntake.fileURLs(pasteboard)
        for (i, p) in plans.compactMap({ $0 }).enumerated() {
            let dir = s.workDir.appendingPathComponent("item-\(i)")
            let original = dir.appendingPathComponent("original").appendingPathComponent(p.base).appendingPathExtension(p.ext)
            let converted = p.kind == .photo
                ? dir.appendingPathComponent("out").appendingPathComponent(p.base).appendingPathExtension("jpg")
                : original
            touch(original)
            if converted != original { touch(converted) }
            s.items.append(Item(kind: p.kind, original: original, converted: converted))
        }
        session = s
        Log.write("AutoFix: drag of \(ids.count) item(s) from Photos")
        let items = s.items, workDir = s.workDir, wantFrames = Settings.videoForAI == .frames
        let started = Date()
        let resolved = plans.compactMap { $0 }
        s.task = Task.detached(priority: .userInitiated) {
            do {
                var frames: [URL] = []
                for (i, (plan, item)) in zip(resolved, items).enumerated() {
                    try Task.checkCancellation()
                    let tmp = workDir.appendingPathComponent("tmp-\(i)")
                    let tmpOriginal = tmp.appendingPathComponent(item.original.lastPathComponent)
                    try await PhotoLibrary.write(plan, to: tmpOriginal)
                    if item.kind == .photo {
                        // Full resolution (within 8000px / 10 MB) for uploads; HEIC & co become JPEG.
                        var jpeg = try ImageConverter.convert(tmpOriginal, outDir: tmp.appendingPathComponent("out"), maxEdge: ImageConverter.maxEdge)
                        if jpeg == tmpOriginal {
                            let copy = tmp.appendingPathComponent("copy.jpg")
                            try FileManager.default.copyItem(at: tmpOriginal, to: copy)
                            jpeg = copy
                        }
                        _ = try FileManager.default.replaceItemAt(item.converted, withItemAt: jpeg)
                    }
                    _ = try FileManager.default.replaceItemAt(item.original, withItemAt: tmpOriginal)
                    if item.kind == .video, wantFrames {
                        frames += (try? await VideoConverter.convert(item.original, outDir: tmp.appendingPathComponent("frames"), transcribe: false)) ?? []
                    }
                }
                let elapsed = Date().timeIntervalSince(started)
                let doneFrames = frames
                await MainActor.run {
                    s.frames = doneFrames
                    s.ready = true
                    Log.write(String(format: "AutoFix: originals ready in %.2fs", elapsed))
                }
            } catch {
                await MainActor.run {
                    s.failed = true
                    Log.write("AutoFix: couldn't fetch from Photos: \(error.localizedDescription)")
                    self.fallBackToSource(s)
                }
            }
        }
        return true
    }

    /// Drag of files (e.g. HEIC from Finder): convert the ones apps can't read, keep the rest.
    private func startFiles(_ urls: [URL]) -> Bool {
        let s = Session(fromPhotos: false)
        s.sourceURLs = urls
        var jobs: [(URL, URL)] = []
        for (i, url) in urls.enumerated() {
            let needs = ImageConverter.needsConversion(url, maxEdge: ImageConverter.maxEdge)
            let converted = needs
                ? s.workDir.appendingPathComponent("item-\(i)").appendingPathComponent(url.baseName).appendingPathExtension("jpg")
                : url
            if needs { touch(converted); jobs.append((url, converted)) }
            s.items.append(Item(kind: .photo, original: url, converted: converted))
        }
        session = s
        Log.write("AutoFix: drag of \(urls.count) file(s), converting \(jobs.count)")
        let workDir = s.workDir
        s.task = Task.detached(priority: .userInitiated) {
            do {
                for (i, (src, dest)) in jobs.enumerated() {
                    let jpeg = try ImageConverter.convert(src, outDir: workDir.appendingPathComponent("tmp-\(i)"), maxEdge: ImageConverter.maxEdge)
                    _ = try FileManager.default.replaceItemAt(dest, withItemAt: jpeg)
                }
                await MainActor.run { s.ready = true; Log.write("AutoFix: files converted") }
            } catch {
                await MainActor.run {
                    s.failed = true
                    Log.write("AutoFix: couldn't convert: \(error.localizedDescription)")
                    self.fallBackToSource(s)
                }
            }
        }
        return true
    }

    /// Called every poll tick while the mouse button is held.
    func dragMoved(to point: NSPoint) {
        guard let s = session, !s.failed else { return }
        let dest = DestinationDetector.destination(at: point)
        switch dest {
        case .photos where s.fromPhotos:
            if s.payload != nil { restoreForPhotos(s) } // back inside Photos (e.g. into an album)
            return
        case .passthrough, .morphlo, .photos:
            // Finder, Mail, our own disc… get the untouched originals — but only rewrite if we
            // already swapped, so drags inside Finder are never touched.
            if s.payload != nil, s.payload != .originals { write(s, .originals, dest) }
            return
        case .aiChat:
            let frames = Settings.videoForAI == .frames && s.ready && !s.frames.isEmpty
            let p: Payload = frames ? .forAI : .converted
            if p != s.payload { write(s, p, dest) }
        case .general, .nowhere:
            if s.payload != .converted { write(s, .converted, dest) }
        }
    }

    func dragEnded() {
        guard let s = session else { return }
        session = nil
        if s.payload != nil && !s.ready && !s.failed { Log.write("AutoFix: dropped before the file finished (may arrive incomplete)") }
        Log.write("AutoFix: drag ended (payload \(String(describing: s.payload)))")
        if s.payload == nil {
            s.task?.cancel()
            let dir = s.workDir
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { try? FileManager.default.removeItem(at: dir) }
        }
    }

    private func write(_ s: Session, _ payload: Payload, _ dest: Destination) {
        let urls: [URL]
        switch payload {
        case .originals: urls = s.items.map(\.original)
        case .converted: urls = s.items.map(\.converted)
        case .forAI:
            urls = s.items.flatMap { $0.kind == .video ? [] : [$0.converted] } + s.frames
        }
        put(urls)
        s.payload = payload
        Log.write("AutoFix: drag now carries \(payload) for \(dest) -> \(urls.map(\.lastPathComponent))")
    }

    private func put(_ urls: [URL]) {
        pb.clearContents()
        pb.writeObjects(urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString("1", forType: .autoFixMarker)
            return item
        })
        onOwnWrite?()
    }

    /// If fetching/conversion fails after we swapped, put back what the drag originally carried.
    private func fallBackToSource(_ s: Session) {
        guard s.payload != nil, session === s else { return }
        pb.clearContents()
        pb.writeObjects(s.sourceURLs.enumerated().map { i, url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if i < s.assetRefs.count { item.setData(s.assetRefs[i], forType: PhotoLibrary.assetRefType) }
            return item
        })
        onOwnWrite?()
        s.payload = nil
    }

    /// Back over Photos: put the asset references back so drops into albums keep working.
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
