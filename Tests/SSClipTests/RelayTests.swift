import AppKit
import Foundation
import Testing
@testable import SSClip

struct RelayPolicyTests {
    @Test func textLimitUsesUTF8BytesAndPreservesWhitespace() {
        #expect(!RelayPolicy.validText(""))
        #expect(RelayPolicy.validText(" \n\t"))
        #expect(RelayPolicy.validText(String(repeating: "a", count: 32768)))
        #expect(!RelayPolicy.validText(String(repeating: "a", count: 32769)))
        #expect(RelayPolicy.validText(String(repeating: "😀", count: 8192)))
        #expect(!RelayPolicy.validText(String(repeating: "😀", count: 8193)))
        #expect(!RelayPolicy.validText(String(repeating: "中", count: 10923)))
    }

    @Test func serviceURLRequiresCredentialFreeHTTPSOrigin() {
        #expect(RelayPolicy.baseURL("https://example.com") != nil)
        #expect(RelayPolicy.baseURL("https://example.com/") != nil)
        for value in ["http://example.com", "ftp://example.com", "example.com",
                      "https://user:secret@example.com", "https://user@example.com",
                      "https://example.com/api", "https://example.com?token=secret",
                      "https://example.com#secret"] {
            #expect(RelayPolicy.baseURL(value) == nil)
        }
    }

    @Test func messageValidationRejectsWrongTargetsUnknownSourcesAndSelfEcho() {
        #expect(valid(message()))
        #expect(!valid(message(source: "unknown")))
        #expect(!valid(message(source: "mac-mini-test")))
        #expect(!valid(message(target: "macbook-test")))
        #expect(!valid(message(text: "")))
    }

    @Test func messageIDsHaveBoundedASCIIAlphabet() {
        #expect(valid(message(id: "abcd_123-XYZ")))
        #expect(valid(message(id: String(repeating: "a", count: 96))))
        for id in ["short", String(repeating: "a", count: 97), "bad.id.123", "中文中文中文", "abcdefgh\n"] {
            #expect(!valid(message(id: id)))
        }
    }

    @Test func expiredFutureAndOverlongTTLMessagesAreRejected() {
        #expect(!valid(message(expires: 1_000_000)))
        #expect(!valid(message(expires: 999_999)))
        #expect(!valid(message(created: 1_000_001)))
        #expect(!valid(message(created: 999_000, expires: 2_199_001)))
        #expect(valid(message(created: 999_000, expires: 2_199_000)))
        #expect(!valid(message(created: .nan)))
        #expect(!valid(message(expires: .infinity)))
    }

    @Test func onlyFreshLatestContinuouslyConnectedUnchangedNonBatchMessagesAutoCopy() {
        #expect(autoCopy())
        #expect(!autoCopy(continuous: false)) // startup, reconnect, wake
        #expect(!autoCopy(unchanged: false)) // user copied while request was in flight
        #expect(!autoCopy(batch: true))
        #expect(!autoCopy(latest: false)) // older entries in one poll go to inbox only
        #expect(autoCopy(created: 990_000))
        #expect(!autoCopy(created: 989_999))
        #expect(!autoCopy(created: 1_000_001))
        #expect(!autoCopy(created: .nan))
    }

    @Test func receiptRoundTripPreservesExactTextScopeAndPendingACK() throws {
        let receipt = RelayReceipt(id: "message_123", text: "中😀\n\"quote\"\\tab\t", source: "iphone-test",
                                   receivedAt: Date(timeIntervalSince1970: 123), scope: "https://example.com|mac-mini-test", pendingAck: true)
        let decoded = try JSONDecoder().decode(RelayReceipt.self, from: JSONEncoder().encode(receipt))
        #expect(decoded.id == receipt.id)
        #expect(decoded.text == receipt.text)
        #expect(decoded.scope == receipt.scope)
        #expect(decoded.pendingAck)
    }

    private func message(id: String = "message_123", source: String = "iphone-test", target: String = "mac-mini-test",
                         text: String = "hello", created: Double = 999_000, expires: Double = 1_010_000) -> RelayMessage {
        RelayMessage(id: id, source: source, target: target, text: text, created_at: created, expires_at: expires)
    }
    private func valid(_ message: RelayMessage) -> Bool {
        RelayPolicy.valid(message, target: "mac-mini-test", serverTime: 1_000_000)
    }
    private func autoCopy(created: Double = 999_000, continuous: Bool = true, unchanged: Bool = true,
                          batch: Bool = false, latest: Bool = true) -> Bool {
        RelayPolicy.mayAutoCopy(created: created, serverTime: 1_000_000, continuous: continuous,
                               requestUnchanged: unchanged, batch: batch, latest: latest)
    }
}

