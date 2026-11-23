import AppKit

/// The convert wheel: a ring of every format the chosen file(s) can become, around the cursor.
/// Hover a slice, click it, and the hub shows progress and then the result.
@MainActor
final class FormatWheel {
    static let shared = FormatWheel()
    private var panel: WheelPanel?
    var isVisible: Bool { panel?.isVisible ?? false }

    /// Results land next to each original (or in Downloads if that folder is read-only).
    /// `onDone` gets the outputs, e.g. so the shelf can show them.
    func present(for urls: [URL], at point: NSPoint? = nil, onDone: (([URL]) -> Void)? = nil) {
        let files = urls.filter { MediaKind.of($0) != nil }
        if let busy = panel, busy.isBusy {
            // One conversion at a time: bring the running wheel back instead of orphaning it.
            NSSound.beep()
            busy.orderFrontRegardless()
            return
        }
        panel?.close()
        guard !files.isEmpty else {
            NSSound.beep()
            Log.write("Wheel: no convertible files in \(urls.map(\.lastPathComponent))")
            return
        }
        let kinds = Set(files.compactMap(MediaKind.of))
        let groups = Targets.groups(for: kinds)
        let targets = groups.flatMap(\.1)
        guard !targets.isEmpty else { NSSound.beep(); return }
        // "Same as the source" = the default format for each file's extension (so an .mp4 still
        // offers MP4 HEVC, and an .m4a still offers ALAC).
        let same = Set(files.compactMap { Self.defaultTargetID(forExtension: $0.pathExtension) })
        let preferred = Targets.preferred(for: kinds, sourceExts: [], among: targets.filter { !same.contains($0.id) })
        var ordered = targets
        if let p = preferred, let i = ordered.firstIndex(of: p) { ordered.remove(at: i); ordered.insert(p, at: 0) }
        ordered = ordered.filter { !same.contains($0.id) } + ordered.filter { same.contains($0.id) }

        let p = WheelPanel(files: files, targets: ordered, sameIDs: same, mixedGroups: groups.count > 1, onDone: onDone)
        p.onClose = { [weak self, weak p] in
            if self?.panel === p { self?.panel = nil }
            DropDisc.shared.wheelClosed()
        }
        panel = p
        p.show(at: point ?? NSEvent.mouseLocation)
        Log.write("Wheel: \(files.count) file(s), \(ordered.count) formats")
    }

    static func defaultTargetID(forExtension e: String) -> String? {
        switch e.lowercased() {
        case "jpg", "jpeg": "jpg"
        case "png": "png"
        case "heic", "heif": "heic"
        case "avif": "avif"
        case "tif", "tiff": "tiff"
        case "gif": "gif-img"
        case "bmp": "bmp"
        case "mp4", "m4v": "mp4-h264"
        case "mov", "qt": "mov-prores"
        case "m4a": "m4a"
        case "wav", "wave": "wav"
        case "flac": "flac"
        case "aif", "aiff", "aifc": "aiff"
        case "docx": "docx"
        case "doc": "doc"
        case "odt": "odt"
        case "rtf": "rtf"
        case "txt": "txt"
        case "html", "htm": "html"
        case "woff": "font-woff"
        case "woff2": "font-woff2"
        case "ttf", "otf": "font-desktop"
        default: nil
        }
    }
}

// MARK: - Panel

@MainActor
final class WheelPanel: NSPanel {
    static let size: CGFloat = 400
    var onClose: (() -> Void)?
    private let wheel: WheelView

    init(files: [URL], targets: [Target], sameIDs: Set<String>, mixedGroups: Bool, onDone: (([URL]) -> Void)?) {
        wheel = WheelView(files: files, targets: targets, sameIDs: sameIDs, mixedGroups: mixedGroups, onDone: onDone)
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        // Flat, solid disc drawn by WheelView (neutral palette, no outer ring).
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        container.wantsLayer = true
        wheel.frame = container.bounds
        wheel.autoresizingMask = [.width, .height]
        container.addSubview(wheel)
        contentView = container
        wheel.close = { [weak self] in self?.close() }
    }

