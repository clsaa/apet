import XCTest
@testable import AgentPetCore

/// `SessionMeta` + `SessionMetaMerger` 纯逻辑测试。
final class SessionMetaTests: XCTestCase {

    private func key(_ id: String, agent: String = "claude-code", root: String = "/Users/x/.claude") -> SessionKey {
        SessionKey(agent: agent, root: root, sessionId: id)
    }
    private func session(_ id: String, createdAt: Double? = nil) -> Session {
        Session(key: key(id), state: .running, lastSeq: 0, lastActiveAt: 100, createdAt: createdAt)
    }

    // MARK: - metaKey 含 root

    func test_metaKey_includesRoot() {
        let k1 = SessionMetaMerger.metaKey(key("s", root: "/a/.claude"))
        let k2 = SessionMetaMerger.metaKey(key("s", root: "/b/.claude"))
        XCTAssertNotEqual(k1, k2, "含 root，多 profile 不串味")
        XCTAssertEqual(k1, "claude-code::/a/.claude::s")
    }

    // MARK: - apply 镜像 favorite/customName

    func test_apply_mirrorsFavoriteAndCustomName() {
        let meta = SessionMeta(favorite: true, customName: "我的活")
        let s = SessionMetaMerger.apply(into: session("s"), meta: meta)
        XCTAssertTrue(s.favorite)
        XCTAssertEqual(s.customName, "我的活")
    }

    func test_apply_nilMeta_leavesDefaults() {
        let s = SessionMetaMerger.apply(into: session("s"), meta: nil)
        XCTAssertFalse(s.favorite)
        XCTAssertNil(s.customName)
    }

    // MARK: - firstSeenAt → createdAt 取 min

    func test_apply_createdAt_takesMinOfExistingAndFirstSeen() {
        // 已有 createdAt=200，meta.firstSeenAt=100 → 取 100（更早）
        let meta = SessionMeta(firstSeenAt: 100)
        let s = SessionMetaMerger.apply(into: session("s", createdAt: 200), meta: meta)
        XCTAssertEqual(s.createdAt, 100)
    }

    func test_apply_createdAt_keepsExisting_whenFirstSeenLater() {
        let meta = SessionMeta(firstSeenAt: 300)
        let s = SessionMetaMerger.apply(into: session("s", createdAt: 200), meta: meta)
        XCTAssertEqual(s.createdAt, 200)
    }

    // MARK: - merge 规则（last-non-nil-wins / firstSeenAt min）

    func test_merge_customName_lastNonNilWins() {
        let old = SessionMeta(customName: "旧名")
        let new = SessionMeta(customName: nil)
        // nil 不覆盖已有名
        XCTAssertEqual(SessionMeta.merge(old, new).customName, "旧名")
        XCTAssertEqual(SessionMeta.merge(old, SessionMeta(customName: "新名")).customName, "新名")
    }

    func test_merge_firstSeenAt_takesMin() {
        let a = SessionMeta(firstSeenAt: 500)
        let b = SessionMeta(firstSeenAt: 200)
        XCTAssertEqual(SessionMeta.merge(a, b).firstSeenAt, 200)
    }
}
