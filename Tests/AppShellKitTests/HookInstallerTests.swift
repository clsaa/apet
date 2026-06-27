import XCTest
@testable import AppShellKit

final class HookInstallerTests: XCTestCase {

    // MARK: - Constants

    private let hookEvents = [
        "SessionStart", "Stop", "Notification",
        "PreToolUse", "PostToolUse", "SubagentStop",
    ]

    // MARK: - Helpers

    private func makeTempURL(suffix: String = ".json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + suffix)
    }

    /// Parse `url` → top-level dict → `hooks` sub-dict.
    private func readHooksDict(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return root["hooks"] as? [String: Any] ?? [:]
    }

    // MARK: - Test 1: Missing file → install → 6 events, isInstalled==true, NO backup

    func testInstallIntoMissingFileCreatesAllSixEvents() throws {
        let url = makeTempURL()
        let bakURL = URL(fileURLWithPath: url.path + ".apet.bak")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: bakURL)
        }

        let installer = HookInstaller()
        let marker = "test-marker-\(UUID().uuidString)"
        let runner = "/usr/local/bin/apet-emit-event"

        try installer.install(into: url, runnerPath: runner, marker: marker)

        // File must exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // isInstalled must return true
        XCTAssertTrue(try installer.isInstalled(settingsURL: url, marker: marker))

        // All 6 events must be present, each with exactly one apet-marked entry
        let hooksDict = try readHooksDict(at: url)
        for event in hookEvents {
            let entries = hooksDict[event] as? [[String: Any]] ?? []
            let apetEntries = entries.filter { ($0["__apet"] as? String) == marker }
            XCTAssertEqual(apetEntries.count, 1,
                           "Expected 1 apet entry for \(event), got \(apetEntries.count)")
        }

        // Backup must NOT exist — no prior file was present
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakURL.path),
                       "Backup must not be created when installing into a non-existent file")
    }

    // MARK: - Test 2: Existing file with user hook on Stop → install preserves user hook + backup

    func testInstallPreservesExistingUserHooksAndCreatesBackup() throws {
        let url = makeTempURL()
        let bakURL = URL(fileURLWithPath: url.path + ".apet.bak")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: bakURL)
        }

        // Write pre-existing settings with one user hook on "Stop"
        let userHookGroup: [String: Any] = [
            "hooks": [["type": "command", "command": "/usr/local/bin/user-hook"]],
        ]
        let existing: [String: Any] = ["hooks": ["Stop": [userHookGroup]]]
        try JSONSerialization.data(withJSONObject: existing, options: .prettyPrinted)
            .write(to: url)

        let originalData = try Data(contentsOf: url)

        let installer = HookInstaller()
        let marker = "apet-\(UUID().uuidString)"
        try installer.install(into: url, runnerPath: "/path/to/runner", marker: marker)

        // ── Backup assertions ────────────────────────────────────────────────
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakURL.path),
                      "Backup must be created when installing into an existing file")
        let bakData = try Data(contentsOf: bakURL)
        XCTAssertEqual(bakData, originalData, "Backup must contain the original file content")

        // ── Stop event: user entry preserved + apet entry added ──────────────
        let hooksDict = try readHooksDict(at: url)
        let stopEntries = hooksDict["Stop"] as? [[String: Any]] ?? []
        let userEntries = stopEntries.filter { ($0["__apet"] as? String) == nil }
        let apetEntries = stopEntries.filter { ($0["__apet"] as? String) == marker }
        XCTAssertEqual(userEntries.count, 1, "User's Stop entry must be preserved")
        XCTAssertEqual(apetEntries.count, 1, "Apet's Stop entry must be added")

        // ── Other 5 events: apet entry present ──────────────────────────────
        for event in hookEvents where event != "Stop" {
            let entries = hooksDict[event] as? [[String: Any]] ?? []
            let apet = entries.filter { ($0["__apet"] as? String) == marker }
            XCTAssertEqual(apet.count, 1, "Expected 1 apet entry for \(event)")
        }

        XCTAssertTrue(try installer.isInstalled(settingsURL: url, marker: marker))
    }

    // MARK: - Test 3: install twice → exactly one apet entry per event (idempotent)

    func testInstallIdempotentNoDuplicates() throws {
        let url = makeTempURL()
        let bakURL = URL(fileURLWithPath: url.path + ".apet.bak")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: bakURL)
        }

        let installer = HookInstaller()
        let marker = "apet-\(UUID().uuidString)"
        let runner = "/path/to/runner"

        try installer.install(into: url, runnerPath: runner, marker: marker)
        try installer.install(into: url, runnerPath: runner, marker: marker)

        let hooksDict = try readHooksDict(at: url)
        for event in hookEvents {
            let entries = hooksDict[event] as? [[String: Any]] ?? []
            let apetEntries = entries.filter { ($0["__apet"] as? String) == marker }
            XCTAssertEqual(apetEntries.count, 1,
                           "Expected exactly 1 apet entry for \(event) after double install")
        }

        XCTAssertTrue(try installer.isInstalled(settingsURL: url, marker: marker))
    }

    // MARK: - Test 4: uninstall → apet entries removed, user Stop entry survives, isInstalled==false

    func testUninstallRemovesApetEntriesPreservesUserHooks() throws {
        let url = makeTempURL()
        let bakURL = URL(fileURLWithPath: url.path + ".apet.bak")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: bakURL)
        }

        // Pre-existing user hook on "Stop"
        let userHookGroup: [String: Any] = [
            "hooks": [["type": "command", "command": "/usr/local/bin/user-hook"]],
        ]
        let existing: [String: Any] = ["hooks": ["Stop": [userHookGroup]]]
        try JSONSerialization.data(withJSONObject: existing, options: .prettyPrinted)
            .write(to: url)

        let installer = HookInstaller()
        let marker = "apet-\(UUID().uuidString)"

        try installer.install(into: url, runnerPath: "/path/to/runner", marker: marker)
        XCTAssertTrue(try installer.isInstalled(settingsURL: url, marker: marker))

        try installer.uninstall(from: url, marker: marker)

        // isInstalled must now be false
        XCTAssertFalse(try installer.isInstalled(settingsURL: url, marker: marker))

        // User's Stop entry must survive
        let hooksDict = try readHooksDict(at: url)
        let stopEntries = hooksDict["Stop"] as? [[String: Any]] ?? []
        let userEntries = stopEntries.filter { ($0["__apet"] as? String) == nil }
        XCTAssertEqual(userEntries.count, 1, "User's Stop entry must survive uninstall")

        // All apet entries must be gone
        for event in hookEvents {
            let entries = hooksDict[event] as? [[String: Any]] ?? []
            let apetEntries = entries.filter { ($0["__apet"] as? String) == marker }
            XCTAssertTrue(apetEntries.isEmpty,
                          "Apet entry for \(event) must be removed by uninstall")
        }
    }

    // MARK: - Test 5: uninstall on file without apet entries → no-op, no throw

    func testUninstallNoOpWhenNotInstalled() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let existing: [String: Any] = ["hooks": [:] as [String: Any]]
        try JSONSerialization.data(withJSONObject: existing, options: .prettyPrinted)
            .write(to: url)

        let installer = HookInstaller()
        let marker = "apet-\(UUID().uuidString)"

        XCTAssertNoThrow(try installer.uninstall(from: url, marker: marker))
        XCTAssertFalse(try installer.isInstalled(settingsURL: url, marker: marker))
    }

    // MARK: - Test 6: malformed JSON (top-level array) → throws .malformedSettings

    func testMalformedTopLevelArrayThrows() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try "[1,2,3]".data(using: .utf8)!.write(to: url)

        let installer = HookInstaller()
        let marker = "apet-\(UUID().uuidString)"

        XCTAssertThrowsError(try installer.install(into: url, runnerPath: "/path", marker: marker)) { err in
            XCTAssertEqual(err as? HookInstallError, .malformedSettings)
        }
        XCTAssertThrowsError(try installer.isInstalled(settingsURL: url, marker: marker)) { err in
            XCTAssertEqual(err as? HookInstallError, .malformedSettings)
        }
    }

    // MARK: - Test 7: garbage data → throws .malformedSettings

    func testGarbageDataThrows() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try "not json at all!!!".data(using: .utf8)!.write(to: url)

        let installer = HookInstaller()
        let marker = "apet-\(UUID().uuidString)"

        XCTAssertThrowsError(try installer.install(into: url, runnerPath: "/path", marker: marker)) { err in
            XCTAssertEqual(err as? HookInstallError, .malformedSettings)
        }
        XCTAssertThrowsError(try installer.isInstalled(settingsURL: url, marker: marker)) { err in
            XCTAssertEqual(err as? HookInstallError, .malformedSettings)
        }
    }

    // MARK: - Test 8: isInstalled returns false for missing file (no throw)

    func testIsInstalledReturnsFalseForMissingFile() throws {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).json")
        let installer = HookInstaller()
        let result = try installer.isInstalled(settingsURL: url, marker: "any")
        XCTAssertFalse(result)
    }

    // MARK: - Test 9: apet entry carries the runnerPath and marker correctly

    func testInstalledEntryContainsCorrectRunnerPathAndMarker() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let installer = HookInstaller()
        let marker = "my-unique-marker"
        let runner = "/opt/homebrew/bin/apet-emit-event"

        try installer.install(into: url, runnerPath: runner, marker: marker)

        let hooksDict = try readHooksDict(at: url)
        let entries = hooksDict["SessionStart"] as? [[String: Any]] ?? []
        let apetGroup = entries.first { ($0["__apet"] as? String) == marker }
        XCTAssertNotNil(apetGroup, "Apet group entry must exist on SessionStart")

        // The apet group must carry a `hooks` array with one command entry
        let innerHooks = apetGroup?["hooks"] as? [[String: Any]] ?? []
        XCTAssertEqual(innerHooks.count, 1)
        XCTAssertEqual(innerHooks.first?["type"] as? String, "command")
        XCTAssertEqual(innerHooks.first?["command"] as? String, runner)
    }
}
