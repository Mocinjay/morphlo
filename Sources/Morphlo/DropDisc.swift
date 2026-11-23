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

    /// Opened from the menu-bar butterfly or the shortcut, the disc is "pinned": it stays up while
    /// you go find a file, steps aside while the wheel is converting, and comes back afterwards.
    /// It closes only when you click the butterfly again, press the shortcut again, press Esc, or
    /// right-click it. Drag it by its center to move it.
    func toggle(under button: NSStatusBarButton?) {
        if let p = panel {
            if p.isAside { p.comeBack() } else { p.close() } // hidden behind the wheel: bring it back
            return
        }
        let p = makePanel(pinned: true)
        p.show(under: button)
    }

    func close() { panel?.close() }

    /// Opens the disc centered on a point (the cursor), e.g. from a shortcut or mid-drag.
    func show(at point: NSPoint, duringDrag: Bool) {
        Log.write("Drop disc: show at \(Int(point.x)),\(Int(point.y)) duringDrag=\(duringDrag) open=\(panel != nil)")
        if let p = panel {
            if p.isAside {
                p.comeBack()              // it was hidden behind the wheel: bring it back, to you
                p.move(centeredOn: point)
            } else if duringDrag && p.pinned && p.isVisible {
                p.move(centeredOn: point) // tapping the trigger mid-drag brings the pinned disc to you
            } else {
                p.close()                 // the trigger again, or the shortcut again: put it away
            }
            return
        }
        let p = makePanel(pinned: !duringDrag)
        p.openedDuringDrag = duringDrag
        p.show(at: point)
    }

    private func makePanel(pinned: Bool) -> DropDiscPanel {
        let p = DropDiscPanel()
        p.pinned = pinned
        p.onClose = { [weak self, weak p] in
            guard let self, self.panel === p else { return }
            self.panel = nil
        }
        p.disc.onPick = { [weak self, weak p] kind in
            guard let self else { return }
            // Only a disc that is still the open one steps aside and comes back.
            if let p, p.pinned, self.panel === p {
                p.stepAside()
                self.onPickFiles?(kind)
                if !FormatWheel.shared.isVisible { p.comeBack() } // picker cancelled
            } else {
                p?.close()
                self.onPickFiles?(kind)
            }
        }
        p.disc.onFiles = { [weak self, weak p] urls, center in
            // The disc may have been closed while a Photos original was still downloading:
            // the files still go to the wheel, but only the live disc steps aside / comes back.
            if let p, p.pinned, self?.panel === p {
                p.stepAside()
                FormatWheel.shared.present(for: urls, at: center)
                if !FormatWheel.shared.isVisible { p.comeBack() } // nothing convertible
            } else {
                p?.close()
                FormatWheel.shared.present(for: urls, at: center)
            }
        }
        panel = p
        return p
    }

    /// The wheel closed: a pinned disc that stepped aside for it comes back.
    func wheelClosed() {
        DispatchQueue.main.async { [weak self] in
            guard let p = self?.panel, p.isAside, !FormatWheel.shared.isVisible else { return }
            p.comeBack()
        }
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
    /// Stays up until it's explicitly closed (see `DropDisc`); otherwise a click elsewhere closes it.
    var pinned = false { didSet { disc.pinned = pinned } }
    /// Hidden while the wheel converts what was dropped on it; comes back when the wheel closes.
    private(set) var isAside = false

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
        if !pinned { watchOutsideClicks() }
    }

    /// Whether a screen point is on the round disc itself (not its transparent corners).
    func covers(_ point: NSPoint) -> Bool {
        hypot(point.x - frame.midX, point.y - frame.midY) <= DropDiscView.outerRadius
    }

    /// Recenters the (already visible) disc on a point, kept on screen.
    func move(centeredOn point: NSPoint) {
        var origin = NSPoint(x: point.x - Self.size / 2, y: point.y - Self.size / 2)
        if let v = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, v.minX + 4), v.maxX - Self.size - 4)
            origin.y = min(max(origin.y, v.minY + 4), v.maxY - Self.size - 4)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrameOrigin(origin)
        }
    }

    func stepAside() {
        isAside = true
        orderOut(nil)
    }

    func comeBack() {
        guard isAside else { return }
        isAside = false
        alphaValue = 0
        makeKeyAndOrderFront(nil) // key again, so Esc closes it (a non-activating panel doesn't activate the app)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
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
        isAside = false
        if disc.pinned { NSCursor.arrow.set() } // it may close under the pointer (open-hand cursor)
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
    /// Pinned discs can be moved by dragging the center, and say so on hover.
    var pinned = false
    private var downEvent: NSEvent?
    private var movedWindow = false

    // Same proportions and palette as the convert wheel / radial menu.
    static let outerRadius: CGFloat = 118
    private let outerR: CGFloat = DropDiscView.outerRadius, bandInnerR: CGFloat = 66, hubR: CGFloat = 58
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
        let subtext: String? = (pinned && hoverHub && !isTargeted && !loading) ? "or drag to move" : nil
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
        if let subtext {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .regular), .foregroundColor: Self.n400]
            let sz = (subtext as NSString).size(withAttributes: a)
            (subtext as NSString).draw(at: NSPoint(x: c.x - sz.width / 2, y: c.y - 26), withAttributes: a)
        }
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverIndex = index(at: p)
        hoverHub = hypot(p.x - c.x, p.y - c.y) <= hubR
        if pinned { (hoverHub ? NSCursor.openHand : NSCursor.arrow).set() }
    }
    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil; hoverHub = false
        if pinned { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        movedWindow = false
    }

    // Pinned: drag the center to move the disc around the screen.
    override func mouseDragged(with event: NSEvent) {
        guard pinned, !movedWindow, let down = downEvent, let window else { return }
        let start = convert(down.locationInWindow, from: nil)
        guard hypot(start.x - c.x, start.y - c.y) <= hubR else { return }
        let now = convert(event.locationInWindow, from: nil)
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        movedWindow = true
        NSCursor.closedHand.set()
        window.performDrag(with: down)
        NSCursor.openHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        if movedWindow { movedWindow = false; return } // that was a move, not a click
        let p = convert(event.locationInWindow, from: nil)
        if let i = index(at: p) { onPick?(slots[i].0) }           // a section: pick that kind of file
        else if hypot(p.x - c.x, p.y - c.y) <= hubR { onPick?(nil) } // center: pick anything
        else if !pinned { window?.close() }
    }

    override func rightMouseUp(with event: NSEvent) { window?.close() }

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
