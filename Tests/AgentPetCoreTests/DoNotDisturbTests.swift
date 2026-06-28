import XCTest
@testable import AgentPetCore

final class DoNotDisturbTests: XCTestCase {
    func test_disabled_neverQuiet() {
        XCTAssertFalse(DNDWindow(enabled: false, startMin: 100, endMin: 200).isQuiet(nowMinOfDay: 150))
    }

    func test_startEqualsEnd_neverQuiet() {   // 防 tautology（架构 M-5/用户 M-5）
        XCTAssertFalse(DNDWindow(enabled: true, startMin: 0, endMin: 0).isQuiet(nowMinOfDay: 0))
        XCTAssertFalse(DNDWindow(enabled: true, startMin: 480, endMin: 480).isQuiet(nowMinOfDay: 480))
    }

    func test_sameDayWindow() {   // 09:00-18:00 = 540-1080
        let w = DNDWindow(enabled: true, startMin: 540, endMin: 1080)
        XCTAssertTrue(w.isQuiet(nowMinOfDay: 600))
        XCTAssertFalse(w.isQuiet(nowMinOfDay: 500))
        XCTAssertTrue(w.isQuiet(nowMinOfDay: 540))    // 边界 now==start → 静
        XCTAssertFalse(w.isQuiet(nowMinOfDay: 1080))  // 边界 now==end → 不静
    }

    func test_crossMidnight() {   // 23:00-07:00 = 1380-420
        let w = DNDWindow(enabled: true, startMin: 1380, endMin: 420)
        XCTAssertTrue(w.isQuiet(nowMinOfDay: 1400))   // 23:20
        XCTAssertTrue(w.isQuiet(nowMinOfDay: 60))     // 01:00
        XCTAssertFalse(w.isQuiet(nowMinOfDay: 720))   // 12:00
        XCTAssertTrue(w.isQuiet(nowMinOfDay: 1380))   // now==start
        XCTAssertFalse(w.isQuiet(nowMinOfDay: 420))   // now==end
    }
}
