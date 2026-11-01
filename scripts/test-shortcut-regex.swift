import Foundation

// Exercise the ACTUAL bundled patterns with Apple's ICU-backed engine.
// This is not an iOS Shortcut execution test.
let data = try Data(contentsOf: URL(fileURLWithPath: "Resources/SSClip-Send.unsigned.shortcut"))
let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
let actions = plist["WFWorkflowActions"] as! [[String: Any]]
let patterns = actions.compactMap { ($0["WFWorkflowActionParameters"] as? [String: Any])?["WFMatchTextPattern"] as? String }
func pattern(_ marker: String) -> String {
    let matches = patterns.filter { $0.contains(marker) }
    precondition(matches.count == 1, "Expected exactly one native pattern for \(marker)")
    return matches[0]
}
var checks = 0
func test(_ pattern: String, _ text: String, _ expected: Bool) throws {
    let regex = try NSRegularExpression(pattern: pattern)
    let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    precondition(found == expected, "Bundled regex regression: \(pattern); expected \(expected)")
    checks += 1
}
let origin = pattern("https://")
for good in ["https://example.com", "https://selfhost.example:443/", "https://127.0.0.1:8443"] { try test(origin, good, true) }
for bad in ["http://example.com", "https://user:pass@example.com", "https://example.com/api", "https://example.com?key=x", "https://example.com/#x", "https://example.com\n", "https://example.com:0", "https://example.com:999999"] { try test(origin, bad, false) }
let key = pattern("{32,256}")
try test(key, String(repeating: "A", count: 32), true)
try test(key, String(repeating: "a_-9", count: 64), true)
for bad in [String(repeating: "a", count: 31), String(repeating: "a", count: 257), String(repeating: "a", count: 32) + "\n", "Bearer " + String(repeating: "a", count: 32)] { try test(key, bad, false) }
let identity = pattern("ios-")
try test(identity, "ios-123456789-123456789-123456789-123456789", true)
try test(identity, "ios-123456789-123456789-123456789-123456789\n", false)
let target = pattern("{8,96}")
try test(target, "12345678-abcd_123", true)
try test(target, "bad/id123", false)
let secret = pattern("ssclip-connection")
for good in [#"{"format":"ssclip-connection"}"#, "{\"format\" \n : \"ssclip-connection\"}"] { try test(secret, good, true) }
try test(secret, "ordinary text", false)
print("PASS: \(checks) actual bundled regex vectors using Foundation/ICU; iOS runtime remains unverified")
