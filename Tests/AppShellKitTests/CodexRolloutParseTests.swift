import XCTest
@testable import AppShellKit
import AgentPetCore

/// Codex rollout jsonl 解析(fixtures 取自本机真实 codex 0.118.0 会话,已脱敏)。
final class CodexRolloutParseTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "codex-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir); super.tearDown() }

    private func write(_ name: String, _ lines: [String]) -> String {
        let p = dir + "/" + name
        try! lines.joined(separator: "\n").write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    // 真实形态 fixture 行(脱敏)
    private let meta = #"{"timestamp":"2026-07-03T14:36:12.000Z","type":"session_meta","payload":{"session_id":"019f2868-9cf2-71a3-a941-9214c8231711","id":"019f2868-9cf2-71a3-a941-9214c8231711","cwd":"/Users/x/proj","originator":"cli","cli_version":"0.118.0"}}"#
    private let userMsg = #"{"timestamp":"2026-07-03T14:40:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"手机上的chatgpt 为什么无法连接你\n","images":[]}}"#
    private let started = #"{"timestamp":"2026-07-03T14:43:28.739Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#
    private let complete = #"{"timestamp":"2026-07-03T14:44:24.673Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"已排查"}}"#

    func test_sessionMeta_extracted() {
        let p = write("r.jsonl", [meta, userMsg, started, complete])
        let f = CodexRolloutParse.parse(path: p, root: "/Users/x/.codex")
        XCTAssertEqual(f?.sessionId, "019f2868-9cf2-71a3-a941-9214c8231711")
        XCTAssertEqual(f?.cwd, "/Users/x/proj")
        XCTAssertEqual(f?.root, "/Users/x/.codex")
    }

    func test_taskComplete_mapsToEndTurn() {
        let p = write("r.jsonl", [meta, started, complete])
        let f = CodexRolloutParse.parse(path: p, root: "/r")
        XCTAssertEqual(f?.lastAssistantStopReason, "end_turn", "complete≥started → 停下等你")
        XCTAssertNotNil(f?.lastAssistantTs)
    }

    func test_startedWithoutComplete_isMidTurn() {
        // 跑到一半:started 在 complete 之后 → 无 stopReason(scanner 按 runningWindow 判 running)
        let started2 = #"{"timestamp":"2026-07-03T14:50:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#
        let p = write("r.jsonl", [meta, started, complete, started2])
        let f = CodexRolloutParse.parse(path: p, root: "/r")
        XCTAssertNil(f?.lastAssistantStopReason)
        XCTAssertEqual(f!.lastAssistantTs!, 1_783_090_200, accuracy: 1, "取最新 started ts(2026-07-03T14:50Z)")
    }

    func test_lastUserMessage_becomesLastPrompt() {
        let p = write("r.jsonl", [meta, userMsg, started, complete])
        let f = CodexRolloutParse.parse(path: p, root: "/r")
        XCTAssertEqual(f?.lastPrompt, "手机上的chatgpt 为什么无法连接你\n")
    }

    func test_titleLookup_wins() {
        let p = write("r.jsonl", [meta, userMsg])
        let f = CodexRolloutParse.parse(path: p, root: "/r",
                                        titleLookup: { $0.hasPrefix("019f2868") ? "排查手机连接" : nil })
        XCTAssertEqual(f?.title, "排查手机连接")
    }

    func test_nonRolloutFile_returnsNil() {
        // 首行不是 session_meta(如 Claude 格式 jsonl / 垃圾文件)→ nil,不误吞别家会话
        let p1 = write("claude.jsonl", [#"{"type":"user","message":{"role":"user","content":"hi"}}"#])
        XCTAssertNil(CodexRolloutParse.parse(path: p1, root: "/r"))
        let p2 = write("garbage.jsonl", ["not json at all"])
        XCTAssertNil(CodexRolloutParse.parse(path: p2, root: "/r"))
    }

    func test_endToEnd_scanDerivesWaitingStop() {
        // 集成:parse → JSONLSessionScanner.scan → task_complete 会话判 waitingStop
        let p = write("r.jsonl", [meta, userMsg, started, complete])
        let f = CodexRolloutParse.parse(path: p, root: "/r")!
        // complete ts = 2026-07-03T14:44:24Z;now 设为其后 5 分钟(idleWindow 内)
        let now = f.lastAssistantTs! + 300
        let result = JSONLSessionScanner.scan(f, now: now, agent: "codex")
        guard case .observe(let state, let key, _, _) = result else {
            return XCTFail("应 observe,得 \(result)")
        }
        XCTAssertEqual(state, .waitingStop)
        XCTAssertEqual(key.agent, "codex")
        XCTAssertEqual(key.sessionId, "019f2868-9cf2-71a3-a941-9214c8231711")
    }

    // MARK: - CodexSessionIndex

    func test_index_loadsAndLatestWins() {
        let p = write("session_index.jsonl", [
            #"{"id":"aaa","thread_name":"旧名","updated_at":"2026-07-01T00:00:00Z"}"#,
            #"{"id":"aaa","thread_name":"新名","updated_at":"2026-07-03T00:00:00Z"}"#,
            "bad json line",
            #"{"id":"bbb","thread_name":"另一个","updated_at":"2026-07-02T00:00:00Z"}"#,
        ])
        let titles = CodexSessionIndex.load(path: p)
        XCTAssertEqual(titles["aaa"], "新名", "同 id 取最后一行")
        XCTAssertEqual(titles["bbb"], "另一个")
        XCTAssertEqual(titles.count, 2, "坏行跳过")
    }
}
