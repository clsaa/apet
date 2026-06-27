import Foundation
import AppKit
import AgentPetCore
import AppShellKit

// MARK: - FocusResult

/// 聚焦操作的执行结果。
public enum FocusResult: Equatable {
    /// osascript 成功找到并激活了目标 session。
    case focused
    /// App 已被激活（activate-only 路径，无 session 精确跳转）。
    case activatedOnly
    /// osascript 执行成功但 session 未命中（exit != 0，脚本 `error ... number -1`）。
    case targetGone
    /// 无法执行跳转（ref 为 nil 或 .other 且无 bundleId）。
    case unsupported
}

// MARK: - TerminalFocusService

/// 执行终端聚焦的副作用层。
///
/// 决策逻辑（纯函数）由 `TerminalFocusPlanner.plan(for:)` 承担；本类仅负责执行。
///
/// ### 线程约定
/// `focus(_:)` 可在任意线程调用（Process.run 同步阻塞到子进程退出）。
/// AppKit API（NSWorkspace）内部线程安全；`activate` 建议在主线程调用，但对 activate-only
/// 路径影响极小，调用者按需 hop 到 MainActor。
public final class TerminalFocusService {

    public init() {}

    /// 根据 `ref` 聚焦对应终端窗口/tab，返回执行结果。
    @discardableResult
    public func focus(_ ref: TerminalRef?) -> FocusResult {
        let action = TerminalFocusPlanner.plan(for: ref)
        switch action {
        case .unsupported:
            return .unsupported

        case .activateBundle(let bundleId):
            activateBundle(bundleId)
            return .activatedOnly

        case .osascript(let invocation):
            return runOsascript(invocation)
        }
    }

    // MARK: - Private: activate-only

    private func activateBundle(_ bundleId: String) {
        // 优先激活已运行实例
        if let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleId }) {
            app.activate(options: .activateIgnoringOtherApps)
            return
        }
        // 未运行 → 尝试启动
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
        }
    }

    // MARK: - Private: osascript

    /// 执行 ScriptInvocation。
    ///
    /// 约定（来自 `TerminalLocator.swift` 注释）：
    ///   - `arguments[0]` = 脚本全文，经 stdin 传给 `osascript -`
    ///   - `arguments[1...]` = 脚本 argv（on run argv 中的元素）
    ///
    /// exit 0 → `.focused`；非零（脚本 `error … number -1` when session not found）→ `.targetGone`。
    private func runOsascript(_ invocation: ScriptInvocation) -> FocusResult {
        guard invocation.arguments.count >= 1 else { return .targetGone }
        let scriptBody = invocation.arguments[0]
        let scriptArgv = Array(invocation.arguments.dropFirst())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        // `-` 告知 osascript 从 stdin 读脚本；后跟的参数成为 AppleScript 的 argv
        process.arguments = ["-"] + scriptArgv

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        // 静默 stdout/stderr，避免污染调用方的输出流
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .targetGone
        }

        // 写完脚本后关闭写端，使 osascript 收到 EOF
        if let data = scriptBody.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        process.waitUntilExit()
        return process.terminationStatus == 0 ? .focused : .targetGone
    }
}
