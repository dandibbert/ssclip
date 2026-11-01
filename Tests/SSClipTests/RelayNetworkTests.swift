import AppKit
import Foundation
import Testing
@testable import SSClip

private final class RelayHTTPScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var stopCount = 0
    private var held: RelayStubProtocol?
    let mode: String
    init(_ mode: String) { self.mode = mode }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path, default: 0] }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
    func stopped() { lock.lock(); stopCount += 1; held = nil; lock.unlock() }
    var hasHeld: Bool { lock.lock(); defer { lock.unlock() }; return held != nil }
    func hold(_ transport: RelayStubProtocol) { lock.lock(); held = transport; lock.unlock() }
    func releaseFresh() {
        lock.lock(); let transport = held; held = nil; lock.unlock()
        transport?.respond(status: 200, data: messageData())
    }
    private func messageData() -> Data {
        let now = Date().timeIntervalSince1970 * 1000
        let payload: [String: Any] = ["server_time": now, "messages": [[
            "id": "network_message_123", "source": "iphone-test", "target": "mac-mini-test",
            "text": "network test 中😀", "created_at": now - 100, "expires_at": now + 60_000
        ]]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
    func reply(_ request: URLRequest) -> (Int, Data)? {
        let path = request.url!.lastPathComponent
        lock.lock(); counts[path, default: 0] += 1; let number = counts[path]!; lock.unlock()
        if mode == "hold" { return nil }
        if mode == "unauthorized" { return (401, Data("{}".utf8)) }
        if path == "ack" {
            return (number == 1 ? 500 : 200, Data("{}".utf8))
        }
        if (mode == "fresh" || mode == "holdFresh") && path == "poll" && number == 1 {
            return (200, try! JSONSerialization.data(withJSONObject: ["server_time": Date().timeIntervalSince1970 * 1000, "messages": []]))
        }
        if mode == "holdFresh" && path == "poll" && number == 2 { return nil }
        return (200, messageData())
    }
}

private final class RelayStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedScenario: RelayHTTPScenario?
    static var scenario: RelayHTTPScenario? {
        get { lock.lock(); defer { lock.unlock() }; return storedScenario }
        set { lock.lock(); storedScenario = newValue; lock.unlock() }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "relay.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let scenario = Self.scenario else { return }
        guard let (status, data) = scenario.reply(request) else { scenario.hold(self); return }
        respond(status: status, data: data)
    }
    func respond(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.scenario?.stopped() }
}

@Suite(.serialized)
@MainActor
struct RelayNetworkTests {
    @Test func firstPollIsInboxOnlyAndFailedACKRetriesWithoutReapplyingReceipt() async throws {
        let context = try makeContext(mode: "retry")
        defer { context.cleanUp() }
        context.pasteboard.clearContents()
        context.pasteboard.setString("local text stays", forType: .string)
        let changeCount = context.pasteboard.changeCount
        context.controller.setEnabled(true)
        try await eventually { context.scenario.count("ack") >= 2 && context.scenario.count("poll") >= 2 && context.controller.inbox.first?.pendingAck == false }
        context.controller.setEnabled(false)
        #expect(context.controller.inbox.count == 1)
        #expect(context.controller.inbox.first?.text == "network test 中😀")
        #expect(context.pasteboard.changeCount == changeCount)
        #expect(context.pasteboard.string(forType: .string) == "local text stays")
        #expect(context.store.items.isEmpty)
        let saved = try JSONDecoder().decode([RelayReceipt].self, from: Data(contentsOf: context.directory.appendingPathComponent("relay-inbox.json")))
        #expect(saved.count == 1)
        #expect(saved.first?.pendingAck == false)
    }

    @Test func authenticationFailureDisablesAndDoesNotRetry() async throws {
        let context = try makeContext(mode: "unauthorized")
        defer { context.cleanUp() }
        context.controller.setEnabled(true)
        try await eventually { !context.controller.enabled && context.scenario.count("poll") == 1 }
        #expect(context.controller.status.contains("认证失败"))
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(context.scenario.count("poll") == 1)
        #expect(!context.defaults.bool(forKey: "relay.enabled"))
        #expect(context.controller.inbox.isEmpty)
    }

    @Test func disablingInFlightCancelsTransportAndNeverAppliesReceipt() async throws {
        let context = try makeContext(mode: "hold")
        defer { context.cleanUp() }
        context.pasteboard.clearContents()
        context.pasteboard.setString("unchanged", forType: .string)
        let changeCount = context.pasteboard.changeCount
        context.controller.setEnabled(true)
        try await eventually { context.scenario.count("poll") == 1 }
        context.controller.setEnabled(false)
        try await eventually { context.scenario.stops > 0 }
        #expect(!context.controller.enabled)
        #expect(context.controller.inbox.isEmpty)
        #expect(context.pasteboard.changeCount == changeCount)
        #expect(context.scenario.count("poll") == 1)
    }

