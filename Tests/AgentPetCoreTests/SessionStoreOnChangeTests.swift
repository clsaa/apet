import XCTest
@testable import AgentPetCore

final class SessionStoreOnChangeTests: XCTestCase {

    /// B6: onChange 在真实状态变化时被调用，携带正确变更集
    func test_onChange_fires_with_changes_on_real_state_change() {
        let store = SessionStore()
        var captured: [StoreChange] = []
        store.onChange = { captured = $0 }
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        _ = store.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                        sessionId: "S", root: "r", ts: "t"), seq: 1, now: 0, replay: false)
        XCTAssertEqual(captured, [.upserted(key)])
    }

    /// B6: running 上的 busy 短路时 onChange 不被调用
    func test_onChange_not_fired_when_no_change() {
        let store = SessionStore()
        var callCount = 0
        store.onChange = { _ in callCount += 1 }
        // 先建会话（onChange 触发 1 次）
        _ = store.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                        sessionId: "S", root: "r", ts: "t"), seq: 1, now: 0, replay: false)
        callCount = 0  // 重置，只关注后续行为
        // busy 在 running 上是自环短路，不产生状态变更，不触发 onChange
        _ = store.apply(AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .busy,
                        sessionId: "S", root: "r", ts: "t"), seq: 2, now: 10, replay: false)
        XCTAssertEqual(callCount, 0)
    }
}
