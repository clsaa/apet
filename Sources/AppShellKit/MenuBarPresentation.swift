import AgentPetCore

// MARK: - Tint

/// The tint color to apply to the menu bar icon.
public enum Tint: Equatable {
    case none, orange, red, green
}

// MARK: - MenuBarPresentation

/// A snapshot of what the menu bar button should look like.
public struct MenuBarPresentation: Equatable {
    /// SF Symbol name (e.g. "pawprint" or "pawprint.fill").
    public let symbolName: String
    /// Icon tint color.
    public let tint: Tint
    /// Badge text shown next to the icon (`nil` = no badge).
    public let badge: String?

    public init(symbolName: String, tint: Tint, badge: String?) {
        self.symbolName = symbolName
        self.tint = tint
        self.badge = badge
    }
}

// MARK: - MenuBarPresenter

/// Pure mapping from ``PetSummary`` to ``MenuBarPresentation``.
///
/// Rules:
/// - **idle**    → "pawprint",      tint `.none`,   badge nil
/// - **busy**    → "pawprint.fill", tint `.green`,  badge = badgeCount > 0 ? "\(badgeCount)" : nil
/// - **calling** → "pawprint.fill", tint `.orange` (attentionCount > 0) or `.red`,
///                badge = badgeCount > 0 ? "\(badgeCount)" : nil
public enum MenuBarPresenter {
    public static func make(from summary: PetSummary) -> MenuBarPresentation {
        let badge: String? = summary.badgeCount > 0 ? "\(summary.badgeCount)" : nil
        switch summary.state {
        case .idle:
            return MenuBarPresentation(symbolName: "pawprint", tint: .none, badge: nil)
        case .busy:
            return MenuBarPresentation(symbolName: "pawprint.fill", tint: .green, badge: badge)
        case .calling:
            let tint: Tint = summary.attentionCount > 0 ? .orange : .red
            return MenuBarPresentation(symbolName: "pawprint.fill", tint: tint, badge: badge)
        }
    }
}
