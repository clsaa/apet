import XCTest
@testable import AppShellKit
import AgentPetCore

/// M3-C：QoderWork（agents.db）纯扫描逻辑。
/// 状态派生「粗略」（M3-C 设计：非 Claude 无 stateRules → 仅按最近活动时间），now 注入。
final class QoderWorkScannerTests: XCTestCase {

    private func row(chatId: String = "c1", name: String? = "修 bug", projectPath: String? = "/Users/x/proj",
                     sessionId: String? = "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34",
                     updatedAt: Double) -> QoderWorkChatRow {
        QoderWorkChatRow(chatId: chatId, name: name, projectPath: projectPath,
                         sessionId: sessionId, updatedAt: updatedAt)
    }

    func test_recentActivity_running() {
        let r = QoderWorkScanner.scan(rows: [row(updatedAt: 1000)], root: "/db", now: 1060,
                                      runningWindow: 120, idleWindow: 1800)
        guard case .observe(let state, let key, let cwd, let title) = r[0] else {
            return XCTFail("expected observe")
        }
        XCTAssertEqual(state, .running)
        XCTAssertEqual(key.agent, "qoder-work")
        XCTAssertEqual(key.root, "/db")
        XCTAssertEqual(key.sessionId, "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34")
        XCTAssertEqual(cwd, "/Users/x/proj")
        XCTAssertEqual(title, "修 bug")
    }

    func test_idleWindow_waitingStop() {
        let r = QoderWorkScanner.scan(rows: [row(updatedAt: 1000)], root: "/db", now: 1000 + 600,
                                      runningWindow: 120, idleWindow: 1800)
        guard case .observe(let state, _, _, _) = r[0] else { return XCTFail() }
        XCTAssertEqual(state, .waitingStop)
    }

    func test_tooOld_ignored() {
        let r = QoderWorkScanner.scan(rows: [row(updatedAt: 1000)], root: "/db", now: 1000 + 3600,
                                      runningWindow: 120, idleWindow: 1800)
        XCTAssertTrue(r.isEmpty, "超过 idleWindow 不进面板")
    }

    func test_missingSessionId_fallsBackToChatId() {
        let r = QoderWorkScanner.scan(rows: [row(chatId: "chat-9", sessionId: nil, updatedAt: 1000)],
                                      root: "/db", now: 1010, runningWindow: 120, idleWindow: 1800)
        guard case .observe(_, let key, _, _) = r[0] else { return XCTFail() }
        XCTAssertEqual(key.sessionId, "chat-9")
    }

    func test_boundary_exactlyRunningWindow_isWaiting() {
        let r = QoderWorkScanner.scan(rows: [row(updatedAt: 1000)], root: "/db", now: 1120,
                                      runningWindow: 120, idleWindow: 1800)
        guard case .observe(let state, _, _, _) = r[0] else { return XCTFail() }
        XCTAssertEqual(state, .waitingStop, "恰好等于窗口边界 → 不算 running")
    }

    // 评审补齐（测试 m10）：idle 边界与 running 边界对称覆盖。
    func test_boundary_exactlyIdleWindow_isExcluded() {
        let r = QoderWorkScanner.scan(rows: [row(updatedAt: 1000)], root: "/db", now: 1000 + 1800,
                                      runningWindow: 120, idleWindow: 1800)
        XCTAssertTrue(r.isEmpty, "恰好等于 idleWindow → 排除（guard age < idleWindow）")
    }

    // 评审补齐（测试 m10）：未来时间（时钟漂移）→ 负 age → running，不崩不排除。
    func test_futureUpdatedAt_isRunning() {
        let r = QoderWorkScanner.scan(rows: [row(updatedAt: 2000)], root: "/db", now: 1000,
                                      runningWindow: 120, idleWindow: 1800)
        guard case .observe(let state, _, _, _) = r[0] else { return XCTFail() }
        XCTAssertEqual(state, .running)
    }
}
