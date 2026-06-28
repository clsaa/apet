import Foundation

public enum StoreChange: Equatable { case upserted(SessionKey); case removed(SessionKey) }

/// 会话单一事实源。
/// ⚠️ **非线程安全**：所有访问（apply / markStale / 读 sessions）必须由 owner 串行化。
/// Plan B 在 @MainActor 上持有本类；FSEvents 等后台回调须先 hop 到该串行上下文再调用。
public final class SessionStore {
    public private(set) var sessions: [SessionKey: Session] = [:]
    private var seenEventIds: Set<String> = []

    private var changeHandlers: [([StoreChange], Bool) -> Void] = []
    /// 注册变更订阅者（可多个，扇出）。Bool = isReplay（回放时为 true，供 NotifyCenter 静默）。
    public func addChangeHandler(_ handler: @escaping ([StoreChange], Bool) -> Void) {
        changeHandlers.append(handler)
    }
    private func emit(_ changes: [StoreChange], replay: Bool) {
        guard !changes.isEmpty else { return }
        for h in changeHandlers { h(changes, replay) }
    }

    public init() {}

    public func apply(_ event: AgentEvent, seq: Int, now: Double, replay: Bool) -> [StoreChange] {
        let changes = applyInner(event, seq: seq, now: now, replay: replay)
        emit(changes, replay: replay)
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
            let initialSt = initialState(event)
            // 回放历史时，被 kill 的会话只有 session_start/busy 无 session_end，会重建成 RUNNING 绿点幽灵。
            // 回放下把 RUNNING 直接落 STALE：用户一打开就是灰"?"而非误导的绿点（面板 H3-1 / AI Finding 4）。
            let finalInitialSt: SessionState = (replay && initialSt == .running) ? .stale : initialSt
            let s = Session(key: key, state: finalInitialSt, cwd: event.cwd,
                            title: event.title, terminal: event.terminal,
                            lastSeq: seq, lastActiveAt: now, source: event.source)
            sessions[key] = s
            return [.upserted(key)]
        }

        // 2) 终態不可回退
        if session.state == .ended { return [] }

        // 3) seq 落后则忽略（按 ingest 单调序排序，不用 ts）
        if seq <= session.lastSeq { return [] }

        // 字段级合并：非空才覆盖（terminal 一旦精确不被空值降级）。设计 §4 红队 M1。
        if let cwd = event.cwd { session.cwd = cwd }
        if let title = event.title { session.title = title }
        if let terminal = event.terminal { session.terminal = terminal }
        // 来源合并：hook 一旦标记不被 jsonl 降级（hook 更精确）。
        session.source = (session.source == .hook) ? .hook : event.source

        let newState = nextState(from: session.state, event: event)
        // 回放历史时，被 kill 的会话只有 session_start/busy 无 session_end，会重建成 RUNNING 绿点幽灵。
        // 回放下把 RUNNING 直接落 STALE：用户一打开就是灰"?"而非误导的绿点（面板 H3-1 / AI Finding 4）。
        var newState2 = newState
        if replay && newState2 == .running { newState2 = .stale }
        let stateChanged = newState2 != session.state

        session.state = newState2
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
    /// 推荐用 summary()（含 hasWaiting/attentionCount/badgeCount）。本方法等价 summary().state。
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
        emit(changes, replay: false)
        return changes
    }

    private func markStaleInner(now: Double, timeout: Double) -> [StoreChange] {
        var changes: [StoreChange] = []
        for (key, var session) in sessions {
            switch session.state {
            case .running:
                // jsonl 会话生命周期由后续 watcher 驱动，不被定时器打灰（架构-B3）
                guard session.source != .jsonl else { break }
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

    /// Fix 4：仅当目标会话来源为 `.jsonl` 时才打灰，否则返回 []（不动 hook 会话）。
    /// 抽出此守卫便于单测，并保证 hook 会话生命周期不被 jsonl watcher 的 .stale 信号误降级
    /// （硬约束 #9：hook 一旦标记不被 jsonl 降级；#10：hook 生命周期 just-in-time，不由 watcher 驱动）。
    @discardableResult
    public func markStaleSessionIfJSONL(_ key: SessionKey, now: Double) -> [StoreChange] {
        guard sessions[key]?.source == .jsonl else { return [] }
        return markStaleSession(key, now: now)
    }

    /// 定向把指定 key 的会话置为 stale（running/waiting → stale）。
    /// ended/stale 属终态或已达目标状态，返回 []；key 不存在同样返回 []。
    /// 用于 jsonl watcher 检测会话消失时主动打灰，区别于定时 markStale（架构-B3）。
    @discardableResult
    public func markStaleSession(_ key: SessionKey, now: Double) -> [StoreChange] {
        guard var session = sessions[key] else { return [] }
        switch session.state {
        case .ended, .stale: return []
        case .running, .waiting: break
        }
        session.state = .stale
        session.lastActiveAt = now
        sessions[key] = session
        let changes: [StoreChange] = [.upserted(key)]
        emit(changes, replay: false)
        return changes
    }

    /// 回收：STALE 超过 endedAfter / WAITING 超过 waitingEndedAfter 的会话转 ENDED，并从 sessions 驱逐。
    /// 返回被移除会话的 .removed 变更。纯计时，不依赖 hook（面板 H3-3）。
    @discardableResult
    public func reap(now: Double, endedAfter: Double, waitingEndedAfter: Double) -> [StoreChange] {
        var removed: [StoreChange] = []
        for (key, session) in sessions {
            let idle = now - session.lastActiveAt
            let shouldEnd: Bool
            switch session.state {
            case .stale:   shouldEnd = idle > endedAfter
            case .waiting: shouldEnd = idle > waitingEndedAfter
            case .ended:   shouldEnd = true   // 已 ended 直接驱逐
            case .running: shouldEnd = false
            }
            if shouldEnd {
                sessions.removeValue(forKey: key)
                removed.append(.removed(key))
            }
        }
        emit(removed, replay: false)
        return removed
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
