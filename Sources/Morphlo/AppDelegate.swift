import AppKit
import UniformTypeIdentifiers
import Carbon
import ServiceManagement
import ApplicationServices
import Photos

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private var statusItem: NSStatusItem!
    private let shelf = ShelfController()
    private let dragWatcher = DragWatcher()
    private let clipboard = ClipboardWatcher()
    private let autoFix = AutoFix()
    private var convertHotKey: HotKey?
    private let menu = NSMenu()

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        WorkDir.cleanOld()
        Log.write("Morphlo \(Self.version) launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MorphloIcon.menuBar()
            button.toolTip = "Morphlo — click to convert a file, right-click for settings"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Dropping straight onto the menu-bar icon also works.
            button.window?.registerForDraggedTypes(DropIntake.acceptedTypes)
            button.window?.delegate = self
        }
        menu.delegate = self

        autoFix.onOwnWrite = { [weak self] in self?.dragWatcher.acknowledgeOwnWrite() }
        dragWatcher.onDragTick = { [weak self] point in self?.autoFix.dragMoved(to: point) }
        dragWatcher.onDragStart = { [weak self] pb in
            guard let self else { return }
            if self.autoFix.dragStarted(pb) { return } // zero-touch handles it; no shelf
            guard Settings.showShelfOnDrag else { return }
            let fromPhotos = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Photos"
            if fromPhotos || DropIntake.isInteresting(pb) { self.shelf.showForDrag() }
        }
        dragWatcher.onDragEnd = { [weak self] in
            self?.autoFix.dragEnded()
            self?.shelf.dragEnded()
        }
        if Settings.autoFix {
            Task {
                let ok = await PhotoLibrary.requestAccess()
                Log.write("Photos access: \(ok ? "granted" : "not granted") (status \(PhotoLibrary.status.rawValue))")
            }
        }
        dragWatcher.start()
        clipboard.start()

        // Convert wheel entry points: Finder right-click service, ⌥⌘K, files opened with the app.
        DropDisc.shared.onPickFiles = { [weak self] kind in self?.pickFiles(of: kind) }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        convertHotKey = HotKey(keyCode: kVK_ANSI_K, modifiers: cmdKey | optionKey) { [weak self] in self?.convertSelection() }
        if convertHotKey == nil { Log.write("⌥⌘K couldn't be registered (another app owns it); use the menu or Finder's Quick Action") }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { WorkDir.cleanOld() }
        }
    }

    // MARK: Status item

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true || event?.modifierFlags.contains(.option) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left-click: the round drop zone. (The shelf lives in the right-click menu.)
            DropDisc.shared.toggle(under: statusItem.button)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, shelf.isVisible ? "Hide Shelf" : "Show Shelf", #selector(toggleShelf))
        let convertItem = add(menu, "Convert a File…", #selector(convertFilePicker), key: "k")
        convertItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())

        add(menu, "Auto-fix drags (Photos & HEIC files) — no clicks", #selector(toggleAutoFix), on: Settings.autoFix)
        if Settings.autoFix && !PhotoLibrary.canRead {
            add(menu, "    ⚠︎ Allow Photos access to turn this on…", #selector(openPhotosPrivacy))
        }
        add(menu, "Get originals from iCloud Photos when needed", #selector(toggleICloud), on: Settings.useICloudOriginals)
        add(menu, "Detect AI chats in browsers (needs Accessibility)", #selector(toggleAX), on: AXIsProcessTrusted())
        add(menu, "Pop up shelf when dragging photos & videos", #selector(toggleShowOnDrag), on: Settings.showShelfOnDrag)
        menu.addItem(.separator())
        let conv = NSMenu()
        add(conv, "Keep original — save a new file next to it", #selector(setKeepOriginal), on: !Settings.replaceOriginal)
        add(conv, "Replace original — move it to the Trash", #selector(setReplaceOriginal), on: Settings.replaceOriginal)
        conv.addItem(.separator())
        let tip = conv.addItem(withTitle: "Hold ⌥ while picking a format to do the other", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        menu.addItem(withTitle: "Convert wheel", action: nil, keyEquivalent: "").submenu = conv
        add(menu, "Fix HEIC when pasting (copy in Photos → paste in Claude)", #selector(toggleClipboard), on: Settings.fixClipboardImages)
        add(menu, "Also swap copied HEIC files for JPEGs", #selector(toggleCopiedFiles), on: Settings.convertCopiedFiles)
        menu.addItem(.separator())

        // Videos: the main choice first, then the still-frame options it controls.
        let video = NSMenu()
        func header(_ m: NSMenu, _ title: String) {
            let h = m.addItem(withTitle: title, action: nil, keyEquivalent: "")
            h.isEnabled = false
        }
        header(video, "When you drag a video into an AI chat")
        add(video, "Send the full video (every frame + audio)", #selector(setVideoForAIVideo), on: Settings.videoForAI == .video)
        add(video, "Send still frames instead", #selector(setVideoForAIFrames), on: Settings.videoForAI == .frames)
        video.addItem(.separator())
        header(video, Settings.videoForAI == .frames ? "Still frames" : "Still frames (used by the shelf)")
        let style = NSMenu()
        for o in VideoOutput.allCases {
            let item = add(style, o.title, #selector(setVideoOutput(_:)), on: Settings.videoOutput == o)
            item.representedObject = o.rawValue
        }
        video.addItem(withTitle: "What to make: \(Settings.videoOutput.title)", action: nil, keyEquivalent: "").submenu = style
        let count = NSMenu()
        for n in [4, 8, 12, 16, 20] {
            let item = add(count, "\(n) frames", #selector(setFrameCount(_:)), on: Settings.frameCount == n)
            item.tag = n
        }
        video.addItem(withTitle: "How many frames: \(Settings.frameCount)", action: nil, keyEquivalent: "").submenu = count
        add(video, "Add a transcript of the audio (on-device)", #selector(toggleTranscribe), on: Settings.transcribe)
        menu.addItem(withTitle: "Videos", action: nil, keyEquivalent: "").submenu = video

        let size = NSMenu()
        for (title, edge) in [("Original size (up to 8000px)", 8000), ("Large (4096px)", 4096), ("Medium (2048px)", 2048)] {
            let item = add(size, title, #selector(setImageEdge(_:)), on: Settings.maxImageEdge == edge)
            item.tag = edge
        }
        menu.addItem(withTitle: "Photo size", action: nil, keyEquivalent: "").submenu = size
        menu.addItem(.separator())

        add(menu, "Launch at login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        add(menu, "Open log", #selector(openLog))
        add(menu, "About Morphlo \(Self.version)", #selector(about))
        add(menu, "Quit Morphlo", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool? = nil, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        if let on { item.state = on ? .on : .off }
        return item
    }

    @objc private func toggleShelf() { shelf.toggle() }
    @objc private func toggleAutoFix() {
        Settings.autoFix.toggle()
        if Settings.autoFix && !PhotoLibrary.canRead {
            Task { if !(await PhotoLibrary.requestAccess()) { self.openPhotosPrivacy() } }
        }
    }
    @objc private func openPhotosPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
    }
    @objc private func toggleAX() {
        if AXIsProcessTrusted() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
    }
    @objc private func toggleICloud() { Settings.useICloudOriginals.toggle() }
    @objc private func setKeepOriginal() { Settings.replaceOriginal = false }
    @objc private func setReplaceOriginal() { Settings.replaceOriginal = true }
    @objc private func setVideoForAIFrames() { Settings.videoForAI = .frames }
    @objc private func setVideoForAIVideo() { Settings.videoForAI = .video }
    @objc private func toggleShowOnDrag() { Settings.showShelfOnDrag.toggle() }
    @objc private func toggleClipboard() { Settings.fixClipboardImages.toggle() }
    @objc private func toggleCopiedFiles() { Settings.convertCopiedFiles.toggle() }
    @objc private func toggleTranscribe() { Settings.transcribe.toggle() }
    @objc private func setVideoOutput(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let o = VideoOutput(rawValue: raw) { Settings.videoOutput = o }
    }
    @objc private func setFrameCount(_ sender: NSMenuItem) { Settings.frameCount = sender.tag }
    @objc private func setImageEdge(_ sender: NSMenuItem) { Settings.maxImageEdge = sender.tag }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            Log.write("Launch at login failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openLog() {
        Log.write("Log opened")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSWorkspace.shared.open(Log.url) }
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Drag photos and videos from Photos into Claude (or any app) without HEIC errors or first-frame-only videos. Free and open source."),
        ])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Convert wheel

    /// ⌥⌘K: convert what's selected in Finder; anywhere else, pick a file.
    private func convertSelection() {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            let urls = FinderSelection.urls()
            if !urls.isEmpty { FormatWheel.shared.present(for: urls); return }
        }
        convertFilePicker()
    }

    private var picking = false

    @objc private func convertFilePicker() { pickFiles(of: nil) }

    /// File picker, optionally limited to one kind (from a drop-disc section).
    private func pickFiles(of kind: MediaKind?) {
        guard !picking else { return }
        picking = true
        defer { picking = false }
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = kind.map { "Choose \($0.noun.lowercased()) files to convert" } ?? "Choose files to convert"
        if let kind {
            let ids = FileTypes.accepted.first { $0.kind == kind }?.identifiers ?? []
            panel.allowedContentTypes = ids.compactMap { UTType($0) }
        }
        panel.prompt = "Convert…"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            if previous?.bundleIdentifier != Bundle.main.bundleIdentifier { previous?.activate() }
            return
        }
        FormatWheel.shared.present(for: panel.urls)
    }

    /// Finder → right-click → Quick Actions / Services → "Convert with Morphlo".
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = DropIntake.fileURLs(pboard)
        Log.write("Service: convert \(urls.map(\.lastPathComponent))")
        DispatchQueue.main.async { FormatWheel.shared.present(for: urls) }
    }

    /// Files dropped on the app icon or opened with `open -a Morphlo file`.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        FormatWheel.shared.present(for: files)
    }

    // MARK: Dropping on the menu-bar icon

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.types?.contains(.morphloMarker) == true ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        shelf.accept(sender.draggingPasteboard)
    }
}
