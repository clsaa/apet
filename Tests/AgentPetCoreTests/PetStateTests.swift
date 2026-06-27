import XCTest
@testable import AgentPetCore

final class PetStateTests: XCTestCase {
    private func push(_ s: SessionStore, _ id: String, _ kind: EventKind, sid: String, seq: Int) {
        _ = s.apply(AgentEvent(v: 1, eventId: id, agent: "a", kind: kind, sessionId: sid, root: "r", ts: "t"),
                    seq: seq, now: 0, replay: false)
    }

    func test_any_running_means_busy() {
        let s = SessionStore()
        push(s, "E1", .stop, sid: "A", seq: 1)        // A waiting
        push(s, "E2", .sessionStart, sid: "B", seq: 2) // B running
        XCTAssertEqual(s.aggregateState(), .busy)
    }

    func test_no_running_but_waiting_means_calling() {
        let s = SessionStore()
        push(s, "E1", .stop, sid: "A", seq: 1)
        XCTAssertEqual(s.aggregateState(), .calling)
    }

    func test_all_ended_means_idle() {
        let s = SessionStore()
        push(s, "E1", .sessionEnd, sid: "A", seq: 1)
        XCTAssertEqual(s.aggregateState(), .idle)
    }

    func test_empty_means_idle() {
        XCTAssertEqual(SessionStore().aggregateState(), .idle)
    }

    func test_activeSessions_excludes_ended() {
        let s = SessionStore()
        push(s, "E1", .sessionStart, sid: "A", seq: 1)
        push(s, "E2", .sessionEnd, sid: "B", seq: 2)
        let active = s.activeSessions()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.key.sessionId, "A")
    }
}
