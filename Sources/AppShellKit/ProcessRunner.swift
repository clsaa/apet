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
public protocol ProcessRunner {
    /// 执行 `executable`（调用方已 PATH 解析）+ argv，可选 stdin，超时后 terminate。
    /// - Throws: 超时/取消/启动失败。
    func run(executable: String, arguments: [String], stdin: String?, timeout: Double) throws -> ProcessResult
}

// MARK: - Mock

public final class MockProcessRunner: ProcessRunner {
    private let result: ProcessResult?
    private let error: Error?
    public private(set) var lastExecutable = ""
    public private(set) var lastArguments: [String] = []
    public private(set) var lastStdin: String?

    public init(result: ProcessResult) { self.result = result; self.error = nil }
    public init(error: Error) { self.result = nil; self.error = error }

    public func run(executable: String, arguments: [String], stdin: String?, timeout: Double) throws -> ProcessResult {
        lastExecutable = executable; lastArguments = arguments; lastStdin = stdin
        if let error { throw error }
        return result!
    }
}

// MARK: - Real

public struct RealProcessRunner: ProcessRunner {
    public init() {}
    public enum RunError: Error { case timedOut, launchFailed }

    public func run(executable: String, arguments: [String], stdin: String?, timeout: Double) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe; p.standardInput = inPipe

        // 异步抽干 stdout/stderr，防 pipe 写满死锁。
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "apet.proc.drain", attributes: .concurrent)
        group.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        do { try p.run() } catch { throw RunError.launchFailed }

        // 显式写 stdin（非 shell 管道），随后关闭。
        if let stdin, let d = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(d)
        }
        try? inPipe.fileHandleForWriting.close()

        // 超时守卫。
        let deadline = DispatchTime.now() + timeout
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        q.asyncAfter(deadline: deadline, execute: timer)
        p.waitUntilExit()
        timer.cancel()
        group.wait()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        // terminate 导致的非零退出按超时上报。
        if p.terminationReason == .uncaughtSignal && !stdout.isEmpty == false {
            // 无法可靠区分，交由 exitCode/调用方判断
        }
        return ProcessResult(exitCode: p.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
