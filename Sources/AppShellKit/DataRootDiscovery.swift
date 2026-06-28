import Foundation

// MARK: - DiscoveryResult

/// The result of a ``DataRootDiscovery/discover(home:existing:excluded:fileOps:maxAutoRoots:)`` pass.
public struct DiscoveryResult: Equatable {
    /// All roots after dedup, exclusion and cap (existing first, then newly found).
    public let roots: [DataRoot]
    /// Subset of `roots` that were *not* present in the `existing` input.
    public let newlyDiscovered: [DataRoot]
}

// MARK: - DataRootDiscovery

/// Pure-logic discovery of Claude Code data roots on the local file system.
///
/// All file-system access is performed through an injected ``FileOps`` instance,
/// making the logic fully testable without touching disk.
///
/// ### Candidate sources
/// 1. `<home>/.claude` — the default Claude Code profile directory.
/// 2. `<home>/.claude-profiles/<x>` — each subdirectory that contains a `projects/`
///    child (a reliable indicator of a genuine Claude root, guards against picking up
///    unrelated directories that happen to live under `.claude-profiles`).
///
/// ### Deduplication
/// Roots are deduplicated by their absolute path string.  Paths already present in
/// `existing` are retained in `roots` but do **not** appear in `newlyDiscovered`.
///
/// ### Ordering
/// `existing` roots appear first; newly-discovered roots follow in the order they
/// were found (`.claude` before profile entries).
public enum DataRootDiscovery {

    /// Scan the file system for Claude Code data roots.
    ///
    /// - Parameters:
    ///   - home: The user's home directory (absolute, tilde-expanded path).
    ///   - existing: Roots already known to apet (paths must be absolute/expanded).
    ///   - excluded: Absolute paths that should be skipped entirely.
    ///   - fileOps: File-system abstraction; inject a mock in unit tests.
    ///   - maxAutoRoots: Maximum number of roots in the final result (default 16).
    /// - Returns: A ``DiscoveryResult`` with the merged roots and the newly-found subset.
    public static func discover(
        home: String,
        existing: [DataRoot],
        excluded: [String],
        fileOps: FileOps,
        maxAutoRoots: Int = 16
    ) -> DiscoveryResult {
        let existingPaths = Set(existing.map(\.path))
        let excludedPaths = Set(excluded)

        // Build the merged list in insertion order: existing roots first, then newly found.
        var ordered: [DataRoot] = []
        var seen = Set<String>()

        /// Attempt to append a root for `path`.  No-ops if already seen or excluded.
        func add(_ path: String) {
            guard !seen.contains(path) else { return }
            guard !excludedPaths.contains(path) else { return }
            seen.insert(path)
            ordered.append(DataRoot(path: path, agent: "claude-code"))
        }

        // 1. Seed with existing roots (preserves user-configured order, handles exclusions).
        for root in existing {
            add(root.path)
        }

        // 2. Candidate: <home>/.claude
        let defaultClaude = home + "/.claude"
        if fileOps.fileExists(defaultClaude) {
            add(defaultClaude)
        }

        // 3. Candidates: <home>/.claude-profiles/<x> where <x>/projects exists.
        //    Only subdirectories that look like genuine Claude roots are included.
        let profilesDir = home + "/.claude-profiles"
        for name in fileOps.contentsOfDir(profilesDir) {
            let profilePath = profilesDir + "/" + name
            if fileOps.fileExists(profilePath + "/projects") {
                add(profilePath)
            }
        }

        // 4. Apply maxAutoRoots cap.
        let roots = Array(ordered.prefix(maxAutoRoots))

        // 5. Newly discovered = roots that were not present in the original `existing` input.
        let newlyDiscovered = roots.filter { !existingPaths.contains($0.path) }

        return DiscoveryResult(roots: roots, newlyDiscovered: newlyDiscovered)
    }
}
