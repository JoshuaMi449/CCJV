import Foundation

enum AnswerSelection {
    /// A background notification reply is usually short and status-shaped.
    /// Do not let it replace a substantive answer to the user's question.
    static let substantiveCharacters = 80
    static let followUpCharacters = 320

    private static let followUpCues = [
        "后台", "监控", "采集", "通知",
        "不是你的新指令", "无需处理", "已恢复", "已正常启动",
        "基线", "有变化我再报"
    ]

    static func isNotificationFollowUp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= followUpCharacters else { return false }
        if trimmed.count <= 60 { return true }
        return followUpCues.contains { trimmed.contains($0) }
    }

    static func isSubstantive(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= substantiveCharacters
    }
}
