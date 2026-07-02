import XCTest
@testable import AppShellKit
import AgentPetCore

/// 纯函数 `ConversationTailParser.turns(lines:)`：jsonl 尾部行 → ConversationTurn（供本地摘要）。
final class ConversationTailParserTests: XCTestCase {

    func test_extractsUserAndAssistantText() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"修复登录 bug"},"timestamp":"2026-07-01T10:00:00Z"}"#,
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"已修复并加了测试"}]},"timestamp":"2026-07-01T10:01:00Z"}"#,
        ]
        let turns = ConversationTailParser.turns(lines: lines)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].role, "user")
        XCTAssertEqual(turns[0].text, "修复登录 bug")
        XCTAssertEqual(turns[1].role, "assistant")
        XCTAssertEqual(turns[1].text, "已修复并加了测试")
        XCTAssertEqual(turns[1].stopReason, "end_turn")
    }

    func test_userContent_arrayForm() {
        // user content 也可能是块数组
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"跑下测试"}]}}"#,
        ]
        let turns = ConversationTailParser.turns(lines: lines)
        XCTAssertEqual(turns.first?.text, "跑下测试")
    }

    func test_skipsNonConversationAndBadLines() {
        let lines = [
            #"{"type":"queue-operation","timestamp":"2026-07-01T10:00:00Z"}"#,
            "not json at all",
            #"{"type":"user","message":{"role":"user","content":"你好"}}"#,
        ]
        let turns = ConversationTailParser.turns(lines: lines)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "你好")
    }

    func test_assistant_toolUseOnly_emptyTextButKeepsStopReason() {
        let lines = [
            #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#,
        ]
        let turns = ConversationTailParser.turns(lines: lines)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "")
        XCTAssertEqual(turns[0].stopReason, "tool_use")
    }

    func test_empty_returnsEmpty() {
        XCTAssertEqual(ConversationTailParser.turns(lines: []).count, 0)
    }
}
