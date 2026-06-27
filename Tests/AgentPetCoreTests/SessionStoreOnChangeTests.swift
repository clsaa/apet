import XCTest
@testable import AgentPetCore

final class SessionStoreOnChangeTests: XCTestCase {

    /// B6: onChange 在真实状态变化时被调用，携带正确变更集
    func test_onChange_fires_with_changes_on_real_state_change() {
        let store = SessionStore()
        var captured: [StoreChange] = []
        store.addChangeHandler { changes, _ in captured = changes }
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        _ = store.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                        sessionId: "S", root: "r", ts: "t"), seq: 1, now: 0, replay: false)
        XCTAssertEqual(captured, [.upserted(key)])
    }

    /// B6: running 上的 busy 短路时 onChange 不被调用
    func test_onChange_not_fired_when_no_change() {
        let store = SessionStore()
        var callCount = 0
        store.addChangeHandler { _, _ in callCount += 1 }
        // 先建会话（onChange 触发 1 次）
        _ = store.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                        sessionId: "S", root: "r", ts: "t"), seq: 1, now: 0, replay: false)
        callCount = 0  // 重置，只关注后续行为
        // busy 在 running 上是自环短路，不产生状态变更，不触发 onChange
        _ = store.apply(AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .busy,
                        sessionId: "S", root: "r", ts: "t"), seq: 2, now: 10, replay: false)
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - H3 新增：replay 链路修复 + 扇出

    /// replay=true 时 session_start 建会话 → state 为 .stale（非 running）
    func test_replay_running_becomes_stale() {
        let store = SessionStore()
        _ = store.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                        sessionId: "S", root: "r", ts: "t"), seq: 1, now: 0, replay: true)
        XCTAssertEqual(store.sessions.values.first?.state, .stale)
    }

    /// handler 收到的 isReplay Bool 与 apply 调用时一致
    func test_replay_flag_delivered_to_handler() {
        let store = SessionStore()
        var capturedReplay: Bool? = nil
        store.addChangeHandler { _, isReplay in capturedReplay = isReplay }

        // replay=true
        _ = store.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionEnd,
                        sessionId: "S1", root: "r", ts: "t"), seq: 1, now: 0, replay: true)
        // sessionEnd 首事件不建会话，不会触发 handler；改用 stop 建会话
        _ = store.apply(AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .stop,
                        sessionId: "S2", root: "r", ts: "t"), seq: 2, now: 0, replay: true)
        XCTAssertEqual(capturedReplay, true)

        // replay=false
        _ = store.apply(AgentEvent(v: 1, eventId: "E3", agent: "a", kind: .stop,
                        sessionId: "S3", root: "r", ts: "t"), seq: 3, now: 0, replay: false)
        XCTAssertEqual(capturedReplay, false)
    }

    /// 注册 2 个 handler，一次有状态变化的 apply → 两个都被调用
    func test_multiple_handlers_all_fire() {
        let store = SessionStore()
        var count1 = 0
        var count2 = 0
        store.addChangeHandler { _, _ in count1 += 1 }
        store.addChangeHandler { _, _ in count2 += 1 }
        _ = store.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                        sessionId: "S", root: "r", ts: "t"), seq: 1, now: 0, replay: false)
        XCTAssertEqual(count1, 1)
        XCTAssertEqual(count2, 1)
    }
}