    @Test func corruptJournalPreventsEnablingOrAnyNetworkRequest() async throws {
        let context = try makeContext(mode: "retry", corruptJournal: true)
        defer { context.cleanUp() }
        context.controller.setEnabled(true)
        #expect(!context.controller.enabled)
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(context.scenario.count("poll") == 0)
        #expect(context.scenario.count("ack") == 0)
        #expect(context.controller.inbox.isEmpty)
        #expect(try String(contentsOf: context.directory.appendingPathComponent("relay-inbox.json"), encoding: .utf8) == "corrupt-journal")
    }

    @Test func freshSecondPollCopiesOnceAfterQuietPeriod() async throws {
        let context = try makeContext(mode: "fresh")
        defer { context.cleanUp() }
        context.pasteboard.clearContents()
        context.pasteboard.setString("original", forType: .string)
        let before = context.pasteboard.changeCount
        try await Task.sleep(nanoseconds: 3_100_000_000)
        context.controller.setEnabled(true)
        try await eventually { context.controller.inbox.count == 1 && context.pasteboard.string(forType: .string) == "network test 中😀" }
        let copiedCount = context.pasteboard.changeCount
        #expect(copiedCount > before)
        #expect(context.store.items.count == 1)
        #expect(context.store.items.first?.text == "network test 中😀")
        try await eventually { context.scenario.count("poll") >= 3 }
        #expect(context.pasteboard.changeCount == copiedCount)
        #expect(context.controller.inbox.count == 1)
    }

    @Test func localClipboardChangeDuringFreshRequestVetoesAutoCopy() async throws {
        let context = try makeContext(mode: "holdFresh")
        defer { context.cleanUp() }
        context.pasteboard.clearContents()
        context.pasteboard.setString("original", forType: .string)
        try await Task.sleep(nanoseconds: 3_100_000_000)
        context.controller.setEnabled(true)
        try await eventually { context.scenario.hasHeld && context.scenario.count("poll") == 2 }
        context.pasteboard.clearContents()
        context.pasteboard.setString("new local text", forType: .string)
        let localChangeCount = context.pasteboard.changeCount
        context.scenario.releaseFresh()
        try await eventually { context.controller.inbox.count == 1 }
        context.controller.setEnabled(false)
        #expect(context.pasteboard.string(forType: .string) == "new local text")
        #expect(context.pasteboard.changeCount == localChangeCount)
        #expect(context.store.items.isEmpty)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition(), "Expected controller state within two seconds")
    }

    private func makeContext(mode: String, corruptJournal: Bool = false) throws -> RelayNetworkContext {
        let suite = "SSClipRelayNetworkTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("https://relay.example.test", forKey: "relay.url")
        defaults.set("mac-mini-test", forKey: "relay.device")
        defaults.set("macbook-test", forKey: "relay.target")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if corruptJournal { try Data("corrupt-journal".utf8).write(to: directory.appendingPathComponent("relay-inbox.json")) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        let store = ClipboardStore(baseDirectory: directory)
        let model = AppModel(settings: AppSettings(defaults: defaults), store: store, pasteService: PasteService(pasteboard: pasteboard))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayStubProtocol.self]
        let session = URLSession(configuration: configuration)
        let scenario = RelayHTTPScenario(mode)
        RelayStubProtocol.scenario = scenario
        let controller = RelayController(model: model, defaults: defaults, directory: directory, session: session, pasteboard: pasteboard,
                                         credentialReader: { _ in "synthetic-unit-test-credential-not-real" }, sleepNanoseconds: 10_000_000)
        return RelayNetworkContext(controller: controller, model: model, store: store, pasteboard: pasteboard,
                                   scenario: scenario, defaults: defaults, session: session, directory: directory, suite: suite)
    }
}

@MainActor
private struct RelayNetworkContext {
    let controller: RelayController
    let model: AppModel // retain: controller's reference is weak
    let store: ClipboardStore
    let pasteboard: NSPasteboard
    let scenario: RelayHTTPScenario
    let defaults: UserDefaults
    let session: URLSession
    let directory: URL
    let suite: String
    func cleanUp() {
        controller.setEnabled(false)
        session.invalidateAndCancel()
        RelayStubProtocol.scenario = nil
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
