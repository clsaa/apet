import XCTest
@testable import AgentPetCore

/// `ResumeCommand` 恢复命令 argv 渲染 + UUID 白名单。安全红线：sessionId 作单一 argv、恶意值被拒。
final class ResumeCommandTests: XCTestCase {

    private let validId = "8eb2fbd6-8607-426d-b1be-8d20e35419c8"

    // MARK: - claude 渲染

    func test_argv_claude() {
        XCTAssertEqual(ResumeCommand.argv(agent: "claude-code", sessionId: validId),
                       ["claude", "--resume", validId])
    }

    func test_argv_claude_altAgentName() {
        XCTAssertEqual(ResumeCommand.argv(agent: "claude", sessionId: validId),
                       ["claude", "--resume", validId])
    }

    func test_display_claude() {
        XCTAssertEqual(ResumeCommand.display(agent: "claude-code", sessionId: validId),
                       "claude --resume \(validId)")
    }

    // MARK: - UUID 白名单（红队）

    func test_argv_rejectsShellInjection() {
        XCTAssertNil(ResumeCommand.argv(agent: "claude-code", sessionId: "\(validId); rm -rf /"))
        XCTAssertNil(ResumeCommand.argv(agent: "claude-code", sessionId: "$(whoami)"))
        XCTAssertNil(ResumeCommand.argv(agent: "claude-code", sessionId: "`id`"))
        XCTAssertNil(ResumeCommand.argv(agent: "claude-code", sessionId: "../etc/passwd"))
        XCTAssertNil(ResumeCommand.argv(agent: "claude-code", sessionId: ""))
        XCTAssertNil(ResumeCommand.argv(agent: "claude-code", sessionId: "not-a-uuid"))
    }

    // MARK: - 未知 agent（M3-C 接 Qoder 再补）

    func test_argv_unknownAgent_nil() {
        XCTAssertNil(ResumeCommand.argv(agent: "qoder", sessionId: validId))
        XCTAssertNil(ResumeCommand.display(agent: "qoder", sessionId: validId))
    }
}
