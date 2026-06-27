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

    public init(assetState: String, badge: String?, bubble: String?, emphasize: Bool) {
        self.assetState = assetState
        self.badge = badge
        self.bubble = bubble
        self.emphasize = emphasize
    }
}

// MARK: - PetPresenter

/// Pure mapping from ``PetSummary`` → ``PetPresentation``.
/// Stateless; all logic is deterministic from the summary.
public enum PetPresenter {
    public static func make(from summary: PetSummary) -> PetPresentation {
        let badge = summary.badgeCount > 0 ? "\(summary.badgeCount)" : nil
        let emphasize = summary.attentionCount > 0

        switch summary.state {
        case .idle:
            return PetPresentation(
                assetState: "idle",
                badge: nil,
                bubble: nil,
                emphasize: false
            )
        case .busy:
            return PetPresentation(
                assetState: "busy",
                badge: badge,
                bubble: nil,
                emphasize: emphasize
            )
        case .calling:
            let bubble = "\(summary.badgeCount) 个等你"
            return PetPresentation(
                assetState: "calling",
                badge: badge,
                bubble: bubble,
                emphasize: emphasize
            )
        }
    }
}
