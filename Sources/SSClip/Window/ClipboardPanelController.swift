import AppKit
import SwiftUI

final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private let panel: ClipboardPanel
    private unowned let model: AppModel
    private var keyEventMonitor: Any?
    private var outsideClickMonitor: Any?
    private var isHiding = false

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init(model: AppModel) {
        self.model = model
        panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 690, height: 470),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 面板按键全部走本地事件监听，不依赖 responder chain；
        // 不指定初始焦点，避免呼出时第一个可聚焦控件（搜索按钮）带上焦点环。
        panel.initialFirstResponder = nil
        panel.contentView = NSHostingView(
            rootView: ClipboardPanelView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.settings)
        )
    }

    func show() {
        positionOnActiveScreen()
        installEventMonitor()
        panel.makeKeyAndOrderFront(nil)
        clearInitialFocus()
    }

    /// SwiftUI 可能在窗口成为 key 后异步把焦点派给第一个可聚焦控件，
    /// 同步 + 下一个 runloop 各清一次；搜索激活时（⌘F 聚焦输入框）不干预。
    private func clearInitialFocus() {
        panel.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.model.isSearching else { return }
            self.panel.makeFirstResponder(nil)
        }
    }

    func hide() {
        guard !isHiding else { return }
        isHiding = true
        removeEventMonitor()
        panel.orderOut(nil)
        isHiding = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isHiding, panel.isVisible else { return }
        model.hidePanel()
    }

    private func positionOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let previewWidth: CGFloat = 520
        let previewGap: CGFloat = 12
        let horizontalMargin: CGFloat = 12
        let preferredGroupWidth = panel.frame.width + previewGap + previewWidth
        let availableGroupWidth = max(panel.frame.width, visible.width - horizontalMargin * 2)
        let groupWidth = min(preferredGroupWidth, availableGroupWidth)
        let origin = NSPoint(
            x: visible.midX - groupWidth / 2,
            y: visible.maxY - panel.frame.height - 72
        )
        panel.setFrameOrigin(origin)
    }

    private func installEventMonitor() {
        removeEventMonitor()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            return self.handle(event) ? nil : event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.panel.isVisible else { return }
                self.model.hidePanel()
            }
        }
    }

    private func removeEventMonitor() {
        if let keyEventMonitor { NSEvent.removeMonitor(keyEventMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        keyEventMonitor = nil
        outsideClickMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        // 输入法组字中（拼音候选等）：按键全部交给输入法，⎋ 取消组字、方向键选字。
        if isComposingWithInputMethod { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shortcuts = model.settings.panelShortcuts
        if shortcuts.search.matches(event) {
            model.activateSearch()
            return true
        }
        if event.keyCode == 53 {
            if model.isSearching || !model.searchQuery.isEmpty { model.closeSearch() } else { model.hidePanel() }
            return true
        }
        // 搜索时仍可用纯文本粘贴，但只放行不会往输入框打字的组合（⌘/⌃ 组合或 ↩ 这类控制键）。
        if shortcuts.pastePlainText.matches(event),
           !model.isSearching || Self.isSafeWhileTyping(event) {
            model.pasteSelectedAsPlainText()
            return true
        }
        // ⌘1…⌘9 / ⌘0：任何状态下粘贴当前页对应条目；搜索时裸数字要留给输入框。
        if modifiers.contains(.command), modifiers.isDisjoint(with: [.control, .option]),
           let value = event.charactersIgnoringModifiers,
           let digit = Int(value), value.count == 1 {
            model.pasteItem(at: digit == 0 ? 9 : digit - 1)
            return true
        }
        if model.isSearching {
            // 单行输入框用不到 ↑/↓：借给列表移动选中；↩ 由输入框 onSubmit 粘贴选中条目。
            switch event.keyCode {
            case 125 where modifiers.isDisjoint(with: [.command, .control, .option, .shift]):
                model.moveSelection(by: 1)
                return true
            case 126 where modifiers.isDisjoint(with: [.command, .control, .option, .shift]):
                model.moveSelection(by: -1)
                return true
            default:
                return false
            }
        }
        if shortcuts.toggleFavorite.matches(event) {
            model.toggleFavoriteForSelected()
            return true
        }
        if shortcuts.deleteItem.matches(event) {
            model.deleteSelected()
            return true
        }

        if event.keyCode == 48, modifiers.isDisjoint(with: [.command, .control, .option]) {
            model.togglePrimarySection()
            return true
        }

        if modifiers.contains(.command), event.keyCode == 123 {
            model.previousPage()
            return true
        }
        if modifiers.contains(.command), event.keyCode == 124 {
            model.nextPage()
            return true
        }

        if modifiers.isDisjoint(with: [.command, .control, .option]),
           let value = event.charactersIgnoringModifiers,
           let digit = Int(value), value.count == 1 {
            model.pasteItem(at: digit == 0 ? 9 : digit - 1)
            return true
        }
        switch event.keyCode {
        case 123: model.previousPage()
        case 124: model.nextPage()
        case 125: model.moveSelection(by: 1)
        case 126: model.moveSelection(by: -1)
        case 36 where modifiers.isEmpty: model.pasteSelected()
        case 49: model.showPreviewImmediately()
        default:
            return false
        }
        return true
    }

    static func isSafeWhileTyping(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !modifiers.isDisjoint(with: [.command, .control]) { return true }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return true }
        return CharacterSet.controlCharacters.contains(scalar)
            || (0xF700...0xF8FF).contains(scalar.value) // NSEvent 功能键专用区
    }

    /// 搜索框正通过输入法组字（拼音候选未上屏）时为 true。
    private var isComposingWithInputMethod: Bool {
        guard model.isSearching,
              let editor = panel.firstResponder as? NSTextView
        else { return false }
        return editor.hasMarkedText()
    }
}
