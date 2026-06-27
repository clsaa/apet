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
        _ = s.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionEnd,
                    sessionId: "S", root: "r", ts: "t"), seq: 1, now: 0, replay: false)
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
}