    override var canBecomeKey: Bool { true }
    var isBusy: Bool { wheel.isBusy }

    func show(at point: NSPoint) {
        // Center on the cursor, but keep the whole wheel on screen.
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: point.x - Self.size / 2, y: point.y - Self.size / 2)
        if let v = screen?.visibleFrame {
            origin.x = min(max(origin.x, v.minX), v.maxX - Self.size)
            origin.y = min(max(origin.y, v.minY), v.maxY - Self.size)
        }
        setFrameOrigin(origin)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        makeFirstResponder(wheel)
        // Springy pop-in: scale 0.5 → 1 from the center, with a quick fade.
        if let layer = contentView?.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: Self.size / 2, y: Self.size / 2)
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.5
            spring.toValue = 1
            spring.stiffness = 420
            spring.damping = 32
            spring.mass = 1
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "pop")
        }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.invalidateShadow() }
    }

    override func resignKey() {
        super.resignKey()
        // Clicking elsewhere dismisses the wheel, unless a conversion is running.
        if !wheel.isBusy { close() }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        wheel.cancel() // stops a running conversion; no-op otherwise
        super.close()
        onClose?()
        onClose = nil
    }
}

// MARK: - Wheel view

@MainActor
final class WheelView: NSView {
    private enum Phase { case picking, working(Double), done([URL]), failed(String) }
    private enum Slice { case format(Target), more, back }

    private let files: [URL]
    private let targets: [Target]
    private let mixedGroups: Bool
    private let sameIDs: Set<String>
    private let onDone: (([URL]) -> Void)?
    var close: (() -> Void)?

    private var page = 0
    private var hovered: Int?
    private var phase: Phase = .picking
    private var appear: CGFloat = 1
    private let runner = Runner()
    private var task: Task<Void, Never>?

    private static let maxSlices = 10
    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    // iPod-style: a continuous ring, a thin groove, and a separate center button.
    // One constant disc: wedge band from ringInnerR to outerR, a narrow dark gap, then the hub.
    static let outerR: CGFloat = 160, ringInnerR: CGFloat = 74, hubR: CGFloat = 64
    private var outerR: CGFloat { Self.outerR }
    private var ringInnerR: CGFloat { Self.ringInnerR }
    private var innerR: CGFloat { Self.hubR }
    private var pressed: Int?

    var isBusy: Bool { if case .working = phase { return true } else { return false } }

    /// Stops a running conversion (kills ffmpeg etc.); partial outputs are removed by the engine.
    func cancel() {
        guard isBusy else { return }
        Log.write("Wheel: conversion cancelled")
        runner.cancel()
        task?.cancel()
    }

