import XCTest
@testable import AgentPetCore

/// 会话"已读"态（红→黄）核心逻辑测试。
/// acknowledge / 自动清除 / summary 计数。
final class SessionStoreAcknowledgeTests: XCTestCase {

    private func makeEvent(eventId: String, agent: String = "claude", root: String = "/r",
                           sessionId: String = "s", kind: EventKind,
                           source: SessionSource = .hook) -> AgentEvent {
        var ev = AgentEvent(v: 1, eventId: eventId, agent: agent, kind: kind,
                            sessionId: sessionId, root: root, ts: "t")
        ev.source = source
        return ev
    }

    private let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")

    // MARK: - acknowledge

    /// TC-ACK-FUNC-001：waiting 会话 acknowledge → acknowledged==true，changes 非空
    func test_acknowledge_waiting_marks_read() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .stop), seq: 1, now: 100, replay: false)
        XCTAssertEqual(store.sessions[key]?.state, .waiting(.stop))
        XCTAssertEqual(store.sessions[key]?.acknowledged, false, "前置：默认未读")

        let changes = store.acknowledge(key: key)

        XCTAssertEqual(changes, [.upserted(key)], "应广播 upserted")
        XCTAssertEqual(store.sessions[key]?.acknowledged, true, "已读标记置 true")
        XCTAssertEqual(store.sessions[key]?.state, .waiting(.stop), "状态不变")
    }

    /// TC-ACK-FUNC-002：waiting(.attention) 同样可被 acknowledge
    func test_acknowledge_attention_marks_read() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .attention), seq: 1, now: 100, replay: false)
        XCTAssertEqual(store.sessions[key]?.state, .waiting(.attention))

        let changes = store.acknowledge(key: key)

        XCTAssertEqual(changes, [.upserted(key)])
        XCTAssertEqual(store.sessions[key]?.acknowledged, true)
    }

    /// TC-ACK-ERR-001：running 会话 acknowledge → no-op []
    func test_acknowledge_running_is_noop() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .busy), seq: 1, now: 100, replay: false)
        XCTAssertEqual(store.sessions[key]?.state, .running)

        let changes = store.acknowledge(key: key)

        XCTAssertEqual(changes, [], "running 不可标记已读")
        XCTAssertEqual(store.sessions[key]?.acknowledged, false)
    }

    /// TC-ACK-ERR-002：stale 会话 acknowledge → no-op []
    func test_acknowledge_stale_is_noop() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .busy), seq: 1, now: 100, replay: false)
        _ = store.markStale(now: 9999, timeout: 600)
        XCTAssertEqual(store.sessions[key]?.state, .stale)

        let changes = store.acknowledge(key: key)

        XCTAssertEqual(changes, [], "stale 不可标记已读")
        XCTAssertEqual(store.sessions[key]?.acknowledged, false)
    }

    /// TC-ACK-ERR-003：ended 会话 acknowledge → no-op []
    func test_acknowledge_ended_is_noop() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .sessionStart), seq: 1, now: 100, replay: false)
        _ = store.apply(makeEvent(eventId: "e2", kind: .sessionEnd), seq: 2, now: 200, replay: false)
        XCTAssertEqual(store.sessions[key]?.state, .ended)

        XCTAssertEqual(store.acknowledge(key: key), [], "ended 不可标记已读")
    }

    /// TC-ACK-PARAM-001：不存在的 key → []
    func test_acknowledge_missing_key_is_noop() {
        let store = SessionStore()
        let ghost = SessionKey(agent: "ghost", root: "/r", sessionId: "x")
        XCTAssertEqual(store.acknowledge(key: ghost), [], "不存在的 key 返回 []")
    }

    // MARK: - 自动清除（重新活跃 → 已读失效）

    /// TC-ACK-FUNC-003：waiting+已读 收到 busy → running 且 acknowledged==false；再收 stop → waiting 且未读
    func test_acknowledged_cleared_on_running_then_new_unread() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .stop), seq: 1, now: 100, replay: false)
        _ = store.acknowledge(key: key)
        XCTAssertEqual(store.sessions[key]?.acknowledged, true, "前置：已读")

        // 重新活跃 → running，已读失效
        _ = store.apply(makeEvent(eventId: "e2", kind: .busy), seq: 2, now: 200, replay: false)
        XCTAssertEqual(store.sessions[key]?.state, .running)
        XCTAssertEqual(store.sessions[key]?.acknowledged, false, "重新 running 后已读清除")

        // 再次 stop → 新的未读
        _ = store.apply(makeEvent(eventId: "e3", kind: .stop), seq: 3, now: 300, replay: false)
        XCTAssertEqual(store.sessions[key]?.state, .waiting(.stop))
        XCTAssertEqual(store.sessions[key]?.acknowledged, false, "新一轮 waiting 仍为未读")
    }

    // MARK: - summary().acknowledgedCount

    /// TC-ACK-FUNC-004：summary 统计 waiting 态且已读的会话数（stop/attention 都算）
    func test_summary_acknowledgedCount() {
        let store = SessionStore()
        // A: waiting(.stop) 已读
        _ = store.apply(makeEvent(eventId: "a1", sessionId: "A", kind: .stop), seq: 1, now: 100, replay: false)
        _ = store.acknowledge(key: SessionKey(agent: "claude", root: "/r", sessionId: "A"))
        // B: waiting(.attention) 已读
        _ = store.apply(makeEvent(eventId: "b1", sessionId: "B", kind: .attention), seq: 2, now: 100, replay: false)
        _ = store.acknowledge(key: SessionKey(agent: "claude", root: "/r", sessionId: "B"))
        // C: waiting(.stop) 未读
        _ = store.apply(makeEvent(eventId: "c1", sessionId: "C", kind: .stop), seq: 3, now: 100, replay: false)
        // D: running（不计）
        _ = store.apply(makeEvent(eventId: "d1", sessionId: "D", kind: .busy), seq: 4, now: 100, replay: false)

        let sum = store.summary()
        XCTAssertEqual(sum.acknowledgedCount, 2, "A+B 已读，C 未读，D running 不计")
        XCTAssertEqual(sum.waitingCount, 3, "A+B+C 共 3 个 waiting")
        XCTAssertEqual(sum.runningCount, 1)
    }

    /// TC-ACK-FUNC-005：空 store → acknowledgedCount==0
    func test_summary_acknowledgedCount_empty() {
        XCTAssertEqual(SessionStore().summary().acknowledgedCount, 0)
    }
}
