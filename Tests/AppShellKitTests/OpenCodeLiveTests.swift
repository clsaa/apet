import XCTest
@testable import AppShellKit
import AgentPetCore

/// 真机实测门(spec §6):APET_OPENCODE_LIVE=1 才跑。
/// 用途:合并前对真实 opencode.db 端到端验证;输出贴 PR 作过门证据。
final class OpenCodeLiveTests: XCTestCase {

    func test_live_readRealDatabase() throws {
        guard ProcessInfo.processInfo.environment["APET_OPENCODE_LIVE"] == "1" else {
            throw XCTSkip("live 测试需 APET_OPENCODE_LIVE=1(真机实测门)")
        }
        let path = OpenCodeDBReader.defaultDBPath(env: ProcessInfo.processInfo.environment)
        let outcome = OpenCodeDBReader(dbPath: path).read()
        let rows = try XCTUnwrap(outcome.rows, "真机读取失败——检查版本漂移(migration 上界见输出)")
        print("[live] db=\(path) rows=\(rows.count) maxMigration=\(outcome.maxMigrationId ?? "nil") verified=\(OpenCodeDBReader.verifiedMaxMigrationId)")
        // 版本格式断言(评审 Blocker 的真机哨兵):id 应为全名(含 _ 后缀)且不新于已验证。
        if let maxId = outcome.maxMigrationId {
            XCTAssertTrue(maxId.contains("_"),
                          "migration id 应为全名 <时间戳>_<名字>,got \(maxId)——上游格式变了?重跑 spec §2 核对")
            XCTAssertFalse(OpenCodeDBReader.isNewerThanVerified(maxId),
                           "真机 schema 新于已验证——按 verifiedMaxMigrationId 注释的四步维护流程更新")
        }
        let rule = SessionIdRule.prefixedBase62(prefix: "ses_", length: 26)
        let now = Date().timeIntervalSince1970
        for row in rows {
            // 秒量级哨兵:抓漏换算(≈1.78e12 即毫秒当秒)与方言漂移(评审 tripwire)。
            XCTAssertGreaterThan(row.lastActivity, 1_577_836_800, "2020 之前?换算/方言异常:\(row.sessionId)")
            XCTAssertLessThan(row.lastActivity, now + 86_400, "未来一天开外?\(row.sessionId)")
            XCTAssertGreaterThan(row.createdAt, 1_577_836_800, "createdAt 换算异常:\(row.sessionId)")
            XCTAssertLessThan(row.createdAt, now + 86_400, "createdAt 未来:\(row.sessionId)")
            // id 不过白名单只打印不断言(spec §6-6:旧迁移异形 id 合法存在,硬断言会误炸真机门)。
            if !rule.validate(row.sessionId) {
                print("[live] 异形 id(旧迁移?):\(row.sessionId)——无恢复命令但应正常展示")
            }
        }
    }
}
