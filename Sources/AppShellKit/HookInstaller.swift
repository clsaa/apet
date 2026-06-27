import Foundation

// MARK: - HookInstallError

/// Errors thrown by ``HookInstaller``.
public enum HookInstallError: Error, Equatable {
    /// The settings file exists but is not a valid JSON object (e.g. top-level array, garbage).
    case malformedSettings
}

// MARK: - HookInstaller

/// Installs and uninstalls Claude Code hook entries into a caller-provided `settings.json` file.
///
/// ### Safety contract
/// This type **never** accesses a hardcoded path such as `~/.claude/settings.json`.
/// Every operation receives an explicit `settingsURL` from the caller.
///
/// ### Hook entry shape
/// Each of the six Claude Code hook events (`SessionStart`, `Stop`, `Notification`,
/// `PreToolUse`, `PostToolUse`, `SubagentStop`) receives one apet group object inside the
/// top-level `"hooks"` dictionary.  The group object is:
/// ```json
/// {
///   "__apet": "<marker>",
///   "hooks": [ { "type": "command", "command": "<runnerPath>" } ]
/// }
/// ```
/// The `"__apet"` key is what distinguishes apet-managed entries from the user's own entries,
/// and is the basis for idempotent install and clean uninstall.
public struct HookInstaller {

    // MARK: - Internal constants

    static let hookEvents: [String] = [
        "SessionStart", "Stop", "Notification",
        "PreToolUse", "PostToolUse", "SubagentStop",
    ]

    // MARK: - Public API

    public init() {}

    /// Returns `true` if `settingsURL` contains at least one apet-marked entry with `marker`.
    ///
    /// - Returns `false` (without throwing) when `settingsURL` does not exist.
    /// - Throws ``HookInstallError/malformedSettings`` when the file exists but is not a
    ///   valid JSON object.
    public func isInstalled(settingsURL: URL, marker: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return false }
        let root = try readSettings(at: settingsURL)
        let hooksDict = try extractHooksDict(from: root)
        return hooksDict.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { ($0["__apet"] as? String) == marker }
        }
    }

    /// Installs apet hook entries into `settingsURL`.
    ///
    /// - When `settingsURL` does not exist the file is created from scratch.
    /// - When `settingsURL` exists, a backup is written to `settingsURL.path + ".apet.bak"`
    ///   **before** any changes are made.
    /// - **Idempotent**: any previously installed apet entry with the same `marker` is removed
    ///   first, so calling `install` twice produces exactly one entry per event.
    ///
    /// - Throws ``HookInstallError/malformedSettings`` when the existing file is not a valid
    ///   JSON object.
    public func install(into settingsURL: URL, runnerPath: String, marker: String) throws {
        let fileExists = FileManager.default.fileExists(atPath: settingsURL.path)

        // Read existing content, or start from empty object.
        var root: [String: Any] = fileExists ? try readSettings(at: settingsURL) : [:]
        var hooksDict = try extractHooksDict(from: root)

        // ── Idempotency: strip previous apet entries for this marker ─────────
        for event in Self.hookEvents {
            if let entries = hooksDict[event] as? [[String: Any]] {
                hooksDict[event] = entries.filter { ($0["__apet"] as? String) != marker }
            }
        }

        // ── Build the apet group entry ────────────────────────────────────────
        let apetGroup: [String: Any] = [
            "__apet": marker,
            "hooks": [["type": "command", "command": runnerPath]],
        ]

        // ── Append the apet entry to each event ──────────────────────────────
        for event in Self.hookEvents {
            var entries = hooksDict[event] as? [[String: Any]] ?? []
            entries.append(apetGroup)
            hooksDict[event] = entries
        }

        root["hooks"] = hooksDict

        // ── Backup the original file (only when it pre-existed) ──────────────
        if fileExists {
            let bakURL = URL(fileURLWithPath: settingsURL.path + ".apet.bak")
            try? FileManager.default.removeItem(at: bakURL)
            try FileManager.default.copyItem(at: settingsURL, to: bakURL)
        }

        try writeSettings(root, to: settingsURL)
    }

    /// Removes all apet-managed entries identified by `marker` from `settingsURL`.
    ///
    /// - User's own hook entries are left untouched.
    /// - Events whose entry arrays become empty after removal are dropped from the dict.
    /// - If the file does not exist, or contains no apet-marked entries, this is a no-op.
    ///
    /// - Throws ``HookInstallError/malformedSettings`` when the file exists but is not a valid
    ///   JSON object.
    public func uninstall(from settingsURL: URL, marker: String) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }

        var root = try readSettings(at: settingsURL)
        var hooksDict = try extractHooksDict(from: root)

        // Scan ALL events (not just the predefined 6) so older installs with different
        // event sets are also cleaned up.
        for event in Array(hooksDict.keys) {
            guard let entries = hooksDict[event] as? [[String: Any]] else { continue }
            let remaining = entries.filter { ($0["__apet"] as? String) != marker }
            if remaining.isEmpty {
                hooksDict.removeValue(forKey: event)
            } else {
                hooksDict[event] = remaining
            }
        }

        root["hooks"] = hooksDict
        try writeSettings(root, to: settingsURL)
    }

    // MARK: - Private helpers

    /// Reads and deserialises the JSON file at `url` as a top-level dictionary.
    ///
    /// Empty files are treated as `{}`. Non-object JSON (array, scalar) throws
    /// ``HookInstallError/malformedSettings``.
    private func readSettings(at url: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HookInstallError.malformedSettings
        }

        guard !data.isEmpty else { return [:] }

        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HookInstallError.malformedSettings
        }

        guard let dict = obj as? [String: Any] else {
            throw HookInstallError.malformedSettings
        }

        return dict
    }

    /// Extracts the `"hooks"` sub-dictionary from the settings root, returning `[:]` when
    /// the key is absent.  Throws ``HookInstallError/malformedSettings`` when the key is
    /// present but not a dictionary.
    private func extractHooksDict(from root: [String: Any]) throws -> [String: Any] {
        guard let hooks = root["hooks"] else { return [:] }
        guard let dict = hooks as? [String: Any] else {
            throw HookInstallError.malformedSettings
        }
        return dict
    }

    /// Serialises `root` as pretty-printed sorted-key JSON and writes it atomically to `url`.
    private func writeSettings(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
