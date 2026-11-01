import Foundation

/// Only known protocol codes become user-visible text; never display raw server bodies.
enum RelayServiceError {
    static func message(for code: String) -> String? {
        switch code {
        case "bark_text_too_large":
            return "未发送：Bark 仅支持短文本（最多 2000 UTF-8 字节，且受通知总大小限制）；未截断，请缩短后再试"
        case "bark_rejected", "bark_delivery_failed":
            return "Bark 推送失败，服务端保留了文本；请到管理端检查或重试"
        case "bark_delivery_unknown":
            return "Bark 推送结果不明；请先检查 iPhone，再到管理端重试，避免重复"
        case "bark_delivery_in_progress":
            return "Bark 推送正在处理中，请稍后查看，勿重复发送"
        case "bark_not_configured", "bark_credential_unavailable":
            return "Bark 配置不可用；请到管理端重新配置"
        default: return nil
        }
    }
}
