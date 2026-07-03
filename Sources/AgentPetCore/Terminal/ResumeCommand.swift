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

    /// 严格 UUID 校验(收敛至 SessionIdRule.uuid,M3-C+ 评审:消除双份实现)。
    private static func isValidUUID(_ s: String) -> Bool {
        SessionIdRule.uuid.validate(s)
    }
}
