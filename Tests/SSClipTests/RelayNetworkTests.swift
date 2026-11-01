import AppKit
import Foundation
import Testing
@testable import SSClip

private let testDeviceID = "11111111-1111-4111-8111-111111111111"
private let testPeerID = "22222222-2222-4222-8222-222222222222"
private let testAPIKey = "synthetic_unit_test_api_key_1234567890"

private final class RelayHTTPScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var stopCount = 0
    private var requests: [URLRequest] = []
    var recordedRequests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
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
        let text: String
        if mode == "secretKey" { text = testAPIKey }
        else if mode == "secretConfig" {
            text = String(data: try! JSONSerialization.data(withJSONObject: ["format": "ssclip-connection", "version": 1, "server_url": "https://relay.example.test", "api_key": testAPIKey]), encoding: .utf8)!
        } else { text = "network test 中😀" }
        let payload: [String: Any] = ["server_time": now, "messages": [[
            "id": "network_message_123", "source": testPeerID, "target": testDeviceID,
            "text": text, "created_at": now - 100, "expires_at": now + 60_000
        ]]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
    func reply(_ request: URLRequest) -> (Int, Data)? {
        let path = request.url!.lastPathComponent
        lock.lock(); requests.append(request); counts[path, default: 0] += 1; let number = counts[path]!; lock.unlock()
        if mode == "unauthorized" { return (401, Data("{}".utf8)) }
        if path == "register" {
            if mode == "registerRetry" && number == 1 { return (500, Data("{}".utf8)) }
            return (200, try! JSONSerialization.data(withJSONObject: ["device": ["id": testDeviceID, "name": "Test Mac", "platform": "macos", "last_seen_at": 1]]))
        }
        if path == "devices" {
            let device: [String: Any] = ["id": testDeviceID, "name": "Test Mac", "platform": "macos", "last_seen_at": 1]
            let peer: [String: Any] = ["id": testPeerID, "name": "Other device", "platform": "ios", "last_seen_at": 1]
            return (200, try! JSONSerialization.data(withJSONObject: ["devices": [device, peer], "server_time": 1]))
        }
        if path == "send" { return (200, Data("{\"state\":\"pending\"}".utf8)) }
        if request.url?.host == "new-relay.example.test", path == "poll" {
            return (200, Data("{\"messages\":[],\"server_time\":1}".utf8))
        }
        if mode == "hold" { return nil }
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
    override class func canInit(with request: URLRequest) -> Bool { ["relay.example.test", "new-relay.example.test"].contains(request.url?.host ?? "") }
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
        try await eventually { !context.controller.enabled && context.scenario.count("register") == 1 }
        #expect(context.controller.status.contains("API Key"))
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(context.scenario.count("poll") == 0)
        #expect(context.scenario.count("register") == 1)
        #expect(!context.defaults.bool(forKey: "relay.v2.enabled"))
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

    @Test func validImportRegistersAndDiscoversWithoutEnablingOrWritingClipboard() async throws {
        let context = try makeContext(mode: "retry", configured: false)
        defer { context.cleanUp() }
        context.pasteboard.clearContents()
        context.pasteboard.setString("local untouched", forType: .string)
        let count = context.pasteboard.changeCount
        #expect(context.controller.importConfiguration(data: configurationData()))
        try await eventually { !context.controller.isRegistering && context.controller.devices.count == 2 }
        #expect(context.controller.isConfigured)
        #expect(!context.controller.enabled)
        #expect(context.controller.targetID == testPeerID)
        #expect(context.scenario.count("register") == 1)
        #expect(context.scenario.count("devices") == 1)
        #expect(context.scenario.count("poll") == 0)
        #expect(context.pasteboard.changeCount == count)
        #expect(context.store.items.isEmpty)
        #expect(context.defaults.string(forKey: "relay.v2.url") == "https://relay.example.test")
        #expect(context.scenario.recordedRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + testAPIKey && $0.value(forHTTPHeaderField: "OAI-Sites-Authorization") == nil })
        #expect(!String(describing: context.defaults.dictionaryRepresentation()).contains(testAPIKey))
    }

    @Test func invalidImportAndFailedKeychainSavePreserveOldConfiguration() async throws {
        let context = try makeContext(mode: "retry", writerSucceeds: false)
        defer { context.cleanUp() }
        let originalURL = context.controller.serviceURL
        let originalTarget = context.controller.targetID
        #expect(!context.controller.importConfiguration(data: Data("not json".utf8)))
        #expect(!context.controller.importConfiguration(data: configurationData(url: "http://new-relay.example.test")))
        #expect(!context.controller.importConfiguration(data: configurationData(url: "https://new-relay.example.test")))
        #expect(context.controller.serviceURL == originalURL)
        #expect(context.controller.targetID == originalTarget)
        #expect(context.controller.isConfigured)
        #expect(context.scenario.recordedRequests.isEmpty)
        #expect(context.controller.status.contains("钥匙串"))
    }

    @Test func repeatedSameOriginImportPreservesExplicitReceivingChoiceAndTarget() async throws {
        let context = try makeContext(mode: "retry")
        defer { context.cleanUp() }
        context.controller.setEnabled(true)
        try await eventually { context.scenario.count("poll") >= 1 }
        context.controller.selectTarget(testPeerID)
        #expect(context.controller.importConfiguration(data: configurationData()))
        try await eventually { !context.controller.isRegistering && context.scenario.count("register") >= 2 }
        #expect(context.controller.enabled)
        #expect(context.controller.targetID == testPeerID)
        #expect(context.defaults.bool(forKey: "relay.v2.enabled"))
    }

    @Test func newOriginDoesNotInheritReceivingOrAcknowledgeOldInbox() async throws {
        let context = try makeContext(mode: "retry")
        defer { context.cleanUp() }
        context.controller.setEnabled(true)
        try await eventually { context.controller.inbox.count == 1 }
        #expect(context.controller.importConfiguration(data: configurationData(url: "https://new-relay.example.test")))
        #expect(context.controller.targetID.isEmpty)
        try await eventually { !context.controller.isRegistering }
        #expect(!context.controller.enabled)
        #expect(context.controller.serviceURL == "https://new-relay.example.test")
        context.controller.setEnabled(true)
        try await eventually { context.scenario.recordedRequests.contains { $0.url?.host == "new-relay.example.test" && $0.url?.lastPathComponent == "poll" } }
        context.controller.setEnabled(false)
        #expect(!context.scenario.recordedRequests.contains { $0.url?.host == "new-relay.example.test" && $0.url?.lastPathComponent == "ack" })
        #expect(context.controller.inbox.count == 1)
    }

    @Test func manualSendWorksWithAutomaticReceivingOff() async throws {
        let context = try makeContext(mode: "retry")
        defer { context.cleanUp() }
        context.controller.refreshDevices()
        try await eventually { !context.controller.isRegistering && !context.controller.devices.isEmpty }
        context.pasteboard.clearContents()
        context.pasteboard.setString("manual upload", forType: .string)
        context.controller.sendCurrentClipboard()
        try await eventually { context.scenario.count("send") == 1 && !context.controller.isSending }
        #expect(!context.controller.enabled)
        #expect(context.scenario.count("poll") == 0)
        #expect(context.controller.status.contains("服务器已接收"))
    }

    @Test func deviceUUIDPersistsAcrossControllerRecreation() throws {
        let context = try makeContext(mode: "retry")
        defer { context.cleanUp() }
        let oldID = context.controller.deviceID
        context.defaults.removeObject(forKey: "relay.deviceUUID")
        let second = RelayController(model: context.model, defaults: context.defaults, directory: context.directory,
            session: context.session, pasteboard: context.pasteboard, credentialReader: { _ in testAPIKey }, automaticallyConnect: false)
        #expect(UUID(uuidString: second.deviceID) != nil)
        #expect(second.deviceID != oldID)
        let third = RelayController(model: context.model, defaults: context.defaults, directory: context.directory,
            session: context.session, pasteboard: context.pasteboard, credentialReader: { _ in testAPIKey }, automaticallyConnect: false)
        #expect(third.deviceID == second.deviceID)
        #expect(context.defaults.string(forKey: "relay.deviceUUID") == second.deviceID)
        #expect(!second.deviceName.isEmpty)
        #expect(context.scenario.recordedRequests.isEmpty)
    }

    @Test func legacyLoginConfigurationRequiresNewImportAndNeverConnects() throws {
        let context = try makeContext(mode: "retry", configured: false)
        defer { context.cleanUp() }
        context.defaults.set("https://legacy.example.test", forKey: "relay.url")
        context.defaults.set(true, forKey: "relay.enabled")
        let migrated = RelayController(model: context.model, defaults: context.defaults, directory: context.directory,
            session: context.session, pasteboard: context.pasteboard, credentialReader: { _ in testAPIKey })
        #expect(!migrated.isConfigured)
        #expect(!migrated.enabled)
        #expect(migrated.serviceURL.isEmpty)
        #expect(migrated.status.contains("旧测试连接"))
        #expect(context.scenario.recordedRequests.isEmpty)
    }

    @Test func registrationRetriesTemporaryFailureWithoutDiscardingReceivingPreference() async throws {
        let context = try makeContext(mode: "registerRetry")
        defer { context.cleanUp() }
        context.controller.setEnabled(true)
        try await eventually { context.scenario.count("register") >= 2 && context.scenario.count("poll") >= 1 }
        #expect(context.controller.enabled)
        #expect(context.defaults.bool(forKey: "relay.v2.enabled"))
        #expect(context.controller.devices.count == 2)
    }

    @Test(arguments: ["secretKey", "secretConfig"])
    func remoteConnectionSecretsAreRedactedBeforePersistenceAndACK(mode: String) async throws {
        let context = try makeContext(mode: mode)
        defer { context.cleanUp() }
        context.pasteboard.clearContents()
        context.pasteboard.setString("keep local", forType: .string)
        let before = context.pasteboard.changeCount
        context.controller.setEnabled(true)
        try await eventually { context.controller.inbox.count == 1 && context.controller.inbox.first?.pendingAck == false }
        context.controller.setEnabled(false)
        #expect(context.controller.inbox.first?.hidden == true)
        #expect(context.controller.inbox.first?.text == "")
        #expect(context.store.items.isEmpty)
        #expect(context.pasteboard.changeCount == before)
        let disk = try String(contentsOf: context.directory.appendingPathComponent("relay-inbox.json"), encoding: .utf8)
        #expect(!disk.contains(testAPIKey))
        #expect(!disk.contains("ssclip-connection"))
        #expect(context.scenario.count("ack") >= 1)
    }

    private func configurationData(url: String = "https://relay.example.test") -> Data {
        try! JSONSerialization.data(withJSONObject: ["format": "ssclip-connection", "version": 1, "server_url": url, "api_key": testAPIKey])
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition(), "Expected controller state within two seconds")
    }

    private func makeContext(mode: String, corruptJournal: Bool = false, configured: Bool = true, writerSucceeds: Bool = true) throws -> RelayNetworkContext {
        let suite = "SSClipRelayNetworkTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        if configured {
            defaults.set("https://relay.example.test", forKey: "relay.v2.url")
            defaults.set(1, forKey: "relay.connectionVersion")
        }
        defaults.set(testDeviceID, forKey: "relay.deviceUUID")
        defaults.set(testPeerID, forKey: "relay.v2.target")
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
                                         credentialReader: { _ in testAPIKey }, sleepNanoseconds: 10_000_000,
                                         credentialWriter: { _, _ in writerSucceeds }, automaticallyConnect: false)
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
