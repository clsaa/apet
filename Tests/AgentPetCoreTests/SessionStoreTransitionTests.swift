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
        _ = s.apply(ev("E0", .sessionStart), seq: 1, now: 0, replay: false)
        _ = s.apply(ev("E1", .sessionEnd), seq: 2, now: 0, replay: false)
        _ = s.apply(ev("E2", .sessionStart), seq: 3, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .ended)
    }

    /// B3: 首事件即 session_end 不建会话
    func test_first_event_session_end_is_ignored() {
        let s = SessionStore()
        let changes = s.apply(ev("E1", .sessionEnd), seq: 1, now: 0, replay: false)
        XCTAssertEqual(changes, [])
        XCTAssertTrue(s.sessions.isEmpty)
    }

    // MARK: - H2 补强

    /// 空 store 首事件为 stop（无 reason）→ 新建会话 state .waiting(.stop)
    func test_first_event_stop_creates_waiting() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .stop), seq: 1, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .waiting(.stop))
    }

    /// running 收到 stop（无 reason 字段）→ infer .stop
    func test_stop_without_reason_infers_stop() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        _ = s.apply(ev("E2", .stop), seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .waiting(.stop))
    }

    /// waiting(.attention) → stop(reason:.stop) → waiting(.stop)，且广播
    func test_waiting_reason_updated_attention_to_stop() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .attention, reason: .attention), seq: 1, now: 0, replay: false)
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        XCTAssertEqual(s.sessions[key]?.state, .waiting(.attention))
        let changes = s.apply(ev("E2", .stop, reason: .stop), seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions[key]?.state, .waiting(.stop))
        XCTAssertEqual(changes, [.upserted(key)])
    }

    /// unknown 事件（.unknown("compacting")）不改状态、不广播，但 lastSeq 更新
    func test_unknown_event_keeps_state_and_no_broadcast() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        let changes = s.apply(ev("E2", .unknown("compacting")), seq: 2, now: 0, replay: false)
        XCTAssertEqual(changes, [])
        XCTAssertEqual(s.sessions[key]?.state, .running)
        XCTAssertEqual(s.sessions[key]?.lastSeq, 2)
    }

    /// plugin_error 不改状态、不广播，lastSeq 更新
    func test_plugin_error_keeps_state_and_no_broadcast() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        let changes = s.apply(ev("E2", .pluginError), seq: 2, now: 0, replay: false)
        XCTAssertEqual(changes, [])
        XCTAssertEqual(s.sessions[key]?.state, .running)
        XCTAssertEqual(s.sessions[key]?.lastSeq, 2)
    }

    /// stale 会话收到 sessionEnd → state .ended，广播
    func test_stale_to_ended() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        _ = s.markStale(now: 9999, timeout: 600)
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        XCTAssertEqual(s.sessions[key]?.state, .stale)
        let changes = s.apply(ev("E2", .sessionEnd), seq: 2, now: 9999, replay: false)
        XCTAssertEqual(s.sessions[key]?.state, .ended)
        XCTAssertEqual(changes, [.upserted(key)])
    }
}
