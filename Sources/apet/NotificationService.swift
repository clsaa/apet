import Foundation
@preconcurrency import UserNotifications   // 消除 UNNotificationRequest 非 Sendable 捕获告警（M2-E）
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
    /// Returns the current DND window; called on `@MainActor` inside `consider`.
    /// Defaults to a disabled window so the service is a drop-in replacement for existing callers.
    private let dndProvider: () -> DNDWindow
    /// 点击通知时把对应会话标记已读（红→黄）。默认空，由 AppCoordinator 注入 store.acknowledge。
    private let onAcknowledge: (SessionKey) -> Void

    // MARK: - Init

    init(
        cooldown: Double = 60.0,
        focusService: TerminalFocusService,
        sessionLookup: @escaping (SessionKey) -> Session?,
        dndProvider: @escaping () -> DNDWindow = { DNDWindow(enabled: false, startMin: 0, endMin: 0) },
        onAcknowledge: @escaping (SessionKey) -> Void = { _ in }
    ) {
        self.gate = NotificationGate(cooldown: cooldown)
        self.focusService = focusService
        self.sessionLookup = sessionLookup
        self.dndProvider = dndProvider
        self.onAcknowledge = onAcknowledge
        super.init()
    }

    // MARK: - Lifecycle

    /// Register as delegate. Authorisation is requested lazily on first delivery (Fix 1),
    /// so we never prompt the user until there is an actual notification to show.
    /// No-ops gracefully in headless / non-bundled environments (e.g. `--smoke`, `swift run`).
    func start() {
        // `UNUserNotificationCenter.current()` aborts if there is no app bundle.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Note: no requestAuthorization here — deferred to `deliver(_:)` on first banner.
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
        // MINOR-7b: 合并为一个 Date() 调用，避免两次墙钟读取之间的微小漂移。
        let nowDate = Date()
        let now = nowDate.timeIntervalSince1970
        guard let content = gate.evaluate(event: event, session: session,
                                          mode: mode, replay: replay, now: now) else { return }

        // DND gate: suppress OS notification if the current time falls inside the quiet window.
        // Time is obtained here (service boundary, same pattern as the `now` above) so that
        // the pure `shouldSuppress` function itself never touches system state.
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: nowDate)
        let nowMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if DNDWindow.shouldSuppress(dnd: dndProvider(), nowMinOfDay: nowMin) { return }

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
        deliver(request)
    }

    // MARK: - Private: lazy-authorised delivery (Fix 1)

    /// Deliver `request`, requesting authorisation lazily on first use.
    ///
    /// - `.notDetermined`: prompt via `requestAuthorization`, then deliver only if granted.
    /// - `.denied`: skip delivery entirely (no banner, no error).
    /// - otherwise (authorised / provisional / ephemeral): deliver.
    ///
    /// `getNotificationSettings` / `requestAuthorization` completion handlers arrive on a
    /// system-managed queue; we hop back to `@MainActor` before touching `UNUserNotificationCenter.add`.
    private func deliver(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .denied:
                // User explicitly declined — do not deliver, do not re-prompt.
                return
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    Task { @MainActor in
                        center.add(request) { _ in }
                    }
                }
            default:
                Task { @MainActor in
                    center.add(request) { _ in }
                }
            }
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
        let rawInfo = response.notification.request.content.userInfo
        let stringInfo = rawInfo as? [String: Any] ?? [:]
        // 纯函数决策（可单测）：合法 userInfo → [.acknowledge(key), .focus(key)]；缺字段 → []。
        let actions = NotificationClickResolver.resolve(userInfo: stringInfo)
        guard !actions.isEmpty else {
            completionHandler()
            return
        }

        // Hop to MainActor to access @MainActor-isolated state, then hop OFF for the blocking
        // osascript call so we never stall the main thread (Fix I-1).
        Task { @MainActor in
            for action in actions {
                switch action {
                case .acknowledge(let key):
                    // B1：看完通知即标记已读（红→黄），与点列表/全部已读路径一致。
                    self.onAcknowledge(key)
                case .focus(let key):
                    let terminal = self.sessionLookup(key)?.terminal
                    let fs = self.focusService
                    Task.detached {
                        _ = fs.focus(terminal)
                    }
                }
            }
            completionHandler()
        }
    }
}
