import AppKit
import Carbon.HIToolbox
import SuperclickCore

/// A global hotkey through Carbon's RegisterEventHotKey. It needs no
/// permission and doesn't see any other keystrokes.
@MainActor
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// nil when the shortcut couldn't be registered (usually: another app owns it).
    init?(preset: HotkeyPreset, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1

        let (code, mods) = Self.keys(for: preset)
        let hotKeyID = EventHotKeyID(signature: OSType(0x5343_4C4B) /* 'SCLK' */, id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(code, mods, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return nil }
        ref = newRef
        Self.actions[id] = action
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    static func keys(for preset: HotkeyPreset) -> (UInt32, UInt32) {
        let space = UInt32(kVK_Space)
        switch preset {
        case .optionSpace: return (space, UInt32(optionKey))
        case .controlOptionSpace: return (space, UInt32(controlKey | optionKey))
        case .shiftOptionSpace: return (space, UInt32(shiftKey | optionKey))
        case .commandShiftSpace: return (space, UInt32(cmdKey | shiftKey))
        }
    }

    fileprivate static func fire(_ id: UInt32) {
        actions[id]?()
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr else { return err }
            let id = hotKeyID.id
            // Carbon calls this on the main thread.
            MainActor.assumeIsolated { HotKey.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
