import XCTest
@testable import AgentPetCore

final class JSONLSessionScannerTests: XCTestCase {

    // MARK: - Helpers

    private func makeFile(
        sessionId: String = "sess-1",
        root: String = "/Users/x/.claude",
        cwd: String? = "/Users/x/project",
        title: String? = "My Session",
        lastPrompt: String? = nil,
        mtime: Double = 1_000_000,
        lastAssistantStopReason: String? = nil,
        lastAssistantTs: Double? = nil,
        lastAwayTs: Double? = nil,
        hasRecentQueueOp: Bool = false,
        lastConversationTs: Double? = nil,
        entrypoint: String? = nil,
        promptSource: String? = nil,
        isSidechain: Bool = false,
        isSubagentPath: Bool = false
    ) -> ScannedFile {
        ScannedFile(
            sessionId: sessionId,
            root: root,
            cwd: cwd,
            title: title,
            lastPrompt: lastPrompt,
            mtime: mtime,
            lastAssistantStopReason: lastAssistantStopReason,
            lastAssistantTs: lastAssistantTs,
            lastAwayTs: lastAwayTs,
            hasRecentQueueOp: hasRecentQueueOp,
            lastConversationTs: lastConversationTs,
            entrypoint: entrypoint,
            promptSource: promptSource,
            isSidechain: isSidechain,
            isSubagentPath: isSubagentPath
        )
    }

    // MARK: - Priority 1: subagent / sidechain

