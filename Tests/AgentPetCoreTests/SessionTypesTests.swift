import XCTest
@testable import AgentPetCore

final class SessionTypesTests: XCTestCase {
    func test_sessionKey_from_event_uses_agent_root_sessionId() {
        let e = AgentEvent(v: 1, eventId: "E", agent: "claude-code", kind: .busy,
                           sessionId: "S1", root: "~/.claude", ts: "t")
        XCTAssertEqual(SessionKey(event: e),
                       SessionKey(agent: "claude-code", root: "~/.claude", sessionId: "S1"))
    }

    func test_same_sessionId_different_root_are_different_keys() {
        let k1 = SessionKey(agent: "a", root: "~/.claude", sessionId: "S")
        let k2 = SessionKey(agent: "a", root: "~/.claude-profiles/x", sessionId: "S")
        XCTAssertNotEqual(k1, k2)
    }

    func test_waiting_states_carry_reason() {
        XCTAssertNotEqual(SessionState.waiting(.stop), SessionState.waiting(.attention))
    }
}
