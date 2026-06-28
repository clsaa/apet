import XCTest
@testable import AgentPetCore

final class PopoverShowPlannerTests: XCTestCase {
    let planner = PopoverShowPlanner()
    // TC-B2-FUNC-05 open 后已显示 → ok，不重试（杜绝 double-show）
    func test_planAfterOpen_ok_whenShown() {
        XCTAssertEqual(planner.planAfterOpen(isShownNow: true, attempt: 1, maxAttempts: 2), .ok)
    }
    // TC-B2-FUNC-06 open 后未显示且有剩余次数 → retry（修首击被吞）
    func test_planAfterOpen_retry_whenNotShownAndAttemptsLeft() {
        XCTAssertEqual(planner.planAfterOpen(isShownNow: false, attempt: 1, maxAttempts: 2), .retry)
    }
    // TC-B2-ERR-07 用尽次数仍未显示 → giveUp，不无限重试
    func test_planAfterOpen_giveUp_whenAttemptsExhausted() {
        XCTAssertEqual(planner.planAfterOpen(isShownNow: false, attempt: 2, maxAttempts: 2), .giveUp)
    }
    // TC-B2-FUNC-08 已显示压倒次数耗尽：isShown 优先于 giveUp
    func test_planAfterOpen_ok_whenShownEvenIfAttemptsExhausted() {
        XCTAssertEqual(planner.planAfterOpen(isShownNow: true, attempt: 2, maxAttempts: 2), .ok)
    }
    // TC-B2-ERR-09 attempt 越界仍 giveUp，不重试
    func test_planAfterOpen_giveUp_whenAttemptBeyondMax() {
        XCTAssertEqual(planner.planAfterOpen(isShownNow: false, attempt: 3, maxAttempts: 2), .giveUp)
    }
}
