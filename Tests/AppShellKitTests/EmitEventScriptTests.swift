import XCTest
import Foundation
@testable import AgentPetCore

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
        termProgram: String? = nil
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
        XCTAssertEqual(event.title,                     "proj a")
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
}
