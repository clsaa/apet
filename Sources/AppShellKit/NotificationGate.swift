import Foundation
import AgentPetCore

/// Composes `NotificationDecider` + `NotificationThrottle` into a single testable gate.
///
/// Pure value type — no system side-effects, fully unit-testable.
/// Returns the content to deliver, or nil if suppressed by the decider, throttle, or replay flag.
public struct NotificationGate {

    // MARK: - State

    public let cooldown: Double
    private var throttle: NotificationThrottle

    // MARK: - Init

    public init(cooldown: Double) {
        self.cooldown = cooldown
        self.throttle = NotificationThrottle()
    }

    // MARK: - Core

    /// Evaluates whether a notification should be delivered.
    ///
    /// - Parameters:
    ///   - event:   The agent event that triggered the check.
    ///   - session: Current session state (may be nil if session unknown).
    ///   - mode:    Notification mode (attentionOnly or everyStop).
    ///   - replay:  True during startup replay — always returns nil.
    ///   - now:     Current Unix timestamp (seconds), injected for testability.
    /// - Returns: `NotificationContent` to deliver, or nil if suppressed.
    public mutating func evaluate(
        event: AgentEvent,
        session: Session?,
        mode: NotifyMode,
        replay: Bool,
        now: Double
    ) -> NotificationContent? {
        // 1. Ask the decider (also handles replay guard internally, but we rely on it here too).
        let decision = NotificationDecider.decide(event: event, session: session, mode: mode, replay: replay)
        guard decision.shouldNotify, let content = decision.content else { return nil }

        // 2. Throttle on (sessionKey, eventKind).
        let key  = sessionKeyString(event: event)
        let kind = kindString(event.kind)
        guard throttle.allow(key: key, kind: kind, now: now, cooldown: cooldown) else { return nil }

        return content
    }

    // MARK: - Private helpers

    private func sessionKeyString(event: AgentEvent) -> String {
        "\(event.agent)|\(event.root)|\(event.sessionId)"
    }

    private func kindString(_ kind: EventKind) -> String {
        switch kind {
        case .attention:       return "attention"
        case .stop:            return "stop"
        case .pluginError:     return "pluginError"
        case .sessionStart:    return "sessionStart"
        case .busy:            return "busy"
        case .sessionEnd:      return "sessionEnd"
        case .unknown(let s):  return "unknown.\(s)"
        }
    }
}
