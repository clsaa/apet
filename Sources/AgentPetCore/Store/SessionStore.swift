import Foundation

public enum StoreChange: Equatable { case upserted(SessionKey) }

/// 会话单一事实源。
/// ⚠️ **非线程安全**：所有访问（apply / markStale / 读 sessions）必须由 owner 串行化。
/// Plan B 在 @MainActor 上持有本类；FSEvents 等后台回调须先 hop 到该串行上下文再调用。
public final class SessionStore {
    public private(set) var sessions: [SessionKey: Session] = [:]
    private var seenEventIds: Set<String> = []

    /// 有状态变化时回调（onChange 在 apply/markStale 返回前、结果非空时触发）。
    public var onChange: (([StoreChange]) -> Void)?

    public init() {}

    public func apply(_ event: AgentEvent, seq: Int, now: Double, replay: Bool) -> [StoreChange] {
        let changes = applyInner(event, seq: seq, now: now, replay: replay)
        if !changes.isEmpty { onChange?(changes) }
        return changes
    }

    private func applyInner(_ event: AgentEvent, seq: Int, now: Double, replay: Bool) -> [StoreChange] {
        // 1) eventId 去重（处理重复行 / 回放）
        guard !seenEventIds.contains(event.eventId) else { return [] }
        seenEventIds.insert(event.eventId)

        let key = SessionKey(event: event)
        guard var session = sessions[key] else {
            // 首事件即 session_end：按 spec §6 忽略，不建会话（面板 B3）
            if case .sessionEnd = event.kind { return [] }
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

        // 字段级合并：非空才覆盖（terminal 一旦精确不被空值降级）。设计 §4 红队 M1。
        if let cwd = event.cwd { session.cwd = cwd }
        if let title = event.title { session.title = title }
        if let terminal = event.terminal { session.terminal = terminal }

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

extension SessionStore {
    public func aggregateState() -> PetState {
        var hasRunning = false, hasWaiting = false
        for s in sessions.values {
            switch s.state {
            case .running: hasRunning = true
            case .waiting: hasWaiting = true
            case .ended, .stale: break
            }
        }
        if hasRunning { return .busy }
        if hasWaiting { return .calling }
        return .idle
    }

    private func sortRank(_ state: SessionState) -> Int {
        switch state {
        case .waiting(.attention): return 0
        case .waiting(.stop):      return 1
        case .running:             return 2
        case .stale:               return 3
        case .ended:               return 4   // 已被过滤
        }
    }

    public func activeSessions() -> [Session] {
        sessions.values
            .filter { $0.state != .ended }
            .sorted {
                let r0 = sortRank($0.state), r1 = sortRank($1.state)
                if r0 != r1 { return r0 < r1 }
                return $0.lastActiveAt > $1.lastActiveAt
            }
    }

    /// 把超过 timeout 秒没有事件的 RUNNING 会话标记为 stale（可复活；WAITING/ended/stale 不动）。
    /// WAITING 是"轮到用户"，本就无活动事件，不因超时降级（面板 B2）。
    public func markStale(now: Double, timeout: Double) -> [StoreChange] {
        let changes = markStaleInner(now: now, timeout: timeout)
        if !changes.isEmpty { onChange?(changes) }
        return changes
    }

    private func markStaleInner(now: Double, timeout: Double) -> [StoreChange] {
        var changes: [StoreChange] = []
        for (key, var session) in sessions {
            switch session.state {
            case .running:
                if now - session.lastActiveAt > timeout {
                    session.state = .stale
                    sessions[key] = session
                    changes.append(.upserted(key))
                }
            case .waiting, .ended, .stale:
                break
            }
        }
        return changes
    }

    public func summary() -> PetSummary {
        var running = 0, waiting = 0, attention = 0, stale = 0
        for s in sessions.values {
            switch s.state {
            case .running: running += 1
            case .waiting(let r): waiting += 1; if r == .attention { attention += 1 }
            case .stale: stale += 1
            case .ended: break
            }
        }
        let state: PetState = running > 0 ? .busy : (waiting > 0 ? .calling : .idle)
        return PetSummary(state: state, runningCount: running, waitingCount: waiting,
                          attentionCount: attention, staleCount: stale)
    }
}
