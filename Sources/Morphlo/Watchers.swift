import AppKit
import ApplicationServices

/// Notices system-wide drags (without Accessibility permission) by watching the drag pasteboard
/// while the mouse button is held down.
@MainActor
final class DragWatcher {
    var onDragStart: ((NSPasteboard) -> Void)?
    var onDragEnd: (() -> Void)?
    /// Cursor position (Cocoa screen coords) every poll while a drag is in progress.
    var onDragTick: ((NSPoint) -> Void)?
    /// Any press-and-move gesture (including drags whose data Morphlo can't see, e.g. from Dock
    /// stacks): ticks while the button is held after moving, so the Shift trigger works everywhere.
    var onHoldTick: ((NSPoint) -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    /// Ticks while a press that started on the Dock is moving but no drag has shown up on the
    /// shared drag pasteboard: the Dock uses a private one, which DragSniffer catches.
    var onHiddenDragTick: ((NSPoint) -> Void)?
    private var downInDock = false
    private var downAt: NSPoint = .zero
    private var moved = false

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var lastCount: Int
    private var monitors: [Any] = []
    private var timer: Timer?
    private var dragging = false

    init() { lastCount = dragPasteboard.changeCount }

    private var buttonPoller: Timer?

    func start() {
        // macOS doesn't report every press to other apps (e.g. inside the Dock's stack pop-up),
        // so also check the button state directly; cheap, and catches every drag.
        buttonPoller = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 1 { self?.beginPolling() }
            }
        }
        buttonPoller?.tolerance = 0.01
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.beginPolling() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }) { monitors.append(m) }
    }

    private func beginPolling() {
        guard timer == nil else { return }
        downAt = NSEvent.mouseLocation
        moved = false
        downInDock = Self.dockWindow(at: downAt)
        onHoldStart?()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.check()
                if NSEvent.pressedMouseButtons & 1 == 0 { self.mouseReleased(); return }
                let p = NSEvent.mouseLocation
                if !self.moved, hypot(p.x - self.downAt.x, p.y - self.downAt.y) > 12 {
                    self.moved = true
                    Log.write("Hold: press-and-move started (frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")\(self.downInDock ? ", from the Dock" : ""))")
                }
                if self.dragging { self.onDragTick?(p) }
                if self.dragging || self.moved { self.onHoldTick?(p) }
                if self.moved, !self.dragging, self.downInDock { self.onHiddenDragTick?(p) }
            }
        }
    }

    private func check() {
        let count = dragPasteboard.changeCount
        guard count != lastCount else { return }
        lastCount = count
        dragging = true
        Log.write("Drag started (frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")): "
                  + (dragPasteboard.types ?? []).map(\.rawValue).joined(separator: ", "))
        onDragStart?(dragPasteboard)
    }

    /// DragSniffer found the private pasteboard of a drag that's already in flight.
    func adopt(_ pasteboard: NSPasteboard) {
        guard timer != nil, !dragging else { return }
        dragging = true
        Log.write("Drag started (from the Dock, private pasteboard): "
                  + (pasteboard.types ?? []).map(\.rawValue).joined(separator: ", "))
        onDragStart?(pasteboard)
    }

    /// Was this press (Cocoa coordinates) on the Dock or one of its stack pop-ups? The Dock draws
    /// everything in one screen-sized window, so ask the Dock (and only the Dock) what's under the
    /// point. Without Accessibility, or if the Dock doesn't answer, assume yes: the sniffer is
    /// invisible and only reacts to real drags.
    private static func dockWindow(at point: NSPoint) -> Bool {
        guard let primary = NSScreen.screens.first,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return false }
        guard AXIsProcessTrusted() else { return true }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var element: AXUIElement?
        let y = Float(primary.frame.height - point.y)
        let err = AXUIElementCopyElementAtPosition(app, Float(point.x), y, &element)
        if err == .noValue { return false }          // nothing of the Dock's at this point
        guard err == .success, let element else { return true }
        if CFEqual(element, app) { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return (role as? String) != kAXApplicationRole as String
    }

    /// Morphlo itself rewrote the drag pasteboard; don't treat that as a new drag.
    func acknowledgeOwnWrite() { lastCount = dragPasteboard.changeCount }

    private func mouseReleased() {
        timer?.invalidate()
        timer = nil
        onHoldEnd?()
        if dragging {
            dragging = false
            onDragEnd?()
        }
    }
}

