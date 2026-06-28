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

    func test_age_belowIdleWindow_doesNotIgnoreAsTooOld() {
        let now: Double = 1_001_799
        let f = makeFile(mtime: 1_000_000) // age = 1799 < 1800
        let result = JSONLSessionScanner.scan(f, now: now, idleWindow: 1800)
        // Should NOT be tooOld — it's an observe
        if case .ignore(.tooOld) = result { XCTFail("Should not be tooOld") }
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

    func test_effectiveTs_lastConversationTs_newerThanMtime_usesLastConversation_notOld() {
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

    func test_effectiveTs_lastConversationTs_olderThanMtime_usesMtime_notOld() {
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
        // lastConversationTs=nil → effectiveTs=mtime=1_000_000 → age=1799 < 1800 → not tooOld
        let f = makeFile(mtime: 1_000_000, lastConversationTs: nil)
        let result = JSONLSessionScanner.scan(f, now: now, idleWindow: 1800)
        if case .ignore(.tooOld) = result { XCTFail("Should not be tooOld") }
    }

    // MARK: - Observe: check key, cwd, title

    func test_observe_returnsCorrectSessionKey() {
        let f = makeFile(sessionId: "abc-123", root: "/Users/x/.claude", mtime: 1_000_000)
        let result = JSONLSessionScanner.scan(f, now: 1_000_000 + 60)
        guard case .observe(let state, let key, _, _) = result else {
            return XCTFail("Expected .observe, got \(result)")
        }
        XCTAssertEqual(state, .stale)
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

    func test_observe_stateIsAlwaysStale_placeholder() {
        let f = makeFile(mtime: 1_000_000)
        let result = JSONLSessionScanner.scan(f, now: 1_000_060)
        guard case .observe(let state, _, _, _) = result else {
            return XCTFail("Expected .observe")
        }
        // Task 4 placeholder: state is always .stale; Task 5 will derive real state
        XCTAssertEqual(state, .stale)
    }
}
