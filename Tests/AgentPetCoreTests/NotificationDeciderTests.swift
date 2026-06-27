import XCTest
@testable import AgentPetCore

final class NotificationDeciderTests: XCTestCase {
    private func ev(_ kind: EventKind, notify: NotifyClass? = nil, title: String? = "Proj") -> AgentEvent {
        AgentEvent(v: 1, eventId: "E", agent: "a", kind: kind, sessionId: "S", root: "r",
                   title: title, notify: notify, ts: "t")
    }
    private let sess = Session(key: SessionKey(agent: "a", root: "r", sessionId: "S"),
                               state: .waiting(.attention), title: "Proj", lastSeq: 1, lastActiveAt: 0)

    func test_attention_rings_in_default_mode() {
        let d = NotificationDecider.decide(event: ev(.attention), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.shouldNotify)
        XCTAssertEqual(d.content?.title, "Proj")
    }

    func test_stop_silent_in_default_mode() {
        let d = NotificationDecider.decide(event: ev(.stop), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertFalse(d.shouldNotify)
    }

    func test_stop_rings_in_everyStop_mode() {
        let d = NotificationDecider.decide(event: ev(.stop), session: sess, mode: .everyStop, replay: false)
        XCTAssertTrue(d.shouldNotify)
    }

    func test_notify_none_override_silences_attention() {
        let d = NotificationDecider.decide(event: ev(.attention, notify: NotifyClass.none), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertFalse(d.shouldNotify)
    }

    func test_notify_alert_override_rings_stop_even_in_default_mode() {
        let d = NotificationDecider.decide(event: ev(.stop, notify: .alert), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.shouldNotify)
    }

    func test_replay_never_rings() {
        let d = NotificationDecider.decide(event: ev(.attention), session: sess, mode: .attentionOnly, replay: true)
        XCTAssertFalse(d.shouldNotify)
    }

    func test_busy_and_start_never_ring() {
        XCTAssertFalse(NotificationDecider.decide(event: ev(.busy), session: sess, mode: .everyStop, replay: false).shouldNotify)
        XCTAssertFalse(NotificationDecider.decide(event: ev(.sessionStart), session: sess, mode: .everyStop, replay: false).shouldNotify)
    }
}
