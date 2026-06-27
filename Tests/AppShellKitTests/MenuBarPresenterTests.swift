import XCTest
@testable import AppShellKit
import AgentPetCore

final class MenuBarPresenterTests: XCTestCase {

    // MARK: - Helpers

    private func summary(
        state: PetState,
        running: Int = 0,
        waiting: Int = 0,
        attention: Int = 0,
        stale: Int = 0
    ) -> PetSummary {
        PetSummary(
            state: state,
            runningCount: running,
            waitingCount: waiting,
            attentionCount: attention,
            staleCount: stale
        )
    }

    // MARK: - Tests

    /// idle → "pawprint", tint .none, badge nil
    func testIdleSummaryGivesDefaultIcon() {
        let p = MenuBarPresenter.make(from: summary(state: .idle))
        XCTAssertEqual(p.symbolName, "pawprint")
        XCTAssertEqual(p.tint, .none)
        XCTAssertNil(p.badge)
    }

    /// busy, 1 running, 0 waiting → "pawprint.fill", .green, badge nil (badgeCount == 0)
    func testBusyWithNoWaitingGivesGreenNoBadge() {
        let p = MenuBarPresenter.make(from: summary(state: .busy, running: 1))
        XCTAssertEqual(p.symbolName, "pawprint.fill")
        XCTAssertEqual(p.tint, .green)
        XCTAssertNil(p.badge)
    }

    /// busy, 1 running + 2 waiting (1 attention) → .green, badge = "1" (badgeCount = attentionCount)
    func testBusyWithAttentionWaitingGivesBadgeEqualToAttentionCount() {
        // badgeCount = attentionCount (1) because attention > 0
        let p = MenuBarPresenter.make(from: summary(
            state: .busy, running: 1, waiting: 2, attention: 1))
        XCTAssertEqual(p.symbolName, "pawprint.fill")
        XCTAssertEqual(p.tint, .green)
        XCTAssertEqual(p.badge, "1")
    }

    /// calling, attentionCount 1 → "pawprint.fill", .orange, badge = "1"
    func testCallingWithAttentionGivesOrangeBadge() {
        let p = MenuBarPresenter.make(from: summary(
            state: .calling, waiting: 1, attention: 1))
        XCTAssertEqual(p.symbolName, "pawprint.fill")
        XCTAssertEqual(p.tint, .orange)
        XCTAssertEqual(p.badge, "1")
    }

    /// calling, attentionCount 0, waiting 3 → "pawprint.fill", .red, badge = "3"
    func testCallingWithNoAttentionGivesRedBadgeEqualToWaitingCount() {
        // badgeCount = waitingCount (3) because attentionCount == 0
        let p = MenuBarPresenter.make(from: summary(
            state: .calling, waiting: 3, attention: 0))
        XCTAssertEqual(p.symbolName, "pawprint.fill")
        XCTAssertEqual(p.tint, .red)
        XCTAssertEqual(p.badge, "3")
    }
}
