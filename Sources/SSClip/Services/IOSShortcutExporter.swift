import AppKit
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers

struct ShortcutSigningResult: Sendable {
    let exitCode: Int32
    let diagnostic: String
}

enum ShortcutSigningFailure: Error { case timedOut }

/// Uses only Apple's installed CLI. No account credentials or API keys are supplied.
private final class OfficialShortcutSigner: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShortcutSigningResult, Error>?
    private var completed = false
    private var cancelled = false
    private var timedOut = false
    private var timeoutWork: DispatchWorkItem?
    private var diagnosticURL: URL?
    private var diagnosticHandle: FileHandle?

    static func sign(input: URL, output: URL) async throws -> ShortcutSigningResult {
        let runner = OfficialShortcutSigner()
        return try await withTaskCancellationHandler(operation: {
            try await runner.run(input: input, output: output)
        }, onCancel: { runner.stop(timedOut: false) })
    }

    private func run(input: URL, output: URL) async throws -> ShortcutSigningResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            if cancelled { lock.unlock(); finish(exitCode: -1); return }
            let log = output.deletingLastPathComponent().appendingPathComponent("signing-diagnostic.txt")
            diagnosticURL = log
            do {
                try Data().write(to: log)
                let handle = try FileHandle(forWritingTo: log)
                diagnosticHandle = handle
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = ["sign", "--mode", "anyone", "--input", input.path, "--output", output.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = handle
                process.terminationHandler = { [weak self] process in self?.finish(exitCode: process.terminationStatus) }
                try process.run()
                let timeout = DispatchWorkItem { [weak self] in self?.stop(timedOut: true) }
                timeoutWork = timeout
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 150, execute: timeout)
            } catch {
                lock.unlock()
                finish(exitCode: -1)
            }
        }
    }

    private func stop(timedOut: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        cancelled = true
        self.timedOut = self.timedOut || timedOut
        let running = process.isRunning
        if running { process.terminate() }
        lock.unlock()
        // Terminate only our own child if it ignores SIGTERM; never kill by process name.
        if running {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if !self.completed && self.process.isRunning { _ = Darwin.kill(self.process.processIdentifier, SIGKILL) }
                self.lock.unlock()
            }
        }
    }

    private func finish(exitCode: Int32) {
        lock.lock()
        guard !completed, let continuation else { lock.unlock(); return }
        completed = true
        self.continuation = nil
        timeoutWork?.cancel()
        try? diagnosticHandle?.close()
        diagnosticHandle = nil
        let wasCancelled = cancelled
        let wasTimedOut = timedOut
        let log = diagnosticURL
        lock.unlock()
        if wasTimedOut { continuation.resume(throwing: ShortcutSigningFailure.timedOut); return }
        if wasCancelled { continuation.resume(throwing: CancellationError()); return }
        var diagnostic = ""
        if let log, let handle = try? FileHandle(forReadingFrom: log) {
            let bytes = (try? handle.read(upToCount: 65_536)) ?? Data()
            diagnostic = String(data: bytes, encoding: .utf8) ?? ""
            try? handle.close()
        }
        continuation.resume(returning: ShortcutSigningResult(exitCode: exitCode, diagnostic: diagnostic))
    }
}

@MainActor
final class IOSShortcutExporter: ObservableObject {
    enum Template: Equatable {
        case send, settings
        var filename: String { self == .send ? "SSClip发送.shortcut" : "SSClip设置.shortcut" }
    }
    typealias Signer = @MainActor (URL, URL) async throws -> ShortcutSigningResult
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    private let templateURL: () -> URL?
    private let settingsTemplateURL: () -> URL?
    private let signer: Signer
    private var operation: Task<Void, Never>?

    init(templateURL: @escaping () -> URL? = { Bundle.main.url(forResource: "SSClip-Send", withExtension: "unsigned.shortcut") },
         settingsTemplateURL: @escaping () -> URL? = { Bundle.main.url(forResource: "SSClip-Settings", withExtension: "unsigned.shortcut") },
         signer: Signer? = nil) {
        self.templateURL = templateURL
        self.settingsTemplateURL = settingsTemplateURL
        self.signer = signer ?? { try await OfficialShortcutSigner.sign(input: $0, output: $1) }
    }

