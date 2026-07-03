import XCTest
@testable import AgentPetCore

/// SessionIdRule:恢复命令 id 白名单(防注入红线)。字符集白名单逐 Unicode 标量,
/// 不用字素计数(组合字符欺骗)、不用正则(ReDoS/转义面)。
final class SessionIdRuleTests: XCTestCase {

    private let ses = SessionIdRule.prefixedBase62(prefix: "ses_", length: 26)
    /// 12 hex + 14 base62 = 26 位(上游真实生成形态,混大小写)。
    private let valid26 = "0189f3ab2c4dXyZ01234abcDEF"

    // ── 正例 ──
    func test_valid_sesId() { XCTAssertTrue(ses.validate("ses_" + valid26)) }
    func test_valid_allDigits() { XCTAssertTrue(ses.validate("ses_" + String(repeating: "9", count: 26))) }

    // ── 前缀 ──
    func test_prefixCaseSensitive() {
        XCTAssertFalse(ses.validate("SES_" + valid26))
        XCTAssertFalse(ses.validate("Ses_" + valid26))
    }
    func test_prefixOnly_andEmpty() {
        XCTAssertFalse(ses.validate("ses_"))
        XCTAssertFalse(ses.validate(""))
    }
    func test_fullwidthPrefix_rejected() { XCTAssertFalse(ses.validate("ｓｅｓ_" + valid26)) }

    // ── 长度(length=前缀外;全长 30 当 26 传是 off-by-4,显式钉死)──
    func test_length25_rejected() { XCTAssertFalse(ses.validate("ses_" + String(valid26.dropLast()))) }
    func test_length27_rejected() { XCTAssertFalse(ses.validate("ses_" + valid26 + "a")) }
    func test_fullLength30AsBody_rejected() {
        XCTAssertFalse(ses.validate("ses_" + "ses_" + valid26))  // 有人把全长 30 串再拼前缀
    }

    // ── 字符集 ──
    func test_hyphen_rejected() { XCTAssertFalse(ses.validate("ses_-" + String(valid26.dropLast()))) }
    func test_underscoreInBody_rejected() { XCTAssertFalse(ses.validate("ses_" + String(valid26.dropLast()) + "_")) }
    func test_embeddedNUL_rejected() {
        XCTAssertFalse(ses.validate("ses_ab\u{0}" + String(repeating: "c", count: 23)))
    }
    func test_fullwidthLetterInBody_rejected() {
        XCTAssertFalse(ses.validate("ses_" + String(valid26.dropLast()) + "Ｆ"))
    }
    /// é = e + U+0301:字素数 26 但标量 27——钉死实现必须逐标量,不得用字素计数。
    func test_combiningCharacter_rejected() {
        XCTAssertFalse(ses.validate("ses_" + String(valid26.dropLast()) + "e\u{0301}"))
    }
    func test_shellInjection_rejected() {
        // "$(id)" 5 位 + 21 个 a = 26 位:长度合法、字符集非法——确保拒绝理由是字符集。
        XCTAssertFalse(ses.validate("ses_$(id)" + String(repeating: "a", count: 21)))
    }

    // ── .uuid 委托回归(既有语料在 ResumeCommand/AgentManifest 测试中,此处钉枚举本体)──
    func test_uuid_valid() { XCTAssertTrue(SessionIdRule.uuid.validate("8dd7ca5f-e655-47b7-8a5f-ad28336c1d34")) }
    func test_uuid_fullwidthHex_rejected() {
        XCTAssertFalse(SessionIdRule.uuid.validate("８dd7ca5f-e655-47b7-8a5f-ad28336c1d34"))
    }
}
