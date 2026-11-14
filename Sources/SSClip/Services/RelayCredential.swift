import Foundation
import Security
import CryptoKit

enum RelayCredential {
    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func remember(_ token: String) {
        var hashes = UserDefaults.standard.stringArray(forKey: "relay.credentialHashes") ?? []
        let hash = fingerprint(token)
        if !hashes.contains(hash) { hashes.append(hash); UserDefaults.standard.set(hashes, forKey: "relay.credentialHashes") }
    }
    static func isCredential(_ text: String) -> Bool {
        if let data = text.data(using: .utf8), RelayConnectionConfiguration.parse(data) != nil { return true }
        return (UserDefaults.standard.stringArray(forKey: "relay.credentialHashes") ?? []).contains(fingerprint(text))
    }
    private static func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "SSClip.RelayAPIKey.v1", kSecAttrAccount as String: host]
    }
    static func read(_ host: String) -> String? {
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, host: String) -> Bool {
        let q = query(host)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let result = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        var add = q.merging(attributes) { _, new in new }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
