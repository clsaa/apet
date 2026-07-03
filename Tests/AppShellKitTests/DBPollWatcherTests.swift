import XCTest
@testable import AppShellKit
import AgentPetCore

/// DBPollWatcher(泛化自 QoderWorkWatcher):轮询/差分/幽灵对账的通用件。
/// 契约:timer queue=.main、start 幂等、scan 返回 nil 整轮跳过。
final class DBPollWatcherTests: XCTestCase {

    private func key(_ id: String) -> SessionKey {
        SessionKey(agent: "x", root: "/r", sessionId: id)
    }

    func test_diffSuppression_and_ghost() {
        var results: [ScanResult] = [.observe(state: .running, key: key("s1"), cwd: nil, title: nil)]
        var emitted: [ScanResult] = []
        let w = DBPollWatcher(scan: { _ in results }, now: { 0 }, emit: { emitted.append($0) })
        w.scanOnce()
        w.scanOnce()   // 同态:差分抑制
        XCTAssertEqual(emitted.count, 1)
        results = []
        w.scanOnce()   // 幽灵 → stale
        XCTAssertEqual(emitted.last, .observe(state: .stale, key: key("s1"), cwd: nil, title: nil))
        XCTAssertEqual(emitted.count, 2)
    }

    func test_scanNil_skipsRound_noGhost() {
        var results: [ScanResult]? = [.observe(state: .running, key: key("s1"), cwd: nil, title: nil)]
        var emitted: [ScanResult] = []
        let w = DBPollWatcher(scan: { _ in results }, now: { 0 }, emit: { emitted.append($0) })
        w.scanOnce()
        results = nil
        w.scanOnce()   // 整轮跳过
        XCTAssertEqual(emitted.count, 1, "nil 轮不 emit、不发幽灵 stale")
    }

    func test_nowIsPassedToScan() {
        var seenNow: Double = -1
        let w = DBPollWatcher(scan: { now in seenNow = now; return [] }, now: { 42 }, emit: { _ in })
        w.scanOnce()
        XCTAssertEqual(seenNow, 42)
    }

    /// 幂等直测(spec §5:泛化本体三条之一;评审:只靠委托层回归网,QoderWorkWatcher 被删即失防线)。
    func test_start_idempotent_stopSilences() {
        var emitted = 0
        let w = DBPollWatcher(
            scan: { [self] _ in [.observe(state: .running, key: key("s1"), cwd: nil, title: nil)] },
            now: { 0 }, emit: { _ in emitted += 1 })
        w.start(every: 0.05)
        w.start(every: 0.05)   // 幂等:不得产生双 timer
        let exp = expectation(description: "first tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        w.stop()
        let after = emitted
        let exp2 = expectation(description: "silence after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { exp2.fulfill() }
        wait(for: [exp2], timeout: 2)
        XCTAssertEqual(emitted, after, "stop 后不得再 emit")
        XCTAssertGreaterThanOrEqual(emitted, 1)
    }
}