/// Makes pasting into Claude work: when the clipboard holds only HEIC image data, adds JPEG and
/// PNG versions alongside it (nothing is removed). Optionally swaps copied HEIC files for JPEGs.
@MainActor
final class ClipboardWatcher {
    private let pb = NSPasteboard.general
    private var lastCount: Int
    private var timer: Timer?

    init() { lastCount = pb.changeCount }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let types = Set(pb.types ?? [])
        guard !types.contains(.morphloMarker) else { return }
        guard Settings.fixClipboardImages || Settings.convertCopiedFiles else { return }

        let urls = DropIntake.fileURLs(pb)
        if !urls.isEmpty {
            guard Settings.convertCopiedFiles, urls.contains(where: { ImageConverter.needsConversion($0) }) else { return }
            Log.write("Clipboard has HEIC files, converting:\n" + Log.describe(pb))
            convertFiles(urls, changeCount: pb.changeCount)
            return
        }

        guard Settings.fixClipboardImages,
              types.contains(.heic) || types.contains(.heif),
              !types.contains(.png), !types.contains(.jpeg), !types.contains(.tiff) else { return }
        Log.write("Clipboard has HEIC data only, adding JPEG/PNG: " + types.map(\.rawValue).joined(separator: ", "))
        addReadableFlavors()
    }

    private func addReadableFlavors() {
        guard let items = pb.pasteboardItems else { return }
        // Snapshot everything so it can be written back untouched. If any flavor can't be read
        // (lazily provided data), leave the clipboard alone rather than lose it.
        var snapshot: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in items {
            var flavors: [(NSPasteboard.PasteboardType, Data)] = []
            for t in item.types {
                guard let d = item.data(forType: t) else {
                    Log.write("Clipboard left alone: flavor \(t.rawValue) not readable")
                    return
                }
                flavors.append((t, d))
            }
            snapshot.append(flavors)
        }
        let changeCount = pb.changeCount
        Task.detached(priority: .userInitiated) {
            var changed = false
            let rebuilt: [[(NSPasteboard.PasteboardType, Data)]] = snapshot.map { flavors in
                var out = flavors
                if let heic = flavors.first(where: { $0.0 == .heic || $0.0 == .heif })?.1,
                   let jpeg = ImageConverter.jpegData(from: heic) {
                    out.append((.jpeg, jpeg))
                    if let rep = NSBitmapImageRep(data: jpeg), let png = rep.representation(using: .png, properties: [:]) {
                        out.append((.png, png))
                    }
                    changed = true
                }
                return out
            }
            guard changed else { return }
            await MainActor.run {
                guard self.pb.changeCount == changeCount else { return } // user copied something else meanwhile
                let newItems: [NSPasteboardItem] = rebuilt.map { flavors in
                    let item = NSPasteboardItem()
                    for (t, d) in flavors { item.setData(d, forType: t) }
                    item.setString("1", forType: .morphloMarker)
                    return item
                }
                self.pb.clearContents()
                self.pb.writeObjects(newItems)
                self.lastCount = self.pb.changeCount
            }
        }
    }

    private func convertFiles(_ urls: [URL], changeCount: Int) {
        let dir = WorkDir.make()
        Task.detached(priority: .userInitiated) {
            let converted: [URL] = urls.map { (try? ImageConverter.convert($0, outDir: dir)) ?? $0 }
            await MainActor.run {
                // Don't clobber something the user copied while we were converting.
                guard self.pb.changeCount == changeCount else { return }
                Clipboard.write(converted)
                self.lastCount = self.pb.changeCount
            }
        }
    }
}

enum Clipboard {
    /// Writes files to the general pasteboard as file URLs, plus JPEG data for images so apps
    /// that only read image data (most web pages) still get something.
    @MainActor static func write(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { pasteboardItem(for: $0, includeImageData: true) })
    }

    static func pasteboardItem(for url: URL, includeImageData: Bool) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString("1", forType: .morphloMarker)
        if includeImageData, let type = url.contentType, type.conforms(to: .jpeg) || type.conforms(to: .png),
           let data = try? Data(contentsOf: url) {
            item.setData(data, forType: type.conforms(to: .png) ? .png : .jpeg)
        } else if url.contentType?.conforms(to: .plainText) == true, let text = try? String(contentsOf: url, encoding: .utf8) {
            item.setString(text, forType: .string)
        }
        return item
    }
}
