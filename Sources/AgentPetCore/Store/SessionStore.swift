import Foundation

public enum StoreChange: Equatable { case upserted(SessionKey) }

public final class SessionStore {
    public private(set) var sessions: [SessionKey: Session] = [:]
    private var seenEventIds: Set<String> = []

    public init() {}

    public func apply(_ event: AgentEvent, seq: Int, now: Double, replay: Bool) -> [StoreChange] {
        // 1) eventId 去重（处理重复行 / 回放）
        guard !seenEventIds.contains(event.eventId) else { return [] }
        seenEventIds.insert(event.eventId)

        let key = SessionKey(event: event)
        guard var session = sessions[key] else {
            // 新会话
            let s = Session(key: key, state: initialState(event), cwd: event.cwd,
                            title: event.title, terminal: event.terminal,
                            lastSeq: seq, lastActiveAt: now)
            sessions[key] = s
            return [.upserted(key)]
        }

        // 2) 终态不可回退
        if session.state == .ended { return [] }

        // 3) seq 落后则忽略（按 ingest 单调序排序，不用 ts）
        if seq <= session.lastSeq { return [] }

        let newState = nextState(from: session.state, event: event)
        let stateChanged = newState != session.state

        session.state = newState
        session.lastSeq = seq
        session.lastActiveAt = now
        sessions[key] = session

        // 4) running 上的 busy 自环：只喂计时，不广播（设计 §4 短路）
        return stateChanged ? [.upserted(key)] : []
    }

    private func initialState(_ event: AgentEvent) -> SessionState {
        nextState(from: .running, event: event)
    }

    private func nextState(from current: SessionState, event: AgentEvent) -> SessionState {
        guard current != .ended else { return .ended }   // 终态不可回退（CLAUDE.md 硬约束 #4）
        switch event.kind {
        case .sessionStart, .busy: return .running
        case .stop:                return .waiting(event.reason ?? .stop)
        case .attention:           return .waiting(event.reason ?? .attention)
        case .sessionEnd:          return .ended
        case .pluginError, .unknown: return current   // 续命不改状态（设计 §6）
        }
    }
}
