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
        // 1 running + 2 waiting(含 1 attention)，ack=0 → badgeCount = waiting - ack = 2 - 0 = 2
        let summary = PetSummary(
            state: .busy,
            runningCount: 1,
            waitingCount: 2,
            attentionCount: 1,
            staleCount: 0
        )
        let p = PetPresenter.make(from: summary)
        XCTAssertEqual(p.assetState, "busy")
        XCTAssertEqual(p.badge, "2")
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

    func test_counts_done_isWaitingMinusAcknowledged() {
        // 1 running + 2 waiting(含 1 attention)，ack=0 → done = waiting(2) - ack(0) = 2（attention 已计入 waiting，不重复加）
        let p = PetPresenter.make(from: PetSummary(state: .busy, runningCount: 1, waitingCount: 2, attentionCount: 1, staleCount: 0))
        XCTAssertEqual(p.runningCount, 1)
        XCTAssertEqual(p.doneCount, 2)
    }

    // MARK: - 已读态（红只数未读 + readCount）

    /// readCount 默认 0；无 acknowledged 时 done 不被扣减
    func test_readCount_defaultsZero() {
        let p = PetPresenter.make(from: PetSummary(state: .calling, runningCount: 0, waitingCount: 2, attentionCount: 0, staleCount: 0))
        XCTAssertEqual(p.readCount, 0)
        XCTAssertEqual(p.doneCount, 2, "无已读时 done = waiting - acknowledged = 2 - 0 = 2")
    }

    /// readCount == acknowledgedCount；done 扣除已读（红只数未读）
    func test_readCount_and_done_excludesAcknowledged() {
        // 3 waiting(含 1 attention)，其中 2 个已读 → done = waiting(3) - ack(2) = 1，read = 2
        // attention 已计入 waitingCount，不重复加，避免双计
        let p = PetPresenter.make(from: PetSummary(
            state: .calling, runningCount: 0, waitingCount: 3, attentionCount: 1,
            staleCount: 0, acknowledgedCount: 2))
        XCTAssertEqual(p.readCount, 2)
        XCTAssertEqual(p.doneCount, 1, "红色只数未读：waiting - acknowledged")
    }

    /// 全部已读 → done 可为 0，read 等于全部
    func test_allAcknowledged_doneZero() {
        let p = PetPresenter.make(from: PetSummary(
            state: .calling, runningCount: 0, waitingCount: 2, attentionCount: 0,
            staleCount: 0, acknowledgedCount: 2))
        XCTAssertEqual(p.readCount, 2)
        XCTAssertEqual(p.doneCount, 0)
    }

    /// MAJOR-2 新增：全部 attention 且全部已读 → doneCount==0（旧公式 waiting+attention-ack=2+2-2=2，双计 bug）
    func test_counts_allAttention_allRead_doneZero() {
        // 2 waiting(全为 attention)，全部已读 → done = max(0, waiting-ack) = max(0, 2-2) = 0
        let p = PetPresenter.make(from: PetSummary(
            state: .calling, runningCount: 0, waitingCount: 2, attentionCount: 2,
            staleCount: 0, acknowledgedCount: 2))
        XCTAssertEqual(p.doneCount, 0, "全部已读后未读数应为 0")
        XCTAssertEqual(p.readCount, 2)
    }

    // MARK: - 精修 2：idleCount 等于 staleCount

    /// idleCount == staleCount；即便为 0 也有值
    func test_idleCount_equalsStaleCount() {
        let p = PetPresenter.make(from: PetSummary(
            state: .idle, runningCount: 0, waitingCount: 0, attentionCount: 0, staleCount: 3))
        XCTAssertEqual(p.idleCount, 3, "idleCount 应等于 staleCount")
    }

    /// staleCount==0 时 idleCount==0
    func test_idleCount_zeroWhenNoStale() {
        let p = PetPresenter.make(from: PetSummary(
            state: .busy, runningCount: 1, waitingCount: 0, attentionCount: 0, staleCount: 0))
        XCTAssertEqual(p.idleCount, 0)
    }

    /// busy 状态下 idleCount 仍正确传递
    func test_idleCount_propagatedInBusyState() {
        let p = PetPresenter.make(from: PetSummary(
            state: .busy, runningCount: 2, waitingCount: 1, attentionCount: 0, staleCount: 5))
        XCTAssertEqual(p.idleCount, 5)
    }
}
