import XCTest
@testable import AgentPetCore

final class SessionTabFilterTests: XCTestCase {
    private func s(_ id: String, state: SessionState = .running, fav: Bool = false,
                   ack: Bool = false, groups: [String] = []) -> Session {
        var x = Session(key: SessionKey(agent: "claude-code", root: "/r", sessionId: id),
                        state: state, cwd: nil, title: nil, terminal: nil,
                        lastSeq: 1, lastActiveAt: 1000, acknowledged: ack)
        x.favorite = fav; x.groups = groups; return x
    }
    func test_all_returnsEverything() {
        XCTAssertEqual(SessionTabFilter.filter([s("a"), s("b", state: .waiting(.stop))], tab: .all).count, 2)
    }
    func test_favorites() {
        XCTAssertEqual(SessionTabFilter.filter([s("a", fav: true), s("b")], tab: .favorites).map(\.key.sessionId), ["a"])
    }
    func test_running() {
        XCTAssertEqual(SessionTabFilter.filter([s("a"), s("b", state: .stale)], tab: .running).map(\.key.sessionId), ["a"])
    }
    func test_read_acknowledgedWaiting() {
        let read = s("a", state: .waiting(.stop), ack: true)
        let unread = s("b", state: .waiting(.stop), ack: false)
        XCTAssertEqual(SessionTabFilter.filter([read, unread], tab: .read).map(\.key.sessionId), ["a"])
    }
    func test_group_multiMember() {
        let x = s("a", groups: ["工作", "重要"])
        XCTAssertEqual(SessionTabFilter.filter([x, s("b")], tab: .group("工作")).map(\.key.sessionId), ["a"])
        XCTAssertEqual(SessionTabFilter.filter([x], tab: .group("重要")).count, 1)
        XCTAssertTrue(SessionTabFilter.filter([x], tab: .group("不存在")).isEmpty)
    }
    func test_encode_roundtrip() {
        for t in [SessionTab.all, .favorites, .running, .read, .group("工作:含冒号")] {
            XCTAssertEqual(SessionTab(encoded: t.encoded), t)
        }
        XCTAssertEqual(SessionTab(encoded: "垃圾未知"), .all)
    }
}
