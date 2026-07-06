import Foundation

/// 会话恢复命令渲染（F11）。sessionId 先过按 agent 选定的白名单规则，再作**单一 argv** 元素——
/// 杜绝 shell 注入（红线）。未知 agent 返回 nil（不臆造假命令，产品评审 M3）。
public enum ResumeCommand {

    /// agent → id 白名单规则。未知 agent → nil（无恢复命令）。
    private static func idRule(agent: String) -> SessionIdRule? {
        switch agent {
        case "claude", "claude-code", "qoder-cli", "codex", "codex-desktop": return .uuid
        case "opencode": return .prefixedBase62(prefix: "ses_", length: 26)
        default: return nil
        }
    }

    /// 恢复命令 argv 数组。非法 sessionId 或未知 agent → nil。
    /// opencode 目录敏感（TUI 按 cwd 解析 project 并 chdir，源码核实 tui.ts:66-79）：
    /// directory 非空时作位置参数；缺席时降级为裸 --session（评审：best effort）。
    public static func argv(agent: String, sessionId: String, directory: String? = nil) -> [String]? {
        guard let rule = idRule(agent: agent), rule.validate(sessionId) else { return nil }
        switch agent {
        case "claude", "claude-code":
            return ["claude", "--resume", sessionId]
        case "qoder-cli":
            // 实测确认（qodercli v1.0.36 --help）：`-r, --resume [id]`。
            return ["qodercli", "--resume", sessionId]
        case "codex", "codex-desktop":
            // 实测确认(codex-cli 0.142.5 `resume --help`):`codex resume [SESSION_ID]`,UUID 直传不走 picker。
            // 桌面端与 CLI 同存储,resume 通用。
            return ["codex", "resume", sessionId]
        case "opencode":
            if let dir = directory, !dir.isEmpty {
                return ["opencode", dir, "--session", sessionId]
            }
            return ["opencode", "--session", sessionId]
        default:
            return nil
        }
    }

    /// 展示用命令行字符串（供「复制恢复命令」）。
    /// M3-C+ 评审：argv 元素含空格/引号等时单引号引用（'→'\''），不再裸空格 join——
    /// 含空格目录否则产出坏命令。argv 本身单元素传递无注入面，引用只为 display。
    public static func display(agent: String, sessionId: String, directory: String? = nil) -> String? {
        guard let parts = argv(agent: agent, sessionId: sessionId, directory: directory) else { return nil }
        let cmd = parts.map(shellQuote).joined(separator: " ")
        // 目录已知 → 前缀 cd(用户实锤:claude/qodercli 按项目目录归档,别处 resume 找不到会话;
        // codex 全局 id 但工作上下文也在原目录;opencode 位置参数保留,cd 双保险)。
        if let dir = directory, !dir.isEmpty {
            return "cd \(shellQuote(dir)) && \(cmd)"
        }
        return cmd
    }

    /// 单引号 shell 引用；纯安全字符原样（命令名/flag/合法 id 均不受影响）。
    static func shellQuote(_ s: String) -> String {
        let safeExtra: Set<Character> = ["-", "_", ".", "/", "=", ":", "@", "%", "+", ","]
        let isSafe = !s.isEmpty && s.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || safeExtra.contains(c))
        }
        if isSafe { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
