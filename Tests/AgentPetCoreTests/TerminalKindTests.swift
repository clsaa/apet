import XCTest
@testable import AgentPetCore

final class TerminalKindTests: XCTestCase {
    func test_bundleId_perKind() {
        XCTAssertEqual(TerminalKind.iterm2.bundleId, "com.googlecode.iterm2")
        XCTAssertEqual(TerminalKind.terminal.bundleId, "com.apple.Terminal")
        XCTAssertEqual(TerminalKind.warp.bundleId, "dev.warp.Warp-Stable")
        XCTAssertEqual(TerminalKind.ghostty.bundleId, "com.mitchellh.ghostty")
        XCTAssertEqual(TerminalKind.vscode.bundleId, "com.microsoft.VSCode")
        XCTAssertNil(TerminalKind.other.bundleId)
    }
}
