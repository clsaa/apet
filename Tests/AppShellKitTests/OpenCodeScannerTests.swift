import XCTest
@testable import AppShellKit
import AgentPetCore

/// OpenCodeScanner(spec §3.1 v3):年龄降档先于内容信号;活跃窗口内按最后 assistant 的
/// in-flight/completed 结构性信号(上游 getCurrentAssistant 同构),无信号才窗口兜底。
final class OpenCodeScannerTests: XCTestCase {

    private func row(id: String = "ses_0189f3ab2c4dXyZ01234abcDEF",
                     dir: String? = "/w", title: String? = "t",
                     activity: Double, signal: AssistantSignal = .none) -> OpenCodeSessionRow {
        OpenCodeSessionRow(sessionId: id, directory: dir, title: title,
                           lastActivity: activity, assistantSignal: signal,
                           createdAt: activity - 100)
    }

    private func scan(_ rows: [OpenCodeSessionRow], now: Double) -> [ScanResult] {
        OpenCodeScanner.scan(rows: rows, root: "/data/opencode", now: now)
    }

    private var key: SessionKey {
        SessionKey(agent: "opencode", root: "/data/opencode",
                   sessionId: "ses_0189f3ab2c4dXyZ01234abcDEF")
    }

    // ── 窗口分档(< 语义:=120 → waitingStop,=1800 → stale,=86400 → 排除;signal=.none)──
    func test_freshActivity_noSignal_running() {
        XCTAssertEqual(scan([row(activity: 1000)], now: 1050),
                       [.observe(state: .running, key: key, cwd: "/w", title: "t")])
    }
    func test_ageExactly120_noSignal_waitingStop() {
        XCTAssertEqual(scan([row(activity: 1000)], now: 1120).first,
                       .observe(state: .waitingStop, key: key, cwd: "/w", title: "t"),
                       "age == runningWindow 属 waitingStop(guard 用 <)")
    }
    func test_ageExactly1800_stale() {
        XCTAssertEqual(scan([row(activity: 1000)], now: 2800).first,
                       .observe(state: .stale, key: key, cwd: "/w", title: "t"),
                       "age == idleWindow 属 stale(常开 TUI 不蒸发,评审)")
    }
    func test_ageExactly86400_dropped() {
        XCTAssertTrue(scan([row(activity: 1000)], now: 87400).isEmpty,
                      "age == staleHorizon 排除")
    }

    // ── in-flight/completed 结构性信号(评审 B1+v3)──
    func test_inFlight_beatsWindowFallback_running() {
        // 长工具执行 500 秒无新行:时间链停摆,但 assistant 未 completed → 仍 running(评审 M1 核心)。
        XCTAssertEqual(scan([row(activity: 1000, signal: .inFlight)], now: 1500).first,
                       .observe(state: .running, key: key, cwd: "/w", title: "t"))
    }
    func test_completedWithin120s_waitingStop_notRunning() {
        // 活动 30 秒前但 assistant 已 completed → 真实完成,不等窗口。
        XCTAssertEqual(scan([row(activity: 1000, signal: .completed)], now: 1030).first,
                       .observe(state: .waitingStop, key: key, cwd: "/w", title: "t"))
    }
    func test_ageDegradationBeatsSignal() {
        // 信号存在但 age >= idleWindow → stale(年龄降档先行;in-flight 的 kill 兜底同理)。
        XCTAssertEqual(scan([row(activity: 1000, signal: .completed)], now: 3000).first,
                       .observe(state: .stale, key: key, cwd: "/w", title: "t"))
        XCTAssertEqual(scan([row(activity: 1000, signal: .inFlight)], now: 3000).first,
                       .observe(state: .stale, key: key, cwd: "/w", title: "t"),
                       "进程被 kill 后 completed 永为 NULL——in-flight 只在活跃窗口内可信")
    }

    // ── 时间边界鲁棒(QoderWork test_futureUpdatedAt 语料带过来,评审)──
    func test_futureActivity_running_noCrash() {
        XCTAssertEqual(scan([row(activity: 5000)], now: 1000).first,
                       .observe(state: .running, key: key, cwd: "/w", title: "t"))
    }
    func test_zeroAndNegativeActivity_dropped() {
        XCTAssertTrue(scan([row(activity: 0)], now: 100_000).isEmpty)
        XCTAssertTrue(scan([row(activity: -50)], now: 100_000).isEmpty)
    }
    func test_hugeActivity_noCrash() {
        _ = scan([row(activity: 9e18)], now: 1000)  // 不崩即可(future → running)
    }

    // ── key/字段 ──
    func test_nilDirAndTitle_passthrough() {
        XCTAssertEqual(scan([row(dir: nil, title: nil, activity: 1000)], now: 1010).first,
                       .observe(state: .running, key: key, cwd: nil, title: nil))
    }
    func test_orderIndependent() {
        let a = row(id: "ses_" + String(repeating: "a", count: 26), activity: 1000)
        let b = row(id: "ses_" + String(repeating: "b", count: 26), activity: 1000)
        XCTAssertEqual(scan([a, b], now: 1010).count, 2)
        XCTAssertEqual(scan([b, a], now: 1010).count, 2)
    }
}
