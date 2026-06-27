import AppKit
import AgentPetCore
import AppShellKit

// MARK: - SessionBox

/// NSObject wrapper that carries a TerminalRef for use as NSMenuItem.representedObject.
private final class SessionBox: NSObject {
    let terminal: TerminalRef?
    init(_ terminal: TerminalRef?) { self.terminal = terminal }
}

// MARK: - MenuBarController

/// Owns the `NSStatusItem` and keeps the menu bar icon + menu up to date.
///
/// Call ``update(summary:sessions:)`` on every store change (already on `@MainActor`
/// via `AppCoordinator.changeHandler`).
@MainActor
final class MenuBarController: NSObject {

    // MARK: - Dependencies

    private let statusItem: NSStatusItem
    private let focusService = TerminalFocusService()

    // MARK: - Init

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    // MARK: - Public API

    /// Refresh icon, tint, badge, and session menu.
    func update(summary: PetSummary, sessions: [Session]) {
        let presentation = MenuBarPresenter.make(from: summary)
        applyPresentation(presentation)
        buildMenu(sessions: sessions)
    }

    // MARK: - Private: button appearance

    private func applyPresentation(_ p: MenuBarPresentation) {
        guard let button = statusItem.button else { return }

        // Build SF Symbol image; disable template rendering so contentTintColor takes effect.
        let img = NSImage(systemSymbolName: p.symbolName, accessibilityDescription: nil)
        img?.isTemplate = (p.tint == .none)   // template for neutral; false for colored
        button.image = img

        // Tint color
        switch p.tint {
        case .none:   button.contentTintColor = nil            // system default (adaptive)
        case .green:  button.contentTintColor = .systemGreen
        case .orange: button.contentTintColor = .systemOrange
        case .red:    button.contentTintColor = .systemRed
        }

        // Badge text
        if let badge = p.badge {
            button.title = " \(badge)"
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // MARK: - Private: menu

    private func buildMenu(sessions: [Session]) {
        let menu = NSMenu()

        for session in sessions {
            menu.addItem(makeSessionItem(for: session))
        }

        if !sessions.isEmpty {
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(
            title: "退出 AgentPet",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func makeSessionItem(for session: Session) -> NSMenuItem {
        // State dot
        let dot: String
        switch session.state {
        case .running:              dot = "🟢"
        case .waiting(.attention):  dot = "🟠"
        case .waiting(.stop):       dot = "🔴"
        case .stale:                dot = "⚫"
        case .ended:                dot = "⚪"
        }

        // Display name: prefer title, fall back to cwd basename, then sessionId
        let name: String
        if let title = session.title, !title.isEmpty {
            name = title
        } else if let cwd = session.cwd {
            name = URL(fileURLWithPath: cwd).lastPathComponent
        } else {
            name = session.key.sessionId
        }

        // Compose label
        var label = "\(dot) \(name)"
        if let profileLabel = session.profileLabel {
            label += " [\(profileLabel)]"
        }

        let item = NSMenuItem(
            title: label,
            action: #selector(sessionItemClicked(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = SessionBox(session.terminal)
        return item
    }

    // MARK: - Actions

    /// Called by AppKit on the main thread when the user clicks a session menu item.
    @objc nonisolated func sessionItemClicked(_ sender: NSMenuItem) {
        // We know AppKit delivers menu actions on the main thread → safe to assume isolation.
        let box = sender.representedObject as? SessionBox
        Task { @MainActor [weak self] in
            guard let self, let box else { return }
            self.focusService.focus(box.terminal)
        }
    }
}
