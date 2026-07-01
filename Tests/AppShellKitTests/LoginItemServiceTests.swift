import XCTest
@testable import AppShellKit
import AgentPetCore

/// `LoginItemCoordinator`（注入 `LoginItemControlling`）行为测试：
/// 按 `LoginItemDecider` 决策调 register/unregister，透传错误供 UI 提示，noop 不调用任何注册 API。
final class LoginItemServiceTests: XCTestCase {

    /// 可控 Mock：预设注册态、可令 register/unregister 抛错、记录调用次数。
    final class MockLoginItemControl: LoginItemControlling {
        var registered: Bool
        var registerError: Error?
        var unregisterError: Error?
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0

        init(registered: Bool) { self.registered = registered }

        var isRegistered: Bool { registered }
        func register() throws {
            registerCalls += 1
            if let e = registerError { throw e }
            registered = true
        }
        func unregister() throws {
            unregisterCalls += 1
            if let e = unregisterError { throw e }
            registered = false
        }
    }

    struct Boom: Error {}

    func test_enable_whenNotRegistered_registersAndReturnsTrue() {
        let mock = MockLoginItemControl(registered: false)
        let result = LoginItemCoordinator(control: mock).apply(desiredEnabled: true)
        XCTAssertEqual(mock.registerCalls, 1)
        XCTAssertEqual(mock.unregisterCalls, 0)
        XCTAssertEqual(try? result.get(), true)
    }

    func test_enable_whenRegisterThrows_returnsFailure() {
        let mock = MockLoginItemControl(registered: false)
        mock.registerError = Boom()
        let result = LoginItemCoordinator(control: mock).apply(desiredEnabled: true)
        XCTAssertEqual(mock.registerCalls, 1)
        if case .success = result { XCTFail("expected .failure") }
    }

    func test_disable_whenRegistered_unregistersAndReturnsFalse() {
        let mock = MockLoginItemControl(registered: true)
        let result = LoginItemCoordinator(control: mock).apply(desiredEnabled: false)
        XCTAssertEqual(mock.unregisterCalls, 1)
        XCTAssertEqual(mock.registerCalls, 0)
        XCTAssertEqual(try? result.get(), false)
    }

    func test_noop_whenAlreadyInDesiredState_callsNothing() {
        let mock = MockLoginItemControl(registered: true)
        let result = LoginItemCoordinator(control: mock).apply(desiredEnabled: true)
        XCTAssertEqual(mock.registerCalls, 0)
        XCTAssertEqual(mock.unregisterCalls, 0)
        XCTAssertEqual(try? result.get(), true) // 维持当前态
    }

    func test_disableNoop_whenNotRegistered_callsNothing() {
        let mock = MockLoginItemControl(registered: false)
        let result = LoginItemCoordinator(control: mock).apply(desiredEnabled: false)
        XCTAssertEqual(mock.registerCalls, 0)
        XCTAssertEqual(mock.unregisterCalls, 0)
        XCTAssertEqual(try? result.get(), false)
    }
}
