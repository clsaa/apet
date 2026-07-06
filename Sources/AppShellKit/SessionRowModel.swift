import Foundation
import AgentPetCore

// MARK: - Dot

/// The colored state indicator shown next to a session row.
public enum Dot: Equatable {
    case running     // green  — session is actively processing
    case attention   // orange — session paused, awaiting user input
    case doneWaiting // red    — session stopped (waiting.stop)
    case read        // yellow — a waiting session the user has acknowledged (红→黄)
    case stale       // gray   — session timed-out or ended
}

// MARK: - SessionRowModel

/// Presentation model for a single row in the session panel.
/// Pure value type — no AppKit/SwiftUI dependencies, fully unit-testable.
public struct SessionRowModel: Equatable, Identifiable {
    /// Stable identifier: "agent|root|sessionId"
    public let id: String
    /// Display title: Session.title → cwd basename → sessionId (fallback chain).
    public let title: String
    /// Secondary line: the full working directory path (empty string if unknown).
    public let subtitle: String
    /// Multi-profile chip label derived from `root` (e.g. "work"). Nil for the default profile.
    public let profileTag: String?
    /// Dot color driven by `SessionState`.
    public let dot: Dot
    /// `true` when the terminal kind only supports app-activate (no precise tab jump).
    /// Currently: `.warp`, `.ghostty`, `.vscode`, `.other`.
    public let activateOnly: Bool
    /// `true` when the terminal is activate-only AND the user must manually find the tab
    /// (VSCode/Cursor integrated terminal). Drives an extra UI hint beyond "仅激活".
    public let needsManualTabHint: Bool
    /// `true` when the session state is inferred from jsonl replay (source == .jsonl &&
    /// state == .waiting). The session is paused/stopped but the terminal info comes from
    /// file scanning rather than a live hook event — so it may be stale.
    public let isInferred: Bool
    /// 收藏（F7）。
    public let favorite: Bool
    /// 会话原始 sessionId（供复制 ID / 恢复命令）。
    public let sessionId: String
    /// 会话所属 agent（供按 agent 渲染恢复命令）。
    public let agent: String
    /// 相对时间文案（F10，如 "3 分钟前"）。由组织层注入 now 后填充；未注入为 ""。
    public let relativeText: String
    /// 无跳转提示（M3-C+ 评审 B3）：DB 轮询源且无终端信息——点击只能走「复制恢复命令」
    /// 弹窗，预期在点击前对齐。
    public let noJumpHint: Bool
    /// 终端 app bundleId（M3-D-D：行首真 app 图标；terminal 未知→nil，不显图标）。
    public let terminalBundleId: String?
    /// 所属自定义分组（M3-D-C：右键「加入分组」勾选态）。
    public let groups: [String]
    /// 手动摘要(用户手写;第二行优先显示)。
    public let note: String?
    /// 系统摘要(ai-title/thread_name 原始值,独立于 customName——改名后系统摘要仍可见/可编辑)。
    public let systemSummary: String?
    /// F10:时间 tooltip(创建于 + 最后活跃绝对时刻;无 createdAt 只显后者)。
    public let timeHelp: String

    public init(
        id: String,
        title: String,
        subtitle: String,
        profileTag: String?,
        dot: Dot,
        activateOnly: Bool,
        needsManualTabHint: Bool = false,
        isInferred: Bool = false,
        favorite: Bool = false,
        sessionId: String = "",
        agent: String = "",
        relativeText: String = "",
        noJumpHint: Bool = false,
        terminalBundleId: String? = nil,
        groups: [String] = [],
        note: String? = nil,
        systemSummary: String? = nil,
        timeHelp: String = ""
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.profileTag = profileTag
        self.dot = dot
        self.activateOnly = activateOnly
        self.needsManualTabHint = needsManualTabHint
        self.isInferred = isInferred
        self.favorite = favorite
        self.sessionId = sessionId
        self.agent = agent
        self.relativeText = relativeText
        self.noJumpHint = noJumpHint
        self.terminalBundleId = terminalBundleId
        self.groups = groups
        self.note = note
        self.systemSummary = systemSummary
        self.timeHelp = timeHelp
    }
}

// MARK: - SessionRowMapper

