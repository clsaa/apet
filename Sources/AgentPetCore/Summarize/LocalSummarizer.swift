/// 一轮对话（已从 jsonl 解析出的轻量模型，供总结用）。
public struct ConversationTurn: Equatable {
    public let role: String        // "user" | "assistant"
    public let text: String
    public let stopReason: String?
    public init(role: String, text: String, stopReason: String? = nil) {
        self.role = role; self.text = text; self.stopReason = stopReason
    }
}

/// 纯函数：免费本地启发式摘要——**「这个会话在做什么」= 第一条真实用户指令(开场任务)**。
/// 一句话/几个字,让用户扫一眼认出会话主题(而非最近活动)。即时零成本;AI 摘要为可选深度升级。
/// 注意:入参 turns 应是转录**开头**的若干轮(开场任务在最前),不是尾部。
public enum LocalSummarizer {
    public static func summarize(turns: [ConversationTurn], maxLen: Int = 40) -> String {
        guard !turns.isEmpty else { return "（无可总结内容）" }

        // 会话主题 = 第一条**有实质内容**的用户指令。跳过 harness 注入 + 寒暄/太短(hello/ok/继续),
        // 那些不代表任务;全是寒暄时退化到第一条真实 user,再退化到第一条 assistant 文本(总比空好)。
        let realUsers = turns.filter { $0.role == "user" && !$0.text.isEmpty && !Self.isInjected($0.text) }
        if let u = realUsers.first(where: { !Self.isTrivial($0.text) }) ?? realUsers.first {
            return sanitize(u.text, maxLen)
        }
        if let a = turns.first(where: { $0.role == "assistant" && !$0.text.isEmpty }) {
            return sanitize(a.text, maxLen)
        }
        return "（无可总结内容）"
    }

    /// 是否为 harness/工具注入的系统消息(非真实用户指令)。用前缀匹配去掉首部空白后判断——
    /// 这些标记出现在消息开头是它们的稳定特征(task-notification/system-reminder/命令回显/
    /// 后台事件/本地命令 caveat)。
    static func isInjected(_ text: String) -> Bool {
        let t = text.drop { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        let markers = [
            "<task-notification>", "<system-reminder>",
            "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>", "<command-name>",
            "<command-message>", "<command-args>", "<bash-stdout>", "<bash-stderr>",
            "[SYSTEM NOTIFICATION", "Caveat: The messages below",
        ]
        return markers.contains { t.hasPrefix($0) }
    }

    /// 是否为寒暄/无实质内容的开场(不代表会话任务):太短 或 命中常见问候/继续词。
    static func isTrivial(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.count < 4 { return true }
        let greetings: Set<String> = [
            "hi", "hello", "hey", "yo", "sup", "hello?", "hi there", "嗨", "嘿", "你好", "在吗", "在么",
            "ok", "okay", "好", "好的", "行", "嗯", "go", "start", "开始", "继续", "go on", "continue",
            "test", "测试", "ping", "?", "？", "quit", "exit", "q", "退出"
        ]
        return greetings.contains(t)
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
