/// 一轮对话（已从 jsonl 解析出的轻量模型，供总结用）。
public struct ConversationTurn: Equatable {
    public let role: String        // "user" | "assistant"
    public let text: String
    public let stopReason: String?
    public init(role: String, text: String, stopReason: String? = nil) {
        self.role = role; self.text = text; self.stopReason = stopReason
    }
}

/// 纯函数：免费本地启发式摘要——「最后一条用户指令 + 最近 assistant 动作/stop_reason」。
/// 即时零成本，是默认展示（模型摘要为可选升级）。
public enum LocalSummarizer {
    public static func summarize(turns: [ConversationTurn], maxLen: Int = 60) -> String {
        guard !turns.isEmpty else { return "（无可总结内容）" }

        let lastUser = turns.last { $0.role == "user" && !$0.text.isEmpty }
        let lastAssistant = turns.last { $0.role == "assistant" }

        var parts: [String] = []
        if let u = lastUser {
            parts.append("指令：\(truncate(u.text, maxLen))")
        }
        if let a = lastAssistant {
            let desc = a.text.isEmpty ? (a.stopReason ?? "完成") : truncate(a.text, maxLen)
            parts.append("最近：\(desc)")
        }
        return parts.isEmpty ? "（无可总结内容）" : parts.joined(separator: " · ")
    }

    private static func truncate(_ s: String, _ maxLen: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        if flat.count <= maxLen { return flat }
        return String(flat.prefix(maxLen)) + "…"
    }
}
