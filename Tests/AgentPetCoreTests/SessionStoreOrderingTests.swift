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
        _ = s.apply(ev("E0", .sessionStart), seq: 1, now: 0, replay: false)
        _ = s.apply(ev("E1", .sessionEnd), seq: 2, now: 0, replay: false)
        let revive = s.apply(ev("E2", .busy), seq: 3, now: 0, replay: false)
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

    /// B4: activeSessions 按状态优先级排序 attention < stop < running
    func test_activeSessions_orders_attention_first_then_stop_then_running() {
        let s = SessionStore()
        _ = s.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                    sessionId: "A", root: "r", ts: "t"), seq: 1, now: 10, replay: false)
        _ = s.apply(AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .stop,
                    sessionId: "B", root: "r", ts: "t"), seq: 2, now: 20, replay: false)
        _ = s.apply(AgentEvent(v: 1, eventId: "E3", agent: "a", kind: .attention,
                    sessionId: "C", root: "r", ts: "t"), seq: 3, now: 30, replay: false)
        let ids = s.activeSessions().map { $0.key.sessionId }
        XCTAssertEqual(ids, ["C", "B", "A"])
    }

    /// B4: 同状态按 lastActiveAt 降序
    func test_activeSessions_same_state_sorted_by_lastActiveAt_desc() {
        let s = SessionStore()
        _ = s.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                    sessionId: "X", root: "r", ts: "t"), seq: 1, now: 10, replay: false)
        _ = s.apply(AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .sessionStart,
                    sessionId: "Y", root: "r", ts: "t"), seq: 2, now: 20, replay: false)
        let ids = s.activeSessions().map { $0.key.sessionId }
        XCTAssertEqual(ids, ["Y", "X"])
    }
}
