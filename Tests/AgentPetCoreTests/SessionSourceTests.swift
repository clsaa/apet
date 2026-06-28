import XCTest
@testable import AgentPetCore
final class SessionSourceTests: XCTestCase {
    func test_decode_defaults_to_hook() {
        let line = #"{"v":1,"eventId":"e","agent":"claude","event":"busy","sessionId":"s","root":"/r","ts":"t"}"#
        let ev = AgentEvent.decode(line: Substring(line))!
        XCTAssertEqual(ev.source, .hook)
    }
    func test_apply_propagates_jsonl_source_to_session() {
        let store = SessionStore()
        var ev = AgentEvent(v: 1, eventId: "e", agent: "claude", kind: .busy,
                            sessionId: "s", root: "/r", ts: "t")
        ev.source = .jsonl
        _ = store.apply(ev, seq: 1, now: 100, replay: false)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")
        XCTAssertEqual(store.sessions[key]?.source, .jsonl)
    }
}
