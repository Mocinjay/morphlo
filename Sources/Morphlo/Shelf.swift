import AppKit
import QuickLookThumbnailing

// MARK: - Model

@MainActor
final class ShelfItem {
    enum State { case working, done([URL]), failed(String) }
    let name: String
    var state: State = .working
    init(name: String) { self.name = name }
}

// MARK: - Controller

@MainActor
final class ShelfController: NSObject {
    private lazy var panel: ShelfPanel = ShelfPanel(controller: self)
    private(set) var items: [ShelfItem] = []
    private var shownForDrag = false
    private var hideWork: DispatchWorkItem?
    private var workDirs: [URL] = []

    var isVisible: Bool { panel.isVisible }
    var outputs: [URL] {
        items.flatMap { item -> [URL] in
            if case .done(let urls) = item.state { return urls }
            return []
        }
    }
    var isWorking: Bool { items.contains { if case .working = $0.state { return true } else { return false } } }

    func show() {
        panel.positionOnActiveScreen()
        panel.orderFrontRegardless()
        panel.refresh()
    }

    func toggle() { isVisible ? hide() : show() }

    func hide() {
        panel.orderOut(nil)
        shownForDrag = false
    }

    func showForDrag() {
        hideWork?.cancel()
        hideWork = nil
        guard !isVisible else { return }
        shownForDrag = true
        show()
    }

    /// A drag that popped the shelf up ended. If nothing was dropped on Morphlo, put things back
    /// the way they were.
    func dragEnded() {
        guard shownForDrag else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shownForDrag else { return }
            self.shownForDrag = false
            if NSEvent.pressedMouseButtons & 1 == 0 && !self.panel.isHovering { self.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func clear() {
        items.removeAll()
        let dirs = workDirs
        workDirs.removeAll()
        DispatchQueue.global(qos: .utility).async { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        panel.refresh()
    }

    /// Called synchronously from a drop.
    func accept(_ pasteboard: NSPasteboard) -> Bool {
        let workDir = WorkDir.make()
        let sources = DropIntake.collect(from: pasteboard, workDir: workDir)
        guard !sources.isEmpty else { return false }
        workDirs.append(workDir)
        hideWork?.cancel()
        shownForDrag = false
        if !isVisible { show() }
        for source in sources { process(source, workDir: workDir) }
        return true
    }

    private func process(_ source: DropSource, workDir: URL) {
        let outDir = workDir.appendingPathComponent("out-\(UUID().uuidString.prefix(8))")
        let item = ShelfItem(name: source.displayName)
        items.append(item)
        panel.refresh()
        Task {
            let (inputs, errors) = await DropIntake.resolve(source, workDir: workDir)
            var outputs: [URL] = []
            var problems = errors
            for input in inputs {
                do {
                    outputs += try await Task.detached(priority: .userInitiated) {
                        try await Converter.convert(input, outDir: outDir)
                    }.value
                } catch {
                    problems.append("\(input.lastPathComponent): \(error.localizedDescription)")
                }
            }
            Log.write("Processed \(item.name): \(outputs.map(\.lastPathComponent)) problems=\(problems)")
            if case .promise = source {
                // The full-size originals Photos exported are no longer needed.
                for input in inputs where !outputs.contains(input) { try? FileManager.default.removeItem(at: input) }
            }
            item.state = outputs.isEmpty ? .failed(problems.first ?? "Nothing usable in the drop") : .done(outputs)
            self.panel.refresh()
        }
    }

    /// Files made by the convert wheel from a shelf item show up on the shelf too.
    func addConverted(_ urls: [URL]) {
        let urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        let item = ShelfItem(name: urls[0].lastPathComponent)
        item.state = .done(urls)
        items.append(item)
        panel.refresh()
    }

    func copyAll() {
        let urls = outputs
        guard !urls.isEmpty else { return }
        Clipboard.write(urls)
        panel.flash("Copied \(urls.count) — paste into Claude")
    }

    func revealAll() {
        let urls = outputs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func dragOutFinished(success: Bool) {
        guard success else { return }
        panel.flash("Sent ✓")
    }
}

// MARK: - Panel

@MainActor
final class ShelfPanel: NSPanel {
    private weak var controller: ShelfController?
    private let root: ShelfRootView

    var isHovering: Bool { root.isDropTargeted }

    init(controller: ShelfController) {
        self.controller = controller
        root = ShelfRootView(controller: controller)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 268, height: 318),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = root
    }

    override var canBecomeKey: Bool { false }

    func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 16))
    }

    func refresh() { root.reload() }
    func flash(_ text: String) { root.flash(text) }
}

// MARK: - Root view (the drop target)

