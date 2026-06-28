import XCTest
@testable import AgentPetCore

// MARK: - NotificationDNDGateTests
//
// Tests for the pure gate function `DNDWindow.shouldSuppress(dnd:nowMinOfDay:)`.
// No system state (`Date()`, timers, notifications) is touched here.

final class NotificationDNDGateTests: XCTestCase {

    // TC-DND-GATE-001  inside window → suppressed
    func test_shouldSuppress_insideWindow() {
        let dnd = DNDWindow(enabled: true, startMin: 540, endMin: 1080)  // 09:00–18:00
        XCTAssertTrue(
            DNDWindow.shouldSuppress(dnd: dnd, nowMinOfDay: 600),  // 10:00
            "nowMinOfDay=600 is inside [540,1080) → should suppress"
        )
    }

    // TC-DND-GATE-002  outside window → not suppressed
    func test_shouldSuppress_outsideWindow() {
        let dnd = DNDWindow(enabled: true, startMin: 540, endMin: 1080)  // 09:00–18:00
        XCTAssertFalse(
            DNDWindow.shouldSuppress(dnd: dnd, nowMinOfDay: 500),  // 08:20
            "nowMinOfDay=500 is outside [540,1080) → should not suppress"
        )
    }

    // TC-DND-GATE-003  disabled window → never suppresses regardless of time
    func test_shouldSuppress_disabled() {
        let dnd = DNDWindow(enabled: false, startMin: 540, endMin: 1080)
        XCTAssertFalse(
            DNDWindow.shouldSuppress(dnd: dnd, nowMinOfDay: 600),
            "disabled DND → should never suppress"
        )
    }
}
