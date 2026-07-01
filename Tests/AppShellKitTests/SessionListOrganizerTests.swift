import XCTest
@testable import AppShellKit
import AgentPetCore

/// 纯函数 `SessionListOrganizer.organize` 的单元测试：搜索过滤 + 置顶「等你」+ 分组。
final class SessionListOrganizerTests: XCTestCase {

    private func session(id: String, agent: String = "claude-code", root: String = "/Users/x/.claude",
                         state: SessionState, cwd: String? = nil, title: String? = nil,
                         acknowledged: Bool = false, lastActiveAt: Double = 0, seq: Int = 0) -> Session {
        Session(key: SessionKey(agent: agent, root: root, sessionId: id),
                state: state, cwd: cwd, title: title, lastSeq: seq,
                lastActiveAt: lastActiveAt, acknowledged: acknowledged)
    }

    // MARK: - 搜索过滤

    func test_filter_matchesTitle_caseInsensitive() {
        let sessions = [
            session(id: "1", state: .running, title: "ApiServer"),
            session(id: "2", state: .running, title: "webapp"),
        ]
        let r = SessionListOrganizer.organize(sessions: sessions, dimension: .agent, filter: "API", now: 0)
        let ids = r.groups.flatMap { $0.rows }.map { $0.id }
        XCTAssertTrue(ids.contains { $0.hasSuffix("|1") })
        XCTAssertFalse(ids.contains { $0.hasSuffix("|2") })
    }

    func test_filter_matchesCwd() {
        let sessions = [
            session(id: "1", state: .running, cwd: "/Users/x/proj-alpha"),
            session(id: "2", state: .running, cwd: "/Users/x/beta"),
        ]
        let r = SessionListOrganizer.organize(sessions: sessions, dimension: .agent, filter: "alpha", now: 0)
        XCTAssertEqual(r.groups.flatMap { $0.rows }.count, 1)
    }

    func test_filter_matchesSessionId() {
        let sessions = [session(id: "abc123", state: .running)]
        let r = SessionListOrganizer.organize(sessions: sessions, dimension: .agent, filter: "abc", now: 0)
        XCTAssertEqual(r.groups.flatMap { $0.rows }.count, 1)
    }

    func test_filter_empty_returnsAll() {
        let sessions = [session(id: "1", state: .running), session(id: "2", state: .running)]
        let r = SessionListOrganizer.organize(sessions: sessions, dimension: .agent, filter: "", now: 0)
        XCTAssertEqual(r.groups.flatMap { $0.rows }.count, 2)
    }

    // MARK: - 置顶「等你」（未读 waiting）

    func test_pinned_containsUnreadWaiting_notReadNotRunning() {
        let sessions = [
            session(id: "wait", state: .waiting(.stop), acknowledged: false),
            session(id: "attn", state: .waiting(.attention), acknowledged: false),
            session(id: "read", state: .waiting(.stop), acknowledged: true),
            session(id: "run", state: .running),
        ]
        let r = SessionListOrganizer.organize(sessions: sessions, dimension: .status, filter: "", now: 0)
        let pinnedIds = r.pinned.map { $0.id }
        XCTAssertTrue(pinnedIds.contains { $0.hasSuffix("|wait") })
        XCTAssertTrue(pinnedIds.contains { $0.hasSuffix("|attn") })
        XCTAssertFalse(pinnedIds.contains { $0.hasSuffix("|read") })
        XCTAssertFalse(pinnedIds.contains { $0.hasSuffix("|run") })
        // 置顶的行不再出现在分组里
        let groupIds = r.groups.flatMap { $0.rows }.map { $0.id }
        XCTAssertFalse(groupIds.contains { $0.hasSuffix("|wait") })
    }

    // MARK: - 按状态分组（非置顶部分）

    func test_group_byStatus() {
        let sessions = [
            session(id: "run", state: .running),
            session(id: "read", state: .waiting(.stop), acknowledged: true),
            session(id: "stale", state: .stale),
        ]
        let r = SessionListOrganizer.organize(sessions: sessions, dimension: .status, filter: "", now: 0)
        let titles = r.groups.map { $0.title }
        XCTAssertTrue(titles.contains("进行中"))
        XCTAssertTrue(titles.contains("已读"))
        XCTAssertTrue(titles.contains("超时"))
    }

    // MARK: - 按 Agent 分组

    func test_group_byAgent() {
        let sessions = [
            session(id: "1", agent: "claude-code", state: .running),
            session(id: "2", agent: "qoder", state: .running),
        ]
        let r = SessionListOrganizer.organize(sessions: sessions, dimension: .agent, filter: "", now: 0)
        XCTAssertEqual(Set(r.groups.map { $0.title }), ["claude-code", "qoder"])
    }

    // MARK: - 按日期分组（UTC 日；now 注入，跨午夜边界）

    func test_group_byDate_todayYesterdayOlder() {
        let now = 1_000_000.0 + 86_400.0 * 10 + 3600 // 第10天 01:00 UTC 附近
        let today = now - 1800          // 同一 UTC 日
        let yesterday = now - 86_400    // 前一 UTC 日
        let older = now - 86_400 * 8    // 8 天前
        let sessions = [
            session(id: "t", state: .running, lastActiveAt: today),
            session(id: "y", state: .running, lastActiveAt: yesterday),
            session(id: "o", state: .running, lastActiveAt: older),
        ]
        let r = SessionListOrganizer.organize(sessions: sessions, dimension: .date, filter: "", now: now)
        let titles = r.groups.map { $0.title }
        XCTAssertTrue(titles.contains("今天"))
        XCTAssertTrue(titles.contains("昨天"))
        XCTAssertTrue(titles.contains("更早"))
    }
}
