import Foundation

public enum StoreChange: Equatable { case upserted(SessionKey) }

public final class SessionStore {
    public private(set) var sessions: [SessionKey: Session] = [:]

    public init() {}

    public func apply(_ event: AgentEvent, seq: Int, now: Double, replay: Bool) -> [StoreChange] {
        let key = SessionKey(event: event)
        var session = sessions[key]
            ?? Session(key: key, state: .running, lastSeq: seq, lastActiveAt: now)

        let newState = nextState(from: session.state, event: event)
        session.state = newState
        session.lastSeq = seq
        session.lastActiveAt = now
        sessions[key] = session
        return [.upserted(key)]
    }

    private func nextState(from current: SessionState, event: AgentEvent) -> SessionState {
        switch event.kind {
        case .sessionStart, .busy: return .running
        case .stop:                return .waiting(event.reason ?? .stop)
        case .attention:           return .waiting(event.reason ?? .attention)
        case .sessionEnd:          return .ended
        case .pluginError, .unknown: return current   // 续命不改状态（设计 §6）
        }
    }
}
