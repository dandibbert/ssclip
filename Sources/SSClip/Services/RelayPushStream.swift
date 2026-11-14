import Foundation

/// 服务端的推送通道：只传“有新消息”的信号，正文仍由 poll 取、ack 确认。
/// 测试里用假的实现替换。
@MainActor
protocol RelayPushChannel: AnyObject {
    /// 连接建立并收到服务端问候的时间；未连接时为 nil。
    var upSince: Date? { get }
    /// 连接建立、断开，或服务端通知有新消息时调用。
    var onSignal: (() -> Void)? { get set }
    func start()
    func stop()
}

/// 基于 WebSocket 的推送通道。服务端不支持时自己停下，由调用方继续按原来的方式轮询。
@MainActor
final class RelayPushStream: RelayPushChannel {
    private(set) var upSince: Date?
    var onSignal: (() -> Void)?

    private let request: URLRequest
    private let session: URLSession
    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var lastTraffic = Date.distantPast

    /// 这些状态码说明服务端没有这个接口或拒绝了凭据，重试没有意义。
    private static let permanentStatuses: Set<Int> = [400, 401, 403, 404, 405, 426, 501]
    private static let heartbeatNanoseconds: UInt64 = 20_000_000_000
    private static let silenceLimit: TimeInterval = 50

    init(request: URLRequest, session: URLSession) {
        self.request = request
        self.session = session
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // 心跳每 20 秒一次，空闲超时要比它长。
        configuration.timeoutIntervalForRequest = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        upSince = nil
    }

    private func run() async {
        var failures = 0
        var everConnected = false
        while !Task.isCancelled {
            let socket = session.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            var permanent = false
            do {
                let greeting = try await socket.receive()
                guard Self.kind(of: greeting) == "hello" else { throw URLError(.badServerResponse) }
                try Task.checkCancellation()
                failures = 0
                everConnected = true
                upSince = Date()
                onSignal?()
                try await listen(on: socket)
            } catch {
                if let response = socket.response as? HTTPURLResponse,
                   Self.permanentStatuses.contains(response.statusCode) {
                    permanent = true
                }
            }
            socket.cancel(with: .goingAway, reason: nil)
            if self.socket === socket { self.socket = nil }
            guard !Task.isCancelled else { return }
            if upSince != nil {
                upSince = nil
                onSignal?()
            }
            guard !permanent else { return }
            failures = min(failures + 1, 6)
            // 从没连上过（多半是不支持推送的旧服务端）：试三次后改为每 10 分钟再试。
            let seconds: UInt64 = !everConnected && failures >= 3 ? 600 : min(60, UInt64(1) << UInt64(failures))
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    }

    private func listen(on socket: URLSessionWebSocketTask) async throws {
        lastTraffic = Date()
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.heartbeatNanoseconds)
                guard !Task.isCancelled, let self else { return }
                // 对端长时间没有任何回应：连接已经死了，断开让外层重连。
                if Date().timeIntervalSince(self.lastTraffic) > Self.silenceLimit {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
                do {
                    try await socket.send(.string("ping"))
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer { heartbeat.cancel() }
        while true {
            let message = try await socket.receive()
            try Task.checkCancellation()
            lastTraffic = Date()
            if Self.kind(of: message) == "notify" { onSignal?() }
        }
    }

    /// 服务端发来的是 `{"type": "hello" | "notify"}` 或心跳应答 `pong`；其他内容一律忽略。
    static func kind(of message: URLSessionWebSocketTask.Message) -> String? {
        guard case .string(let text) = message else { return nil }
        if text == "pong" { return "pong" }
        guard text.utf8.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return object["type"] as? String
    }
}
