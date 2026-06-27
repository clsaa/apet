import XCTest
@testable import AgentPetCore

final class NDJSONIngestorTests: XCTestCase {
    private func line(_ id: String, _ event: String, sid: String = "S") -> String {
        #"{"v":1,"eventId":"\#(id)","agent":"a","event":"\#(event)","sessionId":"\#(sid)","root":"r","ts":"t"}"#
    }

    func test_assigns_monotonic_seq_so_append_order_is_truth() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        _ = ing.ingest(line: Substring(line("E1", "session_start")), now: 0, replay: false)
        _ = ing.ingest(line: Substring(line("E2", "stop")), now: 0, replay: false)
        XCTAssertEqual(store.sessions.values.first?.state, .waiting(.stop))
        XCTAssertEqual(ing.consumedSeq, 2)
    }

    func test_bad_line_skipped_without_consuming_seq() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        let changes = ing.ingest(line: "garbage{", now: 0, replay: false)
        XCTAssertEqual(changes, [])
        XCTAssertEqual(ing.consumedSeq, 0)        // 坏行不占 seq
    }

    func test_multiline_text_ingest_in_order() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        let text = line("E1", "session_start") + "\n" + "broken\n" + line("E2", "stop")
        _ = ing.ingest(text: text, now: 0, replay: false)
        XCTAssertEqual(store.sessions.values.first?.state, .waiting(.stop)) // 坏行被跳过
        XCTAssertEqual(ing.consumedSeq, 2)
    }

    func test_replay_flag_is_forwarded_to_store() {
        // 通过 store 行为间接验证：回放重复 eventId 仍被去重
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        _ = ing.ingest(line: Substring(line("E1", "session_start")), now: 0, replay: false)
        let again = ing.ingest(line: Substring(line("E1", "stop")), now: 0, replay: true)
        XCTAssertEqual(again, [])  // 同 eventId 去重
        XCTAssertEqual(store.sessions.values.first?.state, .running)
    }

    // MARK: - H3 新增：startSeq / ingest(text:) / 空坏输入

    /// startSeq=5 → 第一条行的 seq=6，consumedSeq=6，store lastSeq=6
    func test_startSeq_nonzero_offsets_seq() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store, startSeq: 5)
        _ = ing.ingest(line: Substring(line("E1", "session_start")), now: 0, replay: false)
        XCTAssertEqual(ing.consumedSeq, 6)
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        XCTAssertEqual(store.sessions[key]?.lastSeq, 6)
    }

    /// startSeq 与已有 lastSeq 配合：seq 落后被拒；seq 超前被接受
    func test_startSeq_interplay_with_existing_lastSeq() {
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")

        // Scenario A: store lastSeq=6, ingestor startSeq=5 → produces seq=6 ≤ 6 → rejected
        let store1 = SessionStore()
        _ = store1.apply(AgentEvent(v: 1, eventId: "E0", agent: "a", kind: .sessionStart,
                        sessionId: "S", root: "r", ts: "t"), seq: 6, now: 0, replay: false)
        let ing1 = NDJSONIngestor(store: store1, startSeq: 5)
        let changes1 = ing1.ingest(line: Substring(line("E1", "stop")), now: 0, replay: false)
        XCTAssertEqual(changes1, [])
        XCTAssertEqual(store1.sessions[key]?.state, .running)

        // Scenario B: store lastSeq=4, ingestor startSeq=4 → produces seq=5 > 4 → accepted
        let store2 = SessionStore()
        _ = store2.apply(AgentEvent(v: 1, eventId: "E3", agent: "a", kind: .sessionStart,
                        sessionId: "S", root: "r", ts: "t"), seq: 4, now: 0, replay: false)
        let ing2 = NDJSONIngestor(store: store2, startSeq: 4)
        let changes2 = ing2.ingest(line: Substring(line("E4", "stop")), now: 0, replay: false)
        XCTAssertFalse(changes2.isEmpty)
        XCTAssertEqual(store2.sessions[key]?.state, .waiting(.stop))
    }

    /// ingest(text:) 返回所有新建会话的变更（2 个不同 sessionId → count==2）
    func test_ingest_text_returns_count_of_new_sessions() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        let text = line("E1", "session_start", sid: "S1") + "\n" + line("E2", "session_start", sid: "S2")
        let changes = ing.ingest(text: text, now: 0, replay: false)
        XCTAssertEqual(changes.count, 2)
    }

    /// 空串和全坏输入 → 返回 []，consumedSeq 不变
    func test_empty_and_all_bad_input_returns_empty() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)

        let c1 = ing.ingest(text: "", now: 0, replay: false)
        XCTAssertEqual(c1, [])
        XCTAssertEqual(ing.consumedSeq, 0)

        let c2 = ing.ingest(text: "bad1\nbad2", now: 0, replay: false)
        XCTAssertEqual(c2, [])
        XCTAssertEqual(ing.consumedSeq, 0)
    }

    // MARK: - ingest(event:) overload (M-1 avoid double decode)

    /// ingest(event:) 分配单调序列号，两次调用得到 seq 1 和 2。
    func test_ingest_event_assigns_monotonic_seq() {
        // TC-INGEST-FUNC-10
        // Given: 空 store，两个不同 eventId 的 session_start 事件
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        let e1 = AgentEvent(v: 1, eventId: "EV-1", agent: "a", kind: .sessionStart,
                            sessionId: "S1", root: "r", ts: "t")
        let e2 = AgentEvent(v: 1, eventId: "EV-2", agent: "a", kind: .stop,
                            sessionId: "S1", root: "r", ts: "t")

        // When: 两次 ingest(event:)
        let c1 = ing.ingest(event: e1, now: 0, replay: false)
        let c2 = ing.ingest(event: e2, now: 0, replay: false)

        // Then: seq 递增为 1、2；store 状态为 stop
        XCTAssertFalse(c1.isEmpty, "第一个事件应产生变更")
        XCTAssertFalse(c2.isEmpty, "第二个事件应产生变更")
        XCTAssertEqual(ing.consumedSeq, 2)
        let key = SessionKey(agent: "a", root: "r", sessionId: "S1")
        XCTAssertEqual(store.sessions[key]?.lastSeq, 2)
        XCTAssertEqual(store.sessions[key]?.state, .waiting(.stop))
    }

    /// ingest(event:) 与 ingest(line:) 共享同一 seq 计数器。
    func test_ingest_event_and_line_share_seq_counter() {
        // TC-INGEST-FUNC-11
        // Given: 先用 ingest(line:) 产生 seq=1，再用 ingest(event:) 产生 seq=2
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        _ = ing.ingest(line: Substring(line("EL1", "session_start")), now: 0, replay: false)
        XCTAssertEqual(ing.consumedSeq, 1)

        let e2 = AgentEvent(v: 1, eventId: "EE2", agent: "a", kind: .stop,
                            sessionId: "S", root: "r", ts: "t")
        _ = ing.ingest(event: e2, now: 0, replay: false)

        // Then: seq 连续增长到 2
        XCTAssertEqual(ing.consumedSeq, 2)
    }

    /// H3-9: 含 \r\n 行尾的合法 NDJSON 行正常解码（CRLF 健壮性）
    func test_crlf_line_ending_is_handled_gracefully() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        let crlfLine = Substring(line("E1", "session_start") + "\r")
        let changes = ing.ingest(line: crlfLine, now: 0, replay: false)
        XCTAssertFalse(changes.isEmpty, "CRLF 行应正常解码并产生变更")
        XCTAssertEqual(store.sessions.values.first?.state, .running)
    }
}
