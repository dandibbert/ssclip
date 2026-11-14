import AppKit
import ApplicationServices
import Carbon
import Foundation

/// ANSI 键盘上 V 的键码；查不到当前布局时的退路。
private let ansiVKeyCode: CGKeyCode = 9

enum PasteResult: Sendable {
    case pasted
    case copiedOnly
    case failed
}

enum PasteMode: Sendable {
    case standard
    case plainText
}

@MainActor
final class PasteService {
    struct Environment {
        var requestAccessibility: @MainActor @Sendable () -> Bool
        var activate: @MainActor @Sendable (NSRunningApplication) -> Bool
        var frontmostProcessIdentifier: @MainActor @Sendable () -> pid_t?
        var schedulePaste: @MainActor @Sendable (
            @escaping @MainActor @Sendable () -> Void
        ) -> Void
        var postCommandV: @MainActor @Sendable (pid_t) -> Void

        static let live = Environment(
            requestAccessibility: { PasteService.requestAccessibility() },
            activate: { $0.activate(options: [.activateIgnoringOtherApps]) },
            frontmostProcessIdentifier: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            },
            schedulePaste: { action in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: action)
            },
            postCommandV: { PasteService.postCommandV(targetPID: $0) }
        )
    }

    /// 已经安排好的自动粘贴最后没有发出（目标应用退出或失去焦点）时调用；内容仍留在剪贴板上。
    var onAutomaticPasteSkipped: (() -> Void)?

    private let pasteboard: NSPasteboard
    private let environment: Environment

    init(pasteboard: NSPasteboard = .general, environment: Environment = .live) {
        self.pasteboard = pasteboard
        self.environment = environment
    }

    func paste(
        _ item: ClipboardItem,
        imagesDirectory: URL,
        targetApplication: NSRunningApplication?,
        mode: PasteMode = .standard
    ) -> PasteResult {
        guard write(item, imagesDirectory: imagesDirectory, mode: mode) else { return .failed }
        let sourceChangeCount = pasteboard.changeCount

        guard environment.requestAccessibility() else { return .copiedOnly }
        guard let targetApplication,
              !targetApplication.isTerminated,
              environment.activate(targetApplication)
        else { return .copiedOnly }
        let targetPID = targetApplication.processIdentifier
        environment.schedulePaste { [weak self, environment, pasteboard, targetApplication] in
            // 剪贴板已被别的内容覆盖（比如紧接着的另一次粘贴）：这一次作废，不需要提示。
            guard pasteboard.changeCount == sourceChangeCount else { return }
            guard !targetApplication.isTerminated,
                  environment.frontmostProcessIdentifier() == targetPID
            else {
                self?.onAutomaticPasteSkipped?()
                return
            }
            environment.postCommandV(targetPID)
        }
        return .pasted
    }

    /// 只把内容写上剪贴板，不发送 ⌘V。批量队列靠它维持“队首在剪贴板”的不变式。
    @discardableResult
    func write(_ item: ClipboardItem, imagesDirectory: URL, mode: PasteMode = .standard) -> Bool {
        let objects: [NSPasteboardWriting]
        switch item.kind {
        case .text:
            guard let value = Self.textPasteboardItem(for: item, mode: mode) else { return false }
            objects = [value]
        case .image:
            guard let imageURL = ClipboardItem.safeImageURL(
                filename: item.imageFilename,
                imagesDirectory: imagesDirectory
            ), let image = NSImage(contentsOf: imageURL)
            else { return false }
            objects = [image]
        case .files:
            guard !item.filePaths.isEmpty else { return false }
            objects = item.filePaths.map { NSURL(fileURLWithPath: $0) }
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(objects) else { return false }
        // 给自己的写入打上标记，ClipboardMonitor 读到后跳过，不会把它当成一次新的复制。
        pasteboard.addTypes([.ssclipOwnWrite], owner: nil)
        pasteboard.setString("1", forType: .ssclipOwnWrite)
        return true
    }

    /// `.standard` 写入纯文本 + 捕获时保留的 RTF/HTML；`.plainText` 只写入纯文本。
    static func textPasteboardItem(for item: ClipboardItem, mode: PasteMode) -> NSPasteboardItem? {
        guard let text = item.text else { return nil }
        let value = NSPasteboardItem()
        value.setString(text, forType: .string)
        if mode == .standard {
            if let rtfData = item.rtfData { value.setData(rtfData, forType: .rtf) }
            if let htmlData = item.htmlData { value.setData(htmlData, forType: .html) }
        }
        return value
    }

    nonisolated private static func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    nonisolated private static func postCommandV(targetPID: pid_t) {
        let keyCode = pasteKeyCode()
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(targetPID)
        keyUp.postToPid(targetPID)
    }

    /// 当前键盘布局里“按住 ⌘ 时产生 v”的那个键。Dvorak、Colemak 等布局下它不是键码 9，
    /// 写死 9 会让目标应用收到别的快捷键。
    nonisolated static func pasteKeyCode() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return ansiVKeyCode }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        return layoutData.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return ansiVKeyCode
            }
            // 先按“⌘ 按下”查（兼容“Dvorak – QWERTY ⌘”这类布局），再按无修饰键查。
            for modifierState in [commandState, 0] {
                for keyCode in UInt16(0)..<128 {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout,
                        keyCode,
                        UInt16(kUCKeyActionDown),
                        modifierState,
                        keyboardType,
                        OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState,
                        characters.count,
                        &length,
                        &characters
                    )
                    if status == noErr, length == 1, characters[0] == 0x76 {
                        return CGKeyCode(keyCode)
                    }
                }
            }
            return ansiVKeyCode
        }
    }
}
