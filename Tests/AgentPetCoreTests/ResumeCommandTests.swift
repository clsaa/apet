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

    // MARK: - qoder-cli（实测确认：qodercli --resume [id]，2026-07-02 v1.0.36 --help）

    func test_argv_qoderCli() {
        XCTAssertEqual(ResumeCommand.argv(agent: "qoder-cli", sessionId: validId),
                       ["qodercli", "--resume", validId])
    }

    // MARK: - 未知 agent（qoder IDE / qoder-work resume 未核实）

    func test_argv_unknownAgent_nil() {
        XCTAssertNil(ResumeCommand.argv(agent: "qoder", sessionId: validId))
        XCTAssertNil(ResumeCommand.argv(agent: "qoder-work", sessionId: validId))
        XCTAssertNil(ResumeCommand.display(agent: "qoder", sessionId: validId))
    }

    // MARK: - opencode(M3-C+):id 规则 ses_+26;目录敏感 → 位置参数;display 引号

    private let sesId = "ses_0189f3ab2c4dXyZ01234abcDEF"

    func test_opencode_argv_withDirectory() {
        XCTAssertEqual(
            ResumeCommand.argv(agent: "opencode", sessionId: sesId, directory: "/Users/x/proj"),
            ["opencode", "/Users/x/proj", "--session", sesId])
    }

    func test_opencode_argv_withoutDirectory_degrades() {
        XCTAssertEqual(ResumeCommand.argv(agent: "opencode", sessionId: sesId),
                       ["opencode", "--session", sesId])
    }

    /// 交叉拒绝(测试评审:防"先选规则"重构后规则窜线)。
    func test_crossRules_rejected() {
        XCTAssertNil(ResumeCommand.argv(agent: "opencode", sessionId: validId))
        XCTAssertNil(ResumeCommand.argv(agent: "claude-code", sessionId: sesId))
        XCTAssertNil(ResumeCommand.argv(agent: "qoder-cli", sessionId: sesId))
    }

    /// display:含空格目录必须单引号引用,不得裸空格 join 产出坏命令(评审)。
    func test_opencode_display_quotesSpacedDirectory() {
        XCTAssertEqual(
            ResumeCommand.display(agent: "opencode", sessionId: sesId, directory: "/Users/x/My Proj"),
            "cd '/Users/x/My Proj' && opencode '/Users/x/My Proj' --session \(sesId)")
    }

    func test_opencode_display_quotesSingleQuoteInDirectory() {
        XCTAssertEqual(
            ResumeCommand.display(agent: "opencode", sessionId: sesId, directory: "/Users/x/it's"),
            "cd '/Users/x/it'\\''s' && opencode '/Users/x/it'\\''s' --session \(sesId)")
    }

    /// 既有 agent 的 display 不受引用逻辑影响(无 shell 元字符 → 原样)。
    func test_claude_display_unchangedByQuoting() {
        XCTAssertEqual(ResumeCommand.display(agent: "claude", sessionId: validId),
                       "claude --resume \(validId)")
    }

    // 用户实锤(2026-07-06):claude/qodercli 会话按项目目录归档,不在对应目录 resume 找不到会话。
    func test_display_prependsCdWhenDirectoryKnown() {
        XCTAssertEqual(
            ResumeCommand.display(agent: "claude-code", sessionId: validId, directory: "/Users/x/proj"),
            "cd /Users/x/proj && claude --resume \(validId)")
        // 含空格目录:cd 参数单引号引用
        XCTAssertEqual(
            ResumeCommand.display(agent: "claude-code", sessionId: validId, directory: "/Users/x/My Proj"),
            "cd '/Users/x/My Proj' && claude --resume \(validId)")
        // 无目录:保持原样(向后兼容)
        XCTAssertEqual(
            ResumeCommand.display(agent: "claude-code", sessionId: validId),
            "claude --resume \(validId)")
    }

    func test_display_codex_alsoGetsCd() {
        XCTAssertEqual(
            ResumeCommand.display(agent: "codex", sessionId: validId, directory: "/w"),
            "cd /w && codex resume \(validId)")
    }
}
