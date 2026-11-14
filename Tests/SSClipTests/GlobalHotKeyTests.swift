import Carbon
import Foundation
import Testing
@testable import SSClip

@MainActor
struct GlobalHotKeyTests {
    @Test func instancesOnlyConsumeTheirOwnEvents() {
        let harness = Harness()
        let first = GlobalHotKey(backend: harness.backend)
        let second = GlobalHotKey(backend: harness.backend)
        var firstCalls = 0
        var secondCalls = 0
        first.onPressed = { firstCalls += 1 }
        second.onPressed = { secondCalls += 1 }
        #expect(first.register(.init()))
        #expect(second.register(.init(keyCode: 1, keyDisplayName: "S", usesControl: true)))
        #expect(first.identifier != second.identifier)
        #expect(second.handleEvent(id: first.identifier, kind: UInt32(kEventHotKeyPressed)) == OSStatus(eventNotHandledErr))
        #expect(first.handleEvent(signature: 0, id: first.identifier, kind: UInt32(kEventHotKeyPressed)) == OSStatus(eventNotHandledErr))
        #expect(first.handleEvent(id: first.identifier, kind: UInt32(kEventHotKeyPressed)) == noErr)
        harness.drain()
        #expect(firstCalls == 1)
        #expect(secondCalls == 0)
    }

    @Test func carbonHandlerChainRoutesSyntheticEventsToCorrectInstance() throws {
        let harness = Harness()
        var backend = harness.backend
        backend.installCarbonHandler = true
        let first = GlobalHotKey(backend: backend)
        let second = GlobalHotKey(backend: backend)
        var firstCalls = 0
        var secondCalls = 0
        first.onPressed = { firstCalls += 1 }
        second.onPressed = { secondCalls += 1 }
        #expect(first.register(.init()))
        #expect(second.register(.init(keyCode: 1, keyDisplayName: "S")))
        // Real Carbon handler dispatch; injected registration avoids taking any system shortcut.
        try sendCarbonEvent(id: first.identifier)
        harness.drain()
        #expect(firstCalls == 1)
        #expect(secondCalls == 0)
        try sendCarbonEvent(id: second.identifier)
        harness.drain()
        #expect(firstCalls == 1)
        #expect(secondCalls == 1)
    }

    private func sendCarbonEvent(id: UInt32) throws {
        var event: EventRef?
        #expect(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                            GetCurrentEventTime(), EventAttributes(kEventAttributeUserEvent), &event) == noErr)
        let created = try #require(event)
        defer { ReleaseEvent(created) }
        var identifier = EventHotKeyID(signature: 0x5353434C, id: id)
        #expect(SetEventParameter(created, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                 MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
        #expect(SendEventToEventTarget(created, GetApplicationEventTarget()) == noErr)
    }

    @Test func holdingKeyOnlyFiresOnceUntilReleased() {
        let harness = Harness()
        let hotKey = GlobalHotKey(backend: harness.backend)
        var calls = 0
        hotKey.onPressed = { calls += 1 }
        #expect(hotKey.register(.init()))
        for _ in 0..<20 { hotKey.handleEvent(id: hotKey.identifier, kind: UInt32(kEventHotKeyPressed)) }
        harness.drain()
        #expect(calls == 1)
        hotKey.handleEvent(id: hotKey.identifier, kind: UInt32(kEventHotKeyReleased))
        hotKey.handleEvent(id: hotKey.identifier, kind: UInt32(kEventHotKeyPressed))
        harness.drain()
        #expect(calls == 2)
    }

    @Test func unregisterCancelsQueuedCallbackAndAllowsCleanReenable() {
        let harness = Harness()
        let hotKey = GlobalHotKey(backend: harness.backend)
        var calls = 0
        hotKey.onPressed = { calls += 1 }
        #expect(hotKey.register(.init()))
        let oldID = hotKey.identifier
        hotKey.handleEvent(id: oldID, kind: UInt32(kEventHotKeyPressed))
        hotKey.unregister()
        harness.drain()
        #expect(calls == 0)
        #expect(harness.unregistered.count == 1)
        #expect(hotKey.handleEvent(id: oldID, kind: UInt32(kEventHotKeyPressed)) == OSStatus(eventNotHandledErr))
        #expect(hotKey.register(.init()))
        #expect(hotKey.identifier != oldID)
        hotKey.handleEvent(id: hotKey.identifier, kind: UInt32(kEventHotKeyPressed))
        harness.drain()
        #expect(calls == 1)
    }

