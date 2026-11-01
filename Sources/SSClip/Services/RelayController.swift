import AppKit
import Combine
import Foundation

@MainActor
final class RelayController: ObservableObject {
    var onSendFeedback: ((String) -> Void)?
    private var lastSendStarted = Date.distantPast
    @Published private(set) var devices: [RelayDevice] = []
    @Published private(set) var deviceName: String
    @Published private(set) var isConfigured = false
    @Published private(set) var isRegistering = false
    @Published private(set) var enabled = false
    @Published private(set) var isBatchMode = false
    @Published private(set) var serviceURL: String
    @Published private(set) var deviceID: String
    @Published private(set) var targetID: String
    @Published private(set) var status = "同步未启用"
    @Published private(set) var credentialWarning: String?
    @Published private(set) var isSending = false
    @Published private(set) var inbox: [RelayReceipt] = []
    var hasCredential: Bool { credentialReader(serviceURL) != nil }
    private weak var model: AppModel?
    private let defaults: UserDefaults
    private let journalURL: URL
    private let pasteboard: NSPasteboard
    private let session: URLSession
    private let sendSession: URLSession
    private let credentialReader: (String) -> String?
    private let credentialWriter: (String, String) -> Bool
    private let sleepNanoseconds: UInt64
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var generation = UUID()
    private var connectionID = UUID()
    private var registrationFailures = 0
    private var batchObservation: AnyCancellable?
    private var journalHealthy = true
    private var scope: String { serviceURL + "|" + deviceID }
    var currentInbox: [RelayReceipt] { inbox.filter { $0.scope == scope && !$0.hidden } }

    init(model: AppModel, defaults: UserDefaults = .standard, directory: URL? = nil,
         session: URLSession? = nil, pasteboard: NSPasteboard = .general, credentialReader: @escaping (String) -> String? = RelayCredential.read,
         sleepNanoseconds: UInt64 = 3_000_000_000,
         credentialWriter: @escaping (String, String) -> Bool = { RelayCredential.save($0, host: $1) },
         automaticallyConnect: Bool = true) {
        self.model = model
        self.pasteboard = pasteboard
        self.credentialWriter = credentialWriter
        self.credentialReader = credentialReader
        self.sleepNanoseconds = sleepNanoseconds
        self.defaults = defaults
        serviceURL = defaults.string(forKey: "relay.v2.url") ?? ""
        let savedID = defaults.string(forKey: "relay.deviceUUID") ?? ""
        let initialID = UUID(uuidString: savedID) != nil ? savedID : UUID().uuidString.lowercased()
        deviceID = initialID
        defaults.set(initialID, forKey: "relay.deviceUUID")
        var initialName = defaults.string(forKey: "relay.deviceName") ?? Host.current().localizedName ?? "我的 Mac"
        initialName = String(String.UnicodeScalarView(initialName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
        while initialName.utf16.count > 80 { initialName.removeLast() }
        deviceName = initialName.isEmpty ? "我的 Mac" : initialName
        targetID = defaults.string(forKey: "relay.v2.target") ?? ""
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SSClip")
        journalURL = root.appendingPathComponent("relay-inbox.json")
        self.session = session ?? URLSession(configuration: Self.networkConfiguration(forSending: false), delegate: RelayNoRedirect(), delegateQueue: nil)
        self.sendSession = session ?? URLSession(configuration: Self.networkConfiguration(forSending: true), delegate: RelayNoRedirect(), delegateQueue: nil)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: journalURL.path) {
                inbox = try JSONDecoder().decode([RelayReceipt].self, from: Data(contentsOf: journalURL))
            }
        } catch {
            journalHealthy = false
            status = "同步收件箱无法读取；为防止重复覆盖，已停止同步"
        }
        if let saved = credentialReader(serviceURL) {
            RelayCredential.remember(saved)
            if !model.removeRelayCredentialsFromHistory() { credentialWarning = "凭据的本地历史清理未能写入磁盘，请检查存储错误；旧历史文件可能仍含凭据。" }
        }
        batchObservation = model.$isBatchMode.sink { [weak self] value in self?.isBatchMode = value }
        isConfigured = defaults.integer(forKey: "relay.connectionVersion") == 1 && RelayPolicy.baseURL(serviceURL) != nil && hasCredential
        if !isConfigured {
            status = defaults.string(forKey: "relay.url") == nil ? "导入连接配置，即可开始" : "旧测试连接已停用，请从管理端导入新的 API Key 连接配置"
        } else if automaticallyConnect {
            if defaults.bool(forKey: "relay.v2.enabled") { setEnabled(true) } else { refreshDevices() }
        }
    }

