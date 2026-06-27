import Foundation

// MARK: - AppPaths

/// Central registry of well-known file-system paths used by AgentPet.
///
/// Keeping these in one place ensures that the file-watcher (``AppCoordinator``)
/// and the hook-installer (``HookInstaller`` / ``PreferencesWindow``) both agree
/// on the same default events-file path — no duplicated string literals scattered
/// across the codebase.
public enum AppPaths {

    /// Absolute path to the AgentPet events NDJSON file.
    ///
    /// Default: `$HOME/Library/Application Support/AgentPet/events.ndjson`
    ///
    /// The literal `~` is **never** embedded in the returned string; the home
    /// directory is resolved at module load time.  This makes the path safe to
    /// embed verbatim inside a shell `env` command (the hook runner command string
    /// written into `settings.json`).
    public static let eventsFile: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/AgentPet/events.ndjson"
    }()
}
