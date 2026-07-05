import Foundation
import AgentPetCore   // SessionIdRule 收敛委托所需(M3-C+)

// MARK: - TimestampDialect

/// 时间戳方言。Claude jsonl 用 ISO8601；Qoder jsonl 部分行用 epoch 毫秒；
/// QoderWork agents.db 用 epoch 秒（均为实测事实）。
public enum TimestampDialect: Equatable {
    case iso
    case epochMillis
    case epochSeconds

    /// 解析为 Unix 秒（Double）。非法 → nil。纯解析（无当前时间读取）。
    public func parse(_ raw: String) -> Double? {
        switch self {
        case .epochMillis:
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let ms = Double(trimmed) else { return nil }
            return ms / 1000.0
        case .epochSeconds:
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let s = Double(trimmed) else { return nil }
            return s
        case .iso:
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: raw) { return d.timeIntervalSince1970 }
            // 回退：无小数秒
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            return f2.date(from: raw)?.timeIntervalSince1970
        }
    }
}

// MARK: - AgentManifest

/// 第三方 Agent 接入契约（§3 manifest 精简）。复用同一 DTO 描述路径/时间方言/恢复命令/状态规则。
/// 恢复命令渲染：sessionId 先过 UUID 白名单，再作**单一 argv** 元素替换 `{id}`（防注入红线）。
public struct AgentManifest: Equatable {
    public let id: String
    public let rootsGlobs: [String]
    public let tsDialect: TimestampDialect
    /// 恢复命令 argv 模板（含 `{id}` 占位）。nil = 未核实（不臆造）。
    public let resumeArgvTemplate: [String]?
    /// 是否提供状态派生规则；否则 UI 降级「状态粗略」（仅 mtime）。
    public let hasStateRules: Bool
    /// 会话 id 白名单规则（默认 UUID；M3-C+ 评审：防注入红线按 agent 可配）。
    public let sessionIdRule: SessionIdRule

    public init(id: String, rootsGlobs: [String], tsDialect: TimestampDialect,
                resumeArgvTemplate: [String]?, hasStateRules: Bool,
                sessionIdRule: SessionIdRule = .uuid) {
        self.id = id; self.rootsGlobs = rootsGlobs; self.tsDialect = tsDialect
        self.resumeArgvTemplate = resumeArgvTemplate; self.hasStateRules = hasStateRules
        self.sessionIdRule = sessionIdRule
    }

    /// 渲染恢复命令 argv。模板缺失或 sessionId 非法（按 `sessionIdRule`）→ nil。
    /// 评审修复（AI m8⑤）：模板元素**部分含** `{id}`/`{dir}`（如 `"--resume={id}"`）会静默不替换
    /// 渲染出坏命令——显式拒绝，占位符只允许作为独立元素。
    /// `{dir}`（M3-C+）：directory nil/空 → 该元素整体省略（opencode 目录缺席降级）。
    public func renderResumeArgv(sessionId: String, directory: String? = nil) -> [String]? {
        guard let template = resumeArgvTemplate, sessionIdRule.validate(sessionId) else { return nil }
        guard template.allSatisfy({ el in
            (!el.contains("{id}") || el == "{id}") && (!el.contains("{dir}") || el == "{dir}")
        }) else { return nil }
        var out: [String] = []
        for el in template {
            switch el {
            case "{id}": out.append(sessionId)
            case "{dir}":
                if let dir = directory, !dir.isEmpty { out.append(dir) }
            default: out.append(el)
            }
        }
        return out
    }

    /// 严格 UUID（收敛至 AgentPetCore.SessionIdRule.uuid，M3-C+ 评审：消除双份实现；
    /// 全角十六进制拒绝语料（测试 m9）随委托继续生效）。
    static func isValidUUID(_ s: String) -> Bool {
        SessionIdRule.uuid.validate(s)
    }

    // MARK: - 内置 manifest

    public static let claude = AgentManifest(
        id: "claude-code",
        rootsGlobs: ["~/.claude/projects/**"],
        tsDialect: .iso,
        resumeArgvTemplate: ["claude", "--resume", "{id}"],
        hasStateRules: true
    )

    /// ⚠️ 已废弃 stub（评审修复 AI M4：与 `qoderCli` 同 glob 且方言标注以偏概全——
    /// 实测对话行是 ISO8601，epoch 毫秒只属于 `runtime-config` 元数据行）。
    /// 保留仅为源码历史可读性，**不在 builtins**；Qoder IDE 真实 manifest 待接入时新建。
    @available(*, deprecated, message: "被 qoderCli(实测) 取代；勿用于扫描注册")
    public static let qoder = AgentManifest(
        id: "qoder",
        rootsGlobs: ["~/.qoder/projects/**"],
        tsDialect: .iso,
        resumeArgvTemplate: nil,
        hasStateRules: false
    )

    /// QoderWork（**已实测接入**，2026-07-02）：数据在 SQLite 而非 jsonl——
    /// `~/Library/Application Support/QoderWork/data/agents.db`（chats/projects/sub_chats，
    /// session_id 为 UUID，时间为 **epoch 秒**）。bundleId `com.qoder.work`。
    /// 读取走 `QoderWorkDBReader`（只读）+ `QoderWorkWatcher` 轮询；状态粗略（无 stateRules）。
    /// resume 命令未核实 → nil。Qoder IDE（com.qoder.ide，state.vscdb 键值库）与 Qoder Cli
    ///（本机未装）仍待核实。
    public static let qoderWork = AgentManifest(
        id: "qoder-work",
        rootsGlobs: ["~/Library/Application Support/QoderWork/data/agents.db"],
        tsDialect: .epochSeconds,
        resumeArgvTemplate: nil,
        hasStateRules: false
    )

