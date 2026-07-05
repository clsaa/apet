import Foundation

/// tty 存活探测(P2:终端还开着的闲置会话不被 reap 老化)。
///
/// hook 采集父进程 tty(`ps -o tty=` → 如 "ttys001"),终端窗口/tab 关闭后对应
/// `/dev/ttysNNN` 消失——以此区分「终端开着(保留会话)」vs「终端已关(按窗口老化)」。
///
/// 安全:tty 字符串来自**不可信事件**,先经严格白名单(`ttys` + 数字)才允许拼路径,
/// 非法格式直接判死且不触达文件系统(防 `../` 穿越/任意路径探测)。
///
/// 已知局限:macOS 会复用 tty 号——旧终端关闭后新终端可能占用同号,导致已死会话被误判
/// 存活而多保留一阵(直到该 tty 再次空闲)。P2 精度可接受,不引入 pid 校验复杂度。
public enum TtyLiveness {
    /// 白名单:ttys + 1~4 位数字(macOS 伪终端命名)。
    private static func isValidTtyName(_ t: String) -> Bool {
        guard t.hasPrefix("ttys"), t.count > 4, t.count <= 8 else { return false }
        return t.dropFirst(4).allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// tty 对应的 /dev 设备是否存在。`fileExists` 注入便于测试;默认走真实文件系统。
    /// wire 形态兼容:裸名 "ttys002" 或完整路径 "/dev/ttys002"(hook 在部分环境采到后者)。
    public static func isAlive(tty: String?,
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard var t = tty, !t.isEmpty else { return false }
        if t.hasPrefix("/dev/") { t = String(t.dropFirst(5)) }
        guard isValidTtyName(t) else { return false }
        return fileExists("/dev/\(t)")
    }
}
