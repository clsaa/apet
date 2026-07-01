import XCTest
@testable import AgentPetCore

/// `TerminalAppLocator`（Terminal.app 窗口级定位）+ `TTYPath` 白名单的单元测试。
/// 安全红线：tty 经白名单校验后以 argv 传入 osascript，脚本体零内插（红队用例断言）。
final class TerminalAppLocatorTests: XCTestCase {

    // MARK: - 1. TTYPath 白名单

    func test_ttyValid_devTtys001() {
        XCTAssertTrue(TTYPath.isValid("/dev/ttys001"))
    }

    func test_ttyValid_devTtyp0() {
        XCTAssertTrue(TTYPath.isValid("/dev/ttyp0"))
    }

    func test_ttyInvalid_empty() {
        XCTAssertFalse(TTYPath.isValid(""))
    }

    func test_ttyInvalid_notUnderDevTty() {
        XCTAssertFalse(TTYPath.isValid("/tmp/ttys001"))
        XCTAssertFalse(TTYPath.isValid("ttys001"))
    }

    func test_ttyInvalid_containsSpace() {
        XCTAssertFalse(TTYPath.isValid("/dev/ttys0 01"))
    }

    func test_ttyInvalid_shellInjection() {
        XCTAssertFalse(TTYPath.isValid("/dev/ttys001; rm -rf /"))
        XCTAssertFalse(TTYPath.isValid("/dev/ttys001`whoami`"))
        XCTAssertFalse(TTYPath.isValid("/dev/ttys001$(id)"))
        XCTAssertFalse(TTYPath.isValid("/dev/ttys001\"drop"))
    }

    // MARK: - 2. focusInvocation：tty 作为 argv[1]，脚本体不内插 tty

    func test_focus_producesParameterizedInvocation() throws {
        let ref = TerminalRef(kind: .terminal, tty: "/dev/ttys001")
        let inv = try TerminalAppLocator().focusInvocation(for: ref)

        XCTAssertEqual(inv.executable, "/usr/bin/osascript")
        XCTAssertGreaterThanOrEqual(inv.arguments.count, 2)
        // argv[1] 是 tty；脚本体（argv[0]）绝不含内插的 tty 串
        XCTAssertEqual(inv.arguments[1], "/dev/ttys001")
        XCTAssertFalse(inv.arguments[0].contains("/dev/ttys001"),
                       "脚本体严禁字符串内插 tty（防注入红线）")
        XCTAssertTrue(inv.arguments[0].contains("item 1 of argv"),
                      "脚本必须经 argv 取 tty")
    }

    // MARK: - 3. 缺失/非法 tty → 抛错

    func test_focus_missingTty_throwsMissingRef() {
        let ref = TerminalRef(kind: .terminal, tty: nil)
        XCTAssertThrowsError(try TerminalAppLocator().focusInvocation(for: ref)) { err in
            XCTAssertEqual(err as? LocatorError, .missingRef)
        }
    }

    func test_focus_invalidTty_throwsInvalidRef() {
        let ref = TerminalRef(kind: .terminal, tty: "bad; rm -rf /")
        XCTAssertThrowsError(try TerminalAppLocator().focusInvocation(for: ref)) { err in
            XCTAssertEqual(err as? LocatorError, .invalidRef)
        }
    }

    // MARK: - 4. 能力标注

    func test_kindAndCapability() {
        let loc = TerminalAppLocator()
        XCTAssertEqual(loc.kind, .terminal)
        XCTAssertEqual(loc.capability, .activateOnly) // 脚本层不细分；能力分级另由 TerminalCapabilities 出
    }
}
