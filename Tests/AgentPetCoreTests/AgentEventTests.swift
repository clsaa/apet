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
}
