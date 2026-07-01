import XCTest
@testable import AgentPetCore

/// 纯决策 `LoginItemDecider.plan(desiredEnabled:currentlyRegistered:)` 的 4 组合矩阵。
final class LoginItemDeciderTests: XCTestCase {

    func test_desiredTrue_notRegistered_register() {
        XCTAssertEqual(LoginItemDecider.plan(desiredEnabled: true, currentlyRegistered: false), .register)
    }

    func test_desiredFalse_registered_unregister() {
        XCTAssertEqual(LoginItemDecider.plan(desiredEnabled: false, currentlyRegistered: true), .unregister)
    }

    func test_desiredTrue_registered_noop() {
        XCTAssertEqual(LoginItemDecider.plan(desiredEnabled: true, currentlyRegistered: true), .noop)
    }

    func test_desiredFalse_notRegistered_noop() {
        XCTAssertEqual(LoginItemDecider.plan(desiredEnabled: false, currentlyRegistered: false), .noop)
    }
}
