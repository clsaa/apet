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
}