    init(files: [URL], targets: [Target], sameIDs: Set<String>, mixedGroups: Bool, onDone: (([URL]) -> Void)?) {
        self.sameIDs = sameIDs
        self.files = files
        self.targets = targets
        self.mixedGroups = mixedGroups
        self.onDone = onDone
        super.init(frame: NSRect(x: 0, y: 0, width: WheelPanel.size, height: WheelPanel.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Pages: up to 10 slices; when there are more formats, the last slice is "More".
    private var pages: [[Target]] {
        if targets.count <= Self.maxSlices { return [targets] }
        let per = Self.maxSlices - 1
        return stride(from: 0, to: targets.count, by: per).map { Array(targets[$0..<min($0 + per, targets.count)]) }
    }

    private var slices: [Slice] {
        let ps = pages
        var s = ps[page].map { Slice.format($0) }
        if ps.count > 1 { s.append(page == ps.count - 1 ? .back : .more) }
        return s
    }

    func animateIn() { needsDisplay = true }

    // MARK: Geometry

    private func sliceIndex(at p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = hypot(dx, dy)
        guard r > ringInnerR, r < outerR else { return nil }
        let n = slices.count
        let angle = atan2(dy, dx) * 180 / .pi
        var off = (90 - angle).truncatingRemainder(dividingBy: 360)
        if off < 0 { off += 360 }
        return min(n - 1, Int(off / (360 / CGFloat(n))))
    }

    private func isInHub(_ p: NSPoint) -> Bool { hypot(p.x - center.x, p.y - center.y) <= innerR }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        guard case .picking = phase else { return }
        let i = sliceIndex(at: convert(event.locationInWindow, from: nil))
        if i != hovered {
            hovered = i
            if i != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard case .picking = phase else { return }
        pressed = sliceIndex(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .picking = phase else { return }
        let i = sliceIndex(at: convert(event.locationInWindow, from: nil))
        if i != hovered { hovered = i; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let down = pressed
        pressed = nil
        // A slice only fires if the press started on it too (press A, release on B = no action).
        if case .picking = phase, let i = sliceIndex(at: p), i != down { needsDisplay = true; return }
        switch phase {
        case .picking:
            if let i = sliceIndex(at: p) {
                switch slices[i] {
                case .format(let t): start(t, flip: event.modifierFlags.contains(.option))
                case .more: page += 1; hovered = nil; animateIn()
                case .back: page = 0; hovered = nil; animateIn()
                }
            } else if !isInHub(p) {
                close?()
            } else {
                close?()
            }
        case .working:
            if isInHub(p) { close?() } // clicking the hub while converting cancels
        case .done(let outs):
            if isInHub(p), !outs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outs) }
            close?()
        case .failed:
            close?()
        }
    }

    override func flagsChanged(with event: NSEvent) { needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close?(); return } // esc (cancels a running conversion)
        super.keyDown(with: event)
    }

    // MARK: Converting

    private func start(_ target: Target, flip: Bool = false) {
        let replace = Settings.replaceOriginal != flip
        phase = .working(0)
        hovered = nil
        needsDisplay = true
        let files = self.files, runner = self.runner
        Log.write("Wheel: converting \(files.map(\.lastPathComponent)) to \(target.id)")
        task = Task {
            var outputs: [URL] = []
            var failures: [String] = []
            for (i, file) in files.enumerated() {
                if runner.isCancelled { break }
                do {
                    var outs = try await FormatConverter.convert(file, to: target, settings: ConvSettings(), runner: runner) { [weak self] f in
                        let overall = (Double(i) + f) / Double(files.count)
                        DispatchQueue.main.async { self?.setProgress(overall) }
                    }
                    let inCache = file.standardizedFileURL.path.hasPrefix(WorkDir.root.standardizedFileURL.path)
                    outs = Self.moveOutOfCache(outs, input: file)
                    outputs += outs
                    // Replace mode: the original goes to the Trash (recoverable), the new file stays.
                    if replace, !inCache, !outs.isEmpty, !outs.contains(file) {
                        do {
                            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                            replacedCount += 1
                        } catch {
                            Log.write("Wheel: couldn't move \(file.lastPathComponent) to Trash: \(error.localizedDescription)")
                        }
                    }
                    self.setProgress(Double(i + 1) / Double(files.count))
                } catch is StoppedError {
                    break
                } catch {
                    failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
                    Log.write("Wheel: failed \(failures.last!)")
                }
            }
            if runner.isCancelled { return }
            if outputs.isEmpty {
                phase = .failed(failures.first ?? "Nothing was produced")
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    if case .failed = self?.phase { self?.close?() }
                }
            } else {
                phase = .done(outputs)
                partialFailures = failures.count
                onDone?(outputs)
                Log.write("Wheel: done -> \(outputs.map(\.lastPathComponent)) failures=\(failures.count)")
                DispatchQueue.main.asyncAfter(deadline: .now() + (failures.isEmpty ? 4 : 7)) { [weak self] in
                    if case .done = self?.phase { self?.close?() }
                }
            }
            needsDisplay = true
        }
    }

    private var partialFailures = 0
    private var replacedCount = 0

    /// Shelf items live in Morphlo's cache, which gets cleaned. Conversions of those land in
    /// Downloads instead, where the user can find and keep them.
    private static func moveOutOfCache(_ outs: [URL], input: URL) -> [URL] {
        guard input.standardizedFileURL.path.hasPrefix(WorkDir.root.standardizedFileURL.path) else { return outs }
        let downloads = OutputFolder.fallback
        return outs.map { out in
            let base = out.deletingPathExtension().lastPathComponent
            var dest = downloads.appendingPathComponent(out.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = downloads.appendingPathComponent("\(base) \(n)").appendingPathExtension(out.pathExtension)
                n += 1
            }
            do { try FileManager.default.moveItem(at: out, to: dest); return dest } catch { return out }
        }
    }

    private func setProgress(_ f: Double) {
        if case .working = phase { phase = .working(f); needsDisplay = true }
    }

    // MARK: Drawing — grayscale, Apple HUD style

    private func wedge(_ i: Int, of n: Int) -> NSBezierPath {
        let step = 360 / CGFloat(n)
        let a0 = 90 - CGFloat(i) * step, a1 = 90 - CGFloat(i + 1) * step
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: outerR, startAngle: a0, endAngle: a1, clockwise: true)
        p.appendArc(withCenter: center, radius: ringInnerR, startAngle: a1, endAngle: a0, clockwise: false)
        p.close()
        return p
    }

