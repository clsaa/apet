import XCTest
@testable import AppShellKit

final class JSONLParseTests: XCTestCase {

    // MARK: - Helper

    private func fx(_ filename: String) -> String {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: ext.isEmpty ? nil : ext,
            subdirectory: "fixtures/jsonl"
        ) else {
            XCTFail("Fixture not found: \(filename)")
            return ""
        }
        return url.path
    }

    // MARK: - Tests

    /// stop_reason 在 message 对象顶层，not inside content array
    func test_parse_stop_reason_from_message_top_level() {
        let f = JSONLParse.parse(path: fx("end_turn.jsonl"), root: "/r")!
        XCTAssertEqual(f.lastAssistantStopReason, "end_turn")
        XCTAssertNotNil(f.cwd)
        XCTAssertNotNil(f.lastAssistantTs)
    }

    /// 首行是 last-prompt（无 entrypoint），对话行带 entrypoint=sdk-cli → 必须读到（AI-B1）
    func test_parse_entrypoint_from_conversation_row_not_firstline() {
        let f = JSONLParse.parse(path: fx("sdk_cli.jsonl"), root: "/r")!
        XCTAssertEqual(f.entrypoint, "sdk-cli")
    }

    /// away_summary timestamp 晚于 lastAssistantTs
    func test_parse_away_ts_vs_assistant_ts() {
        let f = JSONLParse.parse(path: fx("away_after.jsonl"), root: "/r")!
        XCTAssertNotNil(f.lastAwayTs)
        XCTAssertNotNil(f.lastAssistantTs)
        XCTAssertGreaterThan(f.lastAwayTs!, f.lastAssistantTs!)
    }

    /// stop_reason==null → lastAssistantStopReason==nil
    func test_parse_null_stop_reason_falls_to_nil() {
        let f = JSONLParse.parse(path: fx("stopreason_null.jsonl"), root: "/r")!
        XCTAssertNil(f.lastAssistantStopReason)
    }

    /// customTitle 优先于 aiTitle / lastPrompt
    func test_parse_title_camelCase() {
        let f = JSONLParse.parse(path: fx("titled.jsonl"), root: "/r")!
        XCTAssertEqual(f.title, "devix-alarm")
    }

    /// tool_use 的 stop_reason 可正确提取
    func test_parse_tool_use_stop_reason() {
        let f = JSONLParse.parse(path: fx("tool_use_fresh.jsonl"), root: "/r")!
        XCTAssertEqual(f.lastAssistantStopReason, "tool_use")
    }

    /// isSidechain 任一行 true → ScannedFile.isSidechain==true
    func test_parse_sidechain_flag() {
        let f = JSONLParse.parse(path: fx("subagent.jsonl"), root: "/r")!
        XCTAssertTrue(f.isSidechain)
    }

    /// root 参数透传到 ScannedFile.root
    func test_parse_root_passthrough() {
        let f = JSONLParse.parse(path: fx("end_turn.jsonl"), root: "/custom/root")!
        XCTAssertEqual(f.root, "/custom/root")
    }

    /// cwd 从最后一条带 cwd 的对话行取
    func test_parse_cwd_from_last_conversation_row() {
        let f = JSONLParse.parse(path: fx("end_turn.jsonl"), root: "/r")!
        XCTAssertEqual(f.cwd, "/Users/test/proj")
    }

    /// lastPrompt 从 last-prompt 裸元数据行读取
    func test_parse_last_prompt_text() {
        let f = JSONLParse.parse(path: fx("end_turn.jsonl"), root: "/r")!
        XCTAssertEqual(f.lastPrompt, "explain this code")
    }
}
