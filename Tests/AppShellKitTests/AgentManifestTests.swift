import XCTest
@testable import AppShellKit

/// M3-C 多 Agent 框架：时间戳方言解析 + manifest 恢复命令 argv 渲染（红队）。
final class AgentManifestTests: XCTestCase {

    // MARK: - 时间戳方言（Qoder 部分行为 epoch 毫秒）

    func test_iso_parse() {
        let ts = TimestampDialect.iso.parse("2026-06-27T10:00:00.000Z")
        XCTAssertNotNil(ts)
        // 2026-06-27T10:00:00Z 的 Unix 秒
        XCTAssertEqual(ts!, 1782554400, accuracy: 1)
    }

    func test_epochMillis_parse() {
        // 1_782_554_400_000 ms → 1_782_554_400 s
        XCTAssertEqual(TimestampDialect.epochMillis.parse("1782554400000")!, 1782554400, accuracy: 0.001)
    }

    func test_invalid_returnsNil() {
        XCTAssertNil(TimestampDialect.iso.parse("not-a-date"))
        XCTAssertNil(TimestampDialect.epochMillis.parse("abc"))
        XCTAssertNil(TimestampDialect.epochMillis.parse(""))
    }

    // MARK: - 内置 manifest

    func test_claudeManifest_resumeArgv() {
        let m = AgentManifest.claude
        XCTAssertEqual(m.renderResumeArgv(sessionId: "8eb2fbd6-8607-426d-b1be-8d20e35419c8"),
                       ["claude", "--resume", "8eb2fbd6-8607-426d-b1be-8d20e35419c8"])
        XCTAssertEqual(m.tsDialect, .iso)
    }

    func test_qoderManifest_epochMillis_and_unknownResume() {
        let m = AgentManifest.qoder
        // Qoder ts 是 epoch 毫秒（实测事实）
        XCTAssertEqual(m.tsDialect, .epochMillis)
        // Qoder resume 命令未核实 → 不臆造，返回 nil
        XCTAssertNil(m.renderResumeArgv(sessionId: "8eb2fbd6-8607-426d-b1be-8d20e35419c8"))
        // 非 Claude 且未提供 stateRules → 降级「状态粗略」
        XCTAssertFalse(m.hasStateRules)
    }

    // MARK: - 恢复命令 argv 红队（sessionId 过 UUID 白名单作单一 argv）

    func test_resumeArgv_rejectsInjection() {
        let m = AgentManifest.claude
        XCTAssertNil(m.renderResumeArgv(sessionId: "x; rm -rf /"))
        XCTAssertNil(m.renderResumeArgv(sessionId: "$(id)"))
        XCTAssertNil(m.renderResumeArgv(sessionId: "`whoami`"))
        XCTAssertNil(m.renderResumeArgv(sessionId: ""))
    }
}
