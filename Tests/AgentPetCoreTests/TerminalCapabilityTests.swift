import XCTest
@testable import AgentPetCore

/// 纯函数 `TerminalCapabilities.capability(for:)` 与 `TerminalCapability` 派生属性的单元测试。
/// 能力分级是「某终端能做到多精确」的单一事实源，planner 与 SessionRowModel 都消费它。
final class TerminalCapabilityTests: XCTestCase {

    // MARK: - 1. kind → capability（当前 4 个 kind；ghostty/vscode 在 Task 3 补）

    func test_iterm2_isPreciseTab() {
        XCTAssertEqual(TerminalCapabilities.capability(for: .iterm2), .preciseTab)
    }

    func test_terminal_isPreciseWindow() {
        XCTAssertEqual(TerminalCapabilities.capability(for: .terminal), .preciseWindow)
    }

    func test_warp_isActivateOnly() {
        XCTAssertEqual(TerminalCapabilities.capability(for: .warp), .activateOnly)
    }

    func test_other_isActivateOnly() {
        XCTAssertEqual(TerminalCapabilities.capability(for: .other), .activateOnly)
    }

    // MARK: - 2. isActivateOnly 派生：仅 precise* 为 false

    func test_preciseTab_isNotActivateOnly() {
        XCTAssertFalse(TerminalCapability.preciseTab.isActivateOnly)
    }

    func test_preciseWindow_isNotActivateOnly() {
        XCTAssertFalse(TerminalCapability.preciseWindow.isActivateOnly)
    }

    func test_activateOnly_isActivateOnly() {
        XCTAssertTrue(TerminalCapability.activateOnly.isActivateOnly)
    }

    func test_activateOnlyManualTab_isActivateOnly() {
        XCTAssertTrue(TerminalCapability.activateOnlyManualTab.isActivateOnly)
    }

    // MARK: - 3. needsManualTabHint 派生：仅 activateOnlyManualTab 为 true

    func test_activateOnlyManualTab_needsManualTabHint() {
        XCTAssertTrue(TerminalCapability.activateOnlyManualTab.needsManualTabHint)
    }

    func test_activateOnly_doesNotNeedManualTabHint() {
        XCTAssertFalse(TerminalCapability.activateOnly.needsManualTabHint)
    }

    func test_preciseTab_doesNotNeedManualTabHint() {
        XCTAssertFalse(TerminalCapability.preciseTab.needsManualTabHint)
    }
}
