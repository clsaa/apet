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

    // MARK: - H3-6: Session.profileLabel

    func test_profileLabel_from_claude_profiles_root() {
        let key = SessionKey(agent: "a", root: "~/.claude-profiles/work", sessionId: "S")
        let session = Session(key: key, state: .running, lastSeq: 0, lastActiveAt: 0)
        XCTAssertEqual(session.profileLabel, "work")
    }

    func test_profileLabel_nil_for_standard_claude_root() {
        let key = SessionKey(agent: "a", root: "~/.claude", sessionId: "S")
        let session = Session(key: key, state: .running, lastSeq: 0, lastActiveAt: 0)
        XCTAssertNil(session.profileLabel)
    }
}
