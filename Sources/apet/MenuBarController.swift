import AppKit
import SwiftUI
import AgentPetCore
import AppShellKit

// MARK: - PanelRootView

/// Wraps ``SessionPanel`` with a "退出" footer.  Private to this file.
private struct PanelRootView: View {
    let rows: [SessionRowModel]
    let onTap: (String) -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SessionPanel(rows: rows, onTap: onTap)
            Divider()
            Button {
                onQuit()
            } label: {
                Text("退出 AgentPet")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 320)
    }
}

// MARK: - MenuBarController

/// Owns the `NSStatusItem` and keeps the menu bar icon + popover panel up to date.
///
/// Call ``update(summary:sessions:)`` on every store change (already on `@MainActor`
/// via `AppCoordinator.changeHandler`).
@MainActor
final class MenuBarController: NSObject {

    // MARK: - Dependencies

    private let statusItem: NSStatusItem
    private let focusService: TerminalFocusService

    // MARK: - State

    /// Latest session list from the store; used to resolve row tap IDs.
    private var currentSessions: [Session] = []
    /// Live popover (nil until first click).
    private var popover: NSPopover?
    /// Hosting controller retained for rootView live-updates.
    private var panelHosting: NSHostingController<PanelRootView>?

    // MARK: - Init

    init(focusService: TerminalFocusService) {
        self.focusService = focusService
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
    }

    // MARK: - Public API

    /// Refresh icon, tint, badge, and session panel rows.
    func update(summary: PetSummary, sessions: [Session]) {
        currentSessions = sessions
        applyPresentation(MenuBarPresenter.make(from: summary))
        // Push new rows into the live hosting controller so the popover updates in-place.
        panelHosting?.rootView = makePanelRootView()
    }

    // MARK: - Private: button setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.action = #selector(statusButtonClicked(_:))
        button.target = self
        // No NSMenu — left-click routes to our action and we show an NSPopover instead.
        statusItem.menu = nil
    }

    // MARK: - Private: button appearance

    private func applyPresentation(_ p: MenuBarPresentation) {
        guard let button = statusItem.button else { return }

        let img = NSImage(systemSymbolName: p.symbolName, accessibilityDescription: nil)
        img?.isTemplate = (p.tint == .none)
        button.image = img

        switch p.tint {
        case .none:   button.contentTintColor = nil
        case .green:  button.contentTintColor = .systemGreen
        case .orange: button.contentTintColor = .systemOrange
        case .red:    button.contentTintColor = .systemRed
        }

        if let badge = p.badge {
            button.title = " \(badge)"
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // MARK: - Private: popover

    /// Build the SwiftUI root view with current rows and callbacks.
    private func makePanelRootView() -> PanelRootView {
        let rows = currentSessions.map(SessionRowMapper.make)
        return PanelRootView(
            rows: rows,
            onTap: { [weak self] id in self?.handleSessionTap(id: id) },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        // Toggle: close if already visible.
        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }

        let rootView = makePanelRootView()
        let hc = NSHostingController(rootView: rootView)
        panelHosting = hc

        let p = NSPopover()
        p.contentViewController = hc
        p.behavior = .transient
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover = p
    }

    // MARK: - Actions

    /// AppKit delivers this on the main thread; `nonisolated` satisfies the `@objc` requirement,
    /// and we hop back to `@MainActor` immediately (same pattern as the existing B2 fix).
    @objc nonisolated func statusButtonClicked(_ sender: AnyObject) {
        Task { @MainActor [weak self] in
            self?.showPopover()
        }
    }

    private func handleSessionTap(id: String) {
        // Resolve the session by its stable id.
        guard let session = currentSessions.first(where: {
            "\($0.key.agent)|\($0.key.root)|\($0.key.sessionId)" == id
        }) else { return }

        let terminal = session.terminal
        let fs = focusService
        // Off-main — osascript blocks (Fix I-1 / B2 pattern).
        Task.detached {
            _ = fs.focus(terminal)
        }

        // Dismiss the popover after the user taps.
        popover?.performClose(nil)
    }
}
