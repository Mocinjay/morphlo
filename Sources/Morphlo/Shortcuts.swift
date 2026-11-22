import AppKit
import Carbon

/// A key plus modifiers, e.g. ⌃⌥M. Stored in UserDefaults; registered as a Carbon hot key.
struct KeyCombo: Equatable, Codable {
    var keyCode: UInt32
    var modifierFlags: UInt   // NSEvent.ModifierFlags raw value, limited to ⌃⌥⇧⌘
    var keyName: String

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    /// Default for "open the drop disc": ⌃⌥M (M for Morphlo) — not a macOS default.
    static let defaultOpenDisc = KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: [.control, .option], keyName: "M")

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, keyName: String) {
        self.keyCode = keyCode
        modifierFlags = modifiers.intersection(Self.relevant).rawValue
        self.keyName = keyName
    }

    init(event: NSEvent) {
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        self.init(keyCode: UInt32(event.keyCode), modifiers: event.modifierFlags,
                  keyName: names[Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "?")
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }
    /// A global shortcut needs ⌃, ⌥ or ⌘, or it would swallow normal typing.
    var isValid: Bool { !modifiers.intersection([.control, .option, .command]).isEmpty }

    var display: String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined() + keyName
    }

    var carbonModifiers: Int {
        var m = 0
        if modifiers.contains(.control) { m |= controlKey }
        if modifiers.contains(.option) { m |= optionKey }
        if modifiers.contains(.shift) { m |= shiftKey }
        if modifiers.contains(.command) { m |= cmdKey }
        return m
    }
}

/// The key you tap *while dragging* to pop the drop disc up under the cursor. Reading modifier
/// state needs no special permission (same approach as OpenShelf).
enum DragTrigger: String, CaseIterable {
    case shift, option, control, command, off

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .option: .option
        case .control: .control
        case .command: .command
        case .off: []
        }
    }
    var title: String {
        switch self {
        case .shift: "⇧ Shift"
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .command: "⌘ Command"
        case .off: "Off"
        }
    }
}

extension Settings {
    static var dragTrigger: DragTrigger {
        get { DragTrigger(rawValue: UserDefaults.standard.string(forKey: "dragTrigger") ?? "") ?? .shift }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dragTrigger") }
    }
    static var openDiscShortcut: KeyCombo? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "openDiscShortcut") else { return .defaultOpenDisc }
            if data.isEmpty { return nil } // explicitly turned off
            return try? JSONDecoder().decode(KeyCombo.self, from: data)
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: "openDiscShortcut")
        }
    }
}

/// Watches the modifier keys during a drag and fires once when the trigger key is tapped or held
/// (held for 70 ms, or pressed and let go — so ⇧ on the way to ⇧⌥ doesn't count).
@MainActor
final class DragTriggerDetector {
    private var heldSince: Date?
    private var fired = false
    private var sawOnlyTrigger = false
    private var armed = true

    /// Called when the mouse goes down. If the trigger key was already held before the press
    /// (e.g. ⇧-drag to extend a text selection), it doesn't count until it's let go.
    func reset() {
        heldSince = nil; fired = false; sawOnlyTrigger = false
        armed = Self.heldModifiers.isEmpty
    }

    /// Modifier keys physically held right now. Reads the hardware (HID) state directly, which
    /// stays accurate while another app owns the drag; AppKit's view is unioned in as a backup.
    static var heldModifiers: NSEvent.ModifierFlags {
        let hid = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.hidSystemState).rawValue))
        return hid.union(NSEvent.modifierFlags).intersection(KeyCombo.relevant)
    }

    /// Call every drag tick. Returns true once per drag when the trigger fires.
    func tick() -> Bool {
        let trigger = Settings.dragTrigger.flags
        guard !trigger.isEmpty, !fired else { return false }
        let held = Self.heldModifiers
        if !armed { if held.isEmpty { armed = true }; return false }
        if held == trigger {
            if heldSince == nil { heldSince = Date(); sawOnlyTrigger = true }
            if let t = heldSince, Date().timeIntervalSince(t) >= 0.07 { fired = true; Log.write("Drag trigger: fired (held)"); return true }
        } else if held.isEmpty {
            if sawOnlyTrigger { fired = true; Log.write("Drag trigger: fired (tap)"); return true } // a quick tap
            heldSince = nil
        } else {
            heldSince = nil
            sawOnlyTrigger = false // another key joined in: not our trigger
        }
        return false
    }
}

/// A tiny "press the new shortcut" window.
@MainActor
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    static let shared = ShortcutRecorder()
    private var window: NSPanel?
    private var monitor: Any?
    private var label: NSTextField?

    func record(title: String, onDone: @escaping (KeyCombo?) -> Void) {
        window?.close()
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self
        let v = NSView(frame: w.contentLayoutRect)
        let l = NSTextField(labelWithString: "Press the new shortcut…\n(use ⌃, ⌥ or ⌘ plus a key — Esc cancels, ⌫ turns it off)")
        l.alignment = .center
        l.maximumNumberOfLines = 3
        l.font = .systemFont(ofSize: 13)
        l.frame = NSRect(x: 16, y: 40, width: 308, height: 70)
        v.addSubview(l)
        w.contentView = v
        label = l
        window = w
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            if e.keyCode == UInt16(kVK_Escape) { self.finish(); return nil }
            if e.keyCode == UInt16(kVK_Delete) { onDone(nil); self.finish(); return nil }
            let combo = KeyCombo(event: e)
            guard combo.isValid else {
                self.label?.stringValue = "\(combo.display) needs ⌃, ⌥ or ⌘ — try again"
                NSSound.beep()
                return nil
            }
            onDone(combo)
            self.finish()
            return nil
        }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
