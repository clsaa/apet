import XCTest
@testable import AppShellKit

/// watcher 扫描预过滤:**按会话桶**(父文件去扩展名 = subagents 上级目录,精确重合)全员
/// idle ≥ idleWindow 才跳过 parse——纯 stat 决策,不误杀「父文件老但 subagent 活跃」的会话。
final class StaleDirPrefilterTests: XCTestCase {
    func test_staleSession_skipped_freshKept() {
        let paths = ["/p/projA/s1.jsonl", "/p/projA/s2.jsonl"]
        let mtimes = ["/p/projA/s1.jsonl": 100.0, "/p/projA/s2.jsonl": 9_000.0]
        let kept = StaleDirPrefilter.freshPaths(paths, now: 10_000, idleWindow: 1800,
                                                mtime: { mtimes[$0] })
        XCTAssertEqual(kept, ["/p/projA/s2.jsonl"], "同项目目录内按会话独立判定")
    }

    func test_freshSubagent_keepsParentSession_realLayout() {
        // 真实布局:<dir>/<sid>.jsonl + <dir>/<sid>/subagents/agent-*.jsonl(JSONLParse:165)
        let paths = ["/p/projA/sid1.jsonl", "/p/projA/sid1/subagents/agent-x.jsonl",
                     "/p/projA/sid2.jsonl"]
        let mtimes = ["/p/projA/sid1.jsonl": 100.0,
                      "/p/projA/sid1/subagents/agent-x.jsonl": 9_950.0,
                      "/p/projA/sid2.jsonl": 200.0]
        let kept = StaleDirPrefilter.freshPaths(paths, now: 10_000, idleWindow: 1800,
                                                mtime: { mtimes[$0] })
        XCTAssertEqual(Set(kept), ["/p/projA/sid1.jsonl", "/p/projA/sid1/subagents/agent-x.jsonl"],
                       "活跃 subagent 保住父会话;同目录的 sid2 独立跳过")
    }

    func test_boundary_exactlyIdleWindow_isStale() {
        let kept = StaleDirPrefilter.freshPaths(["/p/d/s.jsonl"], now: 1900, idleWindow: 1800,
                                                mtime: { _ in 100.0 })
        XCTAssertEqual(kept, [], "恰好等于窗口 → stale(与 scanner >= 同界)")
    }

    func test_statFailure_keepsPath() {
        let kept = StaleDirPrefilter.freshPaths(["/p/d/s.jsonl"], now: 10_000, idleWindow: 1800,
                                                mtime: { _ in nil })
        XCTAssertEqual(kept, ["/p/d/s.jsonl"], "stat 失败保守保留(宁多读,不丢会话)")
    }

    func test_codexRollouts_perFile() {
        let paths = ["/r/sessions/2026/07/01/a.jsonl", "/r/sessions/2026/07/05/b.jsonl"]
        let mtimes = ["/r/sessions/2026/07/01/a.jsonl": 100.0,
                      "/r/sessions/2026/07/05/b.jsonl": 9_900.0]
        let kept = StaleDirPrefilter.freshPaths(paths, now: 10_000, idleWindow: 1800,
                                                mtime: { mtimes[$0] })
        XCTAssertEqual(kept, ["/r/sessions/2026/07/05/b.jsonl"])
    }
}
