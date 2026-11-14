import AppKit
import Foundation

/// 批量模式下监听系统级 ⌘V，用于在每次粘贴后推进队列。
/// 与直接粘贴共用同一份“辅助功能”授权；未授权时监听不到按键。
@MainActor
final class PasteKeyObserver {
    var onPaste: (() -> Void)?
    /// SSClip 自己的全局快捷键（默认 ⌘⌥V）不是粘贴，不能推进队列。
    var excludedHotKey: (() -> HotKeyConfiguration?)?

    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            let characters = event.charactersIgnoringModifiers
            let isRepeat = event.isARepeat
            DispatchQueue.main.async {
                self?.handleKeyDown(
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    characters: characters,
                    isRepeat: isRepeat
                )
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func handleKeyDown(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        characters: String?,
        isRepeat: Bool
    ) {
        guard Self.isPaste(modifierFlags: modifierFlags, characters: characters, isRepeat: isRepeat) else {
            return
        }
        if let hotKey = excludedHotKey?(),
           hotKey.matches(keyCode: keyCode, modifierFlags: modifierFlags) {
            return
        }
        onPaste?()
    }

    /// ⌘V，以及带 ⇧ / ⌥ 的“粘贴并匹配样式”变体算一次粘贴；
    /// 带 ⌃ 的组合和按住不放产生的重复按键不算。
    static func isPaste(
        modifierFlags: NSEvent.ModifierFlags,
        characters: String?,
        isRepeat: Bool
    ) -> Bool {
        guard !isRepeat else { return false }
        let flags = modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.command), !flags.contains(.control) else { return false }
        return characters?.lowercased() == "v"
    }
}