@MainActor
final class ShelfRootView: NSView, NSDraggingSource {
    private weak var controller: ShelfController?
    private let background = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Morphlo")
    private let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let placeholder = NSStackView()
    private let scroll = NSScrollView()
    private let grid = TileGrid()
    private let dragAll = DragAllPill()
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let menuButton = NSButton()
    private(set) var isDropTargeted = false { didSet { needsDisplay = true; background.needsDisplay = true; updateBorder() } }
    private var flashWork: DispatchWorkItem?

    init(controller: ShelfController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 268, height: 318))
        wantsLayer = true
        registerForDraggedTypes(DropIntake.acceptedTypes)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        updateBorder()

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(close)

        menuButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        menuButton.isBordered = false
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.target = self
        menuButton.action = #selector(showMoreMenu(_:))

        let icon = NSImageView(image: NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 34, weight: .light)
        icon.unregisterDraggedTypes()
        icon.contentTintColor = .secondaryLabelColor
        let line1 = NSTextField(labelWithString: "Drop photos & videos here")
        line1.font = .systemFont(ofSize: 13, weight: .medium)
        let line2 = NSTextField(wrappingLabelWithString: "HEIC becomes JPEG, videos get fixed. Drag results anywhere — or click one to convert it to any format.")
        line2.font = .systemFont(ofSize: 11)
        line2.textColor = .secondaryLabelColor
        line2.alignment = .center
        line2.preferredMaxLayoutWidth = 220
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 8
        [icon, line1, line2].forEach { placeholder.addArrangedSubview($0) }

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = grid
        scroll.contentView.drawsBackground = false

        dragAll.source = self
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .regular
        copyButton.target = self
        copyButton.action = #selector(copyAll)

        for v in [titleLabel, statusLabel, closeButton, menuButton, placeholder, scroll, dragAll, copyButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            menuButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            menuButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),

            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: 230),

            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: dragAll.topAnchor, constant: -10),

            dragAll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dragAll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            dragAll.heightAnchor.constraint(equalToConstant: 34),
            dragAll.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            copyButton.centerYAnchor.constraint(equalTo: dragAll.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 64),
        ])
        reload()
    }

    private func updateBorder() {
        background.layer?.borderColor = (isDropTargeted ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.12)).cgColor
        background.layer?.borderWidth = isDropTargeted ? 2 : 1
    }

    private var reloadPending = false

    func reload() {
        guard let controller else { return }
        // Rebuilding tiles between mouseDown and mouseDragged would kill a drag-out.
        if NSEvent.pressedMouseButtons & 1 != 0, window?.isVisible == true {
            if !reloadPending {
                reloadPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.reloadPending = false
                    self?.reload()
                }
            }
            return
        }
        let items = controller.items
        placeholder.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        let outputs = controller.outputs
        dragAll.isHidden = outputs.isEmpty
        copyButton.isHidden = outputs.isEmpty
        dragAll.count = outputs.count
        if flashWork == nil {
            statusLabel.stringValue = controller.isWorking ? "Converting…" : (outputs.isEmpty ? "" : "\(outputs.count) ready")
        }
        grid.setItems(items, source: self)
        let width = scroll.contentSize.width > 0 ? scroll.contentSize.width : 248
        grid.frame.size.width = width
        grid.layoutTiles()
    }

    func flash(_ text: String) {
        flashWork?.cancel()
        statusLabel.stringValue = text
        let work = DispatchWorkItem { [weak self] in
            self?.flashWork = nil
            self?.reload()
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    var outputs: [URL] { controller?.outputs ?? [] }
    func addConverted(_ urls: [URL]) { controller?.addConverted(urls) }

    @objc private func close() { controller?.hide() }
    @objc private func copyAll() { controller?.copyAll() }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clear Shelf", action: #selector(clear), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func reveal() { controller?.revealAll() }
    @objc private func clear() { controller?.clear() }

    // Drop destination
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(.morphloMarker) == true { return [] }
        isDropTargeted = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.types?.contains(.morphloMarker) == true ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTargeted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { isDropTargeted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTargeted = false
        return controller?.accept(sender.draggingPasteboard) ?? false
    }

    // Drag source (tiles and the "drag all" pill)
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.dragOutFinished(success: !operation.isEmpty)
    }

    func startDrag(urls: [URL], event: NSEvent, from view: NSView) {
        guard !urls.isEmpty else { return }
        var items: [NSDraggingItem] = []
        let start = view.convert(event.locationInWindow, from: nil)
        for (i, url) in urls.enumerated() {
            let di = NSDraggingItem(pasteboardWriter: Clipboard.pasteboardItem(for: url, includeImageData: false))
            let image = Thumbs.cached(url) ?? NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(i, 4)) * 6
            di.setDraggingFrame(NSRect(x: start.x - 28 + offset, y: start.y - 28 - offset, width: 56, height: 56), contents: image)
            items.append(di)
        }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
    }
}

// MARK: - Tiles

