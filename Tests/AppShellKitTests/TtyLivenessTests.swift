import XCTest
@testable import AppShellKit

/// tty 存活探测:hook 采集的 tty(如 "ttys001")→ /dev/ttys001 是否存在。
/// tty 来自不可信事件,必须白名单校验,严禁拼进路径前直接使用(防穿越)。
final class TtyLivenessTests: XCTestCase {
    func test_validTty_exists_alive() {
        let alive = TtyLiveness.isAlive(tty: "ttys001", fileExists: { $0 == "/dev/ttys001" })
        XCTAssertTrue(alive)
    }
    func test_validTty_gone_dead() {
        XCTAssertFalse(TtyLiveness.isAlive(tty: "ttys001", fileExists: { _ in false }))
    }
    func test_nilOrEmpty_dead() {
        XCTAssertFalse(TtyLiveness.isAlive(tty: nil, fileExists: { _ in true }))
        XCTAssertFalse(TtyLiveness.isAlive(tty: "", fileExists: { _ in true }))
    }
    func test_devPrefixedTty_accepted() {
        // hook 实际 wire 形态:ps 在部分环境返回完整路径 /dev/ttysNNN。
        XCTAssertTrue(TtyLiveness.isAlive(tty: "/dev/ttys002", fileExists: { $0 == "/dev/ttys002" }))
    }
    func test_traversalOrGarbage_rejected_neverProbed() {
        // 不合法格式绝不触达文件系统(防 ../ 穿越/任意路径探测)。
        for evil in ["../etc/passwd", "ttys001/../..", "console; rm", "tty s1", "/dev/../etc/ttys1", "??", "/dev//ttys1"] {
            var probed = false
            let alive = TtyLiveness.isAlive(tty: evil, fileExists: { _ in probed = true; return true })
            XCTAssertFalse(alive, "非法 tty 必须拒绝: \(evil)")
            XCTAssertFalse(probed, "非法 tty 不得触达文件系统: \(evil)")
        }
    }
    func test_macosPattern_accepted() {
        // macOS ps -o tty= 的合法输出形态。
        for ok in ["ttys000", "ttys012", "ttys123"] {
            XCTAssertTrue(TtyLiveness.isAlive(tty: ok, fileExists: { _ in true }), ok)
        }
    }
}
