import Foundation

// MARK: - ProcessRunner seam

public struct ProcessResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
}

/// 外部进程执行缝。真实实现走 Foundation Process；测试用 ``MockProcessRunner``。
/// 契约（评审修复 AI B1/M3）：
/// - `executable` 必须是**绝对路径**（调用方先 PATH 解析，杜绝 cwd 相对名劫持）
/// - `arguments` **不含 argv[0]**（Process 自动补）
/// - `cwd` 必传（受控工作目录——摘要子进程须落在临时 cwd 防幽灵会话）
/// - 超时 → SIGTERM，宽限后 SIGKILL 升级，最终 **throw `.timedOut`**
public protocol ProcessRunner {
    func run(executable: String, arguments: [String], stdin: String?, cwd: String, timeout: Double) throws -> ProcessResult
}

// MARK: - Mock

public final class MockProcessRunner: ProcessRunner {
    private let result: ProcessResult?
    private let error: Error?
    public private(set) var lastExecutable = ""
    public private(set) var lastArguments: [String] = []
    public private(set) var lastStdin: String?
    public private(set) var lastCwd = ""

    public init(result: ProcessResult) { self.result = result; self.error = nil }
    public init(error: Error) { self.result = nil; self.error = error }

    public func run(executable: String, arguments: [String], stdin: String?, cwd: String, timeout: Double) throws -> ProcessResult {
        lastExecutable = executable; lastArguments = arguments; lastStdin = stdin; lastCwd = cwd
        if let error { throw error }
        return result!
    }
}

// MARK: - PathResolver

/// PATH 解析（纯函数 + 注入 fileExists）。含路径分隔符的名字直接拒绝（防相对路径劫持）。
public enum PathResolver {
    public static func resolve(name: String, pathEnv: String, fileExists: (String) -> Bool) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(name)"
            if fileExists(candidate) { return candidate }
        }
        return nil
    }

    /// IO 便利：读真实 PATH 与文件系统。
    public static func resolveInEnvironment(name: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        return resolve(name: name, pathEnv: pathEnv,
                       fileExists: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}

// MARK: - Real

public struct RealProcessRunner: ProcessRunner {
    public init() {}
    public enum RunError: Error, Equatable { case timedOut, launchFailed }

    public func run(executable: String, arguments: [String], stdin: String?, cwd: String, timeout: Double) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe; p.standardInput = inPipe

        // 异步抽干 stdout/stderr，防 pipe 写满死锁。
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "apet.proc.drain", attributes: .concurrent)
        group.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        // 退出信号：terminationHandler + 信号量，支持带超时等待。
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }

        do { try p.run() } catch { throw RunError.launchFailed }

        // 显式写 stdin（throwing API——子进程早退 EPIPE 不再以 ObjC 异常炸主 App，评审修复 AI M3③）。
        if let stdin, let d = stdin.data(using: .utf8) {
            try? inPipe.fileHandleForWriting.write(contentsOf: d)
        }
        try? inPipe.fileHandleForWriting.close()

        // 超时：SIGTERM → 2s 宽限 → SIGKILL 升级（评审修复 AI M3①：不再依赖子进程自觉）。
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }

        // 抽干等待带 deadline（评审修复 AI M3②：孙进程持有写端不 EOF 时不永久挂起）。
        _ = group.wait(timeout: .now() + 5)

        if timedOut { throw RunError.timedOut }

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return ProcessResult(exitCode: p.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