@MainActor
final class TileGrid: NSView {
    override var isFlipped: Bool { true }
    private var tiles: [TileView] = []
    private let tileSize = NSSize(width: 74, height: 92)
    private let spacing: CGFloat = 6

    func setItems(_ items: [ShelfItem], source: ShelfRootView) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        for item in items {
            switch item.state {
            case .working: tiles.append(TileView(title: item.name, url: nil, working: true, source: source))
            case .failed(let msg): tiles.append(TileView(title: "⚠︎ \(msg)", url: nil, working: false, source: source))
            case .done(let urls):
                for url in urls { tiles.append(TileView(title: url.lastPathComponent, url: url, working: false, source: source)) }
            }
        }
        tiles.forEach { addSubview($0) }
    }

    func layoutTiles() {
        let cols = max(1, Int((bounds.width + spacing) / (tileSize.width + spacing)))
        let usedWidth = CGFloat(cols) * tileSize.width + CGFloat(cols - 1) * spacing
        let inset = max(0, (bounds.width - usedWidth) / 2)
        for (i, t) in tiles.enumerated() {
            let r = i / cols, c = i % cols
            t.frame = NSRect(x: inset + CGFloat(c) * (tileSize.width + spacing),
                             y: CGFloat(r) * (tileSize.height + spacing), width: tileSize.width, height: tileSize.height)
        }
        let rows = (tiles.count + cols - 1) / cols
        let h = CGFloat(rows) * tileSize.height + CGFloat(max(0, rows - 1)) * spacing
        setFrameSize(NSSize(width: bounds.width, height: max(h, superview?.bounds.height ?? h)))
    }
}

@MainActor
final class TileView: NSView {
    private let url: URL?
    private weak var source: ShelfRootView?
    private let imageView = NSImageView()
    private var mouseDownEvent: NSEvent?

    init(title: String, url: URL?, working: Bool, source: ShelfRootView) {
        self.url = url
        self.source = source
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.unregisterDraggedTypes() // NSImageView claims image drops; let the shelf get them
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.frame = NSRect(x: 5, y: 26, width: 64, height: 62)
        addSubview(imageView)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9.5)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        label.frame = NSRect(x: 2, y: 0, width: 70, height: 24)
        addSubview(label)
        toolTip = title

        if working {
            let spinner = NSProgressIndicator(frame: NSRect(x: 27, y: 47, width: 20, height: 20))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            addSubview(spinner)
        } else if let url {
            imageView.image = Thumbs.cached(url) ?? NSWorkspace.shared.icon(forFile: url.path)
            Thumbs.load(url) { [weak self] img in self?.imageView.image = img }
        } else {
            imageView.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            imageView.contentTintColor = .systemOrange
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shared across tiles: tiles get rebuilt between clicks, so a per-tile item could survive a
    /// double-click and open the wheel anyway.
    static var pendingClick: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        Self.pendingClick?.cancel()
        if event.clickCount == 2, let url { NSWorkspace.shared.open(url) }
    }

    override func mouseUp(with event: NSEvent) {
        // A plain click (not a drag, not the start of a double-click) opens the convert wheel.
        guard event.clickCount == 1, mouseDownEvent != nil, let url, let window else { return }
        let point = window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
        let work = DispatchWorkItem { [weak source] in
            FormatWheel.shared.present(for: [url], at: point) { outs in source?.addConverted(outs) }
        }
        Self.pendingClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url, let source, let down = mouseDownEvent else { return }
        // Small jitter during a click shouldn't start a drag.
        let d = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
        guard d > 4 else { return }
        mouseDownEvent = nil
        source.startDrag(urls: [url], event: down, from: self)
    }
}

@MainActor
final class DragAllPill: NSView {
    weak var source: ShelfRootView?
    var count = 0 { didSet { label.stringValue = count == 1 ? "Drag to Claude" : "Drag all \(count) to Claude" } }
    private let label = NSTextField(labelWithString: "")
    private var downEvent: NSEvent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil)!)
        icon.contentTintColor = .white
        icon.unregisterDraggedTypes()
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "Drag this onto Claude's message box"
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { downEvent = event }
    override func mouseDragged(with event: NSEvent) {
        guard let source, let down = downEvent, let controller = source.controllerOutputs() else { return }
        downEvent = nil
        source.startDrag(urls: controller, event: down, from: self)
    }
}

extension ShelfRootView {
    fileprivate func controllerOutputs() -> [URL]? { outputs }
}

// MARK: - Thumbnails

@MainActor
enum Thumbs {
    private static var cache: [URL: NSImage] = [:]

    static func cached(_ url: URL) -> NSImage? { cache[url] }

    static func load(_ url: URL, completion: @escaping (NSImage) -> Void) {
        if let img = cache[url] { completion(img); return }
        // Only media/PDF go through QuickLook; documents just use their Finder icon.
        guard let type = url.contentType, type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf) else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                cache[url] = image
                completion(image)
            }
        }
    }
}
