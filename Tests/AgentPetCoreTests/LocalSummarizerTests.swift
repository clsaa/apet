import XCTest
@testable import AgentPetCore

/// 纯函数 `LocalSummarizer.summarize`：免费本地启发式摘要（最后指令 + 最近动作）。
final class LocalSummarizerTests: XCTestCase {

    func test_lastUserInstruction_and_assistantStopReason() {
        let turns = [
            ConversationTurn(role: "user", text: "修复登录 bug", stopReason: nil),
            ConversationTurn(role: "assistant", text: "好的，我来看看", stopReason: "end_turn"),
            ConversationTurn(role: "user", text: "顺便加个测试", stopReason: nil),
            ConversationTurn(role: "assistant", text: "已加测试并跑通", stopReason: "end_turn"),
        ]
        let s = LocalSummarizer.summarize(turns: turns)
        XCTAssertTrue(s.contains("顺便加个测试"), "应含最后一条用户指令")
        XCTAssertTrue(s.contains("已加测试并跑通") || s.contains("end_turn"), "应含最近 assistant 动作")
    }

    func test_truncatesLongText() {
        let long = String(repeating: "字", count: 200)
        let s = LocalSummarizer.summarize(turns: [ConversationTurn(role: "user", text: long, stopReason: nil)],
                                          maxLen: 20)
        XCTAssertLessThanOrEqual(s.count, 100)
        XCTAssertTrue(s.contains("…"), "过长应截断加省略号")
    }

    func test_empty_returnsPlaceholder() {
        XCTAssertEqual(LocalSummarizer.summarize(turns: []), "（无可总结内容）")
    }

    func test_onlyAssistant_stillSummarizes() {
        let s = LocalSummarizer.summarize(turns: [ConversationTurn(role: "assistant", text: "分析完成", stopReason: "end_turn")])
        XCTAssertTrue(s.contains("分析完成"))
    }

    // 评审修复（AI m6）：不可信文本消毒——控制字符/bidi 覆盖符被滤除，stopReason 也限长。
    func test_sanitizes_controlAndBidiChars() {
        let evil = "正常\u{202E}倒序欺骗\u{0007}响铃"
        let s = LocalSummarizer.summarize(turns: [ConversationTurn(role: "user", text: evil, stopReason: nil)])
        XCTAssertFalse(s.contains("\u{202E}"), "RTL 覆盖符必须滤除")
        XCTAssertFalse(s.contains("\u{0007}"), "控制字符必须滤除")
        XCTAssertTrue(s.contains("正常"))
    }

    func test_stopReason_alsoTruncatedAndSanitized() {
        let longReason = String(repeating: "x", count: 500) + "\u{202E}"
        let s = LocalSummarizer.summarize(
            turns: [ConversationTurn(role: "assistant", text: "", stopReason: longReason)], maxLen: 20)
        XCTAssertFalse(s.contains("\u{202E}"))
        XCTAssertLessThan(s.count, 60, "stopReason 同样限长")
    }
}
