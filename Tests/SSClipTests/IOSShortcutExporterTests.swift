import Foundation
import Testing
@testable import SSClip

@MainActor
struct IOSShortcutExporterTests {
    @Test func successfulOfficialExitPublishesOnlyNewOutputAndPreservesTemplate() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let exporter = IOSShortcutExporter(templateURL: { files.input }, signer: { input, output in
            #expect(input.lastPathComponent == "SSClip发送.shortcut")
            #expect(try Data(contentsOf: input) == files.original)
            try Data("AEA1synthetic-signed-output-for-unit-test".utf8).write(to: output)
            return ShortcutSigningResult(exitCode: 0, diagnostic: "")
        })
        exporter.beginExport(to: files.output)
        try await finished(exporter)
        #expect(try Data(contentsOf: files.output) == Data("AEA1synthetic-signed-output-for-unit-test".utf8))
        #expect(try Data(contentsOf: files.input) == files.original)
        #expect(exporter.status.contains("已生成签名快捷指令"))
        #expect(exporter.status.contains("每次发送选择接收设备"))
        #expect(!exporter.status.contains("默认"))
    }

    @Test func missingICloudDoesNotReplaceExistingDestinationOrExposeDiagnostics() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let exporter = IOSShortcutExporter(templateURL: { files.input }, signer: { _, output in
            try Data("partial".utf8).write(to: output)
            return ShortcutSigningResult(exitCode: 1, diagnostic: "In order to do this, you must be signed into iCloud. PRIVATE-DIAGNOSTIC")
        })
        exporter.beginExport(to: files.output)
        try await finished(exporter)
        #expect(try Data(contentsOf: files.output) == files.previous)
        #expect(exporter.status.contains("登录 iCloud"))
        #expect(!exporter.status.contains("PRIVATE-DIAGNOSTIC"))
        #expect(!exporter.status.contains("已生成"))
    }

    @Test func zeroExitWithoutSignedOutputCannotReportSuccess() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let exporter = IOSShortcutExporter(templateURL: { files.input }, signer: { input, output in
            try Data(contentsOf: input).write(to: output)
            return ShortcutSigningResult(exitCode: 0, diagnostic: "")
        })
        exporter.beginExport(to: files.output)
        try await finished(exporter)
        #expect(try Data(contentsOf: files.output) == files.previous)
        #expect(exporter.status.contains("未保存安装文件"))
    }

    @Test func cancellationPreservesDestinationAndRepeatedStartIsIgnored() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.root) }
        var calls = 0
        let exporter = IOSShortcutExporter(templateURL: { files.input }, signer: { _, _ in
            calls += 1
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return ShortcutSigningResult(exitCode: 0, diagnostic: "")
        })
        exporter.beginExport(to: files.output)
        exporter.beginExport(to: files.output)
        for _ in 0..<100 where calls == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        exporter.cancel()
        try await finished(exporter)
        #expect(calls == 1)
        #expect(try Data(contentsOf: files.output) == files.previous)
        #expect(exporter.status.contains("已取消"))
    }

    @Test func arbitraryNonemptyOutputCannotMasqueradeAsSignedEnvelope() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let exporter = IOSShortcutExporter(templateURL: { files.input }, signer: { _, output in
            try Data("not-an-apple-archive".utf8).write(to: output)
            return ShortcutSigningResult(exitCode: 0, diagnostic: "")
        })
        exporter.beginExport(to: files.output)
        try await finished(exporter)
        #expect(try Data(contentsOf: files.output) == files.previous)
        #expect(exporter.status.contains("未保存安装文件"))
    }

    @Test func rawWorkflowPlistCannotMasqueradeAsSignedOutput() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let exporter = IOSShortcutExporter(templateURL: { files.input }, signer: { _, output in
            let data = try PropertyListSerialization.data(fromPropertyList: ["WFWorkflowActions": []], format: .binary, options: 0)
            try data.write(to: output)
            return ShortcutSigningResult(exitCode: 0, diagnostic: "")
        })
        exporter.beginExport(to: files.output)
        try await finished(exporter)
        #expect(try Data(contentsOf: files.output) == files.previous)
        #expect(exporter.status.contains("未保存安装文件"))
    }

    @Test func cannotOverwriteOriginalTemplate() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.root) }
        var called = false
        let exporter = IOSShortcutExporter(templateURL: { files.input }, signer: { _, _ in
            called = true
            return ShortcutSigningResult(exitCode: 0, diagnostic: "")
        })
        exporter.beginExport(to: files.input)
        try await finished(exporter)
        #expect(!called)
        #expect(try Data(contentsOf: files.input) == files.original)
    }

    @Test func missingTemplateAndTimeoutFailClosed() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.root) }
        var calls = 0
        let missing = IOSShortcutExporter(templateURL: { nil }, signer: { _, _ in
            calls += 1
            return ShortcutSigningResult(exitCode: 0, diagnostic: "")
        })
        missing.beginExport(to: files.output)
        try await finished(missing)
        #expect(calls == 0)
        #expect(missing.status.contains("模板缺失"))
        let timeout = IOSShortcutExporter(templateURL: { files.input }, signer: { _, _ in throw ShortcutSigningFailure.timedOut })
        timeout.beginExport(to: files.output)
        try await finished(timeout)
        #expect(timeout.status.contains("超时"))
        #expect(try Data(contentsOf: files.output) == files.previous)
    }

    private func finished(_ exporter: IOSShortcutExporter) async throws {
        let deadline = Date().addingTimeInterval(2)
        while exporter.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!exporter.isBusy)
    }

    private func fixture() throws -> (root: URL, input: URL, output: URL, original: Data, previous: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SSClipExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("template.unsigned.shortcut")
        let output = root.appendingPathComponent("existing.shortcut")
        let original = Data("unsigned-template-fixture".utf8)
        let previous = Data("previous-user-file".utf8)
        try original.write(to: input)
        try previous.write(to: output)
        return (root, input, output, original, previous)
    }
}