@MainActor
struct RelayAppModelTests {
    @Test func remoteReceiveCopiesExactPlainTextWithoutPastingOrAccessibility() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let text = "中😀\n\"quote\"\\tab\t"
        #expect(context.model.receiveRelayText(text))
        #expect(context.pasteboard.string(forType: .string) == text)
        #expect(context.pasteboard.data(forType: .rtf) == nil)
        #expect(context.pasteboard.data(forType: .html) == nil)
        #expect(context.store.items.first?.text == text)
        #expect(context.effects.calls == 0)
        #expect(context.model.batchItemIDs.isEmpty)
    }

    @Test func invalidRemoteReceiveNeverClearsCurrentClipboard() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        context.pasteboard.clearContents()
        context.pasteboard.setString("keep me", forType: .string)
        let changeCount = context.pasteboard.changeCount
        #expect(!context.model.receiveRelayText(""))
        #expect(!context.model.receiveRelayText(String(repeating: "😀", count: 8193)))
        #expect(context.pasteboard.changeCount == changeCount)
        #expect(context.pasteboard.string(forType: .string) == "keep me")
        #expect(context.store.items.isEmpty)
    }

    @Test func batchModeDefersRemoteEvenIfItDuplicatesQueueHead() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        context.model.toggleBatchMode()
        defer { context.model.toggleBatchMode() }
        context.model.handleCapture(capture("queue head"))
        context.model.handleCapture(capture("queue second"))
        let ids = context.model.batchItemIDs
        let historyIDs = context.store.items.map(\.id)
        let changeCount = context.pasteboard.changeCount
        #expect(!context.model.receiveRelayText("remote"))
        #expect(!context.model.receiveRelayText("queue head"))
        #expect(context.model.batchItemIDs == ids)
        #expect(context.store.items.map(\.id) == historyIDs)
        #expect(context.pasteboard.changeCount == changeCount)
        #expect(context.pasteboard.string(forType: .string) == "queue head")
        #expect(context.effects.calls == 0)
    }

    @Test func knownCredentialCaptureDoesNotJoinBatchAndRestoresQueueHead() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        let token = "synthetic-test-token-" + UUID().uuidString
        RelayCredential.remember(token)
        context.model.toggleBatchMode()
        defer { context.model.toggleBatchMode() }
        context.model.handleCapture(capture("queue head"))
        context.model.handleCapture(capture("queue second"))
        let ids = context.model.batchItemIDs
        let historyIDs = context.store.items.map(\.id)
        context.pasteboard.clearContents()
        context.pasteboard.setString(token, forType: .string)
        context.model.handleCapture(capture(token))
        #expect(context.model.batchItemIDs == ids)
        #expect(context.store.items.map(\.id) == historyIDs)
        #expect(!context.store.items.contains { $0.text == token })
        #expect(context.pasteboard.string(forType: .string) == "queue head")
        #expect(context.effects.calls == 0)
    }

    @Test func whitespaceOnlyRemoteTextCanBeRecoveredUnmodified() throws {
        let context = try makeContext()
        defer { context.cleanUp() }
        #expect(context.model.receiveRelayText(" \n\t"))
        #expect(context.pasteboard.string(forType: .string) == " \n\t")
        #expect(context.store.items.first?.text == " \n\t")
    }

    private func capture(_ text: String) -> CapturedClipboard {
        CapturedClipboard(kind: .text, title: text, text: text, imageData: nil, filePaths: [])
    }

    private func makeContext() throws -> RelayTestContext {
        let suite = "SSClipRelayTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        let effects = RelayPasteEffects()
        let environment = PasteService.Environment(
            requestAccessibility: { effects.calls += 1; return false },
            activate: { _ in effects.calls += 1; return false },
            frontmostProcessIdentifier: { effects.calls += 1; return nil },
            schedulePaste: { _ in effects.calls += 1 },
            postCommandV: { _ in effects.calls += 1 }
        )
        let store = ClipboardStore(baseDirectory: directory)
        let model = AppModel(settings: AppSettings(defaults: defaults), store: store,
                             pasteService: PasteService(pasteboard: pasteboard, environment: environment))
        model.queueAdvanceDelay = 0
        return RelayTestContext(model: model, store: store, pasteboard: pasteboard, effects: effects, suite: suite, directory: directory)
    }
}

@MainActor private final class RelayPasteEffects { var calls = 0 }
@MainActor private struct RelayTestContext {
    let model: AppModel
    let store: ClipboardStore
    let pasteboard: NSPasteboard
    let effects: RelayPasteEffects
    let suite: String
    let directory: URL
    func cleanUp() {
        pasteboard.releaseGlobally()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
