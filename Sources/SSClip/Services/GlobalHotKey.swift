import Carbon
import Foundation

private let hotKeySignature: OSType = 0x5353434C // SSCL

/// Carbon application hot keys need no Accessibility or Input Monitoring permission.
/// Every binding gets a distinct ID so one handler can never consume another's event.
@MainActor
final class GlobalHotKey {
    struct Registration {
        let unregister: () -> Void
    }

    struct Backend {
        var register: (HotKeyConfiguration, EventHotKeyID) -> Registration?
        var schedule: (@escaping () -> Void) -> Void
        var installCarbonHandler: Bool

        static let live = Backend(
            register: { configuration, identifier in
                var reference: EventHotKeyRef?
                let status = RegisterEventHotKey(
                    configuration.keyCode, configuration.carbonModifiers, identifier,
                    GetApplicationEventTarget(), 0, &reference
                )
                guard status == noErr, let reference else { return nil }
                return Registration(unregister: { _ = UnregisterEventHotKey(reference) })
            },
            schedule: { action in DispatchQueue.main.async(execute: action) },
            installCarbonHandler: true
        )
    }

    var onPressed: (() -> Void)?
    /// Suppresses actions while a shortcut recorder or another sensitive UI is active.
    var shouldTrigger: (() -> Bool)?
    private(set) var identifier: UInt32
    private(set) var configuration: HotKeyConfiguration?
    private let backend: Backend
    private var registration: Registration?
    private var eventHandlerRef: EventHandlerRef?
    private var handlerReady = false
    private var isHeld = false
    private var generation: UInt64 = 0
    private static var nextIdentifier: UInt32 = 0

    private static func allocateIdentifier() -> UInt32 {
        // Zero is reserved. Exhaustion would require billions of rebindings in one process.
        nextIdentifier &+= 1
        if nextIdentifier == 0 { nextIdentifier = 1 }
        return nextIdentifier
    }

    init(backend: Backend = .live) {
        self.backend = backend
        identifier = Self.allocateIdentifier()
        guard backend.installCarbonHandler else { handlerReady = true; return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = eventTypes.withUnsafeMutableBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, context in
                    guard let event, let context, Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
                    var identifier = EventHotKeyID()
                    let status = GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                    )
                    guard status == noErr else { return OSStatus(eventNotHandledErr) }
                    let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                    // GetApplicationEventTarget dispatches these events on the application main thread.
                    return MainActor.assumeIsolated {
                        owner.handleEvent(signature: identifier.signature, id: identifier.id, kind: GetEventKind(event))
                    }
                },
                UInt32(buffer.count), buffer.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef
            )
        }
        handlerReady = status == noErr
    }

    deinit {
        registration?.unregister()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    @discardableResult
    func register(_ candidate: HotKeyConfiguration) -> Bool {
        guard handlerReady, candidate.isValid else { return false }
        if let configuration, registration != nil, configuration.sameCombo(as: candidate) {
            self.configuration = candidate
            return true
        }
        let candidateID = Self.allocateIdentifier()
        // Register first. A conflict or invalid candidate leaves the working binding untouched.
        guard let replacement = backend.register(candidate, EventHotKeyID(signature: hotKeySignature, id: candidateID)) else { return false }
        generation &+= 1
        registration?.unregister()
        registration = replacement
        identifier = candidateID
        configuration = candidate
        isHeld = false
        return true
    }

    func unregister() {
        generation &+= 1
        registration?.unregister()
        registration = nil
        configuration = nil
        isHeld = false
    }

    /// Internal entry point also used by deterministic tests without taking system hot keys.
    @discardableResult
    func handleEvent(signature: OSType = hotKeySignature, id: UInt32, kind: UInt32) -> OSStatus {
        guard signature == hotKeySignature, id == identifier, registration != nil else { return OSStatus(eventNotHandledErr) }
        if kind == UInt32(kEventHotKeyReleased) {
            isHeld = false
            return noErr
        }
        guard kind == UInt32(kEventHotKeyPressed) else { return OSStatus(eventNotHandledErr) }
        guard !isHeld else { return noErr }
        isHeld = true
        guard shouldTrigger?() ?? true else { return noErr }
        let expectedGeneration = generation
        backend.schedule { [weak self] in
            guard let self, self.generation == expectedGeneration, self.registration != nil, self.shouldTrigger?() ?? true else { return }
            self.onPressed?()
        }
        return noErr
    }
}
