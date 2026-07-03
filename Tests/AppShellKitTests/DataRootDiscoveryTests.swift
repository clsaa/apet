import XCTest
@testable import AppShellKit

final class DataRootDiscoveryTests: XCTestCase {

    // MARK: - MockFileOps

    final class MockFileOps: FileOps {
        var existing = Set<String>()
        var dirs = [String: [String]]()

        func fileExists(_ p: String) -> Bool { existing.contains(p) }
        func createDir(_ p: String) throws {}
        func copyItem(from: String, to: String) throws {}
        func removeItem(_ p: String) throws {}
        func contentsOfDir(_ p: String) -> [String] { dirs[p] ?? [] }
    }

    private func dr(_ p: String) -> DataRoot { DataRoot(path: p, agent: "claude-code") }

    // MARK: - Tests from brief

    func test_discovers_claude_and_profilesWithProjects() {
        let fo = MockFileOps()
        fo.existing.insert("/h/.claude")
        fo.dirs["/h/.claude-profiles"] = ["work", "junk"]
        fo.existing.insert("/h/.claude-profiles/work/projects")   // work 含 projects/ → 纳入
        // junk 无 projects/ → 不纳入
        let r = DataRootDiscovery.discover(home: "/h", existing: [], excluded: [], fileOps: fo)
        XCTAssertEqual(r.roots.map(\.path).sorted(), ["/h/.claude", "/h/.claude-profiles/work"])
        XCTAssertEqual(r.newlyDiscovered.map(\.path).sorted(), ["/h/.claude", "/h/.claude-profiles/work"])
    }

    /// 归一键防重复回归:jsonl 兜底路径的 Claude 会话 agent 名必须与 hook
    /// (Resources/apet-emit-event.sh 里 `"agent": "claude-code"`)一致——否则同一会话
    /// 经两源各显一行、且 hook+jsonl 融合失效(M3-C+ 修复;AppCoordinator 传 root.agent)。
    func test_discoveredClaudeRoot_agentMatchesHook() {
        let fo = MockFileOps()
        fo.existing.insert("/h/.claude")
        let r = DataRootDiscovery.discover(home: "/h", existing: [], excluded: [], fileOps: fo)
        XCTAssertEqual(r.roots.first(where: { $0.path == "/h/.claude" })?.agent, "claude-code",
                       "jsonl 与 hook 必须同 agent 名,否则会话重复")
    }

    func test_dedups_existing() {
        let fo = MockFileOps()
        fo.existing.insert("/h/.claude")
        let r = DataRootDiscovery.discover(home: "/h", existing: [dr("/h/.claude")], excluded: [], fileOps: fo)
        XCTAssertEqual(r.roots.map(\.path), ["/h/.claude"])
        XCTAssertTrue(r.newlyDiscovered.isEmpty)   // 已在 existing → 非新发现
    }

    func test_excluded_skipped() {
        let fo = MockFileOps()
        fo.dirs["/h/.claude-profiles"] = ["work"]
        fo.existing.insert("/h/.claude-profiles/work/projects")
        let r = DataRootDiscovery.discover(
            home: "/h", existing: [], excluded: ["/h/.claude-profiles/work"], fileOps: fo)
        XCTAssertTrue(r.roots.isEmpty)
    }

    /// 补充断言（计划评审要求）：caps 时 newlyDiscovered 也应截断为相同数量。
    func test_caps_at_maxAutoRoots() {
        let fo = MockFileOps()
        let names = (0..<20).map { "p\($0)" }
        fo.dirs["/h/.claude-profiles"] = names
        for n in names { fo.existing.insert("/h/.claude-profiles/\(n)/projects") }
        let r = DataRootDiscovery.discover(
            home: "/h", existing: [], excluded: [], fileOps: fo, maxAutoRoots: 16)
        XCTAssertEqual(r.roots.count, 16)
        XCTAssertEqual(r.newlyDiscovered.count, 16)  // 全部为新发现，同样截断到 16
    }

    // MARK: - 补充用例：existing 含 profile 子目录路径的去重

    /// 验证：existing 中 agent 非 "claude-code" 的 DataRoot，discover 后 agent 不被覆盖为 "claude-code"。
    func test_existing_agent_preserved() {
        let fo = MockFileOps()
        fo.dirs["/h/.claude-profiles"] = ["work"]
        fo.existing.insert("/h/.claude-profiles/work/projects")
        // existing root has agent "qoder" — must survive discover()
        let existingRoot = DataRoot(path: "/h/.claude-profiles/work", agent: "qoder")
        let r = DataRootDiscovery.discover(
            home: "/h",
            existing: [existingRoot],
            excluded: [],
            fileOps: fo
        )
        XCTAssertEqual(r.roots.count, 1)
        XCTAssertEqual(r.roots[0].agent, "qoder",
                       "existing root's agent must not be overwritten by discover()")
        XCTAssertTrue(r.newlyDiscovered.isEmpty,
                      "a root already in existing must not appear in newlyDiscovered")
    }

    /// 验证：已在 existing 的 profile 子目录不重复出现在 roots；
    /// 且不计入 newlyDiscovered，只有真正新发现的 profile 才算。
    func test_dedup_profile_already_in_existing() {
        let fo = MockFileOps()
        fo.dirs["/h/.claude-profiles"] = ["work", "personal"]
        fo.existing.insert("/h/.claude-profiles/work/projects")
        fo.existing.insert("/h/.claude-profiles/personal/projects")
        // work 已在 existing 中
        let r = DataRootDiscovery.discover(
            home: "/h",
            existing: [dr("/h/.claude-profiles/work")],
            excluded: [],
            fileOps: fo
        )
        // roots 含 work(来自 existing) + personal(新发现)，共 2 个，无重复
        XCTAssertEqual(r.roots.map(\.path).sorted(),
                       ["/h/.claude-profiles/personal", "/h/.claude-profiles/work"])
        // work 已在 existing → 只有 personal 是新发现
        XCTAssertEqual(r.newlyDiscovered.map(\.path), ["/h/.claude-profiles/personal"])
    }
}
