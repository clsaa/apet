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
    /// 显式钉 mtime(缓存失效测试必需:同秒两次写 mtime 可能不变,不可依赖真实时钟)。
    private func setMtime(_ path: String, _ epoch: Double) {
        try! FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: epoch)], ofItemAtPath: path)
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

    func test_newerStarted_overridesOlderComplete_isMidTurn() {
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
            #"{"id":"ccc","thread_name":"","updated_at":"2026-07-02T00:00:00Z"}"#,
            #"{"id":"bbb","thread_name":"另一个","updated_at":"2026-07-02T00:00:00Z"}"#,
        ])
        let titles = CodexSessionIndex.load(path: p)
        XCTAssertEqual(titles["aaa"], "新名", "同 id 取最后一行")
        XCTAssertEqual(titles["bbb"], "另一个")
        XCTAssertEqual(titles.count, 2, "坏行/空名跳过")
    }

    // MARK: - 评审补测(M1 index 缓存 / M2 四象限 / M3 长轮次 / M5 集成链 / minors)

    func test_index_titleFor_mtimeChange_invalidatesCache() {
        let p = write("session_index.jsonl",
                      [#"{"id":"aaa","thread_name":"旧名","updated_at":"2026-07-01T00:00:00Z"}"#])
        setMtime(p, 1_783_000_000)
        let idx = CodexSessionIndex(path: p)
        XCTAssertEqual(idx.title(for: "aaa"), "旧名")
        _ = write("session_index.jsonl",
                  [#"{"id":"aaa","thread_name":"新名","updated_at":"2026-07-03T00:00:00Z"}"#])
        setMtime(p, 1_783_000_100)
        XCTAssertEqual(idx.title(for: "aaa"), "新名", "mtime 变 → 缓存失效重读")
    }

    func test_index_titleFor_sameMtime_servesCache() {
        let p = write("session_index.jsonl",
                      [#"{"id":"aaa","thread_name":"旧名","updated_at":"2026-07-01T00:00:00Z"}"#])
        setMtime(p, 1_783_000_000)
        let idx = CodexSessionIndex(path: p)
        XCTAssertEqual(idx.title(for: "aaa"), "旧名")
        _ = write("session_index.jsonl",
                  [#"{"id":"aaa","thread_name":"新名","updated_at":"2026-07-03T00:00:00Z"}"#])
        setMtime(p, 1_783_000_000)   // mtime 不变
        XCTAssertEqual(idx.title(for: "aaa"), "旧名", "mtime 不变 → 吃缓存(已知取舍:秒级粒度)")
    }

    func test_index_titleFor_missingFile_thenAppears() {
        let p = dir + "/no_index.jsonl"
        let idx = CodexSessionIndex(path: p)
        XCTAssertNil(idx.title(for: "aaa"), "索引不存在 → nil 不崩")
        _ = write("no_index.jsonl",
                  [#"{"id":"aaa","thread_name":"迟到","updated_at":"2026-07-03T00:00:00Z"}"#])
        setMtime(p, 1_783_000_000)
        XCTAssertEqual(idx.title(for: "aaa"), "迟到")
    }

    func test_metaOnly_noTurnSignals_fallsToMtime() {
        let p = write("r.jsonl", [meta])
        let f = CodexRolloutParse.parse(path: p, root: "/r")
        XCTAssertNotNil(f, "只有 meta 也应产出 ScannedFile,不能丢会话")
        XCTAssertNil(f?.lastAssistantStopReason)
        XCTAssertNil(f?.lastAssistantTs, "无任何 assistant 活动 → nil(scanner 判 stale)")
    }

    func test_startedTrulyWithoutComplete_isMidTurn() {
        let p = write("r.jsonl", [meta, userMsg, started])
        let f = CodexRolloutParse.parse(path: p, root: "/r")
        XCTAssertNil(f?.lastAssistantStopReason)
        XCTAssertEqual(f!.lastAssistantTs!, 1_783_089_808.739, accuracy: 1, "ts=最后 started")
    }

    func test_completeOnly_startedOutOfTailWindow_mapsToEndTurn() {
        let p = write("r.jsonl", [meta, started, userMsg, complete])
        let f = CodexRolloutParse.parse(path: p, root: "/r", maxLines: 2)
        XCTAssertEqual(f?.lastAssistantStopReason, "end_turn")
        XCTAssertEqual(f!.lastAssistantTs!, 1_783_089_864.673, accuracy: 1)
    }

    func test_longTurn_bothSignalsOutOfTailWindow_activityFallback_running() {
        // M3 修复验证:长轮次 started 掉出尾窗,response_item 活动 ts 兜底 → running(不再误 stale)
        let filler = (0..<5).map { i in
            "{\"timestamp\":\"2026-07-03T14:51:0\(i).000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\"}}"
        }
        let p = write("r.jsonl", [meta, started] + filler)
        let f = CodexRolloutParse.parse(path: p, root: "/r", maxLines: 4)!
        XCTAssertNotNil(f.lastAssistantTs, "活动 ts 兜底")
        let result = JSONLSessionScanner.scan(f, now: 1_783_090_320, agent: "codex") // 末行后 ~56s
        guard case .observe(let state, _, _, _) = result else { return XCTFail("应 observe,得 \(result)") }
        XCTAssertEqual(state, .running, "热文件不得误判 stale(评审 M3 修复)")
    }

    func test_endToEnd_scanDerivesRunning() {
        let p = write("r.jsonl", [meta, userMsg, started])
        let f = CodexRolloutParse.parse(path: p, root: "/r")!
        let result = JSONLSessionScanner.scan(f, now: f.lastAssistantTs! + 60, agent: "codex")
        guard case .observe(let state, let key, _, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(state, .running)
        XCTAssertEqual(key.agent, "codex")
    }

    func test_endToEnd_metaOnly_scanDerivesStale() {
        let p = write("r.jsonl", [meta])
        let f = CodexRolloutParse.parse(path: p, root: "/r")!
        let result = JSONLSessionScanner.scan(f, now: 1_783_089_372 + 300, agent: "codex")
        guard case .observe(let state, _, _, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(state, .stale)
    }

    func test_endToEnd_oldSession_ignoredTooOld() {
        let p = write("r.jsonl", [meta, userMsg, started, complete])
        let f = CodexRolloutParse.parse(path: p, root: "/r")!
        let result = JSONLSessionScanner.scan(f, now: f.lastAssistantTs! + 1801, agent: "codex")
        XCTAssertEqual(result, .ignore(.tooOld))
    }

    func test_threadName_bidiAndControlChars_strippedBeforePanel() {
        // 评审 M4:半可信 thread_name 的 bidi/控制字符须在进面板前剥离(DisplaySanitizer)。
        let evil = "排查\u{202E}gpj.exe\u{07} 第二行"
        let obj: [String: Any] = ["id": "019f2868-9cf2-71a3-a941-9214c8231711",
                                  "thread_name": evil,
                                  "updated_at": "2026-07-03T00:00:00Z"]
        let line = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        let titles = CodexSessionIndex.load(path: write("session_index.jsonl", [line]))
        let p = write("r.jsonl", [meta, userMsg, started, complete])
        let f = CodexRolloutParse.parse(path: p, root: "/r", titleLookup: { titles[$0] })!
        guard case .observe(_, let key, _, let title) =
                JSONLSessionScanner.scan(f, now: f.lastAssistantTs! + 300, agent: "codex") else {
            return XCTFail("应 observe")
        }
        let session = Session(key: key, state: .waiting(.stop), title: title,
                              lastSeq: 1, lastActiveAt: 0, source: .jsonl)
        let row = SessionRowMapper.make(session)
        XCTAssertFalse(row.title.unicodeScalars.contains {
            $0 == "\u{202E}" || $0.properties.generalCategory == .control
        }, "bidi/控制字符必须在展示边界剥离: \(row.title)")
        XCTAssertTrue(row.title.contains("排查"), "正常内容保留")
    }

    func test_hugeTailLineExceedingMaxBytes_currentlyReturnsNil() {
        let huge = "{\"timestamp\":\"2026-07-03T14:40:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"\(String(repeating: "长", count: 2000))\"}}"
        let p = write("r.jsonl", [meta, huge])
        XCTAssertNil(CodexRolloutParse.parse(path: p, root: "/r", maxBytes: 1024),
                     "尾窗无换行 → nil(缺口注记:更诚实的降级是 mtime-only ScannedFile)")
    }

    func test_completeWithGarbageTimestamp_doesNotMapEndTurn() {
        let badComplete = #"{"timestamp":"not-a-date","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#
        let p = write("r.jsonl", [meta, started, badComplete])
        let f = CodexRolloutParse.parse(path: p, root: "/r")
        XCTAssertNil(f?.lastAssistantStopReason, "垃圾 ts 的 complete 作废 → 半途分支")
        XCTAssertEqual(f!.lastAssistantTs!, 1_783_089_808.739, accuracy: 1)
    }

    func test_metaWithoutCwd_stillParses() {
        let noCwd = #"{"timestamp":"2026-07-03T14:36:12.000Z","type":"session_meta","payload":{"id":"019f2868-9cf2-71a3-a941-9214c8231711","originator":"cli"}}"#
        let f = CodexRolloutParse.parse(path: write("r.jsonl", [noCwd, started, complete]), root: "/r")
        XCTAssertNotNil(f, "cwd 缺失不丢会话")
        XCTAssertNil(f?.cwd)
        XCTAssertEqual(f?.lastAssistantStopReason, "end_turn")
    }

    func test_emptyFile_returnsNil() {
        XCTAssertNil(CodexRolloutParse.parse(path: write("empty.jsonl", []), root: "/r"))
    }

    func test_metaWithEmptyId_returnsNil() {
        let bad = #"{"timestamp":"2026-07-03T14:36:12.000Z","type":"session_meta","payload":{"id":"","cwd":"/x"}}"#
        XCTAssertNil(CodexRolloutParse.parse(path: write("r.jsonl", [bad]), root: "/r"))
    }

    func test_meta_sessionIdKeyFallback() {
        let m = #"{"timestamp":"2026-07-03T14:36:12.000Z","type":"session_meta","payload":{"session_id":"019f2868-9cf2-71a3-a941-9214c8231711","cwd":"/x"}}"#
        XCTAssertEqual(CodexRolloutParse.parse(path: write("r.jsonl", [m]), root: "/r")?.sessionId,
                       "019f2868-9cf2-71a3-a941-9214c8231711")
    }

    func test_resumeAppendsSecondMeta_firstLineIdentityWins() {
        let meta2 = #"{"timestamp":"2026-07-03T15:00:00.000Z","type":"session_meta","payload":{"id":"ffffffff-0000-0000-0000-000000000000","cwd":"/other"}}"#
        let f = CodexRolloutParse.parse(path: write("r.jsonl", [meta, started, complete, meta2]), root: "/r")
        XCTAssertEqual(f?.sessionId, "019f2868-9cf2-71a3-a941-9214c8231711", "resume 追加 meta 不改身份")
        XCTAssertEqual(f?.cwd, "/other", "cwd 取最新 meta(换目录 resume 后不显示旧目录,评审 Minor-3)")
    }

    // MARK: - 评审二轮补测(turn_aborted / cwd 最新 / 附件前缀 / 伪 id)

    func test_turnAborted_treatedAsTurnEnd() {
        // 用户 Esc 中断:盘上 turn_aborted 无 task_complete(上游 policy.rs 实证)→ 视作轮次终结
        let aborted = #"{"timestamp":"2026-07-03T14:45:00.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t2"}}"#
        let started2 = #"{"timestamp":"2026-07-03T14:44:50.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#
        let p = write("r.jsonl", [meta, started, complete, started2, aborted])
        let f = CodexRolloutParse.parse(path: p, root: "/r")
        XCTAssertEqual(f?.lastAssistantStopReason, "end_turn", "中断=停下等你,不是 running")
    }

    func test_laterTurnContext_cwdOverridesFirstMeta() {
        // 换目录 resume:turn_context 带新 cwd,应覆盖首行旧值
        let tc = #"{"timestamp":"2026-07-03T15:00:00.000Z","type":"turn_context","payload":{"cwd":"/Users/x/new-proj"}}"#
        let p = write("r.jsonl", [meta, started, complete, tc])
        XCTAssertEqual(CodexRolloutParse.parse(path: p, root: "/r")?.cwd, "/Users/x/new-proj")
    }

    func test_filesMentionedInjection_skippedAsPrompt() {
        // CLI 粘贴附件时注入的清单不是用户正文,不该成为 lastPrompt
        let inj = #"{"timestamp":"2026-07-03T14:41:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"\n# Files mentioned by the user:\n\n## codex-clipboard-xxx"}}"#
        let p = write("r.jsonl", [meta, userMsg, inj, started, complete])
        XCTAssertEqual(CodexRolloutParse.parse(path: p, root: "/r")?.lastPrompt,
                       "手机上的chatgpt 为什么无法连接你\n", "附件清单注入跳过,保留真用户消息")
    }

    func test_forgedSessionId_rejected() {
        // 伪 id(shell 元字符)不得进 store/剪贴板(架构评审 Minor-2)
        let bad = #"{"timestamp":"2026-07-03T14:36:12.000Z","type":"session_meta","payload":{"id":"$(rm -rf ~)","cwd":"/x"}}"#
        XCTAssertNil(CodexRolloutParse.parse(path: write("r.jsonl", [bad]), root: "/r"))
    }

    // MARK: - Desktop vs CLI 分流(用户需求:区分两端)

    func test_desktopMeta_classifiedAsCodexDesktop() {
        let dm = #"{"timestamp":"2026-07-03T14:36:12.000Z","type":"session_meta","payload":{"id":"019f2868-9cf2-71a3-a941-9214c8231711","cwd":"/x","originator":"Codex Desktop","source":"vscode"}}"#
        let f = CodexRolloutParse.parse(path: write("r.jsonl", [dm, started, complete]), root: "/r")!
        XCTAssertEqual(f.agentOverride, "codex-desktop")
        guard case .observe(_, let key, _, _) = JSONLSessionScanner.scan(f, now: f.lastAssistantTs! + 60, agent: "codex") else { return XCTFail() }
        XCTAssertEqual(key.agent, "codex-desktop", "scan key 用 override")
    }

    func test_cliMeta_staysCodex() {
        let cm = #"{"timestamp":"2026-07-03T14:36:12.000Z","type":"session_meta","payload":{"id":"019f2868-9cf2-71a3-a941-9214c8231711","cwd":"/x","originator":"codex-tui","source":"cli"}}"#
        XCTAssertNil(CodexRolloutParse.parse(path: write("r.jsonl", [cm, started]), root: "/r")?.agentOverride)
    }

    func test_unknownSource_defaultsToCli() {
        // 老版本无 source/originator → 默认 CLI(宁少跳转,不乱激活 App)
        XCTAssertNil(CodexRolloutParse.parse(path: write("r.jsonl", [meta, started]), root: "/r")?.agentOverride,
                     "fixture originator=cli 无 source → CLI")
    }

    func test_mixedOriginators_identityFromFirstMeta() {
        // 真机实锤:会话先 Desktop 后 CLI 混用 → 身份取首条,不漂移
        let dm = #"{"timestamp":"2026-07-03T14:36:12.000Z","type":"session_meta","payload":{"id":"019f2868-9cf2-71a3-a941-9214c8231711","cwd":"/x","source":"vscode"}}"#
        let cm2 = #"{"timestamp":"2026-07-03T15:00:00.000Z","type":"session_meta","payload":{"id":"019f2868-9cf2-71a3-a941-9214c8231711","cwd":"/x","source":"cli"}}"#
        let f = CodexRolloutParse.parse(path: write("r.jsonl", [dm, started, complete, cm2]), root: "/r")
        XCTAssertEqual(f?.agentOverride, "codex-desktop", "首条 Desktop → 恒 desktop,后续 CLI meta 不改身份")
    }
}
