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
        guard let command = PanelKeyRouter.command(
            for: event,
            isSearching: model.isSearching,
            searchQuery: model.searchQuery,
            isComposing: isComposingWithInputMethod,
            shortcuts: model.settings.panelShortcuts
        ) else { return false }

        switch command {
        case .activateSearch:
            model.activateSearch()
        case .closeSearch:
            model.closeSearch()
        case .hidePanel:
            model.hidePanel()
        case .pastePlainText:
            model.pasteSelectedAsPlainText()
        case let .pasteAtIndex(index):
            model.pasteItem(at: index)
        case let .moveSelection(offset):
            model.moveSelection(by: offset)
        case .toggleFavorite:
            model.toggleFavoriteForSelected()
        case .deleteSelected:
            model.deleteSelected()
        case .togglePrimarySection:
            model.togglePrimarySection()
        case .previousPage:
            model.previousPage()
        case .nextPage:
            model.nextPage()
        case .pasteSelected:
            model.pasteSelected()
        case .showPreview:
            model.showPreviewImmediately()
        }
        return true
    }

    /// 搜索框正通过输入法组字（拼音候选未上屏）时为 true。
    private var isComposingWithInputMethod: Bool {
        guard model.isSearching,
              let editor = panel.firstResponder as? NSTextView
        else { return false }
        return editor.hasMarkedText()
    }
}
