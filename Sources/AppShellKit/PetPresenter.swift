import AgentPetCore

// MARK: - PetPresentation

/// Pure presentation model for the floating pet window.
/// Drives image selection, badge, speech bubble, and emphasis state.
public struct PetPresentation: Equatable {
    /// Asset state key: "idle" | "busy" | "calling"
    public let assetState: String
    /// Numeric badge label when badgeCount > 0, otherwise nil.
    public let badge: String?
    /// Speech bubble text when in calling state, otherwise nil.
    public let bubble: String?
    /// True when attentionCount > 0 (drives orange vs red tint).
    public let emphasize: Bool
    /// 始终显示的"进行中"会话数（绿点），即便为 0（用户反馈：时刻显示）。
    public let runningCount: Int
    /// 始终显示的"停下等你/完成（未读）"会话数（红点）= waiting + attention - acknowledged，即便为 0。
    public let doneCount: Int
    /// "已读"会话数（黄点）= acknowledgedCount，即便为 0。
    public let readCount: Int
    /// "闲置"会话数（灰点）= staleCount，即便为 0。
    public let idleCount: Int

    public init(assetState: String, badge: String?, bubble: String?, emphasize: Bool,
                runningCount: Int = 0, doneCount: Int = 0, readCount: Int = 0, idleCount: Int = 0) {
        self.assetState = assetState
        self.badge = badge
        self.bubble = bubble
        self.emphasize = emphasize
        self.runningCount = runningCount
        self.doneCount = doneCount
        self.readCount = readCount
        self.idleCount = idleCount
    }
}

// MARK: - PetPresenter

/// Pure mapping from ``PetSummary`` → ``PetPresentation``.
/// Stateless; all logic is deterministic from the summary.
public enum PetPresenter {
    public static func make(from summary: PetSummary) -> PetPresentation {
        let badge = summary.badgeCount > 0 ? "\(summary.badgeCount)" : nil
        let emphasize = summary.attentionCount > 0
        // 始终携带计数：running=进行中；
        // done=停下等你/完成「未读」（waiting + attention - acknowledged，红色只数未读）；
        // read=已读（acknowledged，黄色）。
        let running = summary.runningCount
        let read = summary.acknowledgedCount
        let done = summary.waitingCount + summary.attentionCount - summary.acknowledgedCount
        let idle = summary.staleCount

        switch summary.state {
        case .idle:
            return PetPresentation(
                assetState: "idle",
                badge: nil,
                bubble: nil,
                emphasize: false,
                runningCount: running,
                doneCount: done,
                readCount: read,
                idleCount: idle
            )
        case .busy:
            return PetPresentation(
                assetState: "busy",
                badge: badge,
                bubble: nil,
                emphasize: emphasize,
                runningCount: running,
                doneCount: done,
                readCount: read,
                idleCount: idle
            )
        case .calling:
            let bubble = "\(summary.badgeCount) 个等你"
            return PetPresentation(
                assetState: "calling",
                badge: badge,
                bubble: bubble,
                emphasize: emphasize,
                runningCount: running,
                doneCount: done,
                readCount: read,
                idleCount: idle
            )
        }
    }
}
