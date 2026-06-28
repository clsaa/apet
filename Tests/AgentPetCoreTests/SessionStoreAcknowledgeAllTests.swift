import XCTest
@testable import AgentPetCore

final class SessionStoreAcknowledgeAllTests: XCTestCase {

    private func ev(_ id: String, _ kind: EventKind, _ sid: String) -> AgentEvent {
        AgentEvent(v: 1, eventId: id, agent: "claude", kind: kind, sessionId: sid, root: "/r", ts: "")
    }
    private func key(_ sid: String) -> SessionKey { SessionKey(agent: "claude", root: "/r", sessionId: sid) }

    // TC-B1-FUNC-03 全部已读后 badgeCount 归零 + 每个会话 acknowledged 直接断言
    func test_acknowledgeAll_clearsBadge_andSetsFlags() {
        let store = SessionStore()
        for sid in ["A", "B"] {
            _ = store.apply(ev("start\(sid)", .sessionStart, sid), seq: 1, now: 90, replay: false)
            _ = store.apply(ev("stop\(sid)", .stop, sid), seq: 2, now: 100, replay: false)
        }
        XCTAssertEqual(store.summary().badgeCount, 2)
        _ = store.acknowledgeAll()
        XCTAssertEqual(store.summary().badgeCount, 0)
        XCTAssertEqual(store.sessions[key("A")]?.acknowledged, true)
        XCTAssertEqual(store.sessions[key("B")]?.acknowledged, true)
    }

    // TC-B1-FUNC-05 混合态：只动未读 waiting，不碰 running/stale/已读；changes 精确；幂等
    func test_acknowledgeAll_onlyTouchesUnreadWaiting() {
        let store = SessionStore()
        // A=waiting(.stop)未读, B=waiting(.attention)未读
        _ = store.apply(ev("a", .stop, "A"), seq: 1, now: 100, replay: false)
        _ = store.apply(ev("b", .attention, "B"), seq: 2, now: 100, replay: false)
        // C=waiting(.stop)已读
        _ = store.apply(ev("c", .stop, "C"), seq: 3, now: 100, replay: false)
        _ = store.acknowledge(key: key("C"))
        // E=running → markStale 打成 stale（此时只有 E 在 running）
        _ = store.apply(ev("e", .busy, "E"), seq: 4, now: 100, replay: false)
        _ = store.markStale(now: 9999, timeout: 600)
        // D=running（markStale 之后建立，保持 running）
        _ = store.apply(ev("d", .busy, "D"), seq: 5, now: 9999, replay: false)

        XCTAssertEqual(store.sessions[key("D")]?.state, .running, "前置：D running")
        XCTAssertEqual(store.sessions[key("E")]?.state, .stale, "前置：E stale")

        let changes = store.acknowledgeAll()

        // changes 精确等于未读的 A、B
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.contains(.upserted(key("A"))))
        XCTAssertTrue(changes.contains(.upserted(key("B"))))
        XCTAssertFalse(changes.contains(.upserted(key("C"))))
        XCTAssertFalse(changes.contains(.upserted(key("D"))))
        XCTAssertFalse(changes.contains(.upserted(key("E"))))
        // 直接断言每个会话
        XCTAssertEqual(store.sessions[key("A")]?.acknowledged, true)
        XCTAssertEqual(store.sessions[key("B")]?.acknowledged, true)
        XCTAssertEqual(store.sessions[key("C")]?.acknowledged, true, "已读保持")
        XCTAssertEqual(store.sessions[key("D")]?.state, .running, "running 不被污染")
        XCTAssertEqual(store.sessions[key("E")]?.state, .stale, "stale 不被污染")

        // 幂等：第二次无未读 → []
        XCTAssertEqual(store.acknowledgeAll(), [])
    }

    // TC-B1-FUNC-06 无 waiting 时安全 no-op
    func test_acknowledgeAll_noopWhenNoWaiting() {
        let store = SessionStore()
        _ = store.apply(ev("d", .busy, "D"), seq: 1, now: 100, replay: false)  // running
        XCTAssertEqual(store.acknowledgeAll(), [])
    }
}
