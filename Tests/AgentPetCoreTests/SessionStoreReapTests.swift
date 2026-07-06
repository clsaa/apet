import XCTest
@testable import AgentPetCore

final class SessionStoreReapTests: XCTestCase {
    private func makeStore(state: EventKind, sid: String = "S") -> (SessionStore, SessionKey) {
        let store = SessionStore()
        let key = SessionKey(agent: "a", root: "r", sessionId: sid)
        _ = store.apply(AgentEvent(v: 1, eventId: "E-\(sid)", agent: "a", kind: state,
                        sessionId: sid, root: "r", ts: "t"), seq: 1, now: 0, replay: false)
        return (store, key)
    }

    // MARK: - STALE 回收

    func test_stale_idle_beyond_endedAfter_is_reaped() {
        let (store, key) = makeStore(state: .sessionStart)
        _ = store.markStale(now: 700, timeout: 600)   // → .stale at now=700
        XCTAssertEqual(store.sessions[key]?.state, .stale)

        let removed = store.reap(now: 700 + 3601, endedAfter: 3600, waitingEndedAfter: 86400)
        XCTAssertEqual(removed, [.removed(key)])
        XCTAssertNil(store.sessions[key])
    }

    func test_stale_idle_within_endedAfter_survives() {
        let (store, key) = makeStore(state: .sessionStart)
        _ = store.markStale(now: 700, timeout: 600)   // → .stale at now=700

        let removed = store.reap(now: 700 + 1800, endedAfter: 3600, waitingEndedAfter: 86400)
        XCTAssertEqual(removed, [])
        XCTAssertNotNil(store.sessions[key])
    }

    // MARK: - WAITING 回收

    func test_waiting_idle_beyond_waitingEndedAfter_is_reaped() {
        let (store, key) = makeStore(state: .stop)  // → .waiting(.stop) at now=0
        XCTAssertEqual(store.sessions[key]?.state, .waiting(.stop))

        let removed = store.reap(now: 86401, endedAfter: 3600, waitingEndedAfter: 86400)
        XCTAssertEqual(removed, [.removed(key)])
        XCTAssertNil(store.sessions[key])
    }

    func test_waiting_idle_within_waitingEndedAfter_survives() {
        let (store, key) = makeStore(state: .stop)

        let removed = store.reap(now: 3600, endedAfter: 3600, waitingEndedAfter: 86400)
        XCTAssertEqual(removed, [])
        XCTAssertNotNil(store.sessions[key])
    }

    // MARK: - RUNNING 永不回收

    func test_running_never_reaped() {
        let (store, key) = makeStore(state: .sessionStart)  // → .running at now=0
        XCTAssertEqual(store.sessions[key]?.state, .running)

        let removed = store.reap(now: 999_999, endedAfter: 1, waitingEndedAfter: 1)
        XCTAssertEqual(removed, [])
        XCTAssertNotNil(store.sessions[key])
    }

    // MARK: - ENDED 驱逐（M2）

    /// ended 会话 → reap 无论时间参数多大均立即驱逐
    func test_ended_session_is_always_reaped() {
        let (store, key) = makeStore(state: .sessionStart)
        _ = store.apply(AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .sessionEnd,
                        sessionId: "S", root: "r", ts: "t"), seq: 2, now: 0, replay: false)
        XCTAssertEqual(store.sessions[key]?.state, .ended)

