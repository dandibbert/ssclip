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
    private let filename = "SSClip发送.shortcut"
    typealias Signer = @MainActor (URL, URL) async throws -> ShortcutSigningResult
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    private let templateURL: () -> URL?
    private let signer: Signer
    private var operation: Task<Void, Never>?

    init(templateURL: @escaping () -> URL? = { Bundle.main.url(forResource: "SSClip-Send", withExtension: "unsigned.shortcut") },
         signer: Signer? = nil) {
        self.templateURL = templateURL
        self.signer = signer ?? { try await OfficialShortcutSigner.sign(input: $0, output: $1) }
    }

    /// Imports data only. Signing never executes the selected workflow.
    func chooseDownloadedTemplate() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择下载的 SSClip 快捷指令模板"
        panel.message = "请选择可信来源的 SSClip 模板（.ssclip-template），不是连接 JSON。"
        panel.allowedContentTypes = [UTType(filenameExtension: "ssclip-template") ?? .data, UTType(filenameExtension: "shortcut") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        chooseDestination(source: source)
    }

    static func validDownloadedTemplate(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024,
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = value as? [String: Any],
              let actions = root["WFWorkflowActions"] as? [[String: Any]],
              !actions.isEmpty, actions.count <= 2000,
              actions.allSatisfy({ ($0["WFWorkflowActionIdentifier"] as? String)?.hasPrefix("is.workflow.actions.") == true }) else { return false }
        return true
    }

    func chooseDestination(source: URL? = nil) {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "生成 iPhone 快捷指令"
        panel.message = "使用本机 Apple 工具签名，需要登录 iCloud。"
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [UTType(filenameExtension: "shortcut") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        beginExport(to: destination, source: source)
    }

    func beginExport(to destination: URL, source: URL? = nil) {
        guard !isBusy else { return }
        // Set busy before scheduling so repeated clicks cannot create two signers.
        isBusy = true
        operation = Task { [weak self] in await self?.performExport(to: destination, source: source) }
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

    private func performExport(to destination: URL, source: URL?) async {
        defer { isBusy = false; operation = nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SSClip-sign-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let access = source?.startAccessingSecurityScopedResource() ?? false
        defer { if access { source?.stopAccessingSecurityScopedResource() } }
        do {
            try Task.checkCancellation()
            if let bundled = templateURL(), bundled.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL {
                status = "请选择新的输出位置，不能覆盖应用内原始模板。"; return
            }
            let resource = source ?? templateURL()
            guard let input = resource, FileManager.default.fileExists(atPath: input.path) else {
                status = "应用内快捷指令模板缺失，请重新安装完整 SSClip 测试包。"; return
            }
            guard input.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
                status = "请选择新的输出位置，不能覆盖应用内原始模板。"; return
            }
            if source != nil {
                let values = try input.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 2 * 1024 * 1024 else {
                    status = "模板文件无效或超过 2 MiB，未签名。"; return
                }
            }
            let original: Data
            if source != nil {
                let handle = try FileHandle(forReadingFrom: input)
                defer { try? handle.close() }
                original = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
            } else {
                original = try Data(contentsOf: input)
            }
            if source != nil && !Self.validDownloadedTemplate(original) {
                status = "请选择下载的快捷指令模板，不是连接 JSON 或安装文件。"; return
            }
            guard !original.isEmpty, original.count <= 20 * 1024 * 1024 else {
                status = "应用内快捷指令模板无效，未生成文件。"; return
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let inputFolder = root.appendingPathComponent("Input", isDirectory: true)
            let outputFolder = root.appendingPathComponent("Output", isDirectory: true)
            try FileManager.default.createDirectory(at: inputFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let namedInput = inputFolder.appendingPathComponent(filename)
            try original.write(to: namedInput, options: .atomic)
            let staged = outputFolder.appendingPathComponent(filename)
            status = "正在用 Apple 官方工具签名，最长约 150 秒…"
            let result = try await signer(namedInput, staged)
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                if result.diagnostic.localizedCaseInsensitiveContains("signed into iCloud") || result.diagnostic.localizedCaseInsensitiveContains("sign in to iCloud") {
                    status = "请先在这台 Mac 登录 iCloud，再重试签名。"
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
            status = "已生成，AirDrop 到 iPhone 并替换“SSClip发送”。"
        } catch is CancellationError {
            status = "已取消生成，原文件未改变。"
        } catch ShortcutSigningFailure.timedOut {
            status = "官方签名超时，未保存安装文件。请检查这台 Mac 的 iCloud 登录与网络后重试。"
        } catch {
            status = "无法生成或保存快捷指令，原文件未被替换。请检查文件位置和系统快捷指令是否可用。"
        }
    }
}