    func test_isSubagentPath_ignoresAsSubagent() {
        let f = makeFile(isSubagentPath: true)
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: 1_000_000),
            .ignore(.subagent)
        )
    }

    func test_isSidechain_ignoresAsSubagent() {
        let f = makeFile(isSidechain: true)
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: 1_000_000),
            .ignore(.subagent)
        )
    }

    /// subagent 优先于 sdk-cli：同时设两者，断言 .subagent 而不是 .synthetic
    func test_subagent_takesOverSdkCli_priorityCheck() {
        let f = makeFile(entrypoint: "sdk-cli", isSubagentPath: true)
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: 1_000_000),
            .ignore(.subagent)
        )
    }

    func test_sidechain_takesOverSdkCli_priorityCheck() {
        let f = makeFile(entrypoint: "sdk-cli", isSidechain: true)
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: 1_000_000),
            .ignore(.subagent)
        )
    }

    // MARK: - Priority 2: synthetic

    func test_entrypoint_sdkCli_ignoresAsSynthetic_sdkCli() {
        let f = makeFile(entrypoint: "sdk-cli")
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: 1_000_000),
            .ignore(.synthetic(.sdkCli))
        )
    }

    func test_promptSource_sdk_ignoresAsSynthetic_sdkPromptSource() {
        let f = makeFile(promptSource: "sdk")
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: 1_000_000),
            .ignore(.synthetic(.sdkPromptSource))
        )
    }

    // MARK: - Priority 3: blacklistedCwd

    func test_cwd_containsIterationDash_ignoresAsBlacklistedCwd() {
        let f = makeFile(cwd: "/Users/x/worktrees-iteration-42/project")
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: 1_000_000),
            .ignore(.blacklistedCwd)
        )
    }

    func test_cwd_containsSlashEvalDash_ignoresAsBlacklistedCwd() {
        let f = makeFile(cwd: "/Users/x/repo/eval-suite/run1")
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: 1_000_000),
            .ignore(.blacklistedCwd)
        )
    }

    func test_cwd_containsPrivateTmpClaudeDash_ignoresAsBlacklistedCwd() {
        let f = makeFile(cwd: "/private/tmp/claude-502/session")
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: 1_000_000),
            .ignore(.blacklistedCwd)
        )
    }

    func test_cwd_containsPrivateVarFolders_ignoresAsBlacklistedCwd() {
        let f = makeFile(cwd: "/private/var/folders/ab/cd/T/some-session")
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: 1_000_000),
            .ignore(.blacklistedCwd)
        )
    }

    /// blacklisted cwd 优先于 tooOld（age >= idleWindow 且 cwd 命中黑名单 → blacklistedCwd）
    func test_blacklistedCwd_takesOverTooOld_priorityCheck() {
        let now: Double = 1_002_000
        let f = makeFile(cwd: "/private/tmp/claude-999/stuff", mtime: 1_000_000) // age=2000 >= 1800
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: now, idleWindow: 1800),
            .ignore(.blacklistedCwd)
        )
    }

    // MARK: - Priority 4: tooOld

    func test_age_meetsIdleWindow_ignoresAsTooOld() {
        let now: Double = 1_001_800
        let f = makeFile(mtime: 1_000_000) // age = 1800 >= 1800
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: now, idleWindow: 1800),
            .ignore(.tooOld)
        )
    }

    func test_age_belowIdleWindow_observesNotTooOld() {
        let now: Double = 1_001_799
        let f = makeFile(mtime: 1_000_000) // age = 1799 < 1800
        // age < idleWindow 且无 subagent/synthetic/blacklist → observe
        // 无 stopReason, age=1799 ≥ runningWindow(120) → waitingStop（mtime 兜底分支）
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: now, idleWindow: 1800),
            .observe(state: .waitingStop,
                     key: SessionKey(agent: "claude", root: "/Users/x/.claude", sessionId: "sess-1"),
                     cwd: "/Users/x/project", title: "My Session")
        )
    }

    /// effectiveTs = min(mtime, lastConversationTs ?? mtime)
    func test_effectiveTs_usesMinOfMtimeAndLastConversationTs() {
        let now: Double = 1_003_600
        // mtime=1_000_000, lastConversationTs=1_001_900 → effectiveTs=1_000_000 → age=3600 >= 1800
        let f = makeFile(mtime: 1_000_000, lastConversationTs: 1_001_900)
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: now, idleWindow: 1800),
            .ignore(.tooOld)
        )
    }

    func test_effectiveTs_lastConversationTs_newerThanMtime_minPicksMtime_isTooOld() {
        let now: Double = 1_003_600
        // mtime=1_000_000 (age=3600 >= 1800), lastConversationTs=1_002_000 (age=1600 < 1800)
        // effectiveTs = min(1_000_000, 1_002_000) = 1_000_000 → tooOld
        // (min always picks mtime here, so this one IS tooOld)
        let f = makeFile(mtime: 1_000_000, lastConversationTs: 1_002_000)
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: now, idleWindow: 1800),
            .ignore(.tooOld)
        )
    }

    func test_effectiveTs_lastConversationTs_olderThanMtime_minPicksLastConvTs_isTooOld() {
        let now: Double = 1_001_700
        // mtime=1_001_600 (age=100), lastConversationTs=999_000 (very old)
        // effectiveTs = min(1_001_600, 999_000) = 999_000 → age=2700 >= 1800 → tooOld
        let f = makeFile(mtime: 1_001_600, lastConversationTs: 999_000)
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: now, idleWindow: 1800),
            .ignore(.tooOld)
        )
    }

    func test_effectiveTs_nilLastConversationTs_fallsBackToMtime() {
        let now: Double = 1_001_799
        // lastConversationTs=nil → effectiveTs=mtime=1_000_000 → age=1799 < 1800 → observe
        // 无 stopReason, age=1799 ≥ runningWindow(120) → waitingStop（mtime 兜底分支）
        let f = makeFile(mtime: 1_000_000, lastConversationTs: nil)
        XCTAssertEqual(
            JSONLSessionScanner.scan(f, now: now, idleWindow: 1800),
            .observe(state: .waitingStop,
                     key: SessionKey(agent: "claude", root: "/Users/x/.claude", sessionId: "sess-1"),
                     cwd: "/Users/x/project", title: "My Session")
        )
    }

    // MARK: - Observe: check key, cwd, title

    func test_observe_returnsCorrectSessionKey() {
        let f = makeFile(sessionId: "abc-123", root: "/Users/x/.claude", mtime: 1_000_000)
        let result = JSONLSessionScanner.scan(f, now: 1_000_000 + 60)
        guard case .observe(let state, let key, _, _) = result else {
            return XCTFail("Expected .observe, got \(result)")
        }
        // age=60 < runningWindow(120), 无 stopReason → mtime 兜底 → running
        XCTAssertEqual(state, .running)
        XCTAssertEqual(key, SessionKey(agent: "claude", root: "/Users/x/.claude", sessionId: "abc-123"))
    }

    func test_observe_cwd_forwarded() {
        let f = makeFile(cwd: "/Users/x/myProject", mtime: 1_000_000)
        let result = JSONLSessionScanner.scan(f, now: 1_000_060)
        guard case .observe(_, _, let cwd, _) = result else {
            return XCTFail("Expected .observe")
        }
        XCTAssertEqual(cwd, "/Users/x/myProject")
    }

    func test_observe_title_usedWhenPresent() {
        let f = makeFile(title: "My Title", lastPrompt: "some prompt", mtime: 1_000_000)
        let result = JSONLSessionScanner.scan(f, now: 1_000_060)
        guard case .observe(_, _, _, let title) = result else {
            return XCTFail("Expected .observe")
        }
        XCTAssertEqual(title, "My Title")
    }

    func test_observe_fallsBackToLastPrompt_whenTitleNil() {
        let f = makeFile(title: nil, lastPrompt: "fix the bug", mtime: 1_000_000)
        let result = JSONLSessionScanner.scan(f, now: 1_000_060)
        guard case .observe(_, _, _, let title) = result else {
            return XCTFail("Expected .observe")
        }
        XCTAssertEqual(title, "fix the bug")
    }

    func test_observe_titleNilAndLastPromptNil() {
        let f = makeFile(title: nil, lastPrompt: nil, mtime: 1_000_000)
        let result = JSONLSessionScanner.scan(f, now: 1_000_060)
        guard case .observe(_, _, _, let title) = result else {
            return XCTFail("Expected .observe")
        }
        XCTAssertNil(title)
    }

    func test_observe_stateIsDerivedFromContent() {
        let f = makeFile(mtime: 1_000_000)
        let result = JSONLSessionScanner.scan(f, now: 1_000_060)
        guard case .observe(let state, _, _, _) = result else {
            return XCTFail("Expected .observe")
        }
        // Task 5: 真实派生——无 stopReason, age=60 < runningWindow(120) → mtime 兜底 → running
        XCTAssertEqual(state, .running)
    }
}

