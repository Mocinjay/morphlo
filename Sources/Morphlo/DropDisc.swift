import AppKit
import UniformTypeIdentifiers

/// The round drop zone that opens under the menu-bar icon. Drop files (from Finder or straight
/// from Photos) and the convert wheel takes over in the same spot. Click it to pick files instead.
@MainActor
final class DropDisc {
    static let shared = DropDisc()
    private var panel: DropDiscPanel?
    var onPickFiles: ((MediaKind?) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(under button: NSStatusBarButton?) {
        if let p = panel, p.isVisible { p.close(); return }
        let p = DropDiscPanel()
        p.onClose = { [weak self] in self?.panel = nil }
        p.disc.onPick = { [weak self, weak p] kind in
            p?.close()
            self?.onPickFiles?(kind)
        }
        p.disc.onFiles = { [weak p] urls, center in
            p?.close()
            FormatWheel.shared.present(for: urls, at: center)
        }
        panel = p
        p.show(under: button)
    }

    func close() { panel?.close() }

    /// Opens the disc centered on a point (the cursor), e.g. from a shortcut or mid-drag.
    func show(at point: NSPoint, duringDrag: Bool) {
        if let p = panel, p.isVisible {
            if duringDrag { return } // already up for this drag
            p.close()
            return
        }
        let p = DropDiscPanel()
        p.openedDuringDrag = duringDrag
        p.onClose = { [weak self] in self?.panel = nil }
        p.disc.onPick = { [weak self, weak p] kind in
            p?.close()
            self?.onPickFiles?(kind)
        }
        p.disc.onFiles = { [weak p] urls, center in
            p?.close()
            FormatWheel.shared.present(for: urls, at: center)
        }
        panel = p
        p.show(at: point)
    }

    /// A drag ended: a disc that popped up for it closes unless the file was dropped on it.
    func dragEnded() {
        guard let p = panel, p.openedDuringDrag else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak p] in
            guard let p, p.isVisible, !p.disc.isBusy else { return }
            p.close()
        }
    }
}

@MainActor
final class DropDiscPanel: NSPanel {
    static let size: CGFloat = 260
    let disc = DropDiscView(frame: NSRect(x: 0, y: 0, width: DropDiscPanel.size, height: DropDiscPanel.size))
    var onClose: (() -> Void)?
    var openedDuringDrag = false

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

