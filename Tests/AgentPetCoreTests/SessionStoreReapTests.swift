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
}