    @Test func failedOrInvalidRebindingPreservesWorkingRegistration() {
        let harness = Harness()
        let hotKey = GlobalHotKey(backend: harness.backend)
        let original = HotKeyConfiguration()
        #expect(hotKey.register(original))
        let originalID = hotKey.identifier
        harness.rejectRegistration = true
        #expect(!hotKey.register(.init(keyCode: 1, keyDisplayName: "S")))
        #expect(!hotKey.register(.init(usesCommand: false, usesOption: false)))
        #expect(hotKey.identifier == originalID)
        #expect(hotKey.configuration == original)
        #expect(harness.unregistered.isEmpty)
        var calls = 0
        hotKey.onPressed = { calls += 1 }
        hotKey.handleEvent(id: originalID, kind: UInt32(kEventHotKeyPressed))
        harness.drain()
        #expect(calls == 1)
    }

    @Test func successfulRebindRejectsOldEventsAndQueuedActions() {
        let harness = Harness()
        let hotKey = GlobalHotKey(backend: harness.backend)
        var calls = 0
        hotKey.onPressed = { calls += 1 }
        #expect(hotKey.register(.init()))
        let oldID = hotKey.identifier
        hotKey.handleEvent(id: oldID, kind: UInt32(kEventHotKeyPressed))
        #expect(hotKey.register(.init(keyCode: 1, keyDisplayName: "S")))
        harness.drain()
        #expect(calls == 0)
        #expect(harness.unregistered == [oldID])
        #expect(hotKey.handleEvent(id: oldID, kind: UInt32(kEventHotKeyPressed)) == OSStatus(eventNotHandledErr))
        hotKey.handleEvent(id: hotKey.identifier, kind: UInt32(kEventHotKeyPressed))
        harness.drain()
        #expect(calls == 1)
    }

    @Test func sameCombinationIsNotReregisteredOrRearmed() {
        let harness = Harness()
        let hotKey = GlobalHotKey(backend: harness.backend)
        #expect(hotKey.register(.init()))
        let identifier = hotKey.identifier
        hotKey.handleEvent(id: identifier, kind: UInt32(kEventHotKeyPressed))
        var renamed = HotKeyConfiguration()
        renamed.keyDisplayName = "v"
        #expect(hotKey.register(renamed))
        #expect(hotKey.identifier == identifier)
        #expect(harness.registrations == 1)
        #expect(harness.unregistered.isEmpty)
        hotKey.handleEvent(id: identifier, kind: UInt32(kEventHotKeyPressed))
        #expect(harness.actions.count == 1)
    }

    @Test func recordingVetoSuppressesPressedHeldAndQueuedActions() {
        let harness = Harness()
        let hotKey = GlobalHotKey(backend: harness.backend)
        var allowed = false
        var calls = 0
        hotKey.shouldTrigger = { allowed }
        hotKey.onPressed = { calls += 1 }
        #expect(hotKey.register(.init()))
        hotKey.handleEvent(id: hotKey.identifier, kind: UInt32(kEventHotKeyPressed))
        #expect(harness.actions.isEmpty)
        allowed = true
        hotKey.handleEvent(id: hotKey.identifier, kind: UInt32(kEventHotKeyPressed))
        #expect(harness.actions.isEmpty) // Must release after a veto; repeat cannot bypass it.
        hotKey.handleEvent(id: hotKey.identifier, kind: UInt32(kEventHotKeyReleased))
        hotKey.handleEvent(id: hotKey.identifier, kind: UInt32(kEventHotKeyPressed))
        allowed = false
        harness.drain()
        #expect(calls == 0) // Recording began after Carbon dispatch but before main-queue callback.
        hotKey.handleEvent(id: hotKey.identifier, kind: UInt32(kEventHotKeyReleased))
        allowed = true
        hotKey.handleEvent(id: hotKey.identifier, kind: UInt32(kEventHotKeyPressed))
        harness.drain()
        #expect(calls == 1)
    }

    private final class Harness {
        var rejectRegistration = false
        var registrations = 0
        var unregistered: [UInt32] = []
        var actions: [() -> Void] = []
        var backend: GlobalHotKey.Backend {
            .init(register: { [self] _, identifier in
                self.registrations += 1
                guard !self.rejectRegistration else { return nil }
                return .init(unregister: { [self] in self.unregistered.append(identifier.id) })
            }, schedule: { [self] action in self.actions.append(action) }, installCarbonHandler: false)
        }
        func drain() {
            let pending = actions
            actions = []
            for action in pending { action() }
        }
    }
}
