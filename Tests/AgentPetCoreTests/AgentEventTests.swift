import XCTest
@testable import AgentPetCore

final class AgentEventTests: XCTestCase {
    func test_decodes_full_event_line() {
        let line = #"{"v":1,"eventId":"E1","agent":"claude-code","event":"stop","sessionId":"S1","root":"~/.claude","cwd":"/p","title":"proj","terminal":{"kind":"iterm2","itermSessionId":"w0t1p0"},"reason":"stop","ts":"2026-06-27T10:00:00.000Z"}"#
        let e = AgentEvent.decode(line: Substring(line))
        XCTAssertEqual(e?.eventId, "E1")
        XCTAssertEqual(e?.kind, .stop)
        XCTAssertEqual(e?.sessionId, "S1")
        XCTAssertEqual(e?.root, "~/.claude")
        XCTAssertEqual(e?.terminal?.kind, .iterm2)
        XCTAssertEqual(e?.terminal?.itermSessionId, "w0t1p0")
        XCTAssertEqual(e?.reason, .stop)
    }

    func test_unknown_event_kind_is_preserved_not_dropped() {
        let line = #"{"v":1,"eventId":"E2","agent":"a","event":"compacting","sessionId":"S","root":"r","ts":"t"}"#
        let e = AgentEvent.decode(line: Substring(line))
        XCTAssertEqual(e?.kind, .unknown("compacting"))
    }

    func test_bad_line_returns_nil_not_throws() {
        XCTAssertNil(AgentEvent.decode(line: "not json"))
        XCTAssertNil(AgentEvent.decode(line: ""))
    }

    func test_optional_fields_absent_is_ok() {
        let line = #"{"v":1,"eventId":"E3","agent":"a","event":"busy","sessionId":"S","root":"r","ts":"t"}"#
        let e = AgentEvent.decode(line: Substring(line))
        XCTAssertNil(e?.cwd)
        XCTAssertNil(e?.terminal)
        XCTAssertEqual(e?.kind, .busy)
    }

    /// B5: 未知 reason rawValue 不丢整条事件，字段降为 nil
    func test_unknown_reason_value_keeps_event_with_nil_reason() {
        let line = #"{"v":1,"eventId":"E","agent":"a","event":"stop","sessionId":"S","root":"r","reason":"focus","ts":"t"}"#
        let e = AgentEvent.decode(line: Substring(line))
        XCTAssertNotNil(e)
        XCTAssertEqual(e?.kind, .stop)
        XCTAssertNil(e?.reason)
    }

    /// B5: 未知 notify rawValue 不丢整条事件，字段降为 nil
    func test_unknown_notify_value_keeps_event_with_nil_notify() {
        let line = #"{"v":1,"eventId":"E","agent":"a","event":"busy","sessionId":"S","root":"r","notify":"weird","ts":"t"}"#
        let e = AgentEvent.decode(line: Substring(line))
        XCTAssertNotNil(e)
        XCTAssertNil(e?.notify)
    }

    // MARK: - H2 补强

    func test_empty_json_object_returns_nil() {
        XCTAssertNil(AgentEvent.decode(line: "{}"))
    }

    func test_missing_each_required_field_returns_nil() {
        // 缺 eventId
        XCTAssertNil(AgentEvent.decode(line: #"{"agent":"a","event":"stop","sessionId":"S","root":"r","ts":"t"}"#))
        // 缺 agent
        XCTAssertNil(AgentEvent.decode(line: #"{"eventId":"E","event":"stop","sessionId":"S","root":"r","ts":"t"}"#))
        // 缺 event
        XCTAssertNil(AgentEvent.decode(line: #"{"eventId":"E","agent":"a","sessionId":"S","root":"r","ts":"t"}"#))
        // 缺 sessionId
        XCTAssertNil(AgentEvent.decode(line: #"{"eventId":"E","agent":"a","event":"stop","root":"r","ts":"t"}"#))
        // 缺 root
        XCTAssertNil(AgentEvent.decode(line: #"{"eventId":"E","agent":"a","event":"stop","sessionId":"S","ts":"t"}"#))
        // 缺 ts
        XCTAssertNil(AgentEvent.decode(line: #"{"eventId":"E","agent":"a","event":"stop","sessionId":"S","root":"r"}"#))
    }

    func test_unknown_terminal_kind_falls_to_other() {
        let line = #"{"eventId":"E","agent":"a","event":"stop","sessionId":"S","root":"r","ts":"t","terminal":{"kind":"hyper","itermSessionId":"w0t1p0"}}"#
        let e = AgentEvent.decode(line: Substring(line))
        XCTAssertEqual(e?.terminal?.kind, .other)
        XCTAssertEqual(e?.terminal?.itermSessionId, "w0t1p0")
    }

    func test_missing_terminal_kind_falls_to_other() {
        let line = #"{"eventId":"E","agent":"a","event":"stop","sessionId":"S","root":"r","ts":"t","terminal":{"itermSessionId":"w0t1p0"}}"#
        let e = AgentEvent.decode(line: Substring(line))
        XCTAssertEqual(e?.terminal?.kind, .other)
    }

    func test_v_absent_defaults_to_1() {
        let line = #"{"eventId":"E","agent":"a","event":"stop","sessionId":"S","root":"r","ts":"t"}"#
        let e = AgentEvent.decode(line: Substring(line))
        XCTAssertEqual(e?.v, 1)
    }
}
