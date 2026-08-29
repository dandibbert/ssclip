import AppKit
import Testing
@testable import SSClip

@MainActor
struct PanelKeyRouterTests {
    private let shortcuts = PanelShortcuts()

    @Test func returnPastesSelectedItem() throws {
        let event = try keyEvent(keyCode: 36, characters: "\r")
        #expect(command(for: event) == .pasteSelected)
    }

    @Test func returnStillPastesWhenCapsLockOrFunctionFlagsAreSet() throws {
        let capsLock = try keyEvent(keyCode: 36, characters: "\r", flags: .capsLock)
        let function = try keyEvent(keyCode: 36, characters: "\r", flags: .function)
        let both = try keyEvent(keyCode: 36, characters: "\r", flags: [.capsLock, .function])

        #expect(command(for: capsLock) == .pasteSelected)
        #expect(command(for: function) == .pasteSelected)
        #expect(command(for: both) == .pasteSelected)
    }

    @Test func keypadEnterPastesSelectedItem() throws {
        let event = try keyEvent(keyCode: 76, characters: "\u{3}")
        #expect(command(for: event) == .pasteSelected)
    }

    @Test func returnPastesSelectedItemWhileSearching() throws {
        let event = try keyEvent(keyCode: 36, characters: "\r")
        #expect(
            command(for: event, isSearching: true) == .pasteSelected
        )
    }

    @Test func returnIsLeftToInputMethodWhileComposing() throws {
        let event = try keyEvent(keyCode: 36, characters: "\r")
        #expect(
            command(for: event, isSearching: true, isComposing: true) == nil
        )
    }

    @Test func shiftReturnPastesPlainText() throws {
        let event = try keyEvent(keyCode: 36, characters: "\r", flags: .shift)
        #expect(command(for: event) == .pastePlainText)
    }

    @Test func commandDigitPastesCorrespondingItem() throws {
        let one = try keyEvent(
            keyCode: 18,
            characters: "1",
            flags: .command
        )
        let zero = try keyEvent(
            keyCode: 29,
            characters: "0",
            flags: .command
        )
        #expect(command(for: one) == .pasteAtIndex(0))
        #expect(command(for: zero) == .pasteAtIndex(9))
    }

    @Test func commandDigitStillWorksWithCapsLock() throws {
        let event = try keyEvent(
            keyCode: 19,
            characters: "2",
            flags: [.command, .capsLock]
        )
        #expect(command(for: event) == .pasteAtIndex(1))
    }

    @Test func commandReturnDoesNotPasteSelected() throws {
        let event = try keyEvent(keyCode: 36, characters: "\r", flags: .command)
        #expect(command(for: event) != .pasteSelected)
        #expect(command(for: event) != .pastePlainText)
    }

    @Test func arrowsMoveSelectionEvenWithFunctionFlag() throws {
        let down = try keyEvent(keyCode: 125, characters: "\u{F701}", flags: .function)
        let up = try keyEvent(keyCode: 126, characters: "\u{F700}", flags: .function)
        #expect(command(for: down) == .moveSelection(1))
        #expect(command(for: up) == .moveSelection(-1))
    }

    private func command(
        for event: NSEvent,
        isSearching: Bool = false,
        isComposing: Bool = false
    ) -> PanelKeyCommand? {
        PanelKeyRouter.command(
            for: event,
            isSearching: isSearching,
            searchQuery: "",
            isComposing: isComposing,
            shortcuts: shortcuts
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
