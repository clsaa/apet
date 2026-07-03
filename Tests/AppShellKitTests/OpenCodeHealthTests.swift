import XCTest
@testable import AppShellKit

/// OpenCodeHealth 决策表(spec §3.3;评审:「未安装」「XDG 失明嫌疑」「版本过新」「旧版」必须可区分)。
final class OpenCodeHealthTests: XCTestCase {

    func test_ok_whenReadSucceeds() {
        XCTAssertEqual(OpenCodeHealthDecider.decide(
            outcome: .ok(rows: [], maxMigrationId: nil),
            dbExists: true, legacyStorageExists: false, configDirExists: true), .ok)
    }

    func test_notInstalled_noTraces() {
        let h = OpenCodeHealthDecider.decide(
            outcome: .ok(rows: [], maxMigrationId: nil),
            dbExists: false, legacyStorageExists: false, configDirExists: false)
        XCTAssertEqual(h, .notInstalled)
        XCTAssertNil(h.userMessage, "未安装是常态,不打扰")
    }

    /// 评审 Blocker(XDG 失明):无 db 但有 opencode 配置痕迹 → 用户可见提示。
    func test_dbNotFound_butConfigDirExists() {
        let h = OpenCodeHealthDecider.decide(
            outcome: .ok(rows: [], maxMigrationId: nil),
            dbExists: false, legacyStorageExists: false, configDirExists: true)
        XCTAssertEqual(h, .dbNotFound)
        XCTAssertNotNil(h.userMessage)
        XCTAssertTrue(h.userMessage!.contains("XDG"), "提示要点名 GUI 读不到 shell 环境变量的场景")
    }

    func test_legacyStorage_upgradeHint() {
        let h = OpenCodeHealthDecider.decide(
            outcome: .ok(rows: [], maxMigrationId: nil),
            dbExists: false, legacyStorageExists: true, configDirExists: true)
        XCTAssertEqual(h, .legacyStorage)
        XCTAssertNotNil(h.userMessage)
    }

    /// spec 合取条件:读失败 ∧ migration 新于已验证 → versionTooNew。
    func test_versionTooNew_requiresBothFailedAndNewer() {
        let newer = "20990101000000_future"
        XCTAssertEqual(OpenCodeHealthDecider.decide(
            outcome: .failed(maxMigrationId: newer),
            dbExists: true, legacyStorageExists: false, configDirExists: true),
            .versionTooNew(maxMigrationId: newer))
        // 读成功 ∧ 新迁移 id → 不报(向后兼容加列大概率无害,spec §2)。
        XCTAssertEqual(OpenCodeHealthDecider.decide(
            outcome: .ok(rows: [], maxMigrationId: newer),
            dbExists: true, legacyStorageExists: false, configDirExists: true), .ok)
        // 读失败 ∧ 版本未超 → 一般性读失败(锁抖动等),不误报版本。
        XCTAssertEqual(OpenCodeHealthDecider.decide(
            outcome: .failed(maxMigrationId: OpenCodeDBReader.verifiedMaxMigrationId),
            dbExists: true, legacyStorageExists: false, configDirExists: true), .readFailed)
    }
}
