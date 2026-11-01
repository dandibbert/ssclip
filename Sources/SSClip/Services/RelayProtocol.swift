import Foundation

struct RelayMessage: Codable, Identifiable {
    let id: String
    let source: String
    let target: String
    let text: String
    let created_at: Double
    let expires_at: Double
}
struct RelayPoll: Decodable {
    let messages: [RelayMessage]
    let server_time: Double
}
struct RelayReceipt: Codable, Identifiable {
    let id: String
    var text: String
    let source: String
    let receivedAt: Date
    let scope: String
    var pendingAck: Bool
    var hidden = false
    var identity: String { scope + "|" + id }
}
enum RelayPolicy {
    static func validDeviceID(_ value: String) -> Bool {
        (8...96).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    static func validText(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 32768 }
    static func baseURL(_ value: String) -> URL? {
        guard let u = URL(string: value), u.scheme == "https", u.host != nil,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              u.path.isEmpty || u.path == "/" else { return nil }
        return u
    }
    static func valid(_ message: RelayMessage, target: String, serverTime: Double) -> Bool {
        let id = message.id
        return (8...96).contains(id.utf8.count)
            && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
            && validDeviceID(message.source) && validDeviceID(target) && message.source != target && message.target == target
            && validText(message.text) && message.created_at.isFinite && message.expires_at.isFinite
            && message.created_at <= serverTime && message.expires_at > serverTime
            && message.expires_at - message.created_at <= 1_200_000
    }
    static func mayAutoCopy(created: Double, serverTime: Double, continuous: Bool,
                            requestUnchanged: Bool, batch: Bool, latest: Bool) -> Bool {
        continuous && requestUnchanged && !batch && latest && serverTime - created >= 0 && serverTime - created <= 10_000
    }
}

// Never follow redirects with a credential, even on the same host.
final class RelayNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct RelayDevice: Codable, Identifiable {
    let id: String
    let name: String
    let platform: String
    let last_seen_at: Double
}
struct RelayDevicesResponse: Decodable { let devices: [RelayDevice]; let server_time: Double }
struct RelayConnectionConfiguration: Codable {
    let format: String
    let version: Int
    let server_url: String
    let api_key: String
    static func parse(_ data: Data) -> RelayConnectionConfiguration? {
        guard data.count <= 16_384,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.format == "ssclip-connection", value.version == 1,
              RelayPolicy.baseURL(value.server_url) != nil,
              (32...256).contains(value.api_key.utf8.count),
              value.api_key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
        else { return nil }
        return value
    }
}
