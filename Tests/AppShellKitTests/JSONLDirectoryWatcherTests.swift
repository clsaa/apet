import XCTest
@testable import AppShellKit
@testable import AgentPetCore

// MARK: - Test helper: mock scanner

private struct MockScanner: DirectoryScanning {
    let paths: [String]
    func jsonlFiles(under projectsDir: String) -> [String] { paths }
}

// MARK: - Helpers

private func stateOf(_ result: ScanResult) -> ScanState? {
    if case .observe(let s, _, _, _) = result { return s }
    return nil
}

private func makeRunningFile(sessionId: String = "sess-1", root: String = "/r") -> ScannedFile {
    // tool_use, fresh within runningWindow (age=20 < 120)
    ScannedFile(
        sessionId: sessionId,
        root: root,
        cwd: "/proj",
        mtime: 980.0,
        lastAssistantStopReason: "tool_use",
        lastConversationTs: 980.0
    )
}

private func makeWaitingFile(sessionId: String = "sess-1", root: String = "/r") -> ScannedFile {
    // end_turn → waitingStop regardless of age
    ScannedFile(
        sessionId: sessionId,
        root: root,
        cwd: "/proj",
        mtime: 980.0,
        lastAssistantStopReason: "end_turn",
        lastConversationTs: 980.0
    )
}

// MARK: - Tests

final class JSONLDirectoryWatcherTests: XCTestCase {

    // now=1000, runningWindow=120, idleWindow=1800
    // age = 1000 - 980 = 20 < 120 → running for tool_use
    private let fixedNow: Double = 1000.0

    /// 同一 running session 重复 scan 只 emit 一次
    func test_running_then_no_repeat() {
        var emitted: [ScanResult] = []

        let watcher = JSONLDirectoryWatcher(
            projectsDir: "/fake",
            root: "/r",
            now: { 1000.0 },
            scanner: MockScanner(paths: ["/fake/a.jsonl"]),
            parse: { _ in makeRunningFile() },
            emit: { emitted.append($0) },
            runningWindow: 120,
            idleWindow: 1800
        )

        watcher.scanOnce()
        watcher.scanOnce()

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(stateOf(emitted[0]), .running)
    }

    /// 滞回：running→waitingStop 需要连续 2 次 quietStreak 才翻转
    /// scanOnce #1: raw=running  → emit running
    /// scanOnce #2: raw=waitStop → streak=1 <2 → effState=running → no emit
    /// scanOnce #3: raw=waitStop → streak=2 ≥2 → effState=waitStop → emit waitStop
    func test_hysteresis_two_quiet_then_flip() {
        var emitted: [ScanResult] = []
        var callCount = 0

        let watcher = JSONLDirectoryWatcher(
            projectsDir: "/fake",
            root: "/r",
            now: { 1000.0 },
            scanner: MockScanner(paths: ["/fake/b.jsonl"]),
            parse: { _ in
                callCount += 1
                if callCount == 1 {
                    return makeRunningFile(sessionId: "sess-hyst")
                } else {
                    return makeWaitingFile(sessionId: "sess-hyst")
                }
            },
            emit: { emitted.append($0) },
            runningWindow: 120,
            idleWindow: 1800
        )

        watcher.scanOnce() // #1: emit running
        watcher.scanOnce() // #2: quiet#1, still running, no emit
        watcher.scanOnce() // #3: quiet#2, flip to waitingStop, emit

        let states = emitted.compactMap { stateOf($0) }
        XCTAssertEqual(states, [.running, .waitingStop])
    }

    /// ignore 结果不 emit
    func test_ignore_not_emitted() {
        var emitted: [ScanResult] = []

        let watcher = JSONLDirectoryWatcher(
            projectsDir: "/fake",
            root: "/r",
            now: { 1000.0 },
            scanner: MockScanner(paths: ["/fake/c.jsonl"]),
            parse: { _ in
                // isSidechain=true → scan returns .ignore(.subagent)
                ScannedFile(
                    sessionId: "sess-sub",
                    root: "/r",
                    mtime: 980.0,
                    lastConversationTs: 980.0,
                    isSidechain: true
                )
            },
            emit: { emitted.append($0) }
        )

        watcher.scanOnce()
        XCTAssertTrue(emitted.isEmpty)
    }

    /// parse 返回 nil（无法解析文件）时不 emit
    func test_nil_parse_not_emitted() {
        var emitted: [ScanResult] = []

        let watcher = JSONLDirectoryWatcher(
            projectsDir: "/fake",
            root: "/r",
            now: { 1000.0 },
            scanner: MockScanner(paths: ["/fake/nonexistent.jsonl"]),
            parse: { _ in nil },
            emit: { emitted.append($0) }
        )

        watcher.scanOnce()
        XCTAssertTrue(emitted.isEmpty)
    }

