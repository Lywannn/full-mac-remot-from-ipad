import Carbon
import IPadModeCore

/// The emergency hotkey (R52): a Carbon hot key on the application's event target, which needs no Accessibility
/// permission. Carbon delivers it in the AppKit event loop, on the main thread. Unregistered when released.
@MainActor public final class HotkeyRegistrar {
    /// 'IPMD', id 1: the hot key that is ours.
    private static let signature: OSType = "IPMD".utf8.reduce(0) { $0 << 8 | OSType($1) }
    private static let id: UInt32 = 1

    private let action: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Nil when the key cannot be registered, e.g. because another app holds it.
    public init?(spec: HotkeySpec, action: @escaping @MainActor () -> Void) {
        self.action = action
        let target = GetApplicationEventTarget()
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(target, hotKeyPressed, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(),
                                  &handler) == noErr else { return nil }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.id)
        guard RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, hotKeyID, target, 0, &hotKey) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil   // so that deinit does not remove it again
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    fileprivate func pressed(_ id: EventHotKeyID) {
        guard id.signature == Self.signature, id.id == Self.id else { return }
        action()
    }
}

/// Carbon calls this for each hot key of the application, on the main thread inside the event loop.
private func hotKeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?,
                           _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let registrar = Unmanaged<HotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { registrar.pressed(id) }
    return noErr
}