/// Pure mapping from `Session` → `SessionRowModel`.
public enum SessionRowMapper {
    /// `now` 注入时填充 `relativeText`（F10 相对时间）；nil 时留空。`tzOffset` 供本地日界。
    public static func make(_ session: Session, now: Double? = nil, tzOffset: Double = 0) -> SessionRowModel {
        let key = session.key

        // Stable ID: "agent|root|sessionId"
        let id = "\(key.agent)|\(key.root)|\(key.sessionId)"

        // Title fallback chain: 自定义名(F7) → explicit title → cwd basename → sessionId
        let rawTitle: String
        if let name = session.customName, !name.isEmpty {
            rawTitle = name
        } else if let t = session.title, !t.isEmpty {
            rawTitle = t
        } else if let cwd = session.cwd, !cwd.isEmpty {
            rawTitle = URL(fileURLWithPath: cwd).lastPathComponent
        } else {
            rawTitle = key.sessionId
        }
        // 半可信输入(模型生成的 ai-title/thread_name)→ 展示边界消毒(bidi/控制字符,评审 M4)。
        let title = DisplaySanitizer.sanitize(rawTitle)

        // Subtitle: full cwd (empty string if not available)
        // E1:路径折叠(home→~,超长→…/父/叶),消除满屏重复前缀。
        let subtitle = PathAbbreviator.abbreviate(session.cwd ?? "", home: NSHomeDirectory())

        // Dot colour from session state.
        // 已读（acknowledged）的 waiting 会话优先渲染为黄色 .read（红→黄），先于 doneWaiting/attention。
        let dot: Dot
        switch session.state {
        case .running:                              dot = .running
        case .waiting where session.acknowledged:   dot = .read
        case .waiting(.attention):                  dot = .attention
        case .waiting(.stop):                       dot = .doneWaiting
        case .stale:                                dot = .stale
        case .ended:                                dot = .stale   // shouldn't appear in active list
        }

        // activateOnly: 由终端能力分级单一事实源推导（与 TerminalFocusPlanner 一致）。
        // 无终端信息（kind == nil）时不显降级提示。
        let activateOnly: Bool
        let needsManualTabHint: Bool
        if let kind = session.terminal?.kind {
            let cap = TerminalCapabilities.capability(for: kind)
            activateOnly = cap.isActivateOnly
            needsManualTabHint = cap.needsManualTabHint
        } else {
            activateOnly = false
            needsManualTabHint = false
        }

        // isInferred: jsonl-sourced session whose state is waiting (stop or attention).
        // The session appears stopped/paused but we learned this from file scanning, not a
        // live hook event — the terminal may no longer exist.
        let isWaiting: Bool
        if case .waiting = session.state { isWaiting = true } else { isWaiting = false }
        let isInferred = session.source == .jsonl && isWaiting

        // opencode/codex 等无 terminal 且无 hook 升级路径 → 行内「无跳转」(M3-C+ 评审 B3/架构评审 Major-2)。
        let noJumpHint = session.terminal == nil
            && AgentManifest.noJumpAgents.contains(key.agent)
        // M3-D-D:终端 bundleId(ref 自带优先,否则 kind 映射;未知→nil)。
        let terminalBundleId = session.terminal?.bundleId ?? session.terminal?.kind.bundleId

        let relativeText = now.map { RelativeTime.short(from: session.lastActiveAt, now: $0, tzOffset: tzOffset) } ?? ""

        // F10:tooltip 补绝对时刻(创建 + 最后活跃)。
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var timeHelp = "最后活跃:\(df.string(from: Date(timeIntervalSince1970: session.lastActiveAt)))"
        if let created = session.createdAt {
            timeHelp = "创建于:\(df.string(from: Date(timeIntervalSince1970: created)))\n" + timeHelp
        }

        return SessionRowModel(
            id: id,
            title: title,
            subtitle: subtitle,
            profileTag: session.profileLabel,
            dot: dot,
            activateOnly: activateOnly,
            needsManualTabHint: needsManualTabHint,
            isInferred: isInferred,
            favorite: session.favorite,
            sessionId: key.sessionId,
            agent: key.agent,
            relativeText: relativeText,
            noJumpHint: noJumpHint,
            terminalBundleId: terminalBundleId,
            groups: session.groups,
            note: session.note.map(DisplaySanitizer.sanitize),
            systemSummary: session.title.flatMap { t in
                let clean = DisplaySanitizer.sanitize(t)
                return clean.isEmpty ? nil : clean
            },
            timeHelp: timeHelp
        )
    }
}
