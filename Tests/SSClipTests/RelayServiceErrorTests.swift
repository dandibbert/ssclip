import Testing
@testable import SSClip

struct RelayServiceErrorTests {
    @Test func barkSizeFailureExplainsLimitWithoutTruncation() {
        let message = RelayServiceError.message(for: "bark_text_too_large") ?? ""
        #expect(message.contains("APNs 4096"))
        #expect(message.contains("未截断"))
    }
    @Test func unknownDeliveryDoesNotInviteBlindDuplicateSend() {
        let message = RelayServiceError.message(for: "bark_delivery_unknown") ?? ""
        #expect(message.contains("先检查 iPhone"))
        #expect(message.contains("避免重复"))
    }
    @Test func onlyExplicitCodesAreMapped() {
        for code in ["bark_rejected", "bark_delivery_failed", "bark_delivery_in_progress", "bark_not_configured", "bark_credential_unavailable", "bark_dns_unavailable", "bark_private_address_blocked"] {
            #expect(RelayServiceError.message(for: code) != nil)
        }
        #expect(RelayServiceError.message(for: "unknown_secret_payload") == nil)
        #expect(RelayServiceError.message(for: "<html>error</html>") == nil)
    }
}
