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

        // 优先取「最后一条真实用户指令」——跳过 harness 注入的系统消息(在 jsonl 里也是 user
        // 角色,但不是用户输入);全被跳过时退化到最后一条非空 user(有内容比空好)。
        let lastUser = turns.last { $0.role == "user" && !$0.text.isEmpty && !Self.isInjected($0.text) }
            ?? turns.last { $0.role == "user" && !$0.text.isEmpty }
        let lastAssistant = turns.last { $0.role == "assistant" }

        var parts: [String] = []
        if let u = lastUser {
            parts.append("指令：\(sanitize(u.text, maxLen))")
        }
        if let a = lastAssistant {
            // stopReason 同样来自不可信 jsonl——一并消毒限长（评审修复 AI m6）
            let desc = a.text.isEmpty ? sanitize(a.stopReason ?? "完成", maxLen) : sanitize(a.text, maxLen)
            parts.append("最近：\(desc)")
        }
        return parts.isEmpty ? "（无可总结内容）" : parts.joined(separator: " · ")
    }

    /// 是否为 harness/工具注入的系统消息(非真实用户指令)。用前缀匹配去掉首部空白后判断——
    /// 这些标记出现在消息开头是它们的稳定特征(task-notification/system-reminder/命令回显/
    /// 后台事件/本地命令 caveat)。
    static func isInjected(_ text: String) -> Bool {
        let t = text.drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        let markers = [
            "<task-notification>", "<system-reminder>",
            "<local-command-stdout>", "<local-command-stderr>", "<command-name>",
            "<command-message>", "<command-args>", "<bash-stdout>", "<bash-stderr>",
            "[SYSTEM NOTIFICATION", "Caveat: The messages below",
        ]
        return markers.contains { t.hasPrefix($0) }
    }

    /// 不可信文本消毒：滤控制字符（C0/C1）与 bidi 覆盖符（RTL 欺骗）、拉平换行、限长。
    private static func sanitize(_ s: String, _ maxLen: Int) -> String {
        let bidi: Set<Character> = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                                    "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
        let flat = String(s.map { c -> Character in
            if c == "\n" || c == "\r" || c == "\t" { return " " }
            return c
        }).filter { c in
            guard let scalar = c.unicodeScalars.first else { return false }
            if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) { return false }
            return !bidi.contains(c)
        }
        if flat.count <= maxLen { return flat }
        return String(flat.prefix(maxLen)) + "…"
    }
}
