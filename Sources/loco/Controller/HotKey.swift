import Carbon.HIToolbox
import Cocoa

/// A system-wide hotkey (Carbon `RegisterEventHotKey`) that fires even when our
/// accessory app isn't frontmost. The callback is delivered on the main thread.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    /// `keyCode` is a `kVK_*` virtual key; `modifiers` is a Carbon mask
    /// (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`). Returns nil if the
    /// combo couldn't be registered (e.g. already taken by another app).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        // No captures → converts to a C function pointer; context comes via userData.
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                                  selfPtr, &eventHandler) == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4C_4F_43_4B), id: 1)  // 'LOCK'
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(),
                                  0, &hotKeyRef) == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
