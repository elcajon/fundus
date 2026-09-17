import AppKit
import Carbon.HIToolbox

/// Systemweiter Kurzbefehl über die Carbon-Hotkey-API. Braucht keine Bedienungshilfen-Freigabe.
@MainActor
final class GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `keyCode` ist ein virtueller Tastencode (z. B. `kVK_ANSI_A`), `modifiers` Carbon-Flags (`cmdKey | optionKey`).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x41424C47), id: id) // 'ABLG'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Log.app.error("Kurzbefehl nicht registriert (\(status)), vermutlich schon belegt")
            return nil
        }
        Self.handlers[id] = action
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
