import XCTest
@testable import AgentPetCore

final class SessionStoreOrderingTests: XCTestCase {
    private func ev(_ id: String, _ kind: EventKind, reason: WaitingReason? = nil) -> AgentEvent {
        AgentEvent(v: 1, eventId: id, agent: "a", kind: kind, sessionId: "S", root: "r",
                   reason: reason, ts: "t")
    }

    func test_duplicate_eventId_is_ignored() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        let dup = s.apply(ev("E1", .stop), seq: 2, now: 0, replay: false) // 同 eventId
        XCTAssertEqual(dup, [])
        XCTAssertEqual(s.sessions.values.first?.state, .running) // 未被 stop 影响
    }

    func test_out_of_order_lower_seq_is_ignored() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 5, now: 0, replay: false)
        let stale = s.apply(ev("E2", .busy), seq: 3, now: 0, replay: false) // seq 落后
        XCTAssertEqual(stale, [])
        XCTAssertEqual(s.sessions.values.first?.lastSeq, 5)
    }

    func test_ended_is_terminal_and_cannot_be_revived() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionEnd), seq: 1, now: 0, replay: false)
        let revive = s.apply(ev("E2", .busy), seq: 2, now: 0, replay: false)
        XCTAssertEqual(revive, [])
        XCTAssertEqual(s.sessions.values.first?.state, .ended)
    }

    func test_busy_on_running_does_not_broadcast_but_updates_lastActiveAt() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 10, replay: false)
        let changes = s.apply(ev("E2", .busy), seq: 2, now: 20, replay: false)
        XCTAssertEqual(changes, [])                       // 不广播
        XCTAssertEqual(s.sessions.values.first?.lastActiveAt, 20) // 但喂了 STALE 计时
        XCTAssertEqual(s.sessions.values.first?.lastSeq, 2)
    }

    func test_real_state_change_does_broadcast() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        let changes = s.apply(ev("E2", .stop), seq: 2, now: 0, replay: false)
        XCTAssertEqual(changes, [.upserted(SessionKey(agent: "a", root: "r", sessionId: "S"))])
    }
}
