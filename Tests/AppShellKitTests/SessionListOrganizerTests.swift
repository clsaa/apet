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

    func test_filter_matchesAgent() {
        // 交互评审 B4:搜索应能命中 agent 名(「搜 opencode 只看这个 agent」)。
        let sessions = [session(id: "1", agent: "opencode", state: .running),
                        session(id: "2", agent: "claude-code", state: .running)]
        let r = SessionListOrganizer.organize(sessions: sessions, dimension: .agent, filter: "opencode", now: 0)
        XCTAssertEqual(r.groups.flatMap { $0.rows }.map(\.sessionId), ["1"])
    }

    func test_filter_matchesCustomName() {
        // F7 重命名后按新名字搜索必须命中（产品评审 M5：看得见的名字要搜得到）
        var s = session(id: "1", state: .running, title: "orig-title")
        s.customName = "大促需求"
        let r = SessionListOrganizer.organize(sessions: [s], dimension: .agent, filter: "大促", now: 0)
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

    // 评审补齐（测试 M4）：「本周」桶 + 组序 + 每组归属全值断言（2/6/7/8 天前四会话）。
    func test_group_byDate_thisWeekBucket_andFullOrder() {
        let dayN = 100
        let noon = Double(dayN) * 86_400 + 43_200  // 第100日正午
        let sessions = [
            session(id: "d2", state: .running, lastActiveAt: noon - 86_400 * 2),  // 本周
            session(id: "d6", state: .running, lastActiveAt: noon - 86_400 * 6),  // 本周
            session(id: "d7", state: .running, lastActiveAt: noon - 86_400 * 7),  // 更早（== nowDay-7）
            session(id: "d8", state: .running, lastActiveAt: noon - 86_400 * 8),  // 更早
        ]
        let r = SessionListOrganizer.organize(sessions: sessions, dimension: .date, filter: "", now: noon)
        XCTAssertEqual(r.groups.map { $0.title }, ["本周", "更早"], "组序固定：本周在更早之前")
        XCTAssertEqual(r.groups[0].rows.map { $0.sessionId }, ["d2", "d6"])
        XCTAssertEqual(r.groups[1].rows.map { $0.sessionId }, ["d7", "d8"], "7 天整属「更早」")
    }

    // M3-D-B:organizeFlat 平铺 + U1 跨tab常驻
    func test_organizeFlat_tabFilters_and_pinsUnreadWaiting() {
        let run = session(id: "a", state: .running)
        let waitUnread = session(id: "b", state: .waiting(.stop))
        let out = SessionListOrganizer.organizeFlat(sessions: [run, waitUnread], tab: .all, filter: "", now: 2000)
        XCTAssertEqual(out.pinned.map(\.sessionId), ["b"])
        XCTAssertEqual(out.rest.map(\.sessionId), ["a"])
    }
    func test_organizeFlat_runningTab_excludesOthers() {
        let out = SessionListOrganizer.organizeFlat(
            sessions: [session(id: "a", state: .running), session(id: "b", state: .stale)],
            tab: .running, filter: "", now: 2000)
        XCTAssertEqual((out.pinned + out.rest).map(\.sessionId), ["a"])
    }
    /// U1:未读 waiting 跨 tab 常驻——选「收藏」tab 且它非收藏,仍在 pinned。
    func test_organizeFlat_unreadWaiting_pinnedAcrossTabs() {
        let waitUnread = session(id: "b", state: .waiting(.stop))
        let out = SessionListOrganizer.organizeFlat(sessions: [waitUnread], tab: .favorites, filter: "", now: 2000)
        XCTAssertEqual(out.pinned.map(\.sessionId), ["b"], "等你会话不被 favorites tab 过滤掉")
    }

    func test_organizeFlat_readTab_onlyAcknowledgedWaiting() {
        let read = session(id: "r", state: .waiting(.stop), acknowledged: true)
        let unread = session(id: "u", state: .waiting(.stop), acknowledged: false)
        let run = session(id: "g", state: .running)
        let out = SessionListOrganizer.organizeFlat(sessions: [read, unread, run], tab: .read, filter: "", now: 2000)
        XCTAssertEqual(out.pinned.map(\.sessionId), ["u"], "未读 waiting 跨 tab 常驻")
        XCTAssertEqual(out.rest.map(\.sessionId), ["r"], "read tab rest 只含已读 waiting")
    }
    func test_organizeFlat_favorite_sortsFirst_stable() {
        var fav = session(id: "fav", state: .running); fav.favorite = true
        let n1 = session(id: "n1", state: .running); let n2 = session(id: "n2", state: .running)
        let out = SessionListOrganizer.organizeFlat(sessions: [n1, fav, n2], tab: .all, filter: "", now: 2000)
        XCTAssertEqual(out.rest.map(\.sessionId), ["fav", "n1", "n2"], "收藏优先,非收藏保输入序")
    }
    func test_organizeFlat_pinned_stable_favoriteFirst() {
        var favA = session(id: "favA", state: .waiting(.stop)); favA.favorite = true
        let n1 = session(id: "n1", state: .waiting(.stop)); let n2 = session(id: "n2", state: .waiting(.stop))
        var favB = session(id: "favB", state: .waiting(.stop)); favB.favorite = true
        let out = SessionListOrganizer.organizeFlat(sessions: [n1, favA, n2, favB], tab: .all, filter: "", now: 2000)
        XCTAssertEqual(out.pinned.map(\.sessionId), ["favA", "favB", "n1", "n2"], "pinned 稳定:收藏优先+输入序")
    }
    func test_organizeFlat_row_carriesGroupsAndBundleId() {
        var s = Session(key: SessionKey(agent: "claude-code", root: "/r", sessionId: "x"),
                        state: .running, cwd: nil, title: nil, terminal: TerminalRef(kind: .warp),
                        lastSeq: 1, lastActiveAt: 1000, acknowledged: false)
        s.groups = ["工作"]
        let out = SessionListOrganizer.organizeFlat(sessions: [s], tab: .all, filter: "", now: 2000)
        let row = out.rest.first!
        XCTAssertEqual(row.groups, ["工作"], "分组注入链贯通 organizeFlat 出口")
        XCTAssertEqual(row.terminalBundleId, "dev.warp.Warp-Stable")
    }
}