    private func circle(_ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }

    // Neutral palette (Tailwind neutral-50…950), dark mode.
    private static func n(_ v: CGFloat) -> NSColor { NSColor(srgbRed: v, green: v, blue: v, alpha: 1) }
    private static let n950 = n(0.039), n800 = n(0.149), n700 = n(0.251), n600 = n(0.322), n400 = n(0.639), n50 = n(0.98)

    override func draw(_ dirtyRect: NSRect) {
        let c = center
        let items = slices
        let n = items.count
        let step = 360 / CGFloat(n)

        // Base: one solid disc, so the gap between band and hub reads as a dark groove.
        Self.n950.setFill()
        circle(outerR).fill()

        for (i, item) in items.enumerated() {
            let active = hovered == i || pressed == i
            let path = wedge(i, of: n)
            (pressed == i ? Self.n600 : (active ? Self.n700 : Self.n800)).setFill()
            path.fill()
            Self.n600.setStroke()
            path.lineWidth = 1
            path.stroke()

            let mid = (90 - (CGFloat(i) + 0.5) * step) * .pi / 180
            let lr = (ringInnerR + outerR) / 2
            let lp = NSPoint(x: c.x + cos(mid) * lr, y: c.y + sin(mid) * lr)
            let (title, sub) = labels(for: item)
            let color = isDimmed(item) ? Self.n600 : (active ? Self.n50 : Self.n400)
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: n > 8 ? 12.5 : 13.5, weight: .semibold), .foregroundColor: color,
            ]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .regular), .foregroundColor: color.withAlphaComponent(0.7),
            ]
            let ts = (title as NSString).size(withAttributes: titleAttrs)
            if let sub {
                let ss = (sub as NSString).size(withAttributes: subAttrs)
                (title as NSString).draw(at: NSPoint(x: lp.x - ts.width / 2, y: lp.y - 1), withAttributes: titleAttrs)
                (sub as NSString).draw(at: NSPoint(x: lp.x - ss.width / 2, y: lp.y - ss.height), withAttributes: subAttrs)
            } else {
                (title as NSString).draw(at: NSPoint(x: lp.x - ts.width / 2, y: lp.y - ts.height / 2), withAttributes: titleAttrs)
            }
        }

        drawHub(c, innerR)
    }

    private func isDimmed(_ item: Slice) -> Bool {
        guard case .format(let t) = item else { return false }
        return sameIDs.contains(t.id)
    }

    private func labels(for item: Slice) -> (String, String?) {
        switch item {
        case .more: return ("More", nil)
        case .back: return ("Back", nil)
        case .format(let t):
            var title = t.label, sub: String?
            if let open = title.range(of: " (") {
                sub = String(title[open.upperBound...]).replacingOccurrences(of: ")", with: "")
                title = String(title[..<open.lowerBound])
            }
            if title.hasPrefix("Word 97") { title = "DOC"; sub = "Word 97" }
            if title.hasPrefix("Word") { title = "DOCX" }
            if title == "Plain Text" { title = "TXT" }
            if title == "Rich Text" { title = "RTF" }
            if title == "OpenDocument" { title = "ODT" }
            if title.hasPrefix("TTF / OTF") { title = "TTF/OTF" }
            if mixedGroups && t.group == .audio { sub = sub.map { "audio · " + $0 } ?? "audio" }
            if let s = sub, s.count > 17 { sub = String(s.prefix(16)) + "…" }
            return (title, sub)
        }
    }

    private func drawHub(_ c: NSPoint, _ r: CGFloat) {
        let hub = circle(r)
        Self.n950.setFill()
        hub.fill()
        hub.lineWidth = 1
        Self.n600.withAlphaComponent(0.8).setStroke()
        hub.stroke()

        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: Self.n400]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                                                   .foregroundColor: Self.n50]
        func centered(_ s: String, _ y: CGFloat, _ a: [NSAttributedString.Key: Any], maxW: CGFloat = 104) {
            var text = s
            while (text as NSString).size(withAttributes: a).width > maxW && text.count > 4 { text = String(text.dropLast(2)) + "…" }
            let sz = (text as NSString).size(withAttributes: a)
            (text as NSString).draw(at: NSPoint(x: c.x - sz.width / 2, y: y), withAttributes: a)
        }
        func symbol(_ name: String, _ size: CGFloat, y: CGFloat) {
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .medium)) else { return }
            let tinted = NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect); NSColor(white: 1, alpha: 0.95).set(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: c.x - img.size.width / 2, y: y, width: img.size.width, height: img.size.height))
        }

        switch phase {
        case .picking:
            // Just the file name and what you're pointing at; no icon.
            let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            centered(name, c.y + 1, bold)
            let replacing = Settings.replaceOriginal != NSEvent.modifierFlags.contains(.option)
            var hint = replacing ? "Replace with…" : "Convert to…"
            if let h = hovered, h < slices.count, case .format(let t) = slices[h] { hint = (replacing ? "Replace → " : "") + t.label }
            centered(hint, c.y - 15, small)
        case .working(let f):
            // Progress runs around the groove between the button and the ring.
            let gr = (r + ringInnerR) / 2
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: gr, startAngle: 0, endAngle: 360)
            track.lineWidth = 3
            Self.n800.setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: gr, startAngle: 90, endAngle: 90 - 360 * CGFloat(max(0.02, f)), clockwise: true)
            arc.lineWidth = 3
            arc.lineCapStyle = .round
            NSColor(white: 1, alpha: 0.95).setStroke()
            arc.stroke()
            centered("\(Int(f * 100))%", c.y - 2, [.font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold),
                                                    .foregroundColor: NSColor(white: 1, alpha: 0.95)])
            centered("Click to cancel", c.y - 19, small)
        case .done(let outs):
            symbol("checkmark.circle", 24, y: c.y + 6)
            centered(outs.count == 1 ? outs[0].lastPathComponent : "\(outs.count) files saved", c.y - 12, bold)
            let note = partialFailures > 0 ? "\(partialFailures) failed — see log"
                : replacedCount > 0 ? "Original moved to Trash" : "Show in Finder"
            centered(note, c.y - 27, small)
        case .failed(let msg):
            symbol("exclamationmark.circle", 24, y: c.y + 6)
            let detail = msg.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
            centered("Couldn't convert", c.y - 12, bold)
            centered(detail.isEmpty ? msg : detail, c.y - 27, small)
        }
    }
}
