import XCTest
@testable import AgentPetCore

final class SessionStoreStaleTests: XCTestCase {
    private func start(_ s: SessionStore, now: Double) {
        _ = s.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                    sessionId: "S", root: "r", ts: "t"), seq: 1, now: now, replay: false)
    }

    func test_running_becomes_stale_after_timeout() {
        let s = SessionStore()
        start(s, now: 0)
        let changes = s.markStale(now: 700, timeout: 600)
        XCTAssertEqual(changes, [.upserted(SessionKey(agent: "a", root: "r", sessionId: "S"))])
        XCTAssertEqual(s.sessions.values.first?.state, .stale)
    }

    func test_not_stale_within_timeout() {
        let s = SessionStore()
        start(s, now: 0)
        XCTAssertEqual(s.markStale(now: 100, timeout: 600), [])
        XCTAssertEqual(s.sessions.values.first?.state, .running)
    }

    func test_ended_is_not_marked_stale() {
        let s = SessionStore()
        _ = s.apply(AgentEvent(v: 1, eventId: "E0", agent: "a", kind: .sessionStart,
                    sessionId: "S", root: "r", ts: "t"), seq: 1, now: 0, replay: false)
        _ = s.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionEnd,
                    sessionId: "S", root: "r", ts: "t"), seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.markStale(now: 9999, timeout: 600), [])
        XCTAssertEqual(s.sessions.values.first?.state, .ended)
    }

    func test_stale_session_revives_on_new_event() {
        let s = SessionStore()
        start(s, now: 0)
        _ = s.markStale(now: 700, timeout: 600)
        _ = s.apply(AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .busy,
                    sessionId: "S", root: "r", ts: "t"), seq: 2, now: 800, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .running) // 复活
    }

    /// B2: WAITING 不因超时降级为 stale
    func test_waiting_is_not_marked_stale() {
        let s = SessionStore()
        _ = s.apply(AgentEvent(v: 1, eventId: "W1", agent: "a", kind: .stop,
                    sessionId: "S", root: "r", ts: "t"), seq: 1, now: 0, replay: false)
        let changes = s.markStale(now: 9999, timeout: 600)
        XCTAssertEqual(changes, [])
        XCTAssertEqual(s.sessions.values.first?.state, .waiting(.stop))
    }

    // MARK: - H2 补强

    /// 严格 >：等于边界不算 stale
    func test_markStale_exact_boundary_not_stale() {
        let s = SessionStore()
        start(s, now: 0)
        let changes = s.markStale(now: 600, timeout: 600)
        XCTAssertEqual(changes, [])
        XCTAssertEqual(s.sessions.values.first?.state, .running)
    }

    /// 已是 stale 的会话再次 markStale 不触发第二次广播
    func test_already_stale_not_double_processed() {
        let s = SessionStore()
        start(s, now: 0)
        _ = s.markStale(now: 700, timeout: 600)
        XCTAssertEqual(s.sessions.values.first?.state, .stale)
        let changes = s.markStale(now: 1000, timeout: 600)
        XCTAssertEqual(changes, [])
    }

    /// 多会话部分超时：只有超时会话变 stale
    func test_multiple_sessions_partial_stale() {
        let s = SessionStore()
        let keyA = SessionKey(agent: "a", root: "r", sessionId: "A")
        let keyB = SessionKey(agent: "a", root: "r", sessionId: "B")
        _ = s.apply(AgentEvent(v: 1, eventId: "EA", agent: "a", kind: .sessionStart,
                               sessionId: "A", root: "r", ts: "t"), seq: 1, now: 0, replay: false)
        _ = s.apply(AgentEvent(v: 1, eventId: "EB", agent: "a", kind: .sessionStart,
                               sessionId: "B", root: "r", ts: "t"), seq: 2, now: 500, replay: false)
        let changes = s.markStale(now: 700, timeout: 600)
        XCTAssertEqual(changes, [.upserted(keyA)])
        XCTAssertEqual(s.sessions[keyA]?.state, .stale)
        XCTAssertEqual(s.sessions[keyB]?.state, .running)
    }
}