        let removed = store.reap(now: 0, endedAfter: 999_999, waitingEndedAfter: 999_999)
        XCTAssertEqual(removed, [.removed(key)])
        XCTAssertNil(store.sessions[key])
    }

    // MARK: - changeHandler 收到 .removed

    func test_reap_emits_removed_to_handler() {
        let (store, key) = makeStore(state: .sessionStart)
        _ = store.markStale(now: 700, timeout: 600)

        var capturedChanges: [StoreChange] = []
        store.addChangeHandler { changes, _ in capturedChanges = changes }

        _ = store.reap(now: 700 + 3601, endedAfter: 3600, waitingEndedAfter: 86400)
        XCTAssertEqual(capturedChanges, [.removed(key)])
    }

    // MARK: - 存活三态(alive 保护 / dead 快清 / unknown 正常窗口)

    /// pid 已死 = claude 进程确定退出 → 短窗口(deadAfter)快速清除,不占 8 小时。
    /// 场景:程序化批量拉起的测试会话/用户退出的 claude,确定死了还挂 8h 是面板噪声。
    func test_deadPid_reapedAfterShortWindow() {
        let store = SessionStore()
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        _ = store.apply(AgentEvent(v: 1, eventId: "E", agent: "a", kind: .stop,
                        sessionId: "S", root: "r",
                        terminal: TerminalRef(kind: .warp, tty: "ttys001", pid: 42),
                        ts: "t"), seq: 1, now: 0, replay: false)
        let removed = store.reap(now: 1801, endedAfter: 14400, waitingEndedAfter: 28800,
                                 deadAfter: 1800, liveness: { _ in .dead })
        XCTAssertEqual(removed, [.removed(key)], "pid 已死 → 短窗口清除")
    }

    func test_deadPid_withinShortWindow_survives() {
        let store = SessionStore()
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        _ = store.apply(AgentEvent(v: 1, eventId: "E", agent: "a", kind: .stop,
                        sessionId: "S", root: "r",
                        terminal: TerminalRef(kind: .warp, tty: "ttys001", pid: 42),
                        ts: "t"), seq: 1, now: 0, replay: false)
        let removed = store.reap(now: 900, endedAfter: 14400, waitingEndedAfter: 28800,
                                 deadAfter: 1800, liveness: { _ in .dead })
        XCTAssertEqual(removed, [], "刚结束的会话保留一阵(可见近况)")
        XCTAssertNotNil(store.sessions[key])
    }

    func test_unknownLiveness_normalWindows() {
        let store = SessionStore()
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        _ = store.apply(AgentEvent(v: 1, eventId: "E", agent: "a", kind: .stop,
                        sessionId: "S", root: "r", ts: "t"), seq: 1, now: 0, replay: false)
        var removed = store.reap(now: 10_000, endedAfter: 14400, waitingEndedAfter: 28800,
                                 deadAfter: 1800, liveness: { _ in .unknown })
        XCTAssertEqual(removed, [], "unknown 不适用短窗口")
        removed = store.reap(now: 28_801, endedAfter: 14400, waitingEndedAfter: 28800,
                             deadAfter: 1800, liveness: { _ in .unknown })
        XCTAssertEqual(removed, [.removed(key)], "unknown 走正常 waiting 窗口")
    }

    // MARK: - tty 存活保护(终端还开着的闲置会话不被 reap)

    /// 带存活 tty 的 waiting 会话,即使闲置超过 waitingEndedAfter 也保留——
    /// 终端窗口还开着,用户随时会回来;老化窗口只对「终端已关」的会话生效。
    func test_waiting_beyondWindow_butTtyAlive_survives() {
        let store = SessionStore()
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        _ = store.apply(AgentEvent(v: 1, eventId: "E", agent: "a", kind: .stop,
                        sessionId: "S", root: "r",
                        terminal: TerminalRef(kind: .warp, tty: "ttys001"),
                        ts: "t"), seq: 1, now: 0, replay: false)
        let removed = store.reap(now: 999_999, endedAfter: 3600, waitingEndedAfter: 28800,
                                 liveness: { s in s.terminal?.tty == "ttys001" ? .alive : .unknown })
        XCTAssertEqual(removed, [])
        XCTAssertNotNil(store.sessions[key], "tty 存活 → 保留")
    }

    func test_waiting_beyondWindow_ttyDead_reaped() {
        let store = SessionStore()
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        _ = store.apply(AgentEvent(v: 1, eventId: "E", agent: "a", kind: .stop,
                        sessionId: "S", root: "r",
                        terminal: TerminalRef(kind: .warp, tty: "ttys001"),
                        ts: "t"), seq: 1, now: 0, replay: false)
        let removed = store.reap(now: 999_999, endedAfter: 3600, waitingEndedAfter: 28800,
                                 liveness: { _ in .unknown })
        XCTAssertEqual(removed, [.removed(key)])
        XCTAssertNil(store.sessions[key], "tty 已死 → 按窗口正常回收")
    }

    /// ended(明确 session_end,Claude 已退出)不受 tty 保护——终端开着也没意义,会话已终。
    func test_ended_ttyAlive_still_reaped() {
        let store = SessionStore()
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        _ = store.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                        sessionId: "S", root: "r",
                        terminal: TerminalRef(kind: .warp, tty: "ttys001"),
                        ts: "t"), seq: 1, now: 0, replay: false)
        _ = store.apply(AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .sessionEnd,
                        sessionId: "S", root: "r", ts: "t"), seq: 2, now: 0, replay: false)
        let removed = store.reap(now: 100, endedAfter: 3600, waitingEndedAfter: 28800,
                                 liveness: { _ in .alive })
        XCTAssertEqual(removed, [.removed(key)])
        XCTAssertNil(store.sessions[key], "ended 是终态,tty 保护不适用")
    }

    /// 默认参数(不传 isAlive)行为不变——向后兼容既有调用方。
    func test_reap_defaultIsAlive_behavesAsBefore() {
        let (store, key) = makeStore(state: .sessionStart)
        _ = store.markStale(now: 700, timeout: 600)
        let removed = store.reap(now: 700 + 3601, endedAfter: 3600, waitingEndedAfter: 86400)
        XCTAssertEqual(removed, [.removed(key)])
    }

    /// 用户实锤(termarium 测试拉起的 claude 子进程):进程已死却挂绿点 10 分钟——
    /// running + pid 已死 → 立即打灰(进程没了不可能还在跑)。
    func test_runningWithDeadPid_staleImmediately() {
        let store = SessionStore()
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        _ = store.apply(AgentEvent(v: 1, eventId: "E", agent: "a", kind: .busy,
                        sessionId: "S", root: "r",
                        terminal: TerminalRef(kind: .warp, tty: "ttys001", pid: 42),
                        ts: "t"), seq: 1, now: 0, replay: false)
        XCTAssertEqual(store.sessions[key]?.state, .running)
        // 刚活跃 10s(远未到 timeout 600)但 pid 已死 → 打灰
        let changes = store.markStale(now: 10, timeout: 600, liveness: { _ in .dead })
        XCTAssertEqual(changes, [.upserted(key)])
        XCTAssertEqual(store.sessions[key]?.state, .stale)
    }

    func test_runningAliveOrUnknown_notStaleBeforeTimeout() {
        let store = SessionStore()
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        _ = store.apply(AgentEvent(v: 1, eventId: "E", agent: "a", kind: .busy,
                        sessionId: "S", root: "r",
                        terminal: TerminalRef(kind: .warp, tty: "ttys001", pid: 42),
                        ts: "t"), seq: 1, now: 0, replay: false)
        XCTAssertEqual(store.markStale(now: 10, timeout: 600, liveness: { _ in .alive }), [])
        XCTAssertEqual(store.markStale(now: 10, timeout: 600, liveness: { _ in .unknown }), [])
        XCTAssertEqual(store.sessions[key]?.state, .running, "活着/未知照旧等 timeout")
    }
}
