import Foundation
import Darwin
import AgentPetCore

/// 会话存活探测(P2:终端还开着的闲置会话不被 reap 老化)。
///
/// 判定 = **pid 活着(kill-0)且 tty 设备存在**,双重匹配:
/// - 单靠 tty 存在会被 macOS tty 编号复用严重误判(真机实锤 2026-07-05:昨天死会话的
///   ttys002/003 被今天新 tab 占用 → 全部误判存活永不清理,低编号几乎总被占用)。
/// - pid(hook 采集的 claude 进程 $PPID)在 claude 退出/终端关闭时即消失;pid 复用 + tty
///   复用同时撞上同一会话几乎不可能。
/// - 无 pid(旧事件/第三方 agent)→ **不保护**,按窗口正常老化(宁可老化,不留僵尸)。
///
/// 安全:tty 来自不可信事件,严格白名单(ttys+数字,兼容 /dev/ 前缀)才触达文件系统;
/// pid 只用于 kill(pid, 0) 存在性探测(信号 0 不发送任何信号)。
public enum TtyLiveness {
    /// 三态分类(reap 用):无 pid → .unknown(正常窗口);pid 活+tty 在 → .alive(保护);
    /// pid 已死 → .dead(短窗口快清:claude 确定退出,批量测试会话/退出的 claude 不再占位 8h)。
    public static func classify(
        tty: String?, pid: Int?,
        processAlive: (Int) -> Bool = { kill(pid_t($0), 0) == 0 },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> AgentPetCore.SessionLiveness {
        guard let pid, pid > 0 else { return .unknown }
        guard processAlive(pid) else { return .dead }
        return isAlive(tty: tty, pid: pid, processAlive: processAlive, fileExists: fileExists)
            ? .alive : .unknown   // pid 活但 tty 异常:保守按 unknown(正常窗口)
    }

    private static func isValidTtyName(_ t: String) -> Bool {
        guard t.hasPrefix("ttys"), t.count > 4, t.count <= 8 else { return false }
        return t.dropFirst(4).allSatisfy { $0.isASCII && $0.isNumber }
    }

    public static func isAlive(
        tty: String?,
        pid: Int?,
        processAlive: (Int) -> Bool = { kill(pid_t($0), 0) == 0 },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard let pid, pid > 0, processAlive(pid) else { return false }
        guard var t = tty, !t.isEmpty else { return false }
        if t.hasPrefix("/dev/") { t = String(t.dropFirst(5)) }
        guard isValidTtyName(t) else { return false }
        return fileExists("/dev/\(t)")
    }
}
