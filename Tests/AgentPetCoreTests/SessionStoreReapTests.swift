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
                                 isAlive: { s in s.terminal?.tty == "ttys001" })
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
                                 isAlive: { _ in false })
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
                                 isAlive: { _ in true })
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
}
