import Carbon
import Foundation

private let hotKeySignature: OSType = 0x5353434C // SSCL

@MainActor
final class GlobalHotKey {
    var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == hotKeySignature else { return noErr }
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { owner.onPressed?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    @discardableResult
    func register(_ configuration: HotKeyConfiguration) -> Bool {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        guard configuration.isValid else { return false }
        let identifier = EventHotKeyID(signature: hotKeySignature, id: 1)
        let status = RegisterEventHotKey(
            configuration.keyCode,
            configuration.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return status == noErr
    }
}
