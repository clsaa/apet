import XCTest
@testable import AppShellKit
import AgentPetCore

/// Unit tests for `NotificationGate` — pure logic, no system side-effects.
final class NotificationGateTests: XCTestCase {

    // MARK: - Helpers

    private func makeAttentionEvent(
        agent: String = "claude",
        root: String = "/root/proj",
        sessionId: String = "s1",
        eventId: String = "e1"
    ) -> AgentEvent {
        AgentEvent(
            v: 1, eventId: eventId, agent: agent,
            kind: .attention, sessionId: sessionId, root: root,
            ts: "2026-01-01T00:00:00Z"
        )
    }

    private func makeStopEvent(
        agent: String = "claude",
        root: String = "/root/proj",
        sessionId: String = "s1",
        eventId: String = "e2"
    ) -> AgentEvent {
        AgentEvent(
            v: 1, eventId: eventId, agent: agent,
            kind: .stop, sessionId: sessionId, root: root,
            ts: "2026-01-01T00:00:00Z"
        )
    }

    // MARK: - TC-GATE-FUNC-001: attention, attentionOnly, first call → content delivered

    func testAttentionFirstCall_ReturnsContent() {
        var gate = NotificationGate(cooldown: 30.0)
        let event = makeAttentionEvent()

        let result = gate.evaluate(event: event, session: nil,
                                   mode: .attentionOnly, replay: false, now: 100.0)

        XCTAssertNotNil(result, "attention event on first call should produce content")
        // title falls back to event.agent when no event.title or session.title
        XCTAssertEqual(result?.title, "claude")
        // body: no session → no projectTag → just the default body
        XCTAssertEqual(result?.body, "需要你输入")
    }

    // MARK: - TC-GATE-THROTTLE-001: same key+kind within cooldown → nil

    func testAttentionWithinCooldown_ReturnsNil() {
        var gate = NotificationGate(cooldown: 30.0)
        let event = makeAttentionEvent()

        _ = gate.evaluate(event: event, session: nil,
                          mode: .attentionOnly, replay: false, now: 100.0)

        let result = gate.evaluate(event: event, session: nil,
                                   mode: .attentionOnly, replay: false, now: 110.0)

        XCTAssertNil(result, "second call within cooldown (10 s < 30 s) should be throttled")
    }

    // MARK: - TC-GATE-FUNC-002: stop, attentionOnly → nil (decider suppresses)

    func testStopEvent_AttentionOnly_ReturnsNil() {
        var gate = NotificationGate(cooldown: 30.0)
        let event = makeStopEvent()

        let result = gate.evaluate(event: event, session: nil,
                                   mode: .attentionOnly, replay: false, now: 100.0)

        XCTAssertNil(result, "stop event in attentionOnly mode should be suppressed by decider")
    }

    // MARK: - TC-GATE-FUNC-003: stop, everyStop → content delivered

    func testStopEvent_EveryStop_ReturnsContent() {
        var gate = NotificationGate(cooldown: 30.0)
        let event = makeStopEvent()

        let result = gate.evaluate(event: event, session: nil,
                                   mode: .everyStop, replay: false, now: 100.0)

        XCTAssertNotNil(result, "stop event in everyStop mode should produce content")
        XCTAssertEqual(result?.body, "本轮已完成")
    }

    // MARK: - TC-GATE-REPLAY-001: replay=true → nil regardless of kind/mode

    func testReplay_AlwaysReturnsNil() {
        var gate = NotificationGate(cooldown: 30.0)
        let event = makeAttentionEvent()

        let result = gate.evaluate(event: event, session: nil,
                                   mode: .attentionOnly, replay: true, now: 100.0)

        XCTAssertNil(result, "replay events must always be suppressed")
    }

    // MARK: - TC-GATE-THROTTLE-002: after cooldown elapses → content again

    func testAfterCooldown_ReturnsContent() {
        var gate = NotificationGate(cooldown: 30.0)
        let event = makeAttentionEvent()

        _ = gate.evaluate(event: event, session: nil,
                          mode: .attentionOnly, replay: false, now: 100.0)

        // 131 > 100 + 30 → cooldown elapsed
        let result = gate.evaluate(event: event, session: nil,
                                   mode: .attentionOnly, replay: false, now: 131.0)

        XCTAssertNotNil(result, "call after cooldown should be allowed again")
    }

    // MARK: - TC-GATE-THROTTLE-003: different sessions do not interfere

    func testDifferentSessions_AreIndependent() {
        var gate = NotificationGate(cooldown: 30.0)
        let e1 = makeAttentionEvent(sessionId: "s1", eventId: "e1")
        let e2 = makeAttentionEvent(sessionId: "s2", eventId: "e2")

        _ = gate.evaluate(event: e1, session: nil, mode: .attentionOnly, replay: false, now: 100.0)

        let result = gate.evaluate(event: e2, session: nil,
                                   mode: .attentionOnly, replay: false, now: 105.0)

        XCTAssertNotNil(result, "different sessions should have independent throttle buckets")
    }

    // MARK: - TC-GATE-CONTENT-001: session cwd is reflected in body

    func testSessionCwd_AppearsInBody() {
        var gate = NotificationGate(cooldown: 30.0)
        let event = makeAttentionEvent()
        let key = SessionKey(event: event)
        let session = Session(key: key, state: .waiting(.attention),
                              cwd: "/Users/test/myproject",
                              lastSeq: 1, lastActiveAt: 100.0)

        let result = gate.evaluate(event: event, session: session,
                                   mode: .attentionOnly, replay: false, now: 100.0)

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.body.contains("myproject") == true,
                      "body should include the project directory tag from session.cwd")
    }
}
