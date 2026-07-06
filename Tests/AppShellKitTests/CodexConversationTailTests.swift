import XCTest
@testable import AppShellKit
import AgentPetCore

/// codex rollout → ConversationTurn(解锁快速/AI 摘要;fixture 取真实形态)。
final class CodexConversationTailTests: XCTestCase {
    func test_userAndAgentMessages_becomeTurns() {
        let lines = [
            #"{"timestamp":"t","type":"session_meta","payload":{"id":"x","cwd":"/p"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"user_message","message":"排查连接问题"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"agent_message","message":"已定位到代理配置","phase":"final_answer"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"已定位到代理配置"}}"#,
        ]
        let turns = CodexConversationTail.turns(lines: lines)
        XCTAssertEqual(turns.map(\.role), ["user", "assistant"])
        XCTAssertEqual(turns[0].text, "排查连接问题")
        XCTAssertEqual(turns[1].text, "已定位到代理配置")
        XCTAssertEqual(turns[1].stopReason, "end_turn", "task_complete 后最后 assistant 标 end_turn")
    }

    func test_filesMentionedInjection_skipped() {
        let lines = [
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"user_message","message":"\n# Files mentioned by the user:\n## x"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"user_message","message":"真实问题"}}"#,
        ]
        let turns = CodexConversationTail.turns(lines: lines)
        XCTAssertEqual(turns.map(\.text), ["真实问题"], "附件清单注入不算用户回合")
    }

    func test_garbageLines_skipped() {
        let turns = CodexConversationTail.turns(lines: ["not json", #"{"type":"event_msg"}"#])
        XCTAssertTrue(turns.isEmpty)
    }

    func test_localSummarizer_integration_opensWithFirstUserTask() {
        let lines = [
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"user_message","message":"hello"}}"#,
            #"{"timestamp":"t","type":"event_msg","payload":{"type":"user_message","message":"帮我修构建脚本"}}"#,
        ]
        let s = LocalSummarizer.summarize(turns: CodexConversationTail.turns(lines: lines))
        XCTAssertTrue(s.contains("修构建脚本"), "跳过寒暄取真任务: \(s)")
    }
}
