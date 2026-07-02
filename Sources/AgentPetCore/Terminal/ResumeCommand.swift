import Foundation

/// 会话恢复命令渲染（F11）。sessionId 先过 UUID 白名单，再作**单一 argv** 元素——
/// 杜绝 shell 注入（红线）。未知 agent 返回 nil（M3-C 接 Qoder 后按 agent 分流补齐）。
public enum ResumeCommand {

    /// 恢复命令 argv 数组。仅 Claude 系（`claude` / `claude-code`）已知：`["claude","--resume","<id>"]`。
    /// 非法 sessionId 或未知 agent → nil。
    public static func argv(agent: String, sessionId: String) -> [String]? {
        guard isValidUUID(sessionId) else { return nil }
        switch agent {
        case "claude", "claude-code":
            return ["claude", "--resume", sessionId]
        case "qoder-cli":
            // 实测确认（qodercli v1.0.36 --help）：`-r, --resume [id]`。
            return ["qodercli", "--resume", sessionId]
        default:
            return nil
        }
    }

    /// 展示用命令行字符串（供「复制恢复命令」）。渲染自 `argv`，空格连接。
    public static func display(agent: String, sessionId: String) -> String? {
        guard let parts = argv(agent: agent, sessionId: sessionId) else { return nil }
        return parts.joined(separator: " ")
    }

    /// 严格 UUID 校验：8-4-4-4-12 十六进制，只放行 `[0-9a-fA-F-]`。
    private static func isValidUUID(_ s: String) -> Bool {
        let groups = [8, 4, 4, 4, 12]
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == groups.count else { return false }
        for (part, expected) in zip(parts, groups) {
            guard part.count == expected else { return false }
            guard part.allSatisfy({ c in
                (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
            }) else { return false }
        }
        return true
    }
}