    /// Validate and save the complete origin+key pair before changing the live connection.
    /// A cancelled picker or invalid import never touches the previous configuration.
    @discardableResult
    func importConfiguration(data: Data) -> Bool {
        guard let configuration = RelayConnectionConfiguration.parse(data) else {
            status = "配置未导入：格式、版本或 HTTPS 地址无效，原连接未改变"; return false
        }
        let url = configuration.server_url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard credentialWriter(configuration.api_key, url) else {
            status = "配置未导入：钥匙串保存失败，原连接未改变"; return false
        }
        let sameOrigin = url == serviceURL
        let resumeReceiving = sameOrigin && enabled
        setEnabled(false)
        RelayCredential.remember(configuration.api_key)
        if let text = String(data: data, encoding: .utf8) { RelayCredential.remember(text) }
        if model?.removeRelayCredentialsFromHistory() == false {
            credentialWarning = "连接已保存，但历史清理写入失败；旧历史文件可能仍含连接秘密，请检查存储错误。"
        }
        serviceURL = url
        defaults.set(url, forKey: "relay.v2.url")
        defaults.set(1, forKey: "relay.connectionVersion")
        devices = []
        if !sameOrigin { targetID = ""; defaults.removeObject(forKey: "relay.v2.target") }
        isConfigured = true
        status = "连接已导入，正在注册本机；自动接收尚未开启"
        if resumeReceiving { setEnabled(true) } else { refreshDevices() }
        return true
    }

