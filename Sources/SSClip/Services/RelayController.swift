import AppKit
import Combine
import Foundation

@MainActor
final class RelayController: ObservableObject {
    static let devices: [(id: String, name: String)] = [("mac-mini-test", "Mac mini"), ("macbook-test", "MacBook"), ("iphone-test", "iPhone（网页接收）")]
    @Published private(set) var enabled = false
    @Published private(set) var serviceURL: String
    @Published private(set) var deviceID: String
    @Published private(set) var targetID: String
    @Published private(set) var status = "同步未启用"
    @Published private(set) var isSending = false
    @Published private(set) var inbox: [RelayReceipt] = []
    var hasCredential: Bool { RelayCredential.read(serviceURL) != nil }
    private weak var model: AppModel?
    private let defaults: UserDefaults
    private let journalURL: URL
    private let session: URLSession
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var generation = UUID()
    private var journalHealthy = true
    private var scope: String { serviceURL + "|" + deviceID }

    init(model: AppModel, defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.model = model
        self.defaults = defaults
        serviceURL = defaults.string(forKey: "relay.url") ?? "https://ssclip-relay-lab.sgah81.chatgpt.site"
        deviceID = defaults.string(forKey: "relay.device") ?? "mac-mini-test"
        targetID = defaults.string(forKey: "relay.target") ?? "macbook-test"
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SSClip")
        journalURL = root.appendingPathComponent("relay-inbox.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RelayNoRedirect(), delegateQueue: nil)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: journalURL.path) {
                inbox = try JSONDecoder().decode([RelayReceipt].self, from: Data(contentsOf: journalURL))
            }
        } catch {
            journalHealthy = false
            status = "同步收件箱无法读取；为防止重复覆盖，已停止同步"
        }
        if let saved = RelayCredential.read(serviceURL) {
            RelayCredential.remember(saved)
            model.removeRelayCredentialsFromHistory()
        }
        // First launch is opt-in; honor a previously saved user choice.
        if defaults.bool(forKey: "relay.enabled") { setEnabled(true) }
    }

    @discardableResult
    func configure(serviceURL: String, deviceID: String, targetID: String, token: String?) -> Bool {
        setEnabled(false)
        guard let url = RelayPolicy.baseURL(serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              RelayPolicy.devices.contains(deviceID), deviceID != "iphone-test",
              RelayPolicy.devices.contains(targetID), deviceID != targetID else {
            status = "请填写 HTTPS 网站根地址，并选择不同的本机和目标设备"; return false
        }
        let normalized = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let token, !token.isEmpty {
            guard !token.contains("\n"), !token.contains("\r"), RelayCredential.save(token, host: normalized) else {
                status = "凭证未保存：请检查输入与钥匙串权限"; return false
            }
        }
        if let token, !token.isEmpty {
            RelayCredential.remember(token)
            model?.removeRelayCredentialsFromHistory()
        }
        self.serviceURL = normalized; self.deviceID = deviceID; self.targetID = targetID
        defaults.set(normalized, forKey: "relay.url")
        defaults.set(deviceID, forKey: "relay.device")
        defaults.set(targetID, forKey: "relay.target")
        status = "设置已保存，请手动开启同步"; return true
    }

    func setEnabled(_ value: Bool) {
        generation = UUID()
        receiveTask?.cancel(); receiveTask = nil
        sendTask?.cancel(); sendTask = nil; isSending = false
        enabled = false
        defaults.set(false, forKey: "relay.enabled")
        guard value else { status = "同步未启用"; return }
        guard journalHealthy, RelayPolicy.baseURL(serviceURL) != nil,
              RelayPolicy.devices.contains(deviceID), deviceID != "iphone-test", hasCredential else {
            status = "请先保存有效地址、本机设备和服务凭证"; return
        }
        defaults.set(true, forKey: "relay.enabled")
        enabled = true; status = "正在连接（启动时旧消息只进收件箱）"
        let current = generation
        receiveTask = Task { [weak self] in await self?.pollLoop(current) }
    }

    private enum Failure: Error { case http(Int), invalid, storage }
    private func request(_ endpoint: String, body: [String: Any]? = nil) async throws -> Data {
        guard let base = RelayPolicy.baseURL(serviceURL), let credential = RelayCredential.read(serviceURL) else { throw Failure.invalid }
        var components = URLComponents(url: base.appendingPathComponent("api/service/" + endpoint), resolvingAgainstBaseURL: false)!
        if body == nil { components.queryItems = [URLQueryItem(name: "target", value: deviceID)] }
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer " + credential, forHTTPHeaderField: "OAI-Sites-Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.invalid }
        guard (200...299).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        guard data.count < 1_000_000 else { throw Failure.invalid }
        return data
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(inbox)
        try data.write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private func pollLoop(_ current: UUID) async {
        var lastSuccess: Date?
        var failures = 0
        while enabled && current == generation && !Task.isCancelled {
            let started = Date()
            let changeCount = NSPasteboard.general.changeCount
            do {
                // Retry receipts without ever applying their clipboard side effect again.
                for receipt in inbox where receipt.scope == scope && receipt.pendingAck {
                    do { _ = try await request("ack", body: ["id": receipt.id, "target": deviceID]) }
                    catch Failure.http(let code) where code == 404 || code == 410 { /* terminal */ }
                    guard current == generation, !Task.isCancelled else { return }
                    if let index = inbox.firstIndex(where: { $0.id == receipt.id && $0.scope == receipt.scope }) {
                        inbox[index].pendingAck = false
                        try persist()
                    }
                }
                let response = try JSONDecoder().decode(RelayPoll.self, from: await request("poll"))
                guard current == generation, !Task.isCancelled else { return }
                let continuous = lastSuccess.map { started.timeIntervalSince($0) < 10 } ?? false
                let valid = response.messages.filter { RelayPolicy.valid($0, target: deviceID, serverTime: response.server_time) }
                var received = 0
                for message in valid {
                    guard !inbox.contains(where: { $0.id == message.id && $0.scope == scope }) else { continue }
                    // Bounded durable inbox: preserve recent receipts for deduplication.
                    inbox.removeAll { !$0.pendingAck && Date().timeIntervalSince($0.receivedAt) > 86_400 }
                    guard inbox.count < 1000 else { throw Failure.storage }
                    let receipt = RelayReceipt(id: message.id, text: message.text, source: message.source,
                                               receivedAt: Date(), scope: scope, pendingAck: true)
                    inbox.insert(receipt, at: 0)
                    do { try persist() } catch { inbox.removeAll { $0.id == receipt.id && $0.scope == receipt.scope }; throw Failure.storage }
                    // Persist BEFORE clipboard side effect. A crash/retry must not overwrite again.
                    let localQuietFor = Date().timeIntervalSince(model?.lastClipboardActivity ?? Date())
                    let messageAge = (response.server_time - message.created_at) / 1000
                    let canCopy = localQuietFor > max(3, messageAge + 1) && RelayPolicy.mayAutoCopy(created: message.created_at, serverTime: response.server_time,
                        continuous: continuous && Date().timeIntervalSince(started) < 10,
                        requestUnchanged: NSPasteboard.general.changeCount == changeCount,
                        batch: model?.isBatchMode ?? true, latest: message.id == valid.last?.id)
                    let copied = canCopy && (model?.receiveRelayText(message.text) ?? false)
                    status = copied ? "已接收并复制；尚未粘贴" : "已收到，暂存同步收件箱（未覆盖剪贴板）"
                    received += 1
                }
                let recovered = failures > 0
                lastSuccess = Date(); failures = 0
                if received == 0 && (recovered || status.hasPrefix("正在连接")) { status = "已连接，等待新消息" }
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                lastSuccess = nil
                if case Failure.http(let code) = error, code == 401 || code == 403 {
                    setEnabled(false); status = "认证失败，已停止；更新凭证后手动开启"; return
                }
                if case Failure.storage = error {
                    setEnabled(false); status = "收件箱无法保存或已满；已停止同步，不确认接收"; return
                }
                failures = min(failures + 1, 5)
                status = "连接暂时失败，正在退避重试；恢复后的旧消息不会自动复制"
            }
            try? await Task.sleep(nanoseconds: UInt64(failures == 0 ? 3 : min(60, 3 * (1 << failures))) * 1_000_000_000)
        }
    }

    func sendCurrentClipboard() {
        guard enabled, !isSending, deviceID != targetID,
              let text = NSPasteboard.general.string(forType: .string), RelayPolicy.validText(text) else {
            status = "请先开启同步；仅支持非空纯文本，最多 32 KiB"; return
        }
        guard !RelayCredential.isCredential(text) else {
            status = "当前剪贴板是服务凭据，已阻止发送；请自行复制其他文本替换"; return
        }
        let current = generation
        let body: [String: Any] = ["id": UUID().uuidString, "source": deviceID, "target": targetID, "text": text, "ttl_seconds": 1200]
        isSending = true
        sendTask = Task { [weak self] in
            guard let self else { return }
            defer { if current == self.generation { self.isSending = false } }
            do {
                _ = try await self.request("send", body: body)
                guard current == self.generation, !Task.isCancelled else { return }
                self.status = "服务器已接收（20 分钟内有效），不代表对端已复制"
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                if case Failure.http(let code) = error, code == 401 || code == 403 {
                    self.setEnabled(false); self.status = "认证失败，已停止；更新凭证后手动开启"
                } else { self.status = "发送结果未确认；可能已到达，请先检查对端再重发" }
            }
        }
    }

    func copyReceipt(_ receipt: RelayReceipt) {
        guard model?.isBatchMode == false else { status = "批量模式中暂不复制；请先关闭批量模式"; return }
        status = model?.receiveRelayText(receipt.text) == true ? "已从收件箱复制；尚未粘贴" : "复制失败，原记录仍在收件箱"
    }
    func deleteReceipt(_ receipt: RelayReceipt) {
        guard let index = inbox.firstIndex(where: { $0.id == receipt.id && $0.scope == receipt.scope }) else { return }
        let old = inbox[index]
        inbox[index].text = ""
        inbox[index].hidden = true
        do { try persist(); status = "已移出收件箱；不会清除系统剪贴板或历史" }
        catch { inbox[index] = old; status = "删除未保存，请稍后重试" }
    }
}
