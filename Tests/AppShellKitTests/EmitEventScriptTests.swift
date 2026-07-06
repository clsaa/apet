import XCTest
import Foundation
@testable import AgentPetCore
@testable import AppShellKit

// MARK: - EmitEventScriptTests
// Drives apet-emit-event.sh via Process and verifies the emitted NDJSON event.

final class EmitEventScriptTests: XCTestCase {

    // MARK: - Script location

    /// Resolves the script path from the source file's compile-time path.
    /// Layout: Tests/AppShellKitTests/<this file> → up 3 → package root → Resources/
    private static let scriptURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AppShellKitTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Resources/apet-emit-event.sh")
    }()

    // MARK: - Helpers

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("apet-emit-\(UUID().uuidString).ndjson")
    }

    /// Runs the emit-event script with the given hook JSON piped to stdin.
    @discardableResult
    private func runScript(
        hookJSON: String,
        outURL: URL,
        itermSessionId: String? = nil,
        termProgram: String? = nil,
        agentOverride: String? = nil,
        parentComm: String = "zsh"   // 默认模拟用户 shell(真实 ps 在测试环境是 xctest)
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.scriptURL.path]

        var env: [String: String] = [
            "PATH":          "/usr/bin:/bin:/usr/local/bin",
            "HOME":          NSHomeDirectory(),
            "AGENTPET_OUT":  outURL.path,
            "AGENTPET_ROOT": "~/.claude",
        ]
        if let s = itermSessionId { env["ITERM_SESSION_ID"] = s }
        if let t = termProgram    { env["TERM_PROGRAM"]     = t }
        if let a = agentOverride  { env["AGENTPET_AGENT"]   = a }
        env["AGENTPET_PARENT_COMM"] = parentComm
        process.environment = env

        // Pipe hook payload to stdin; close write-end so bash's `cat` sees EOF
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        stdinPipe.fileHandleForWriting.write(hookJSON.data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Test 1: Stop hook → stop event + iTerm2 terminal, cwd with space

    func testStopHookProducesStopEventWithIterm2Terminal() throws {
        let outURL = makeTempURL()
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: outURL.path + ".lock"))
        }

        let hookJSON = #"{"hook_event_name":"Stop","session_id":"S1","cwd":"/Users/x/proj a"}"#
        let status = try runScript(
            hookJSON: hookJSON,
            outURL: outURL,
            itermSessionId: "w0t1p0:ABC"
        )
        XCTAssertEqual(status, 0, "Script must exit 0")

        let content = try String(contentsOf: outURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "Exactly one NDJSON line must be written")

        guard let event = AgentEvent.decode(line: lines[0]) else {
            return XCTFail("Could not decode AgentEvent from: \(lines[0])")
        }

        XCTAssertEqual(event.kind,                      .stop)
        XCTAssertEqual(event.sessionId,                 "S1")
        XCTAssertEqual(event.cwd,                       "/Users/x/proj a")
        // title 故意不发(nil):hook 若带 basename(cwd) 会经 last-non-nil 合并反复覆盖
        // jsonl 真标题(ai-title/lastPrompt),面板全变目录名。显示层有 cwd basename 兜底。
        XCTAssertNil(event.title, "hook 不得发 title,否则覆盖 jsonl 真标题")
        XCTAssertEqual(event.agent,                     "claude-code")
        XCTAssertEqual(event.v,                         1)
        XCTAssertFalse(event.eventId.isEmpty,           "eventId must be non-empty")
        XCTAssertEqual(event.terminal?.kind,            .iterm2)
        XCTAssertEqual(event.terminal?.itermSessionId,  "w0t1p0:ABC")
        XCTAssertEqual(event.terminal?.bundleId,        "com.googlecode.iterm2")
    }

    // MARK: - Test 2: Notification hook → attention event

    func testNotificationHookProducesAttentionEvent() throws {
        let outURL = makeTempURL()
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: outURL.path + ".lock"))
        }

        let hookJSON = #"{"hook_event_name":"Notification","session_id":"S2","cwd":"/tmp/demo"}"#
        let status = try runScript(hookJSON: hookJSON, outURL: outURL)
        XCTAssertEqual(status, 0, "Script must exit 0")

        let content = try String(contentsOf: outURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "Exactly one NDJSON line must be written")

        guard let event = AgentEvent.decode(line: lines[0]) else {
            return XCTFail("Could not decode AgentEvent from: \(lines[0])")
        }

        XCTAssertEqual(event.kind,      .attention)
        XCTAssertEqual(event.sessionId, "S2")
        XCTAssertNil(event.terminal,    "No terminal env → terminal must be nil")
    }

    // MARK: - Test 3: SessionStart hook → session_start event

    func testSessionStartMapsToSessionStart() throws {
        let outURL = makeTempURL()
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: outURL.path + ".lock"))
        }

        let hookJSON = #"{"hook_event_name":"SessionStart","session_id":"S_START","cwd":"/tmp"}"#
        let status = try runScript(hookJSON: hookJSON, outURL: outURL)
        XCTAssertEqual(status, 0, "Script must exit 0")

        let content = try String(contentsOf: outURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "Exactly one NDJSON line must be written")

        guard let event = AgentEvent.decode(line: lines[0]) else {
            return XCTFail("Could not decode AgentEvent from: \(lines[0])")
        }

        XCTAssertEqual(event.kind,      .sessionStart)
        XCTAssertEqual(event.sessionId, "S_START")
    }

    // MARK: - Test 4: PreToolUse hook → busy event

    func testPreToolUseMapsToBusy() throws {
        let outURL = makeTempURL()
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: outURL.path + ".lock"))
        }

        let hookJSON = #"{"hook_event_name":"PreToolUse","session_id":"S_TOOL","cwd":"/tmp"}"#
        let status = try runScript(hookJSON: hookJSON, outURL: outURL)
        XCTAssertEqual(status, 0, "Script must exit 0")

        let content = try String(contentsOf: outURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "Exactly one NDJSON line must be written")

        guard let event = AgentEvent.decode(line: lines[0]) else {
            return XCTFail("Could not decode AgentEvent from: \(lines[0])")
        }

        XCTAssertEqual(event.kind,      .busy)
        XCTAssertEqual(event.sessionId, "S_TOOL")
    }

    // MARK: - Test 5: Injection-safe cwd handling

    func testInjectionSafeCwd() throws {
        let outURL = makeTempURL()
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: outURL.path + ".lock"))
        }

        // cwd with quotes, backticks, and $(...) injection attempt
        let dangerousCwd = "/Users/x/proj \"a\" $(touch /tmp/apet_pwn_$$)"
        let escaped = dangerousCwd.replacingOccurrences(of: "\"", with: "\\\"")
        let hookJSON = "{\"hook_event_name\":\"Stop\",\"session_id\":\"S_INJ\",\"cwd\":\"\(escaped)\"}"

        let status = try runScript(hookJSON: hookJSON, outURL: outURL)
        XCTAssertEqual(status, 0, "Script must exit 0 even with dangerous cwd")

        let content = try String(contentsOf: outURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "Exactly one NDJSON line must be written")

        guard let event = AgentEvent.decode(line: lines[0]) else {
            return XCTFail("Could not decode AgentEvent from: \(lines[0])")
        }

        // Verify cwd is stored as literal string, not executed
        XCTAssertEqual(event.cwd, dangerousCwd, "cwd must be literal string, not shell-expanded")

        // Verify no injection occurred (no /tmp/apet_pwn_* file created)
        let fileManager = FileManager.default
        let tmpDir = "/tmp"
        do {
            let files = try fileManager.contentsOfDirectory(atPath: tmpDir)
            let pwnedFiles = files.filter { $0.hasPrefix("apet_pwn_") }
            XCTAssertTrue(pwnedFiles.isEmpty, "No shell injection should have occurred - no /tmp/apet_pwn_* files should exist")
        } catch {
            XCTFail("Could not read /tmp directory: \(error)")
        }
    }

    // MARK: - Test 6: Missing AGENTPET_OUT exits zero, no crash

    func testMissingAgentpetOutExitsZeroNoCrash() throws {
        let outURL = makeTempURL()
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: outURL.path + ".lock"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.scriptURL.path]

        let env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
            // AGENTPET_OUT is intentionally NOT set
        ]
        process.environment = env

        // Pipe hook payload to stdin
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        let hookJSON = #"{"hook_event_name":"Stop","session_id":"S_NOOUT","cwd":"/tmp"}"#
        stdinPipe.fileHandleForWriting.write(hookJSON.data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "Script must exit 0 even when AGENTPET_OUT is unset")

        // Verify no output file was created
        let exists = FileManager.default.fileExists(atPath: outURL.path)
        XCTAssertFalse(exists, "No output file should be created when AGENTPET_OUT is unset")
    }

    // qoder-cli 复用(官方 hooks migrate 自认 Claude 兼容):agent 经 AGENTPET_AGENT 参数化。
    func testAgentEnvOverride_qoderCli() throws {
        let outURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: outURL) }
        let status = try runScript(
            hookJSON: #"{"hook_event_name": "Stop", "session_id": "S1", "cwd": "/x"}"#,
            outURL: outURL, agentOverride: "qoder-cli")
        XCTAssertEqual(status, 0)
        let content = try String(contentsOfFile: outURL.path, encoding: .utf8)
        let event = AgentEvent.decode(line: Substring(content.split(separator: "\n").first ?? ""))
        XCTAssertEqual(event?.agent, "qoder-cli", "AGENTPET_AGENT 覆盖默认 claude-code")
    }

    func testHookCommand_withAgent() {
        let cmd = HookInstaller.hookCommand(scriptPath: "/s.sh", eventsPath: "/e.ndjson",
                                            rootPath: "/r", agent: "qoder-cli")
        XCTAssertTrue(cmd.contains("AGENTPET_AGENT=qoder-cli"), cmd)
        // 默认(claude)不带 agent 变量,向后兼容已有安装
        let plain = HookInstaller.hookCommand(scriptPath: "/s.sh", eventsPath: "/e.ndjson", rootPath: "/r")
        XCTAssertFalse(plain.contains("AGENTPET_AGENT"), plain)
    }

    /// 用户实锤:termarium node-pty 拉起的 claude 继承 Warp 环境变量,但不是 Warp tab——
    /// 父进程非 shell → 终端降级 kind=other(去误导图标/激活),tty/pid 保留(存活判定不受损)。
    func testSpawnedByNonShell_terminalDowngraded() throws {
        let outURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: outURL) }
        let status = try runScript(
            hookJSON: #"{"hook_event_name": "Stop", "session_id": "S1", "cwd": "/x"}"#,
            outURL: outURL, termProgram: "WarpTerminal", parentComm: "node")
        XCTAssertEqual(status, 0)
        let content = try String(contentsOfFile: outURL.path, encoding: .utf8)
        let event = AgentEvent.decode(line: Substring(content.split(separator: "\n").first ?? ""))
        XCTAssertEqual(event?.terminal?.kind, .other, "程序化拉起 → 不冒充 Warp")
        XCTAssertNil(event?.terminal?.bundleId, "无 bundleId(不误激活 App)")
        XCTAssertNotNil(event?.terminal?.pid, "pid 保留(死进程快清仍工作)")
    }

    func testShellParent_keepsTerminalKind() throws {
        let outURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: outURL) }
        _ = try runScript(
            hookJSON: #"{"hook_event_name": "Stop", "session_id": "S1", "cwd": "/x"}"#,
            outURL: outURL, termProgram: "WarpTerminal", parentComm: "-zsh")
        let content = try String(contentsOfFile: outURL.path, encoding: .utf8)
        let event = AgentEvent.decode(line: Substring(content.split(separator: "\n").first ?? ""))
        XCTAssertEqual(event?.terminal?.kind, .warp, "用户 shell 下照常识别")
    }
}
