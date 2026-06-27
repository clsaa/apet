import XCTest
@testable import AgentPetCore

final class SessionStoreMergeTests: XCTestCase {
    func test_terminal_not_overwritten_by_later_nil() {
        let s = SessionStore()
        let withTerm = AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
            sessionId: "S", root: "r", terminal: TerminalRef(kind: .iterm2, itermSessionId: "w0t1p0"), ts: "t")
        let noTerm = AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .stop,
            sessionId: "S", root: "r", terminal: nil, ts: "t")
        _ = s.apply(withTerm, seq: 1, now: 0, replay: false)
        _ = s.apply(noTerm, seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.terminal?.itermSessionId, "w0t1p0") // 保留
    }

    func test_cwd_and_title_filled_in_when_later_event_provides_them() {
        let s = SessionStore()
        let e1 = AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
            sessionId: "S", root: "r", cwd: nil, title: nil, ts: "t")
        let e2 = AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .stop,
            sessionId: "S", root: "r", cwd: "/proj", title: "Proj", ts: "t")
        _ = s.apply(e1, seq: 1, now: 0, replay: false)
        _ = s.apply(e2, seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.cwd, "/proj")
        XCTAssertEqual(s.sessions.values.first?.title, "Proj")
    }

    // MARK: - H2 补强

    /// cwd 非空值不被后续 nil 覆盖
    func test_cwd_not_overwritten_by_nil() {
        let s = SessionStore()
        let e1 = AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                            sessionId: "S", root: "r", cwd: "/p", ts: "t")
        let e2 = AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .stop,
                            sessionId: "S", root: "r", cwd: nil, ts: "t")
        _ = s.apply(e1, seq: 1, now: 0, replay: false)
        _ = s.apply(e2, seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.cwd, "/p")
    }
}
