import AppKit

/// Drags that start in the Dock (a stack such as Downloads, or a file kept in the Dock) don't use
/// the shared drag pasteboard that Finder and Photos use. The Dock gives every drag its own
/// randomly named pasteboard, so Morphlo can't see it by watching. The name is only revealed to a
/// window the drag passes over.
///
/// So while such a drag is in flight, Morphlo keeps a tiny, practically invisible window under the
/// cursor. The moment the drag touches it, Morphlo learns the pasteboard's name and hands it to
/// the normal auto-fix path, which swaps in the JPEG before the drag reaches its target. The window
/// never accepts the drop and disappears as soon as it has the name.
@MainActor
final class DragSniffer: NSPanel {
    var onCatch: ((NSPasteboard) -> Void)?
    private let side: CGFloat = 96
    private(set) var caught = false
    private var active = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 96, height: 96),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        hasShadow = false
        // Fully clear pixels let the window server pass the drag straight through, so use the
        // faintest possible tint instead. It can't be seen.
        backgroundColor = NSColor(white: 0, alpha: 0.01)
        level = .popUpMenu // above the Dock and its stacks; .screenSaver and higher never get drags
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        let view = SnifferView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        view.onEnter = { [weak self] info in self?.entered(info) }
        view.onScroll = { [weak self] in self?.giveUp() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Called every tick while an unseen drag is in flight: keep the window centred on the cursor.
    func follow(_ point: NSPoint) {
        guard !caught else { return }
        // display: true so the window has drawn pixels; an undrawn window is see-through to drags.
        setFrame(NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), display: !active)
        if !active {
            active = true
            orderFrontRegardless()
            Log.write("Sniffer: watching an unseen drag from the Dock at \(Int(point.x)),\(Int(point.y)) (window \(windowNumber), visible \(isVisible))")
        }
    }

    /// Something other than a drag is going on (scrolling): get out of the way until the next press.
    func giveUp() {
        orderOut(nil)
        active = false
        caught = true
    }

    /// The press ended (or the drag was handled): hide and get ready for the next one.
    func reset() {
        if active { orderOut(nil) }
        active = false
        caught = false
    }

    private func entered(_ info: NSDraggingInfo) {
        guard active, !caught else { return }
        caught = true
        let name = info.draggingPasteboard.name
        orderOut(nil)
        active = false
        // The shared pasteboard is already handled by DragWatcher; only adopt private ones.
        guard name != .drag else { return }
        let pb = NSPasteboard(name: name)
        Log.write("Sniffer: caught the Dock's private drag pasteboard (\(name.rawValue)): "
                  + (pb.types ?? []).map(\.rawValue).joined(separator: ", "))
        onCatch?(pb)
    }
}

@MainActor
private final class SnifferView: NSView {
    var onEnter: ((NSDraggingInfo) -> Void)?
    var onScroll: (() -> Void)?

    // A scroll means this press isn't a Dock drag; let the app underneath have the next ones.
    override func scrollWheel(with event: NSEvent) { onScroll?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png,
                                 NSPasteboard.PasteboardType("NSFilenamesPboardType"),
                                 NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Never accept anything: the user must not be able to drop onto this window.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onEnter?(sender)
        return []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}