    func renameDevice(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            status = "设备名称需为 1–80 个字符"; return
        }
        deviceName = name; defaults.set(name, forKey: "relay.deviceName")
        if isConfigured { refreshDevices() }
    }

    func selectTarget(_ id: String) {
        if id.isEmpty {
            targetID = ""; defaults.removeObject(forKey: "relay.v2.target"); return
        }
        guard id != deviceID, devices.contains(where: { $0.id == id && $0.canReceive }) else { return }
        targetID = id; defaults.set(id, forKey: "relay.v2.target")
    }

    func refreshDevices() { connect(startReceiving: enabled && receiveTask == nil) }

    private func connect(startReceiving: Bool) {
        guard isConfigured, hasCredential else { status = "请先导入管理端导出的连接配置"; return }
        registrationTask?.cancel()
        connectionID = UUID()
        let connection = connectionID
        let current = generation
        isRegistering = true
        registrationTask = Task { [weak self] in
            guard let self else { return }
            defer { if current == self.generation && connection == self.connectionID { self.isRegistering = false } }
            do {
                _ = try await self.request("register", body: ["id": self.deviceID, "name": self.deviceName, "platform": "macos"])
                let list = try JSONDecoder().decode(RelayDevicesResponse.self, from: await self.request("devices"))
                guard current == self.generation, !Task.isCancelled else { return }
                guard list.devices.count <= 128, Set(list.devices.map(\.id)).count == list.devices.count,
                      list.devices.contains(where: { $0.id == self.deviceID }),
                      list.devices.allSatisfy({ RelayPolicy.validDeviceID($0.id) && !$0.name.isEmpty && $0.name.utf16.count <= 80 && $0.last_seen_at.isFinite && ["macos", "ios", "web"].contains($0.platform) }) else { throw Failure.invalid }
                self.registrationFailures = 0
                self.devices = list.devices.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
                let hadDefaultTarget = !self.targetID.isEmpty
                if !self.devices.contains(where: { $0.id == self.targetID && $0.id != self.deviceID && $0.canReceive }) {
                    self.targetID = ""
                    self.defaults.set(self.targetID, forKey: "relay.v2.target")
                }
                self.status = self.targetID.isEmpty
                    ? (hadDefaultTarget ? "原默认设备已不可用，未自动换目标；请重新选择，或临时选择设备发送" : "本机已连接；可临时选设备发送，或设置快捷键的默认目标")
                    : (self.enabled ? "已连接，等待新消息" : "已连接，可手动发送；自动接收未开启")
                if startReceiving && self.enabled {
                    self.receiveTask = Task { [weak self] in await self?.pollLoop(current) }
                }
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                if case Failure.http(let code) = error, code == 401 || code == 403 {
                    self.setEnabled(false); self.status = "API Key 无效或已撤销；请重新导入连接配置"
                } else {
                    if case Failure.invalid = error {
                        self.setEnabled(false); self.status = "服务端响应不兼容，连接配置已保留；请检查服务端"; return
                    }
                    if case Failure.http(let code) = error, (400...499).contains(code), code != 429 {
                        self.setEnabled(false); self.status = "服务端拒绝注册，请检查连接配置与设备数量"; return
                    }
                    self.registrationFailures = min(5, self.registrationFailures + 1)
                    self.status = "暂时无法连接，正在自动重试；已保留自动接收选择"
                    try? await Task.sleep(nanoseconds: min(60_000_000_000, self.sleepNanoseconds * UInt64(1 << self.registrationFailures)))
                    guard current == self.generation, connection == self.connectionID, !Task.isCancelled else { return }
                    self.connect(startReceiving: startReceiving)
                }
            }
        }
    }

    func setEnabled(_ value: Bool) {
        generation = UUID()
        receiveTask?.cancel(); receiveTask = nil
        registrationTask?.cancel(); registrationTask = nil; isRegistering = false
        sendTask?.cancel(); sendTask = nil; isSending = false
        enabled = false
        defaults.set(false, forKey: "relay.v2.enabled")
        guard value else { status = "自动接收已关闭；仍可手动发送"; return }
        guard journalHealthy, isConfigured, RelayPolicy.validDeviceID(deviceID), hasCredential else {
            status = journalHealthy ? "请先导入有效连接配置" : "收件箱无法读取；为防止重复覆盖，自动接收已停止"; return
        }
        defaults.set(true, forKey: "relay.v2.enabled")
        enabled = true; status = "正在连接（启动时旧消息只进收件箱）"
        connect(startReceiving: true)
    }

    static func networkConfiguration(forSending: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // Bark may spend up to 8s checking DNS and 8s on push delivery.
        configuration.timeoutIntervalForRequest = forSending ? 30 : 12
        configuration.timeoutIntervalForResource = forSending ? 35 : 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    private enum Failure: Error { case http(Int), service(String), invalid, storage }
    private func request(_ endpoint: String, body: [String: Any]? = nil) async throws -> Data {
        guard let base = RelayPolicy.baseURL(serviceURL), let credential = credentialReader(serviceURL) else { throw Failure.invalid }
        var components = URLComponents(url: base.appendingPathComponent("api/service/" + endpoint), resolvingAgainstBaseURL: false)!
        if body == nil && (endpoint == "poll" || endpoint == "status") { components.queryItems = [URLQueryItem(name: "target", value: deviceID)] }
        var req = URLRequest(url: components.url!)
        req.timeoutInterval = endpoint == "send" ? 30 : 12
        req.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let transport = endpoint == "send" ? sendSession : session
        let (data, response) = try await transport.data(for: req)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.invalid }
        guard (200...299).contains(http.statusCode) else {
            if endpoint == "send", [409, 413, 502, 503].contains(http.statusCode), data.count <= 4096,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = object["error"] as? String, RelayServiceError.message(for: code) != nil {
                throw Failure.service(code)
            }
            throw Failure.http(http.statusCode)
        }
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
        var lastObservedChange = pasteboard.changeCount
        var lastObservedChangeAt = Date.distantPast
        while enabled && current == generation && !Task.isCancelled {
            let started = Date()
            let changeCount = pasteboard.changeCount
            if changeCount != lastObservedChange {
                lastObservedChange = changeCount
                lastObservedChangeAt = started
            }
            do {
                // Retry receipts without ever applying their clipboard side effect again.
                for receipt in inbox where receipt.scope == scope && receipt.pendingAck {
                    do { _ = try await request("ack", body: ["id": receipt.id, "target": deviceID]) }
                    catch Failure.http(let code) where code == 404 || code == 410 { /* terminal */ }
                    guard current == generation, !Task.isCancelled else { return }
                    if let index = inbox.firstIndex(where: { $0.id == receipt.id && $0.scope == receipt.scope }) {
                        inbox[index].pendingAck = false
                        do { try persist() } catch { throw Failure.storage }
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
                    let sensitive = RelayCredential.isCredential(message.text)
                    let receipt = RelayReceipt(id: message.id, text: sensitive ? "" : message.text, source: message.source,
                                               receivedAt: Date(), scope: scope, pendingAck: true, hidden: sensitive)
                    inbox.insert(receipt, at: 0)
                    do { try persist() } catch { inbox.removeAll { $0.id == receipt.id && $0.scope == receipt.scope }; throw Failure.storage }
                    // Persist BEFORE clipboard side effect. A crash/retry must not overwrite again.
                    if sensitive {
                        status = "已拦截连接密钥或配置消息，未保存正文或复制"; received += 1; continue
                    }
                    let localQuietFor = min(Date().timeIntervalSince(model?.lastClipboardActivity ?? Date()), Date().timeIntervalSince(lastObservedChangeAt))
                    let messageAge = (response.server_time - message.created_at) / 1000
                    let canCopy = localQuietFor > max(3, messageAge + 1) && RelayPolicy.mayAutoCopy(created: message.created_at, serverTime: response.server_time,
                        continuous: continuous && Date().timeIntervalSince(started) < 10,
                        requestUnchanged: pasteboard.changeCount == changeCount,
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
            try? await Task.sleep(nanoseconds: failures == 0 ? sleepNanoseconds : min(60_000_000_000, sleepNanoseconds * UInt64(1 << failures)))
        }
    }

    private func sendFeedback(_ message: String) { status = message; onSendFeedback?(message) }

    func sendCurrentClipboard(to temporaryTargetID: String? = nil) {
        let sendingTargetID = temporaryTargetID ?? targetID
        guard isConfigured else { sendFeedback("未发送：请先导入连接配置"); return }
        guard !isRegistering else { sendFeedback("未发送：正在连接并刷新设备，请稍候"); return }
        guard !isSending else { sendFeedback("正在发送上一条，请勿重复触发"); return }
        guard deviceID != sendingTargetID, let destination = devices.first(where: { $0.id == sendingTargetID && $0.canReceive }) else {
            sendFeedback(temporaryTargetID == nil ? "未发送：请在跨设备同步中选择默认发送目标" : "未发送：所选设备已不可用，请刷新设备后重选"); return
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            sendFeedback("未发送：剪贴板中没有纯文本"); return
        }
        guard RelayPolicy.validText(text) else { sendFeedback("未发送：纯文本超过 32 KiB"); return }
        guard !RelayCredential.isCredential(text) else {
            sendFeedback("已阻止发送连接密钥或配置，请复制普通文本后再试"); return
        }
        guard Date().timeIntervalSince(lastSendStarted) >= 1 else {
            sendFeedback("已忽略过快的重复发送，请稍候再按"); return
        }
        let current = generation
        let destinationName = destination.name
        let body: [String: Any] = ["id": UUID().uuidString, "source": deviceID, "target": sendingTargetID, "text": text, "ttl_seconds": 1200]
        lastSendStarted = Date()
        isSending = true
        sendFeedback("正在发送到 \(destinationName)…")
        sendTask = Task { [weak self] in
            guard let self, current == self.generation, !Task.isCancelled else { return }
            defer { if current == self.generation { self.isSending = false } }
            do {
                let response = try await self.request("send", body: body)
                guard current == self.generation, !Task.isCancelled else { return }
                let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
                if object?["delivery"] as? String == "submitted" {
                    self.sendFeedback("Bark 已接受推送 → \(destinationName)；不代表手机已收到或复制")
                } else { self.sendFeedback("服务器已接收 → \(destinationName)；不代表对方已复制") }
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                if case Failure.service(let code) = error, let message = RelayServiceError.message(for: code) {
                    self.sendFeedback(message); return
                }
                if case Failure.http(let code) = error, code == 401 || code == 403 {
                    self.setEnabled(false); self.sendFeedback("未确认发送：API Key 无效，请重新导入连接配置")
                } else { self.sendFeedback("发送结果未确认；可能已到达，请先检查 \(destinationName) 再重发") }
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
