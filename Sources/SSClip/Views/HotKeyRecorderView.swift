import AppKit
import SwiftUI

struct HotKeyRecorderView: NSViewRepresentable {
    @Binding var configuration: HotKeyConfiguration
    var validate: ((HotKeyConfiguration) -> String?)?

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.onRecord = { value in
            configuration = value
        }
        button.validate = validate
        button.configuration = configuration
        return button
    }

    func updateNSView(_ button: HotKeyRecorderButton, context: Context) {
        button.onRecord = { value in
            configuration = value
        }
        button.validate = validate
        if !button.isRecording {
            button.configuration = configuration
        }
    }
}

final class HotKeyRecorderButton: NSButton {
    var onRecord: ((HotKeyConfiguration) -> Void)?
    /// 返回非 nil 表示该组合不可用，字符串会短暂显示为原因。
    var validate: ((HotKeyConfiguration) -> String?)?
    private(set) var isRecording = false
    private var rejectionResetTask: Task<Void, Never>?
    var configuration = HotKeyConfiguration() {
        didSet {
            if !isRecording { title = configuration.displayName }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        contentTintColor = .labelColor
        target = self
        action = #selector(toggleRecording)
        title = configuration.displayName
        toolTip = "点击后按下新的快捷键，再次点击或按 ⎋ 取消"
        setAccessibilityLabel("快捷键")
        setAccessibilityHelp("点击后直接按下新的组合键，再次点击取消录制")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func toggleRecording() {
        if isRecording {
            cancelRecording()
            window?.makeFirstResponder(nil)
        } else {
            isRecording = true
            title = "请按快捷键…"
            window?.makeFirstResponder(self)
        }
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        cancelRecording()
        return result
    }

    // 录制时实时显示按住的修饰键，与系统偏好设置里的录制体验一致。
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        let preview = Self.modifierPrefix(for: event.modifierFlags)
        title = preview.isEmpty ? "请按快捷键…" : preview
    }

    // ⌘F、⌘Q 这类组合会先走菜单键等价路径，不拦截的话录制不到。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        handleRecordingKeyDown(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handleRecordingKeyDown(event)
    }

    private func handleRecordingKeyDown(_ event: NSEvent) {
        rejectionResetTask?.cancel()
        if event.keyCode == 53 {
            cancelRecording()
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let configuration = HotKeyConfiguration(
            keyCode: UInt32(event.keyCode),
            keyDisplayName: Self.displayName(for: event),
            usesCommand: modifiers.contains(.command),
            usesOption: modifiers.contains(.option),
            usesControl: modifiers.contains(.control),
            usesShift: modifiers.contains(.shift)
        )
        guard configuration.isValid else {
            reject(reason: "请加修饰键")
            return
        }
        if let reason = validate?(configuration) {
            reject(reason: reason)
            return
        }

        self.configuration = configuration
        isRecording = false
        title = configuration.displayName
        onRecord?(configuration)
        window?.makeFirstResponder(nil)
    }

    private func reject(reason: String) {
        NSSound.beep()
        title = reason
        rejectionResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.title = "请按快捷键…"
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        rejectionResetTask?.cancel()
        isRecording = false
        title = configuration.displayName
    }

    private static func modifierPrefix(for flags: NSEvent.ModifierFlags) -> String {
        var value = ""
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        if flags.contains(.shift) { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        return value
    }

    private static func displayName(for event: NSEvent) -> String {
        let specialKeys: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            71: "Clear", 76: "⌤", 115: "Home", 116: "⇞", 117: "⌦",
            119: "End", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
            97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        if let name = specialKeys[event.keyCode] { return name }
        let characters = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard let characters, !characters.isEmpty else { return "Key \(event.keyCode)" }
        return String(characters.prefix(2))
    }
}
