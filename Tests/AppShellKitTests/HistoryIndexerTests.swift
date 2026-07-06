import XCTest
@testable import AppShellKit

/// 历史索引:缓存/去重/排序(IO 注入,纯逻辑)。
final class HistoryIndexerTests: XCTestCase {
    func test_cache_skipsUnchangedFiles() {
        let idx = HistoryIndexer()
        var parseCount = 0
        let files = [("/p/a.jsonl", 100.0), ("/p/b.jsonl", 200.0)]
        let parse: (String) -> (String, String?, String?)? = { path in
            parseCount += 1
            return ((path as NSString).lastPathComponent, "/cwd", "T")
        }
        _ = idx.claudeStyleEntries(agent: "claude-code", root: "/r",
                                   listFiles: { files.map { (path: $0.0, mtime: $0.1) } },
                                   parse: { p in parse(p).map { (sessionId: $0.0, cwd: $0.1, title: $0.2) } })
        XCTAssertEqual(parseCount, 2)
        // 第二轮:mtime 未变 → 零解析
        let again = idx.claudeStyleEntries(agent: "claude-code", root: "/r",
                                           listFiles: { files.map { (path: $0.0, mtime: $0.1) } },
                                           parse: { p in parse(p).map { (sessionId: $0.0, cwd: $0.1, title: $0.2) } })
        XCTAssertEqual(parseCount, 2, "缓存命中零重析")
        XCTAssertEqual(again.count, 2)
        // 第三轮:a 变了 → 只重析 a
        let files2 = [("/p/a.jsonl", 150.0), ("/p/b.jsonl", 200.0)]
        _ = idx.claudeStyleEntries(agent: "claude-code", root: "/r",
                                   listFiles: { files2.map { (path: $0.0, mtime: $0.1) } },
                                   parse: { p in parse(p).map { (sessionId: $0.0, cwd: $0.1, title: $0.2) } })
        XCTAssertEqual(parseCount, 3)
    }

    func test_codexEntries_desktopSplit_andIndexTitle() {
        let idx = HistoryIndexer()
        let out = idx.codexEntries(root: "/c",
                                   listRollouts: { [(path: "/c/s/r1.jsonl", mtime: 500)] },
                                   titles: ["sid1": "排查问题"],
                                   parseMeta: { _ in (sessionId: "sid1", cwd: "/w", isDesktop: true) })
        XCTAssertEqual(out.first?.agent, "codex-desktop")
        XCTAssertEqual(out.first?.title, "排查问题")
    }

    func test_merged_dedupNewestWins_sortedDesc() {
        let a = HistoryEntry(agent: "codex", root: "/r", sessionId: "x", lastTs: 100)
        let b = HistoryEntry(agent: "codex", root: "/r", sessionId: "x", title: "新", lastTs: 300)
        let c = HistoryEntry(agent: "claude-code", root: "/r2", sessionId: "y", lastTs: 200)
        let m = HistoryIndexer.merged([[a, c], [b]])
        XCTAssertEqual(m.map(\.sessionId), ["x", "y"], "倒序")
        XCTAssertEqual(m.first?.title, "新", "同 id 取最新")
    }
}
