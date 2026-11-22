import AppKit

/// The round drop zone that opens under the menu-bar icon. Drop files (from Finder or straight
/// from Photos) and the convert wheel takes over in the same spot. Click it to pick files instead.
@MainActor
final class DropDisc {
    static let shared = DropDisc()
    private var panel: DropDiscPanel?
    var onPickFiles: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(under button: NSStatusBarButton?) {
        if let p = panel, p.isVisible { p.close(); return }
        let p = DropDiscPanel()
        p.onClose = { [weak self] in self?.panel = nil }
        p.disc.onPick = { [weak self, weak p] in
            p?.close()
            self?.onPickFiles?()
        }
        p.disc.onFiles = { [weak p] urls, center in
            p?.close()
            FormatWheel.shared.present(for: urls, at: center)
        }
        panel = p
        p.show(under: button)
    }

    func close() { panel?.close() }
}

@MainActor
final class DropDiscPanel: NSPanel {
    static let size: CGFloat = 260
    let disc = DropDiscView(frame: NSRect(x: 0, y: 0, width: DropDiscPanel.size, height: DropDiscPanel.size))
    var onClose: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        let container = NSView(frame: disc.frame)
        container.wantsLayer = true
        container.addSubview(disc)
        contentView = container
    }

    override var canBecomeKey: Bool { true }

    func show(under button: NSStatusBarButton?) {
        // Centered under the menu-bar icon (or the top-right corner as a fallback), kept on screen.
        var anchor = NSPoint(x: (NSScreen.main?.visibleFrame.maxX ?? 800) - Self.size / 2 - 12,
                             y: NSScreen.main?.visibleFrame.maxY ?? 800)
        if let b = button, let w = b.window {
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            anchor = NSPoint(x: r.midX, y: r.minY)
        }
        var origin = NSPoint(x: anchor.x - Self.size / 2, y: anchor.y - Self.size - 8)
        if let v = (NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, v.minX + 8), v.maxX - Self.size - 8)
        }
        setFrameOrigin(origin)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        if let layer = contentView?.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 1) // springs down from the menu bar
            layer.position = CGPoint(x: Self.size / 2, y: Self.size)
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.6
            spring.toValue = 1
            spring.stiffness = 420
            spring.damping = 30
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "pop")
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.invalidateShadow() }
        watchOutsideClicks()
    }

    // It stays open while you go grab a file: clicking into Finder/Photos to start a drag must
    // not dismiss it. A plain click elsewhere (no drag started) does.
    private var monitors: [Any] = []
    private var dragCountAtMouseDown = 0
    private let dragPB = NSPasteboard(name: .drag)

    private func watchOutsideClicks() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dragCountAtMouseDown = self?.dragPB.changeCount ?? 0 }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.disc.isTargeted else { return }
                // Selecting a file in Finder or Photos (before dragging it) keeps the disc open.
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                if ["com.apple.finder", "com.apple.Photos"].contains(front) { return }
                if self.dragPB.changeCount == self.dragCountAtMouseDown { self.close() } // plain click, not a drag
            }
        }) { monitors.append(m) }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        super.close()
        onClose?()
        onClose = nil
    }
}

@MainActor
final class DropDiscView: NSView {
    var onFiles: (([URL], NSPoint) -> Void)?
    var onPick: (() -> Void)?
    private(set) var isTargeted = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var loading = false { didSet { needsDisplay = true } }

    private let outerR: CGFloat = 118, bandInnerR: CGFloat = 92, innerR: CGFloat = 84

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DropIntake.acceptedTypes)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var c: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private func circle(_ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }

    // Same neutral palette as the convert wheel.
    private static func n(_ v: CGFloat) -> NSColor { NSColor(srgbRed: v, green: v, blue: v, alpha: 1) }
    private static let n950 = n(0.039), n800 = n(0.149), n700 = n(0.251), n600 = n(0.322), n400 = n(0.639), n50 = n(0.98)

    override func draw(_ dirtyRect: NSRect) {
        let hot = isTargeted || hovering
        // One constant disc: outer band, thin groove, inner drop well.
        Self.n950.setFill(); circle(outerR).fill()
        let band = circle(outerR)
        band.append(circle(bandInnerR).reversed)
        (isTargeted ? Self.n700 : Self.n800).setFill(); band.fill()
        Self.n600.setStroke(); band.lineWidth = 1; band.stroke()

        let well = circle(innerR)
        (hot ? Self.n800 : Self.n950).setFill(); well.fill()
        let dash = circle(innerR - 12)
        dash.lineWidth = 1.5
        dash.setLineDash([5, 5], count: 2, phase: 0)
        (isTargeted ? Self.n400 : Self.n600).setStroke()
        dash.stroke()

        let title: String, sub: String
        if loading { title = "Getting file…"; sub = "from Photos" }
        else if isTargeted { title = "Release to convert"; sub = "" }
        else { title = "Drop a file"; sub = "or click to choose" }
        let ta: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                                 .foregroundColor: hot ? Self.n50 : Self.n400]
        let sa: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .regular),
                                                 .foregroundColor: Self.n600.blended(withFraction: 0.4, of: Self.n400) ?? Self.n600]
        let ts = (title as NSString).size(withAttributes: ta)
        let ss = (sub as NSString).size(withAttributes: sa)
        let total = ts.height + (sub.isEmpty ? 0 : ss.height + 2)
        let top = c.y + total / 2
        (title as NSString).draw(at: NSPoint(x: c.x - ts.width / 2, y: top - ts.height), withAttributes: ta)
        if !sub.isEmpty { (sub as NSString).draw(at: NSPoint(x: c.x - ss.width / 2, y: top - ts.height - ss.height - 2), withAttributes: sa) }

        // Ring label, like an engraved bezel.
        let label = "MORPHLO" as NSString
        let la: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8.5, weight: .semibold), .kern: 2.2,
                                                 .foregroundColor: Self.n600.blended(withFraction: 0.3, of: Self.n400) ?? Self.n600]
        let ls = label.size(withAttributes: la)
        label.draw(at: NSPoint(x: c.x - ls.width / 2, y: c.y - (bandInnerR + outerR) / 2 - ls.height / 2), withAttributes: la)
    }

    private func inDisc(_ p: NSPoint) -> Bool { hypot(p.x - c.x, p.y - c.y) <= outerR }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if inDisc(p) { onPick?() } else { window?.close() }
    }

    // MARK: Drop destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(.morphloMarker) == true { return [] }
        isTargeted = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.types?.contains(.morphloMarker) == true ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { isTargeted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        // Photos hands over promises: fetch the real originals first (into Morphlo's cache;
        // the wheel saves conversions of those to Downloads).
        let workDir = WorkDir.make()
        let sources = DropIntake.collect(from: sender.draggingPasteboard, workDir: workDir)
        guard !sources.isEmpty else { return false }
        let center = window.map { $0.convertPoint(toScreen: convert(c, to: nil)) } ?? NSEvent.mouseLocation
        loading = sources.contains { if case .promise = $0 { return true } else { return false } }
        Task {
            var urls: [URL] = []
            for s in sources { urls += await DropIntake.resolve(s, workDir: workDir).0 }
            loading = false
            if urls.isEmpty { NSSound.beep(); return }
            onFiles?(urls, center)
        }
        return true
    }
}
