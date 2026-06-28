import XCTest
@testable import AppShellKit

final class OnboardingGateTests: XCTestCase {

    // 首次启动（onboardingShown=false）→ 应该显示
    func test_shouldShow_whenOnboardingNotYetShown() {
        XCTAssertTrue(OnboardingGate.shouldShow(onboardingShown: false))
    }

    // 已显示过（onboardingShown=true）→ 不再显示
    func test_shouldNotShow_whenOnboardingAlreadyShown() {
        XCTAssertFalse(OnboardingGate.shouldShow(onboardingShown: true))
    }
}
