import XCTest
@testable import AppShellKit

final class ConfigHealthTests: XCTestCase {

    // MARK: - overall == .ready

    func test_ready_whenJsonlFound_hookNotInstalled_notifNotDetermined() {
        let sut = ConfigHealth(
            notification: .notDetermined,
            hook: .notInstalled,
            jsonlSource: .found(count: 3),
            dataRoots: []
        )
        XCTAssertEqual(sut.overall, .ready)
    }

    func test_ready_whenJsonlFound_hookFailed_notifNotDetermined() {
        // hook 失败不算故障 — 只要 jsonl found 且通知非 denied → .ready
        let sut = ConfigHealth(
            notification: .notDetermined,
            hook: .failed(reason: "脚本不存在"),
            jsonlSource: .found(count: 1),
            dataRoots: []
        )
        XCTAssertEqual(sut.overall, .ready)
    }

    // MARK: - overall == .readyEnhanced

    func test_readyEnhanced_whenJsonlFound_hookInstalled_notifAuthorized() {
        let sut = ConfigHealth(
            notification: .authorized,
            hook: .installed(path: "/usr/local/bin/hook"),
            jsonlSource: .found(count: 5),
            dataRoots: []
        )
        XCTAssertEqual(sut.overall, .readyEnhanced)
    }

    func test_readyEnhanced_whenJsonlFound_hookInstalled_notifNotDetermined() {
        // 通知未确定也算 enhanced，只要 hook 装了且 jsonl found
        let sut = ConfigHealth(
            notification: .notDetermined,
            hook: .installed(path: "/tmp/hook"),
            jsonlSource: .found(count: 2),
            dataRoots: []
        )
        XCTAssertEqual(sut.overall, .readyEnhanced)
    }

    // MARK: - overall == .degraded (jsonl 不可用)

    func test_degraded_whenJsonlPathMissing() {
        let sut = ConfigHealth(
            notification: .authorized,
            hook: .installed(path: "/tmp/hook"),
            jsonlSource: .pathMissing,
            dataRoots: []
        )
        XCTAssertEqual(sut.overall, .degraded(reason: "jsonl 数据源不可用"))
    }

    func test_degraded_whenJsonlUnreadable_independentAssertion() {
        // 独立断言 unreadable 分支（测试-M8）
        let sut = ConfigHealth(
            notification: .authorized,
            hook: .installed(path: "/tmp/hook"),
            jsonlSource: .unreadable(path: "/home/user/.jsonl"),
            dataRoots: []
        )
        XCTAssertEqual(sut.overall, .degraded(reason: "jsonl 数据源不可用"))
    }

    // MARK: - overall == .degraded (通知被拒)

    func test_degraded_whenNotifDenied_jsonlFound_hookNotInstalled() {
        let sut = ConfigHealth(
            notification: .denied,
            hook: .notInstalled,
            jsonlSource: .found(count: 10),
            dataRoots: []
        )
        XCTAssertEqual(sut.overall, .degraded(reason: "通知被拒：完成提醒收不到"))
    }

    func test_degraded_whenNotifDenied_jsonlFound_hookInstalled() {
        // 即使 hook 已装，通知被拒优先于 readyEnhanced
        let sut = ConfigHealth(
            notification: .denied,
            hook: .installed(path: "/tmp/hook"),
            jsonlSource: .found(count: 4),
            dataRoots: []
        )
        XCTAssertEqual(sut.overall, .degraded(reason: "通知被拒：完成提醒收不到"))
    }

    // MARK: - jsonl 优先级高于通知

    func test_degraded_jsonlPathMissing_beats_notifDenied() {
        // jsonl 不可用 > 通知被拒：应输出 jsonl 原因
        let sut = ConfigHealth(
            notification: .denied,
            hook: .notInstalled,
            jsonlSource: .pathMissing,
            dataRoots: []
        )
        XCTAssertEqual(sut.overall, .degraded(reason: "jsonl 数据源不可用"))
    }

    // MARK: - dataRoots 透传

    func test_dataRoots_areStored() {
        let roots = ["/home/a", "/home/b"]
        let sut = ConfigHealth(
            notification: .notDetermined,
            hook: .notInstalled,
            jsonlSource: .found(count: 0),
            dataRoots: roots
        )
        XCTAssertEqual(sut.dataRoots, roots)
    }
}
