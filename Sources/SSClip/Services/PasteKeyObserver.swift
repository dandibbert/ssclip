import AppKit
import Foundation

/// 批量模式下监听系统级 ⌘V，用于在每次粘贴后推进队列。
/// 与直接粘贴共用同一份“辅助功能”授权；未授权时监听不到按键。
@MainActor
final class PasteKeyObserver {
    var onPaste: (() -> Void)?

    private var monitor: Any?
    private var ignoreCount = 0

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v"
            else { return }
            DispatchQueue.main.async { self?.handlePasteEvent() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        ignoreCount = 0
    }

    /// SSClip 自己合成的 ⌘V（面板内单条粘贴）不应推进队列。
    func ignoreNextPaste() {
        ignoreCount += 1
    }

    func handlePasteEvent() {
        if ignoreCount > 0 {
            ignoreCount -= 1
            return
        }
        onPaste?()
    }
}
