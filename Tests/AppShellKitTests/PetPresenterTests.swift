import XCTest
import AgentPetCore
@testable import AppShellKit

final class PetPresenterTests: XCTestCase {

    // MARK: - Idle

    func test_idle() {
        let summary = PetSummary(
            state: .idle,
            runningCount: 0,
            waitingCount: 0,
            attentionCount: 0,
            staleCount: 0
        )
        let p = PetPresenter.make(from: summary)
        XCTAssertEqual(p.assetState, "idle")
        XCTAssertNil(p.badge)
        XCTAssertNil(p.bubble)
        XCTAssertFalse(p.emphasize)
    }

    // MARK: - Busy

    func test_busy_noWaiting() {
        let summary = PetSummary(
            state: .busy,
            runningCount: 1,
            waitingCount: 0,
            attentionCount: 0,
            staleCount: 0
        )
        let p = PetPresenter.make(from: summary)
        XCTAssertEqual(p.assetState, "busy")
        XCTAssertNil(p.badge)
        XCTAssertNil(p.bubble)
        XCTAssertFalse(p.emphasize)
    }

    func test_busy_withWaitingAndAttention() {
        // 1 running + 2 waiting (1 attention) → badgeCount = attentionCount = 1
        let summary = PetSummary(
            state: .busy,
            runningCount: 1,
            waitingCount: 2,
            attentionCount: 1,
            staleCount: 0
        )
        let p = PetPresenter.make(from: summary)
        XCTAssertEqual(p.assetState, "busy")
        XCTAssertEqual(p.badge, "1")
        XCTAssertNil(p.bubble)
    }

    // MARK: - Calling

    func test_calling_withAttention() {
        let summary = PetSummary(
            state: .calling,
            runningCount: 0,
            waitingCount: 1,
            attentionCount: 1,
            staleCount: 0
        )
        let p = PetPresenter.make(from: summary)
        XCTAssertEqual(p.assetState, "calling")
        XCTAssertEqual(p.badge, "1")
        XCTAssertEqual(p.bubble, "1 个等你")
        XCTAssertTrue(p.emphasize)
    }

    func test_calling_noAttention() {
        let summary = PetSummary(
            state: .calling,
            runningCount: 0,
            waitingCount: 3,
            attentionCount: 0,
            staleCount: 0
        )
        let p = PetPresenter.make(from: summary)
        XCTAssertEqual(p.assetState, "calling")
        XCTAssertEqual(p.badge, "3")
        XCTAssertEqual(p.bubble, "3 个等你")
        XCTAssertFalse(p.emphasize)
    }

    // MARK: - Always-on counts（用户反馈：时刻显示运行/完成数）

    func test_counts_idle_bothZero() {
        let p = PetPresenter.make(from: PetSummary(state: .idle, runningCount: 0, waitingCount: 0, attentionCount: 0, staleCount: 0))
        XCTAssertEqual(p.runningCount, 0)
        XCTAssertEqual(p.doneCount, 0)   // 即便 0 也有值，供桌宠常显
    }

    func test_counts_running_isRunningCount() {
        let p = PetPresenter.make(from: PetSummary(state: .busy, runningCount: 2, waitingCount: 0, attentionCount: 0, staleCount: 0))
        XCTAssertEqual(p.runningCount, 2)
        XCTAssertEqual(p.doneCount, 0)
    }

    func test_counts_done_isWaitingPlusAttention() {
        // 1 running + 2 waiting(含 1 attention) → done = waiting(2) + attention(1) = 3（停下等你/完成）
        let p = PetPresenter.make(from: PetSummary(state: .busy, runningCount: 1, waitingCount: 2, attentionCount: 1, staleCount: 0))
        XCTAssertEqual(p.runningCount, 1)
        XCTAssertEqual(p.doneCount, 3)
    }
}
