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
    func test_hook_not_downgraded_by_jsonl() {
        let store = SessionStore()
        let ev1 = AgentEvent(v: 1, eventId: "e1", agent: "claude", kind: .busy,
                             sessionId: "s", root: "/r", ts: "t") // source = .hook
        _ = store.apply(ev1, seq: 1, now: 100, replay: false)
        var ev2 = AgentEvent(v: 1, eventId: "e2", agent: "claude", kind: .busy,
                             sessionId: "s", root: "/r", ts: "t")
        ev2.source = .jsonl
        _ = store.apply(ev2, seq: 2, now: 101, replay: false)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")
        XCTAssertEqual(store.sessions[key]?.source, .hook) // hook 不被 jsonl 降级
    }
}
