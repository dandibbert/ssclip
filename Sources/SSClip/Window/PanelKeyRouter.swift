import AppKit

enum PanelKeyCommand: Equatable {
    case activateSearch
    case closeSearch
    case hidePanel
    case pastePlainText
    case pasteAtIndex(Int)
    case moveSelection(Int)
    case toggleFavorite
    case deleteSelected
    case togglePrimarySection
    case previousPage
    case nextPage
    case pasteSelected
    case showPreview
}

enum PanelKeyRouter {
    private static let returnKeyCodes: Set<UInt16> = [36, 76]

    /// 只认 Command/Option/Control/Shift，忽略 Caps Lock / Fn / 数字区等无关 flag。
    /// 否则 Return 会被 modifiers.isEmpty 误判成有修饰键，选中条目没法粘贴。
    static func significantModifiers(in event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .option, .control, .shift])
    }

    static func command(
        for event: NSEvent,
        isSearching: Bool,
        searchQuery: String,
        isComposing: Bool,
        shortcuts: PanelShortcuts
    ) -> PanelKeyCommand? {
        // 输入法组字中：按键全部交给输入法。
        if isComposing { return nil }

        let modifiers = significantModifiers(in: event)
        if shortcuts.search.matches(event) {
            return .activateSearch
        }
        if event.keyCode == 53 {
            return (isSearching || !searchQuery.isEmpty) ? .closeSearch : .hidePanel
        }
        // 搜索时仍可用纯文本粘贴，但只放行不会往输入框打字的组合。
        if shortcuts.pastePlainText.matches(event),
           !isSearching || isSafeWhileTyping(event) {
            return .pastePlainText
        }
        // Command+digit：任何状态下粘贴当前页对应条目；搜索时裸数字留给输入框。
        if modifiers.contains(.command), modifiers.isDisjoint(with: [.control, .option]),
           let index = pasteIndex(from: event) {
            return .pasteAtIndex(index)
        }
        // Return / keypad Enter：任何状态下粘贴选中条目。
        // 搜索时不依赖输入框 onSubmit（面板重开后搜索框可能没焦点）；
        // Caps Lock / Fn 也不该挡住回车。
        if Self.returnKeyCodes.contains(event.keyCode),
           modifiers.isDisjoint(with: [.command, .control, .option, .shift]) {
            return .pasteSelected
        }
        if isSearching {
            switch event.keyCode {
            case 125 where modifiers.isDisjoint(with: [.command, .control, .option, .shift]):
                return .moveSelection(1)
            case 126 where modifiers.isDisjoint(with: [.command, .control, .option, .shift]):
                return .moveSelection(-1)
            default:
                return nil
            }
        }
        if shortcuts.toggleFavorite.matches(event) {
            return .toggleFavorite
        }
        if shortcuts.deleteItem.matches(event) {
            return .deleteSelected
        }

        if event.keyCode == 48, modifiers.isDisjoint(with: [.command, .control, .option]) {
            return .togglePrimarySection
        }

        if modifiers.contains(.command), event.keyCode == 123 {
            return .previousPage
        }
        if modifiers.contains(.command), event.keyCode == 124 {
            return .nextPage
        }

        if modifiers.isDisjoint(with: [.command, .control, .option]),
           let index = pasteIndex(from: event) {
            return .pasteAtIndex(index)
        }
        switch event.keyCode {
        case 123: return .previousPage
        case 124: return .nextPage
        case 125: return .moveSelection(1)
        case 126: return .moveSelection(-1)
        case 49: return .showPreview
        default:
            return nil
        }
    }

    static func isSafeWhileTyping(_ event: NSEvent) -> Bool {
        let modifiers = significantModifiers(in: event)
        if !modifiers.isDisjoint(with: [.command, .control]) { return true }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return true }
        return CharacterSet.controlCharacters.contains(scalar)
            || (0xF700...0xF8FF).contains(scalar.value)
    }

    private static func pasteIndex(from event: NSEvent) -> Int? {
        guard let value = event.charactersIgnoringModifiers,
              value.count == 1,
              let digit = Int(value)
        else { return nil }
        return digit == 0 ? 9 : digit - 1
    }
}