    /// Centered on the cursor, kept on screen.
    func show(at point: NSPoint) {
        var origin = NSPoint(x: point.x - Self.size / 2, y: point.y - Self.size / 2)
        if let v = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, v.minX + 4), v.maxX - Self.size - 4)
            origin.y = min(max(origin.y, v.minY + 4), v.maxY - Self.size - 4)
        }
        present(origin: origin, anchorTop: false)
    }

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
        present(origin: origin, anchorTop: true)
    }

    private func present(origin: NSPoint, anchorTop: Bool) {
        setFrameOrigin(origin)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        if let layer = contentView?.layer {
            // Springs down from the menu bar, or out from the cursor.
            layer.anchorPoint = anchorTop ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 0.5, y: 0.5)
            layer.position = anchorTop ? CGPoint(x: Self.size / 2, y: Self.size) : CGPoint(x: Self.size / 2, y: Self.size / 2)
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
    var onPick: ((MediaKind?) -> Void)?
    private(set) var isTargeted = false { didSet { needsDisplay = true } }
    private var hoverIndex: Int? { didSet { if hoverIndex != oldValue { needsDisplay = true } } }
    private var hoverHub = false { didSet { if hoverHub != oldValue { needsDisplay = true } } }
    private var dragKind: MediaKind? { didSet { needsDisplay = true } }
    private var loading = false { didSet { needsDisplay = true } }
    var isBusy: Bool { loading || isTargeted }

    // Same proportions and palette as the convert wheel / radial menu.
    private let outerR: CGFloat = 118, bandInnerR: CGFloat = 66, hubR: CGFloat = 58
    private let slots: [(MediaKind, String, String)] = [
        (.image, "photo", "Images"), (.video, "film", "Video"), (.audio, "waveform", "Audio"),
        (.document, "doc.text", "Documents"), (.pdf, "doc.richtext", "PDF"), (.font, "textformat", "Fonts"),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DropIntake.acceptedTypes)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var c: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private func circle(_ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }

    private static func n(_ v: CGFloat) -> NSColor { NSColor(srgbRed: v, green: v, blue: v, alpha: 1) }
    private static let n950 = n(0.039), n800 = n(0.149), n700 = n(0.251), n600 = n(0.322), n400 = n(0.639), n50 = n(0.98)

    private func wedge(_ i: Int) -> NSBezierPath {
        let step = 360 / CGFloat(slots.count)
        let a0 = 90 + step / 2 - CGFloat(i) * step, a1 = a0 - step // slot 0 centered at the top
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: outerR, startAngle: a0, endAngle: a1, clockwise: true)
        p.appendArc(withCenter: c, radius: bandInnerR, startAngle: a1, endAngle: a0, clockwise: false)
        p.close()
        return p
    }

    private func index(at p: NSPoint) -> Int? {
        let r = hypot(p.x - c.x, p.y - c.y)
        guard r > bandInnerR, r < outerR else { return nil }
        let step = 360 / CGFloat(slots.count)
        var off = (90 + step / 2 - atan2(p.y - c.y, p.x - c.x) * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if off < 0 { off += 360 }
        return min(slots.count - 1, Int(off / step))
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.n950.setFill(); circle(outerR).fill() // one constant disc

        for (i, slot) in slots.enumerated() {
            let lit = (isTargeted && (dragKind == nil || dragKind == slot.0)) || hoverIndex == i
            let path = wedge(i)
            (lit ? Self.n700 : Self.n800).setFill(); path.fill()
            Self.n600.setStroke(); path.lineWidth = 1; path.stroke()
            let step = 360 / CGFloat(slots.count)
            let mid = (90 - CGFloat(i) * step) * .pi / 180
            let ir = (bandInnerR + outerR) / 2
            let ic = NSPoint(x: c.x + cos(mid) * ir, y: c.y + sin(mid) * ir)
            if let img = NSImage(systemSymbolName: slot.1, accessibilityDescription: slot.2)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) {
                let tint = lit ? Self.n50 : Self.n400
                let t = NSImage(size: img.size, flipped: false) { r in img.draw(in: r); tint.set(); r.fill(using: .sourceAtop); return true }
                t.draw(in: NSRect(x: ic.x - img.size.width / 2, y: ic.y - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
        }

        // Center: dark well with a hairline rim and the small ring dot, like the radial menu.
        let hub = circle(hubR)
        Self.n950.setFill(); hub.fill()
        hub.lineWidth = 1
        Self.n600.withAlphaComponent(0.7).setStroke(); hub.stroke()

        let text: String? = loading ? "Getting file…"
            : isTargeted ? "Release to convert"
            : hoverIndex.map { slots[$0].2 }
            ?? (hoverHub ? "Choose a file" : "Drop to convert")
        let dotY = c.y + 9
        let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 3, y: dotY - 3, width: 6, height: 6))
        dot.lineWidth = 1
        (isTargeted ? Self.n400 : Self.n600).setStroke(); dot.stroke()
        if let text {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: (isTargeted || hoverHub || hoverIndex != nil) ? Self.n50 : Self.n400]
            let sz = (text as NSString).size(withAttributes: a)
            (text as NSString).draw(at: NSPoint(x: c.x - sz.width / 2, y: c.y - 12), withAttributes: a)
        }
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverIndex = index(at: p)
        hoverHub = hypot(p.x - c.x, p.y - c.y) <= hubR
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; hoverHub = false }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = index(at: p) { onPick?(slots[i].0) }           // a section: pick that kind of file
        else if hypot(p.x - c.x, p.y - c.y) <= hubR { onPick?(nil) } // center: pick anything
        else { window?.close() }
    }

    // MARK: Drop destination

    private func kind(of pb: NSPasteboard) -> MediaKind? {
        if let url = DropIntake.fileURLs(pb).first { return MediaKind.of(url) }
        let types = pb.types ?? []
        if types.contains(.heic) || types.contains(.png) || types.contains(.tiff) { return .image }
        if let r = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver])?.first,
           let t = r.fileTypes.first.flatMap({ UTType($0) }) {
            return t.conforms(to: .movie) ? .video : t.conforms(to: .image) ? .image : nil
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(.morphloMarker) == true { return [] }
        dragKind = kind(of: sender.draggingPasteboard)
        isTargeted = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.types?.contains(.morphloMarker) == true ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { isTargeted = false; dragKind = nil }
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