// MARK: - Task 5: 状态矩阵（内容信号优先 + away 时间感知 + effectiveTs 漂移）
extension JSONLSessionScannerTests {

    /// 创建最小化 ScannedFile（mtime=1000，无 stop reason，无 away 信号）
    private func base(_ configure: (inout ScannedFile) -> Void = { _ in }) -> ScannedFile {
        var f = ScannedFile(
            sessionId: "s1",
            root: "/r",
            cwd: "/project",
            mtime: 1000
        )
        configure(&f)
        return f
    }

    /// scan 后断言 .observe(state == expected)
    private func assertState(
        _ f: ScannedFile,
        now: Double,
        _ expected: ScanState,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let result = JSONLSessionScanner.scan(f, now: now)
        guard case .observe(let state, _, _, _) = result else {
            XCTFail("Expected .observe, got \(result)", file: file, line: line)
            return
        }
        XCTAssertEqual(state, expected, file: file, line: line)
    }

    // away 晚于最后 assistant → stale（awayIsLatest=true 分支）
    func test_away_after_last_assistant_is_stale() {
        let f = base { $0.lastAssistantStopReason = "end_turn"; $0.lastAssistantTs = 1000; $0.lastAwayTs = 1005; $0.mtime = 1005 }
        assertState(f, now: 1010, .stale)
    }

    // away 早于最后 assistant → awayIsLatest=false，按 tool_use 新鲜度判 running
    func test_away_before_last_assistant_ignored() {
        let f = base { $0.lastAssistantStopReason = "tool_use"; $0.lastAssistantTs = 1000; $0.lastAwayTs = 900; $0.mtime = 1000 }
        assertState(f, now: 1010, .running)
    }

    // end_turn 近期（age=10 < idleWindow）→ waitingStop（无死分支，不检查 age）
    func test_end_turn_recent_waitingStop() {
        assertState(base { $0.lastAssistantStopReason = "end_turn"; $0.mtime = 1000 }, now: 1010, .waitingStop)
    }

    // tool_use 新鲜（age=50 < runningWindow=120）→ running
    func test_tool_use_fresh_running() {
        assertState(base { $0.lastAssistantStopReason = "tool_use"; $0.mtime = 1000 }, now: 1050, .running)
    }

    // 边界 age == runningWindow(120)：age < 120 为 false → waitingStop
    func test_running_boundary_exact_is_waitingStop() {
        assertState(base { $0.lastAssistantStopReason = "tool_use"; $0.mtime = 1000 }, now: 1120, .waitingStop)
    }

    // 边界 age == idleWindow(1800)：在过滤层已返回 .ignore(.tooOld)
    func test_idle_boundary_exact_is_ignore_tooOld() {
        let r = JSONLSessionScanner.scan(base { $0.lastAssistantStopReason = "tool_use"; $0.mtime = 1000 }, now: 1000 + 1800)
        XCTAssertEqual(r, .ignore(.tooOld))
    }

    // effectiveTs 漂移：mtime=2000, lastConversationTs=1000, now=2000
    // effectiveTs=min(2000,1000)=1000, age=1000 ≥ 120 → waitingStop
    func test_mtime_drift_corrected() {
        assertState(base { $0.lastAssistantStopReason = "tool_use"; $0.mtime = 2000; $0.lastConversationTs = 1000 }, now: 2000, .waitingStop)
    }
}
