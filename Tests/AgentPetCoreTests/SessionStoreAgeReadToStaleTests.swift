import XCTest
@testable import AgentPetCore

/// 精修 3：已读（黄）会话超时自动转灰（闲置）逻辑单测。
final class SessionStoreAgeReadToStaleTests: XCTestCase {

    private func makeEvent(eventId: String, sessionId: String = "s", kind: EventKind) -> AgentEvent {
        AgentEvent(v: 1, eventId: eventId, agent: "claude", kind: kind,
                   sessionId: sessionId, root: "/r", ts: "t")
    }

    private func key(_ sessionId: String = "s") -> SessionKey {
        SessionKey(agent: "claude", root: "/r", sessionId: sessionId)
    }

    // TC-AGR-FUNC-001：waiting+acknowledged+超时 → stale，acknowledged 重置为 false
    func test_waiting_acknowledged_expired_becomesStale() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .stop), seq: 1, now: 100, replay: false)
        _ = store.acknowledge(key: key())
        XCTAssertEqual(store.sessions[key()]?.state, .waiting(.stop))
        XCTAssertEqual(store.sessions[key()]?.acknowledged, true, "前置：已读")

        let changes = store.ageReadToStale(now: 3701, readGrayAfter: 3600)  // 3701-100=3601 > 3600

        XCTAssertEqual(changes, [.upserted(key())], "超时后应广播 upserted")
        XCTAssertEqual(store.sessions[key()]?.state, .stale, "转灰后状态为 stale")
        XCTAssertEqual(store.sessions[key()]?.acknowledged, false, "转灰后 acknowledged 重置为 false")
    }

    // TC-AGR-FUNC-002：waiting+acknowledged 但未超时 → no-op
    func test_waiting_acknowledged_notExpired_stays() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .stop), seq: 1, now: 100, replay: false)
        _ = store.acknowledge(key: key())

        let changes = store.ageReadToStale(now: 3000, readGrayAfter: 3600)  // 3000-100=2900 < 3600

        XCTAssertEqual(changes, [], "未超时应 no-op")
        XCTAssertEqual(store.sessions[key()]?.state, .waiting(.stop), "状态不变")
        XCTAssertEqual(store.sessions[key()]?.acknowledged, true, "已读标记不变")
    }

    // TC-AGR-FUNC-003：waiting 但未 acknowledge → 不受影响
    func test_waiting_notAcknowledged_unaffected() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .stop), seq: 1, now: 100, replay: false)
        // 不调用 acknowledge

        let changes = store.ageReadToStale(now: 9999, readGrayAfter: 3600)

        XCTAssertEqual(changes, [], "未 acknowledge 的 waiting 不受影响")
        XCTAssertEqual(store.sessions[key()]?.state, .waiting(.stop))
    }

    // TC-AGR-FUNC-004：running 会话 → 不受影响
    func test_running_unaffected() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .busy), seq: 1, now: 100, replay: false)

        let changes = store.ageReadToStale(now: 9999, readGrayAfter: 3600)

        XCTAssertEqual(changes, [], "running 不受影响")
        XCTAssertEqual(store.sessions[key()]?.state, .running)
    }

    // TC-AGR-FUNC-005：stale 会话（不含 waiting）→ 不受影响
    func test_stale_unaffected() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .busy), seq: 1, now: 100, replay: false)
        _ = store.markStale(now: 9999, timeout: 600)
        XCTAssertEqual(store.sessions[key()]?.state, .stale)

        let changes = store.ageReadToStale(now: 99999, readGrayAfter: 3600)

        XCTAssertEqual(changes, [], "stale 会话不受影响")
    }

    // TC-AGR-FUNC-006：空 store → []
    func test_empty_store_returnsEmpty() {
        let store = SessionStore()
        XCTAssertEqual(store.ageReadToStale(now: 9999, readGrayAfter: 3600), [])
    }

    // TC-AGR-FUNC-007：多会话，只超时的已读转灰，其余不动
    func test_multiSession_onlyExpiredAcknowledged_converted() {
        let store = SessionStore()
        // A: waiting+acknowledged，lastActiveAt=100，超时
        _ = store.apply(makeEvent(eventId: "a1", sessionId: "A", kind: .stop), seq: 1, now: 100, replay: false)
        _ = store.acknowledge(key: key("A"))
        // B: waiting+acknowledged，lastActiveAt=10000，未超时
        _ = store.apply(makeEvent(eventId: "b1", sessionId: "B", kind: .stop), seq: 2, now: 10000, replay: false)
        _ = store.acknowledge(key: key("B"))
        // C: waiting 未读，超时也不动
        _ = store.apply(makeEvent(eventId: "c1", sessionId: "C", kind: .stop), seq: 3, now: 100, replay: false)

        let changes = store.ageReadToStale(now: 13701, readGrayAfter: 3600)  // 13701-100=3601>3600; 13701-10000=3701>3600

        // B: 13701-10000=3701 > 3600 → 也超时转灰
        // A: 13701-100=13601 > 3600 → 超时转灰
        // C: 未 acknowledged → 不转
        let changedIds = Set(changes.compactMap { change -> String? in
            if case .upserted(let k) = change { return k.sessionId }
            return nil
        })
        XCTAssertTrue(changedIds.contains("A"), "A 超时应转灰")
        XCTAssertTrue(changedIds.contains("B"), "B 超时应转灰")
        XCTAssertFalse(changedIds.contains("C"), "C 未 acknowledged 不转")
        XCTAssertEqual(store.sessions[key("C")]?.state, .waiting(.stop), "C 状态不变")
    }
}
