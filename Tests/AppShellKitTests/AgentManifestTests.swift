import XCTest
@testable import AppShellKit
import AgentPetCore

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

    func test_epochSeconds_parse() {
        XCTAssertEqual(TimestampDialect.epochSeconds.parse("1780290835")!, 1780290835, accuracy: 0.001)
    }

    func test_invalid_returnsNil() {
        XCTAssertNil(TimestampDialect.iso.parse("not-a-date"))
        XCTAssertNil(TimestampDialect.epochMillis.parse("abc"))
        XCTAssertNil(TimestampDialect.epochMillis.parse(""))
        XCTAssertNil(TimestampDialect.epochSeconds.parse("x"))
    }

    func test_qoderWorkManifest_verifiedFacts() {
        let m = AgentManifest.qoderWork
        XCTAssertEqual(m.id, "qoder-work")
        XCTAssertEqual(m.tsDialect, .epochSeconds)
        XCTAssertNil(m.renderResumeArgv(sessionId: "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34"),
                     "resume 未核实 → nil，不臆造")
    }

    // MARK: - 内置 manifest

    func test_claudeManifest_resumeArgv() {
        let m = AgentManifest.claude
        XCTAssertEqual(m.renderResumeArgv(sessionId: "8eb2fbd6-8607-426d-b1be-8d20e35419c8"),
                       ["claude", "--resume", "8eb2fbd6-8607-426d-b1be-8d20e35419c8"])
        XCTAssertEqual(m.tsDialect, .iso)
    }

    // 评审修复（AI M4）：builtins 无 glob 重叠（废弃的 qoder stub 已移出注册表）。
    func test_builtins_noGlobOverlap() {
        let allGlobs = AgentManifest.builtins.flatMap { $0.rootsGlobs }
        XCTAssertEqual(allGlobs.count, Set(allGlobs).count, "builtins 各 manifest 的 roots glob 不得重叠")
        XCTAssertFalse(AgentManifest.builtins.contains { $0.id == "qoder" }, "废弃 stub 不进注册表")
    }

    // 评审修复（AI m8⑤）：模板元素部分含 {id} → 拒绝渲染（防静默产出坏命令）。
    func test_renderResumeArgv_rejectsPartialPlaceholder() {
        let m = AgentManifest(id: "x", rootsGlobs: [], tsDialect: .iso,
                              resumeArgvTemplate: ["tool", "--resume={id}"], hasStateRules: false)
        XCTAssertNil(m.renderResumeArgv(sessionId: "8eb2fbd6-8607-426d-b1be-8d20e35419c8"))
    }

    // 评审修复（测试 m9）：全角十六进制"数字"必须被拒（isHexDigit 会放行）。
    func test_uuid_rejectsFullWidthHexDigits() {
        let fullWidth = "８ｅｂ２ｆｂｄ６-8607-426d-b1be-8d20e35419c8"
        XCTAssertNil(AgentManifest.claude.renderResumeArgv(sessionId: fullWidth))
    }

    // 防漂移 tripwire（架构 M4/AI m7：resume 命令双真相）——ResumeCommand（core 硬编码，
    // UI 实际消费）与 AgentManifest（对外契约）对每个已核实 agent 必须渲染出**相同 argv**。
    // 任何一边单独改动都会在此爆红，倒逼两边同步（结构性收敛列入 M4 契约工作）。
    func test_resumeCommand_manifest_consistency() {
        let id = "8eb2fbd6-8607-426d-b1be-8d20e35419c8"
        XCTAssertEqual(ResumeCommand.argv(agent: "claude-code", sessionId: id),
                       AgentManifest.claude.renderResumeArgv(sessionId: id))
        XCTAssertEqual(ResumeCommand.argv(agent: "qoder-cli", sessionId: id),
                       AgentManifest.qoderCli.renderResumeArgv(sessionId: id))
        XCTAssertEqual(ResumeCommand.argv(agent: "qoder-work", sessionId: id),
                       AgentManifest.qoderWork.renderResumeArgv(sessionId: id),
                       "两边都应是 nil（未核实）")
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
