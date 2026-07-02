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
        relativeText: String = ""
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
        let title: String
        if let name = session.customName, !name.isEmpty {
            title = name
        } else if let t = session.title, !t.isEmpty {
            title = t
        } else if let cwd = session.cwd, !cwd.isEmpty {
            title = URL(fileURLWithPath: cwd).lastPathComponent
        } else {
            title = key.sessionId
        }

        // Subtitle: full cwd (empty string if not available)
        let subtitle = session.cwd ?? ""

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

        let relativeText = now.map { RelativeTime.short(from: session.lastActiveAt, now: $0, tzOffset: tzOffset) } ?? ""

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
            relativeText: relativeText
        )
    }
}
