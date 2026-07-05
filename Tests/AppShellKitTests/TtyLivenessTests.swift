import XCTest
@testable import AppShellKit

/// 会话存活探测:pid(claude 进程)活着 **且** tty 设备存在,双重匹配才判「终端还开着」。
/// 单靠 tty 会被 macOS 编号复用严重误判(真机实锤:昨天死会话的 ttys002 被今天新 tab 占用,
/// 全部误判存活永不清理);pid+tty 同时撞车几乎不可能。无 pid(旧事件)→ 不保护。
final class TtyLivenessTests: XCTestCase {
    func test_pidAlive_ttyExists_alive() {
        XCTAssertTrue(TtyLiveness.isAlive(tty: "ttys001", pid: 42,
                                          processAlive: { $0 == 42 },
                                          fileExists: { $0 == "/dev/ttys001" }))
    }
    func test_pidDead_notAlive_evenIfTtyExists() {
        // 核心:tty 被新终端复用(存在)但 claude 进程已死 → 不保护(修 tty 复用误判)。
        XCTAssertFalse(TtyLiveness.isAlive(tty: "ttys001", pid: 42,
                                           processAlive: { _ in false },
                                           fileExists: { _ in true }))
    }
    func test_noPid_notProtected() {
        // 旧事件无 pid → 不保护(宁可老化,不留僵尸)。
        XCTAssertFalse(TtyLiveness.isAlive(tty: "ttys001", pid: nil,
                                           processAlive: { _ in true },
                                           fileExists: { _ in true }))
    }
    func test_pidAlive_ttyGone_notAlive() {
        XCTAssertFalse(TtyLiveness.isAlive(tty: "ttys001", pid: 42,
                                           processAlive: { _ in true },
                                           fileExists: { _ in false }))
    }
    func test_devPrefixedTty_accepted() {
        XCTAssertTrue(TtyLiveness.isAlive(tty: "/dev/ttys002", pid: 1,
                                          processAlive: { _ in true },
                                          fileExists: { $0 == "/dev/ttys002" }))
    }
    func test_traversalOrGarbage_rejected_neverProbed() {
        for evil in ["../etc/passwd", "ttys001/../..", "console; rm", "tty s1", "/dev/../etc/ttys1", "??", "/dev//ttys1"] {
            var probed = false
            let alive = TtyLiveness.isAlive(tty: evil, pid: 1,
                                            processAlive: { _ in true },
                                            fileExists: { _ in probed = true; return true })
            XCTAssertFalse(alive, "非法 tty 必须拒绝: \(evil)")
            XCTAssertFalse(probed, "非法 tty 不得触达文件系统: \(evil)")
        }
    }
    func test_invalidPid_notAlive() {
        XCTAssertFalse(TtyLiveness.isAlive(tty: "ttys001", pid: 0,
                                           processAlive: { _ in true }, fileExists: { _ in true }))
        XCTAssertFalse(TtyLiveness.isAlive(tty: "ttys001", pid: -5,
                                           processAlive: { _ in true }, fileExists: { _ in true }))
    }
}
