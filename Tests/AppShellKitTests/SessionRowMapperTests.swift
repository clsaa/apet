import XCTest
@testable import AppShellKit
import AgentPetCore

// MARK: - SessionRowMapperTests

final class SessionRowMapperTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession(
        agent: String = "claude-code",
        root: String = "~/.claude",
        sessionId: String = "sess-1",
        state: SessionState = .running,
        cwd: String? = nil,
        title: String? = nil,
        terminal: TerminalRef? = nil
    ) -> Session {
        Session(
            key: SessionKey(agent: agent, root: root, sessionId: sessionId),
            state: state,
            cwd: cwd,
            title: title,
            terminal: terminal,
            lastSeq: 1,
            lastActiveAt: 1_000
        )
    }

    // MARK: - TC-ROWMAP-FUNC-001  running + iterm2 → dot .running, activateOnly false

    func test_running_dotRunning_activateOnlyFalse() {
        // Arrange
        let session = makeSession(
            state: .running,
            terminal: TerminalRef(kind: .iterm2, itermSessionId: "session-abc-123")
        )
        // Act
        let row = SessionRowMapper.make(session)
        // Assert
        XCTAssertEqual(row.dot, .running)
        XCTAssertFalse(row.activateOnly)
    }

    // MARK: - TC-ROWMAP-FUNC-002  waiting(.attention) → dot .attention

    func test_waitingAttention_dotAttention() {
        // Arrange
        let session = makeSession(state: .waiting(.attention))
        // Act
        let row = SessionRowMapper.make(session)
        // Assert
        XCTAssertEqual(row.dot, .attention)
    }

    // MARK: - TC-ROWMAP-FUNC-003  waiting(.stop) → dot .doneWaiting

    func test_waitingStop_dotDoneWaiting() {
        // Arrange
        let session = makeSession(state: .waiting(.stop))
        // Act
        let row = SessionRowMapper.make(session)
        // Assert
        XCTAssertEqual(row.dot, .doneWaiting)
    }

    // MARK: - TC-ROWMAP-FUNC-004  stale → dot .stale

    func test_stale_dotStale() {
        // Arrange
        let session = makeSession(state: .stale)
        // Act
        let row = SessionRowMapper.make(session)
        // Assert
        XCTAssertEqual(row.dot, .stale)
    }

    // MARK: - TC-ROWMAP-FUNC-005  title fallback: title nil, cwd "/a/b/proj" → title "proj"

    func test_titleFallback_lastCwdComponent() {
        // Arrange — title is nil; cwd provides the basename
        let session = makeSession(cwd: "/a/b/proj", title: nil)
        // Act
        let row = SessionRowMapper.make(session)
        // Assert
        XCTAssertEqual(row.title, "proj")
        XCTAssertEqual(row.subtitle, "/a/b/proj")
    }

    // MARK: - TC-ROWMAP-FUNC-006  profileLabel from root "~/.claude-profiles/work" → profileTag "work"

    func test_profileTag_derivedFromRoot() {
        // Arrange — root encodes the profile name
        let session = makeSession(root: "~/.claude-profiles/work")
        // Act
        let row = SessionRowMapper.make(session)
        // Assert
        XCTAssertEqual(row.profileTag, "work")
    }

    // MARK: - TC-ROWMAP-FUNC-007  terminal .warp → activateOnly true

    func test_warpTerminal_activateOnlyTrue() {
        // Arrange
        let session = makeSession(terminal: TerminalRef(kind: .warp))
        // Act
        let row = SessionRowMapper.make(session)
        // Assert
        XCTAssertTrue(row.activateOnly)
    }

    // MARK: - TC-ROWMAP-FUNC-008  terminal .iterm2 → activateOnly false

    func test_iterm2Terminal_activateOnlyFalse() {
        // Arrange
        let session = makeSession(
            terminal: TerminalRef(kind: .iterm2, itermSessionId: "abc-123")
        )
        // Act
        let row = SessionRowMapper.make(session)
        // Assert
        XCTAssertFalse(row.activateOnly)
    }

    // MARK: - TC-ROWMAP-INFER-001  jsonl + waiting(.stop) → isInferred true

    func test_jsonl_waitingStop_isInferred() {
        // Arrange — jsonl 来源，waiting(.stop)，应标记为推断态
        var s = makeSession(state: .waiting(.stop))
        s.source = .jsonl
        // Act
        let row = SessionRowMapper.make(s)
        // Assert
        XCTAssertTrue(row.isInferred)
    }

    // MARK: - TC-ROWMAP-INFER-002  hook + waiting(.stop) → isInferred false

    func test_hook_waitingStop_notInferred() {
        // Arrange — hook 来源，waiting(.stop)，精确事件流，不是推断
        var s = makeSession(state: .waiting(.stop))
        s.source = .hook
        // Act
        let row = SessionRowMapper.make(s)
        // Assert
        XCTAssertFalse(row.isInferred)
    }

    // MARK: - TC-ROWMAP-INFER-003  jsonl + running → isInferred false

    func test_jsonl_running_notInferred() {
        // Arrange — jsonl 来源但处于 running，活跃中不是推断
        var s = makeSession(state: .running)
        s.source = .jsonl
        // Act
        let row = SessionRowMapper.make(s)
        // Assert
        XCTAssertFalse(row.isInferred)
    }

    // MARK: - TC-ROWMAP-INFER-004  jsonl + stale → isInferred false

    func test_jsonl_stale_notInferred() {
        // Arrange — jsonl 来源但已 stale，超时灰显不是推断
        var s = makeSession(state: .stale)
        s.source = .jsonl
        // Act
        let row = SessionRowMapper.make(s)
        // Assert
        XCTAssertFalse(row.isInferred)
    }
}
