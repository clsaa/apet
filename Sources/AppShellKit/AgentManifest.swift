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

    public init(id: String, rootsGlobs: [String], tsDialect: TimestampDialect,
                resumeArgvTemplate: [String]?, hasStateRules: Bool) {
        self.id = id; self.rootsGlobs = rootsGlobs; self.tsDialect = tsDialect
        self.resumeArgvTemplate = resumeArgvTemplate; self.hasStateRules = hasStateRules
    }

    /// 渲染恢复命令 argv。模板缺失或 sessionId 非法 UUID → nil。
    /// 评审修复（AI m8⑤）：模板元素**部分含** `{id}`（如 `"--resume={id}"`）会静默不替换
    /// 渲染出坏命令——显式拒绝，占位符只允许作为独立元素。
    public func renderResumeArgv(sessionId: String) -> [String]? {
        guard let template = resumeArgvTemplate, Self.isValidUUID(sessionId) else { return nil }
        guard template.allSatisfy({ !$0.contains("{id}") || $0 == "{id}" }) else { return nil }
        return template.map { $0 == "{id}" ? sessionId : $0 }
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

    /// 内置注册表（无 glob 重叠——评审修复 AI M4：废弃 stub 已移出）。
    public static let builtins: [AgentManifest] = [.claude, .qoderWork, .qoderCli, .qoderIDE]
}
