import Foundation
import AppShellKit

/// 可执行文件定位(GUI app 专属):LSUIElement 背景 app 的 PATH 极简(通常只有
/// /usr/bin:/bin:/usr/sbin:/sbin),装在 nvm/homebrew/~/.local 里的 `claude` 找不到。
/// 策略:当前 PATH → 登录 shell 的完整 PATH(一次性探测缓存)→ 常见目录兜底。
///
/// 安全:只用固定命令 `echo $PATH` 探测,**不把任何不可信内容传给 shell**;拿到 PATH 后
/// 仍走 `PathResolver` 的直接 exec 解析(名字含 `/` 拒绝),不引入 shell 注入面。
enum ExecutableLocator {
    /// 登录 shell 的 PATH,首次用时探测并缓存(整进程生命周期不变)。
    private static let loginShellPath: String? = probeLoginShellPath()

    /// 解析可执行名到绝对路径。供 `SummarizerService(resolveExecutable:)` 注入。
    static func resolve(_ name: String) -> String? {
        // 1) 当前进程 PATH
        if let p = PathResolver.resolveInEnvironment(name: name) { return p }
        // 2) 登录 shell 的完整 PATH
        if let shellPath = loginShellPath,
           let p = PathResolver.resolve(name: name, pathEnv: shellPath,
                                        fileExists: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return p
        }
        // 3) 常见安装目录兜底(homebrew arm/intel、用户本地、nvm 当前 default)
        let home = NSHomeDirectory()
        let common = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
                      "\(home)/.nvm/current/bin", "\(home)/bin"]
        for dir in common {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// 跑登录+交互 shell 取其 PATH(`$SHELL -lic 'echo $PATH'`;nvm/rbenv 等常在 .zshrc 里改 PATH,
    /// 非交互取不到)。失败返回 nil。
    private static func probeLoginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lic", "echo $PATH"]   // login+interactive:.zshrc 里的 nvm PATH 才生效;固定命令无外部输入
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }
}
