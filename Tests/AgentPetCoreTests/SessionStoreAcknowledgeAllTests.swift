import XCTest
@testable import AgentPetCore

final class SessionStoreAcknowledgeAllTests: XCTestCase {

    private func ev(_ id: String, _ kind: EventKind, _ sid: String) -> AgentEvent {
        AgentEvent(v: 1, eventId: id, agent: "claude", kind: kind, sessionId: sid, root: "/r", ts: "")
    }

    // TC-B1-FUNC-03 全部已读后 badgeCount 归零（所有 waiting 置 acknowledged）
    func test_acknowledgeAll_clearsBadge() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        for i in 1...2 {
            _ = ing.ingest(event: ev("start\(i)", .sessionStart, "s\(i)"), now: 90, replay: false)
            _ = ing.ingest(event: ev("stop\(i)", .stop, "s\(i)"), now: 100, replay: false)
        }
        XCTAssertEqual(store.summary().badgeCount, 2, "两个 waiting 会话应有 badge=2")
        _ = store.acknowledgeAll()
        XCTAssertEqual(store.summary().badgeCount, 0, "全部已读后 badge 应归零")
    }

    // TC-B1-FUNC-04 无 waiting 时 acknowledgeAll 安全 no-op
    func test_acknowledgeAll_noopWhenNoWaiting() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        _ = ing.ingest(event: ev("start1", .sessionStart, "s1"), now: 90, replay: false)  // running，无 waiting
        let changes = store.acknowledgeAll()
        XCTAssertTrue(changes.isEmpty, "无 waiting 会话时应返回空变更")
    }
}
