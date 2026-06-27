import XCTest
@testable import AppShellKit
import AgentPetCore

/// 纯函数 `TerminalFocusPlanner.plan(for:)` 的单元测试。
/// 所有 case 无副作用，断言精确，覆盖 nil / iTerm2 精确 / iTerm2 fallback /
/// Terminal / Warp / .other-无-bundleId / .other-有-bundleId 七条路径。
final class TerminalFocusPlannerTests: XCTestCase {

    // MARK: - 1. nil ref → .unsupported

    func testNilRefIsUnsupported() {
        XCTAssertEqual(TerminalFocusPlanner.plan(for: nil), .unsupported)
    }

    // MARK: - 2. iTerm2 + valid session id → .osascript, argv[1] == id

    func testIterm2WithValidIdProducesOsascript() {
        let ref = TerminalRef(kind: .iterm2, itermSessionId: "w0t1p0:ABC")
        let action = TerminalFocusPlanner.plan(for: ref)

        guard case .osascript(let inv) = action else {
            return XCTFail("expected .osascript, got \(action)")
        }
        // arguments[0] = script body, arguments[1] = session id
        XCTAssertGreaterThanOrEqual(inv.arguments.count, 2, "ScriptInvocation must have at least 2 arguments")
        XCTAssertEqual(inv.arguments[1], "w0t1p0:ABC", "arguments[1] must be the session id")
    }

    // MARK: - 3. iTerm2 + empty (invalid) id → .activateBundle default

    func testIterm2WithEmptyIdFallsBackToDefaultBundle() {
        let ref = TerminalRef(kind: .iterm2, itermSessionId: "")
        XCTAssertEqual(
            TerminalFocusPlanner.plan(for: ref),
            .activateBundle("com.googlecode.iterm2")
        )
    }

    // MARK: - 4. iTerm2 + nil itermSessionId → .activateBundle default

    func testIterm2WithNilSessionIdFallsBackToDefaultBundle() {
        let ref = TerminalRef(kind: .iterm2, itermSessionId: nil)
        XCTAssertEqual(
            TerminalFocusPlanner.plan(for: ref),
            .activateBundle("com.googlecode.iterm2")
        )
    }

    // MARK: - 5. iTerm2 + nil id but custom bundleId → .activateBundle(custom)

    func testIterm2WithNilSessionIdUsesCustomBundleId() {
        let ref = TerminalRef(kind: .iterm2, bundleId: "com.custom.iterm")
        XCTAssertEqual(
            TerminalFocusPlanner.plan(for: ref),
            .activateBundle("com.custom.iterm")
        )
    }

    // MARK: - 6. .terminal, no bundleId → .activateBundle("com.apple.Terminal")

    func testTerminalKindNoBundleIdUsesDefault() {
        let ref = TerminalRef(kind: .terminal)
        XCTAssertEqual(
            TerminalFocusPlanner.plan(for: ref),
            .activateBundle("com.apple.Terminal")
        )
    }

    // MARK: - 7. .terminal WITH bundleId → .activateBundle(bundleId)

    func testTerminalKindWithBundleIdUsesCustomBundle() {
        let ref = TerminalRef(kind: .terminal, bundleId: "com.custom.terminal")
        XCTAssertEqual(
            TerminalFocusPlanner.plan(for: ref),
            .activateBundle("com.custom.terminal")
        )
    }

    // MARK: - 8. .warp → .activateBundle("dev.warp.Warp")

    func testWarpKindNoBundleIdUsesDefault() {
        let ref = TerminalRef(kind: .warp)
        XCTAssertEqual(
            TerminalFocusPlanner.plan(for: ref),
            .activateBundle("dev.warp.Warp")
        )
    }

    // MARK: - 9. .other, no bundleId → .unsupported

    func testOtherKindNoBundleIdIsUnsupported() {
        let ref = TerminalRef(kind: .other)
        XCTAssertEqual(TerminalFocusPlanner.plan(for: ref), .unsupported)
    }

    // MARK: - 10. .other WITH bundleId → .activateBundle(bundleId)

    func testOtherKindWithBundleIdActivatesBundle() {
        let ref = TerminalRef(kind: .other, bundleId: "x.y")
        XCTAssertEqual(
            TerminalFocusPlanner.plan(for: ref),
            .activateBundle("x.y")
        )
    }
}
