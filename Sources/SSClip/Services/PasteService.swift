import AppKit
import ApplicationServices
import Foundation

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

    var beforePasteboardWrite: (() -> Void)?

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
        environment.schedulePaste { [environment, pasteboard, targetApplication] in
            guard pasteboard.changeCount == sourceChangeCount,
                  !targetApplication.isTerminated,
                  environment.frontmostProcessIdentifier() == targetPID
            else { return }
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
        beforePasteboardWrite?()
        pasteboard.clearContents()
        return pasteboard.writeObjects(objects)
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
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(targetPID)
        keyUp.postToPid(targetPID)
    }
}
