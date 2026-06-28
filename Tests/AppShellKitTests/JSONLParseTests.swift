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
        // Fix 8：away_summary 是带 timestamp 的对话行，也应更新 lastConversationTs。
        // 该 away 行是文件末行，故 lastConversationTs 应等于 lastAwayTs。
        XCTAssertEqual(f.lastConversationTs!, f.lastAwayTs!)
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

    // MARK: - M1: ISO8601 无小数秒兜底

    /// M1 修复：无小数秒时间戳（"2026-06-28T10:01:00Z"）应能解析，lastAssistantTs 不应为 nil
    func test_parse_no_fractional_seconds_timestamp_parseable() {
        let f = JSONLParse.parse(path: fx("no_frac_ts.jsonl"), root: "/r")!
        XCTAssertNotNil(f.lastAssistantTs,
            "无小数秒 ISO8601 时间戳应能解析，lastAssistantTs 不应为 nil")
        XCTAssertEqual(f.lastAssistantStopReason, "end_turn")
    }

    // MARK: - M2: isSubagentPath 路径判断

    /// M2：路径含 /subagents/ 时，parse 应将 isSubagentPath 置为 true
    func test_parse_path_containing_subagents_dir_isSubagentPath() throws {
        // 在系统临时目录构造含 /subagents/ 的路径
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("apet-m2-\(UUID().uuidString)")
            .path
        let subagentsDir = (tmpBase as NSString).appendingPathComponent("projects/default/subagents")
        try FileManager.default.createDirectory(atPath: subagentsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpBase) }

        // 把 end_turn.jsonl 内容复制到 /subagents/ 子目录下
        let srcPath = fx("end_turn.jsonl")
        let dstPath = (subagentsDir as NSString).appendingPathComponent("session.jsonl")
        try FileManager.default.copyItem(atPath: srcPath, toPath: dstPath)

        let f = JSONLParse.parse(path: dstPath, root: "/r")!
        XCTAssertTrue(f.isSubagentPath,
            "路径含 /subagents/ 时 isSubagentPath 应为 true，实际路径：\(dstPath)")
    }

    // MARK: - M3: latestSubagentMtime 填充

    /// 主文件 <dir>/<sessionId>.jsonl 旁有 <dir>/<sessionId>/subagents/agent-x.jsonl
    /// → parse 应发现 subagent 文件并填充 latestSubagentMtime（值约等于该文件 mtime）
    func test_parse_subagentMtime_discovered() throws {
        let srcPath = fx("end_turn.jsonl")

        // 构造临时目录：<tmp>/<sessionId>.jsonl + <tmp>/<sessionId>/subagents/agent-x.jsonl
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("apet-subagent-\(UUID().uuidString)")
            .path
        let sessionId = "testsession-abc"
        let mainDir = tmpBase
        let subagentDir = (tmpBase as NSString)
            .appendingPathComponent("\(sessionId)/subagents")
        try FileManager.default.createDirectory(atPath: subagentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpBase) }

        // 主文件
        let mainPath = (mainDir as NSString).appendingPathComponent("\(sessionId).jsonl")
        try FileManager.default.copyItem(atPath: srcPath, toPath: mainPath)

        // subagent 文件（agent- 前缀 + .jsonl 后缀）
        let agentPath = (subagentDir as NSString).appendingPathComponent("agent-001.jsonl")
        try FileManager.default.copyItem(atPath: srcPath, toPath: agentPath)

        // 读取 agent 文件的实际 mtime 作为参考
        let agentAttrs = try FileManager.default.attributesOfItem(atPath: agentPath)
        let agentMtime = (agentAttrs[.modificationDate] as? Date)!.timeIntervalSince1970

        let f = JSONLParse.parse(path: mainPath, root: "/r")!
        XCTAssertNotNil(f.latestSubagentMtime,
            "存在 agent-*.jsonl 时 latestSubagentMtime 应不为 nil")
        XCTAssertEqual(f.latestSubagentMtime!, agentMtime, accuracy: 1.0,
            "latestSubagentMtime 应与 subagent 文件 mtime 基本一致")
    }

    /// 主文件旁无 subagent 目录 → latestSubagentMtime 应为 nil
    func test_parse_noSubagentDir_latestSubagentMtimeIsNil() {
        let f = JSONLParse.parse(path: fx("end_turn.jsonl"), root: "/r")!
        XCTAssertNil(f.latestSubagentMtime,
            "无 subagent 目录时 latestSubagentMtime 应为 nil")
    }
}