    /// DefaultDirectoryScanner 排除 /subagents/ 路径和 agent- 前缀文件
    func test_DefaultDirectoryScanner_excludes_subagents() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apet-scanner-test-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Include: a.jsonl at root
        let aPath = (tmpDir as NSString).appendingPathComponent("a.jsonl")
        FileManager.default.createFile(atPath: aPath, contents: nil)

        // Exclude: x/subagents/agent-1.jsonl (both /subagents/ path and agent- prefix)
        let subagentDir = (tmpDir as NSString).appendingPathComponent("x/subagents")
        try FileManager.default.createDirectory(atPath: subagentDir, withIntermediateDirectories: true)
        let agentPath = (subagentDir as NSString).appendingPathComponent("agent-1.jsonl")
        FileManager.default.createFile(atPath: agentPath, contents: nil)

        // Exclude: agent-prefixed at root
        let agentRootPath = (tmpDir as NSString).appendingPathComponent("agent-session.jsonl")
        FileManager.default.createFile(atPath: agentRootPath, contents: nil)

        let scanner = DefaultDirectoryScanner()
        let files = scanner.jsonlFiles(under: tmpDir)

        XCTAssertEqual(files.count, 1, "Expected only a.jsonl; got: \(files)")
        XCTAssertTrue(files[0].hasSuffix("/a.jsonl"), "Expected a.jsonl but got: \(files[0])")
    }

    /// 状态从 stale 变 running 时正确 emit
    func test_state_change_from_stale_to_running_emits() {
        var emitted: [ScanResult] = []
        var callCount = 0

        let watcher = JSONLDirectoryWatcher(
            projectsDir: "/fake",
            root: "/r",
            now: { 1000.0 },
            scanner: MockScanner(paths: ["/fake/d.jsonl"]),
            parse: { _ in
                callCount += 1
                if callCount == 1 {
                    // away > assistant → stale
                    return ScannedFile(
                        sessionId: "sess-stale",
                        root: "/r",
                        cwd: "/proj",
                        mtime: 990.0,
                        lastAssistantTs: 900.0,
                        lastAwayTs: 950.0,
                        lastConversationTs: 950.0
                    )
                } else {
                    // tool_use fresh → running
                    return makeRunningFile(sessionId: "sess-stale")
                }
            },
            emit: { emitted.append($0) },
            runningWindow: 120,
            idleWindow: 1800
        )

        watcher.scanOnce() // emit stale
        watcher.scanOnce() // emit running

        let states = emitted.compactMap { stateOf($0) }
        XCTAssertEqual(states, [.stale, .running])
    }

    /// Fix 3（幽灵会话对账）：round1 running → round2 文件变 .ignore(tooOld)（消失）
    /// → 扫尾应补发一条 .stale，使曾上屏的会话被打灰。
    /// 预期 emit 序列：[.running, .stale]
    func test_running_then_gone_emits_stale() {
        var emitted: [ScanResult] = []
        var callCount = 0

        let watcher = JSONLDirectoryWatcher(
            projectsDir: "/fake",
            root: "/r",
            now: { 1000.0 },
            scanner: MockScanner(paths: ["/fake/ghost.jsonl"]),
            parse: { _ in
                callCount += 1
                if callCount == 1 {
                    // tool_use fresh（age=20 < 120）→ running
                    return makeRunningFile(sessionId: "sess-ghost")
                } else {
                    // 文件已极旧：effectiveTs=-1000, now=1000 → age=2000 >= idleWindow(1800)
                    // → scan 返回 .ignore(.tooOld)，本轮不再 observe 该 key
                    return ScannedFile(
                        sessionId: "sess-ghost",
                        root: "/r",
                        cwd: "/proj",
                        mtime: -1000.0,
                        lastAssistantStopReason: "tool_use",
                        lastConversationTs: -1000.0
                    )
                }
            },
            emit: { emitted.append($0) },
            runningWindow: 120,
            idleWindow: 1800
        )

        watcher.scanOnce() // #1: emit running
        watcher.scanOnce() // #2: ignore(tooOld) → 扫尾对账补发 stale

        let states = emitted.compactMap { stateOf($0) }
        XCTAssertEqual(states, [.running, .stale])

        // 对账后 key 应被移出 lastEmitted：再扫一次仍 tooOld，不应重复补 stale
        watcher.scanOnce() // #3: 依旧消失，但已无基线 → 不再 emit
        XCTAssertEqual(emitted.compactMap { stateOf($0) }, [.running, .stale],
                       "幽灵 key 已清出基线，重复扫描不应再次补 stale")
    }
}