    /// Qoder CLI（**全量实测**，2026-07-02 v1.0.36 真实会话验证）：
    /// - config root `~/.qoder`；transcript `~/.qoder/projects/<编码cwd>/<sessionId>.jsonl`（已确认）
    /// - 对话行（user/assistant）ISO8601 时间戳 + entrypoint="cli" + message.stop_reason ——
    ///   与 Claude 格式同构，现有 JSONLParse/Scanner 直接兼容（端到端验证：会话入 store）
    /// - `runtime-config` 元数据行为 epoch 毫秒整数（被解析器天然忽略，无害）
    /// - **resume 已核实**：`qodercli --resume [id]`
    public static let qoderCli = AgentManifest(
        id: "qoder-cli",
        rootsGlobs: ["~/.qoder/projects/**"],
        tsDialect: .iso,
        resumeArgvTemplate: ["qodercli", "--resume", "{id}"],
        hasStateRules: false
    )

    /// Qoder IDE（**实测接入**，2026-07-03）：`com.qoder.ide`（VSCode fork）。会话 jsonl 在
    /// `~/Library/Application Support/Qoder/SharedClientCache/cli/projects/<编码cwd>/
    /// task-<id>.session.execution.jsonl`——user/assistant 行 ISO 时间戳，与 Claude 同构。
    /// sessionId 形如 `task-xxx`（非 UUID）；resume 未核实 → nil；无 stateRules（内容信号
    /// 可用则用，否则 mtime 兜底）。点击激活 IDE。
    public static let qoderIDE = AgentManifest(
        id: "qoder-ide",
        rootsGlobs: ["~/Library/Application Support/Qoder/SharedClientCache/cli/projects/**"],
        tsDialect: .iso,
        resumeArgvTemplate: nil,
        hasStateRules: false
    )

    /// OpenCode（sst/opencode，**源码核实 v1.17.13 / commit 04d236c，2026-07-03**；真机实测门待过）：
    /// SQLite `$XDG_DATA_HOME/opencode/opencode*.db`（默认 ~/.local/share；OPENCODE_DB 可覆盖；
    /// 非常规 channel 有后缀）。时间 epoch 毫秒；id `ses_`+26 位 base62（前缀外，全长 30）；
    /// 状态派生内容信号优先（最后 assistant 消息 in-flight/completed + 行插入时间窗口兜底），
    /// 见 OpenCodeScanner——hasStateRules=true（非纯 mtime）。
    /// resume 目录敏感 → {dir} 位置参数（tui.ts:66-79）。读取走 OpenCodeDBReader + DBPollWatcher。
    /// ⚠️ rootsGlobs 是**文档性默认路径**（UI 展示用）；实际解析含 OPENCODE_DB/XDG/launchctl
    /// 兜底，见 `OpenCodeDBReader.defaultDBPath`（开源评审：防第三方按 glob 语义消费漏发现）。
    public static let openCode = AgentManifest(
        id: "opencode",
        rootsGlobs: ["~/.local/share/opencode/opencode*.db"],
        tsDialect: .epochMillis,
        resumeArgvTemplate: ["opencode", "{dir}", "--session", "{id}"],
        hasStateRules: true,
        sessionIdRule: .prefixedBase62(prefix: "ses_", length: 26)
    )

    /// 内置注册表（无 glob 重叠——评审修复 AI M4：废弃 stub 已移出）。
    /// OpenAI Codex CLI(**实测接入**,2026-07-05,codex 0.118.0 真实会话解剖):
    /// - 会话 `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuidv7>.jsonl`(首行 session_meta 含 id/cwd)
    /// - 标题白送:`~/.codex/session_index.jsonl` 的 thread_name(CodexSessionIndex)
    /// - 轮次信号:event_msg task_started/task_complete → CodexRolloutParse 映射 end_turn
    /// - resume 未核实(本机 codex 二进制损坏、README 无记载)→ nil(红线:不复制未核实命令)
    /// - 无终端信息 → 无跳转诚实降级(与 OpenCode 同)
    public static let codex = AgentManifest(
        id: "codex",
        rootsGlobs: ["~/.codex/sessions/**"],
        tsDialect: .iso,
        resumeArgvTemplate: nil,
        hasStateRules: false
    )

    public static let builtins: [AgentManifest] = [.claude, .qoderWork, .qoderCli, .qoderIDE, .openCode, .codex]

    /// DB 型 agent（会话在 SQLite 而非 jsonl 转录）：
    /// 用于 ① 轮询源 waitingStop 预置已读（架构 m6 收敛，评审 B2：别再加 agent 字符串 if）；
    /// ② 右键「本地摘要」隐藏（无 jsonl 转录必弹死弹窗，交互评审）。
    /// ⚠️ M4 公开契约前的**内部注册表**，非第三方接入面——M4 时应改为 manifest 字段
    ///（如 sourceKind），第三方 DB 型 agent 才能经契约声明获得同等语义（开源评审）。
    public static let dbBackedAgents: Set<String> = ["qoder-work", "opencode"]

    /// 转录为 Claude 同构 jsonl 的 agent(快速/AI 摘要可用:SessionTranscriptLocator +
    /// ConversationTailParser 直接兼容)。codex 的 rollout schema 不同 → 摘要菜单隐藏(遗留:codex tail 解析)。
    public static let claudeStyleTranscriptAgents: Set<String> = ["claude-code", "qoder-cli", "qoder-ide"]
}
