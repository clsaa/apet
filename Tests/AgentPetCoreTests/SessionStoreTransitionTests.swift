import XCTest
@testable import AgentPetCore

final class SessionStoreTransitionTests: XCTestCase {
    private func ev(_ id: String, _ kind: EventKind, reason: WaitingReason? = nil,
                   sid: String = "S", root: String = "r") -> AgentEvent {
        AgentEvent(v: 1, eventId: id, agent: "a", kind: kind, sessionId: sid, root: root,
                   reason: reason, ts: "t")
    }

    func test_session_start_creates_running_and_broadcasts() {
        let s = SessionStore()
        let changes = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        XCTAssertEqual(changes, [.upserted(key)])
        XCTAssertEqual(s.sessions[key]?.state, .running)
        XCTAssertEqual(s.sessions[key]?.lastSeq, 1)
    }

    func test_stop_moves_running_to_waiting_stop() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        _ = s.apply(ev("E2", .stop, reason: .stop), seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .waiting(.stop))
    }

    func test_attention_moves_to_waiting_attention() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        _ = s.apply(ev("E2", .attention, reason: .attention), seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .waiting(.attention))
    }

    func test_waiting_then_busy_returns_to_running() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .stop, reason: .stop), seq: 1, now: 0, replay: false)
        _ = s.apply(ev("E2", .busy), seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .running)
    }

    func test_event_without_explicit_reason_infers_from_kind() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .attention), seq: 1, now: 0, replay: false)  // reason 缺省
        XCTAssertEqual(s.sessions.values.first?.state, .waiting(.attention))
    }

    func test_ended_is_terminal_ignores_all_events() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionEnd), seq: 1, now: 0, replay: false)
        _ = s.apply(ev("E2", .sessionStart), seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .ended)
    }
}
