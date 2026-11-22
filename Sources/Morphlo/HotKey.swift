import AppKit
import Carbon

/// A system-wide keyboard shortcut (Carbon hot key: no Accessibility permission needed).
/// Each instance only reacts to its own key (several can be registered at once).
final class HotKey {
    private static var nextID: UInt32 = 1
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void

    /// `keyCode` is a virtual key code (e.g. kVK_ANSI_K), `modifiers` Carbon flags (cmdKey | optionKey).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        id = HotKey.nextID
        HotKey.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let hk = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            guard hkID.id == hk.id else { return OSStatus(eventNotHandledErr) } // someone else's key
            DispatchQueue.main.async { hk.action() }
            return noErr
        }, 1, &spec, me, &handler)
        guard status == noErr else { return nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D52_504C), id: id) // "MRPL"
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// Reads the current Finder selection via Apple Events (asks the user once for permission).
enum FinderSelection {
    static func urls() -> [URL] {
        let source = """
        with timeout of 3 seconds
        tell application "Finder"
            set out to ""
            repeat with f in (selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        end timeout
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            if let error {
                Log.write("Finder selection failed: \(error)")
                if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                    let alert = NSAlert()
                    alert.messageText = "Allow Morphlo to read your Finder selection"
                    alert.informativeText = "Turn on Morphlo → Finder in System Settings → Privacy & Security → Automation. Until then, use right-click → Convert with Morphlo."
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Not Now")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                    }
                }
            }
            return []
        }
        return result.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}
