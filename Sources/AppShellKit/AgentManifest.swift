import Foundation

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
    public func renderResumeArgv(sessionId: String) -> [String]? {
        guard let template = resumeArgvTemplate, Self.isValidUUID(sessionId) else { return nil }
        return template.map { $0 == "{id}" ? sessionId : $0 }
    }

    /// 严格 UUID（8-4-4-4-12 hex）。
    static func isValidUUID(_ s: String) -> Bool {
        let groups = [8, 4, 4, 4, 12]
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == groups.count else { return false }
        for (part, expected) in zip(parts, groups) {
            guard part.count == expected, part.allSatisfy({ $0.isHexDigit }) else { return false }
        }
        return true
    }

    // MARK: - 内置 manifest

    public static let claude = AgentManifest(
        id: "claude-code",
        rootsGlobs: ["~/.claude/projects/**"],
        tsDialect: .iso,
        resumeArgvTemplate: ["claude", "--resume", "{id}"],
        hasStateRules: true
    )

    /// Qoder 系接入目标（用户指定）：**Qoder / Qoder Work / Qoder Cli** 三个产品。
    /// 各自的真实路径 / jsonl 格式 / resume 命令 **待逐一核实**，核实前只留可扩展 manifest 接口、
    /// 不臆造（遵守 no-fabricated-urls-commands）。下面 `qoder` 为占位 stub，
    /// 待补 `qoderWork` / `qoderCli` 变体。
    ///
    /// Qoder：路径/时间方言为实测事实；**resume 命令与状态规则未核实 → 不臆造**。
    public static let qoder = AgentManifest(
        id: "qoder",
        rootsGlobs: ["~/.qoder/projects/**"],
        tsDialect: .epochMillis,
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

    /// Qoder CLI（**部分实测**，2026-07-02 v1.0.36）：config root `~/.qoder`（安装脚本确认）；
    /// **resume 已核实**：`qodercli --resume [id]`（--help）。CLI 与 Claude Code 高度同构，
    /// transcript 预期落 `~/.qoder/projects/**`（登录后待最终确认；watcher 对不存在目录安全为空）。
    public static let qoderCli = AgentManifest(
        id: "qoder-cli",
        rootsGlobs: ["~/.qoder/projects/**"],
        tsDialect: .iso,
        resumeArgvTemplate: ["qodercli", "--resume", "{id}"],
        hasStateRules: false
    )

    /// 内置注册表。
    public static let builtins: [AgentManifest] = [.claude, .qoder, .qoderWork, .qoderCli]
}