    func chooseDestination(template: Template = .send) {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = template == .send ? "生成 iPhone 快捷指令" : "生成 iPhone 设置入口"
        panel.message = "由这台 Mac 的系统快捷指令工具签名。请先登录 iCloud；生成的文件不包含你的 API Key。"
        panel.nameFieldStringValue = template.filename
        panel.allowedContentTypes = [UTType(filenameExtension: "shortcut") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        beginExport(to: destination, template: template)
    }

    func beginExport(to destination: URL, template: Template = .send) {
        guard !isBusy else { return }
        // Set busy before scheduling so repeated clicks cannot create two signers.
        isBusy = true
        operation = Task { [weak self] in await self?.performExport(to: destination, template: template) }
    }

    func cancel() {
        guard isBusy else { return }
        status = "正在取消…"
        operation?.cancel()
    }

    private static func isRawWorkflow(_ data: Data) -> Bool {
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = value as? [String: Any] else { return false }
        return dictionary["WFWorkflowActions"] != nil
    }

    private func performExport(to destination: URL, template: Template) async {
        defer { isBusy = false; operation = nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SSClip-sign-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try Task.checkCancellation()
            let resource = template == .send ? templateURL() : settingsTemplateURL()
            guard let input = resource, FileManager.default.fileExists(atPath: input.path) else {
                status = "应用内快捷指令模板缺失，请重新安装完整 SSClip 测试包。"; return
            }
            guard input.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
                status = "请选择新的输出位置，不能覆盖应用内原始模板。"; return
            }
            let original = try Data(contentsOf: input)
            guard !original.isEmpty, original.count <= 20 * 1024 * 1024 else {
                status = "应用内快捷指令模板无效，未生成文件。"; return
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let inputFolder = root.appendingPathComponent("Input", isDirectory: true)
            let outputFolder = root.appendingPathComponent("Output", isDirectory: true)
            try FileManager.default.createDirectory(at: inputFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let namedInput = inputFolder.appendingPathComponent(template.filename)
            try original.write(to: namedInput, options: .atomic)
            let staged = outputFolder.appendingPathComponent(template.filename)
            status = "正在用 Apple 官方工具签名，最长约 150 秒…"
            let result = try await signer(namedInput, staged)
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                if result.diagnostic.localizedCaseInsensitiveContains("signed into iCloud") || result.diagnostic.localizedCaseInsensitiveContains("sign in to iCloud") {
                    status = "尚未生成：请先在这台 Mac 登录 iCloud，再点“生成 iPhone 快捷指令”。不需要向 SSClip 提供 Apple 账号或密码。"
                } else {
                    status = "Apple 官方签名未成功，未保存安装文件。请确认已登录 iCloud 且网络可用后重试。"
                }
                return
            }
            let signed = try Data(contentsOf: staged)
            // Current official shared Shortcuts use the AEA1 envelope. This is a
            // format sanity check, not a replacement for Apple's signature validation.
            guard signed.starts(with: Data("AEA1".utf8)), signed.count > 4,
                  signed.count <= 20 * 1024 * 1024, signed != original, !Self.isRawWorkflow(signed) else {
                status = "签名工具没有生成有效的新文件，未保存安装文件。"; return
            }
            try Task.checkCancellation()
            // Atomic write keeps an existing destination intact on signing or write failure.
            try signed.write(to: destination, options: .atomic)
            status = template == .send
                ? "已生成签名快捷指令。请 AirDrop 到 iPhone 并打开安装；首次运行选择连接 JSON 和目标 Mac。请保留名称“SSClip发送”。"
                : "已生成签名设置入口。请 AirDrop 到 iPhone 并安装“SSClip设置”，用于重选目标或重新导入；需同时安装并保留名称“SSClip发送”。"
        } catch is CancellationError {
            status = "已取消生成，原文件未改变。"
        } catch ShortcutSigningFailure.timedOut {
            status = "官方签名超时，未保存安装文件。请检查这台 Mac 的 iCloud 登录与网络后重试。"
        } catch {
            status = "无法生成或保存快捷指令，原文件未被替换。请检查文件位置和系统快捷指令是否可用。"
        }
    }
}
