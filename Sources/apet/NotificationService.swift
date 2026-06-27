import Foundation
import UserNotifications
import AgentPetCore
import AppShellKit

// MARK: - NotificationService

/// Delivers macOS notifications via `UNUserNotificationCenter`.
///
/// Wraps `NotificationGate` (decider + throttle) so only actionable, non-replayed events
/// produce banners. On click, resolves the session's `TerminalRef` and hands off to
/// `TerminalFocusService`.
///
/// ### Threading
/// All public methods must be called on `@MainActor`.
/// The `UNUserNotificationCenterDelegate` callbacks arrive on a system-managed queue;
/// we hop back to `@MainActor` for any state access.
@MainActor
final class NotificationService: NSObject {

    // MARK: - Dependencies

    private var gate: NotificationGate
    private let focusService: TerminalFocusService
    /// Called on `@MainActor` to look up a live session by key.
    private let sessionLookup: (SessionKey) -> Session?

    // MARK: - Init

    init(
        cooldown: Double = 60.0,
        focusService: TerminalFocusService = TerminalFocusService(),
        sessionLookup: @escaping (SessionKey) -> Session?
    ) {
        self.gate = NotificationGate(cooldown: cooldown)
        self.focusService = focusService
        self.sessionLookup = sessionLookup
        super.init()
    }

    // MARK: - Lifecycle

    /// Request notification authorisation and register as delegate.
    /// No-ops gracefully in headless / non-bundled environments (e.g. `--smoke`, `swift run`).
    func start() {
        // `UNUserNotificationCenter.current()` aborts if there is no app bundle.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Ignore the result; we simply try — user can grant later via System Settings.
        }
    }

    // MARK: - Public API

    /// Evaluate whether `event` should produce a notification and, if so, post it.
    ///
    /// - Parameters:
    ///   - event:   The agent event to evaluate.
    ///   - session: Current state of the related session (may be nil).
    ///   - mode:    Notification preference.
    ///   - replay:  Pass `true` during startup replay; the gate suppresses all such events.
    func consider(
        event: AgentEvent,
        session: Session?,
        mode: NotifyMode,
        replay: Bool
    ) {
        let now = Date().timeIntervalSince1970
        guard let content = gate.evaluate(event: event, session: session,
                                          mode: mode, replay: replay, now: now) else { return }

        let un = UNMutableNotificationContent()
        un.title = content.title
        un.body  = content.body
        un.sound = .default

        // Encode the session key in userInfo so the click handler can reconstruct it.
        let key = SessionKey(event: event)
        un.userInfo = [
            "agent":     key.agent,
            "root":      key.root,
            "sessionId": key.sessionId,
        ]

        // Guard: UNUserNotificationCenter requires a bundled app; skip in headless mode.
        guard Bundle.main.bundleIdentifier != nil else { return }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: un,
            trigger: nil    // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { _ in
            // Silently ignore delivery errors (e.g. no authorisation).
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {

    /// Show banner + play sound even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// On click: resolve the session key → terminal ref → focus.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard
            let agent     = userInfo["agent"]     as? String,
            let root      = userInfo["root"]      as? String,
            let sessionId = userInfo["sessionId"] as? String
        else {
            completionHandler()
            return
        }
        let key = SessionKey(agent: agent, root: root, sessionId: sessionId)

        // Hop to MainActor to access @MainActor-isolated state, then call completionHandler.
        Task { @MainActor in
            let session = self.sessionLookup(key)
            self.focusService.focus(session?.terminal)
            completionHandler()
        }
    }
}
