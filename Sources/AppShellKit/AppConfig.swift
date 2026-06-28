import Foundation

// MARK: - DataRoot

/// A Claude Code profile directory (e.g. `~/.claude`) from which apet installs hooks
/// and monitors agent activity.
public struct DataRoot: Codable, Equatable, Identifiable {
    /// Stable identifier — the absolute path string.
    public var id: String { path }
    /// Absolute path to the Claude profile directory (e.g. `/Users/alice/.claude`).
    public var path: String
    /// Agent type string; currently always `"claude-code"`.
    public var agent: String

    public init(path: String, agent: String = "claude-code") {
        self.path = path
        self.agent = agent
    }
}

// MARK: - AppConfig

/// User-persisted application configuration.
///
/// Stored as JSON at `~/Library/Application Support/AgentPet/config.json` via ``ConfigStore``.
public struct AppConfig: Codable, Equatable {
    /// List of Claude profile directories to monitor.
    public var dataRoots: [DataRoot]
    /// How to show the agent: `"pet"` (floating window) or `"menuBarOnly"`.
    public var displayMode: String
    /// When to notify: `"attentionOnly"` or `"everyStop"`.
    public var notifyMode: String
    /// Seconds of inactivity before a session is marked stale.
    public var staleAfterSec: Double
    /// Seconds after which an ended (stopped) session is reaped from memory.
    public var endedAfterSec: Double
    /// Seconds after which a waiting (attention) session that never resumes is reaped.
    public var waitingEndedAfterSec: Double
    /// Which pet sprite to render: `"shiba"` or `"bichon"`.
    public var selectedPet: String
    /// 已读（黄）会话超过此秒数自动转灰（闲置）。默认 3600（1 小时）。
    public var readGrayAfterSec: Double
    /// 呼出面板的全局快捷键配置。默认 ⌥⌘P。
    public var panelHotKey: HotKeyConfig

    // CodingKeys：含 readGrayAfterSec / panelHotKey，供自定义 decoder 和 synthesized encoder 共同使用。
    private enum CodingKeys: String, CodingKey {
        case dataRoots, displayMode, notifyMode, staleAfterSec, endedAfterSec,
             waitingEndedAfterSec, selectedPet, readGrayAfterSec, panelHotKey
    }

    /// 自定义解码：旧版 config.json 缺少可选字段时用默认值，不丢失其他已有设置。
    /// - `readGrayAfterSec` 缺失 → 3600
    /// - `panelHotKey` 缺失 → `.defaultPanel`（⌥⌘P）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dataRoots            = try c.decode([DataRoot].self, forKey: .dataRoots)
        displayMode          = try c.decode(String.self,    forKey: .displayMode)
        notifyMode           = try c.decode(String.self,    forKey: .notifyMode)
        staleAfterSec        = try c.decode(Double.self,    forKey: .staleAfterSec)
        endedAfterSec        = try c.decode(Double.self,    forKey: .endedAfterSec)
        waitingEndedAfterSec = try c.decode(Double.self,    forKey: .waitingEndedAfterSec)
        selectedPet          = try c.decode(String.self,    forKey: .selectedPet)
        readGrayAfterSec     = try c.decodeIfPresent(Double.self,        forKey: .readGrayAfterSec) ?? 3600
        panelHotKey          = try c.decodeIfPresent(HotKeyConfig.self,  forKey: .panelHotKey) ?? .defaultPanel
    }

    public init(
        dataRoots: [DataRoot],
        displayMode: String,
        notifyMode: String,
        staleAfterSec: Double,
        endedAfterSec: Double,
        waitingEndedAfterSec: Double,
        selectedPet: String,
        readGrayAfterSec: Double = 3600,
        panelHotKey: HotKeyConfig = .defaultPanel
    ) {
        self.dataRoots = dataRoots
        self.displayMode = displayMode
        self.notifyMode = notifyMode
        self.staleAfterSec = staleAfterSec
        self.endedAfterSec = endedAfterSec
        self.waitingEndedAfterSec = waitingEndedAfterSec
        self.selectedPet = selectedPet
        self.readGrayAfterSec = readGrayAfterSec
        self.panelHotKey = panelHotKey
    }

    /// Factory that produces the out-of-the-box defaults.
    ///
    /// The default data root is `~/.claude` (the standard Claude Code profile directory).
    /// `displayMode` 合法值：`"pet"` | `"compact"` | `"menuBarOnly"`。
    public static var defaults: AppConfig {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let claudeRoot = homeDir.appendingPathComponent(".claude").path
        return AppConfig(
            dataRoots: [DataRoot(path: claudeRoot, agent: "claude-code")],
            displayMode: "pet",
            notifyMode: "attentionOnly",
            staleAfterSec: 600,
            endedAfterSec: 14400,
            waitingEndedAfterSec: 28800,
            selectedPet: "shiba",
            readGrayAfterSec: 3600,
            panelHotKey: .defaultPanel
        )
    }
}

// MARK: - ConfigStore

/// Loads and saves ``AppConfig`` to a JSON file at a caller-specified URL.
///
/// ### Safety
/// ``ConfigStore`` never accesses a hardcoded path; the URL is always injected by the caller.
/// This makes it easy to redirect to a temp directory in tests.
public struct ConfigStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Load config from disk.
    ///
    /// Returns ``AppConfig/defaults`` when:
    /// - The file does not exist yet.
    /// - The file exists but cannot be decoded (e.g. corrupted JSON).
    public func load() -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppConfig.defaults
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            return AppConfig.defaults
        }
    }

    /// Persist `config` to disk as pretty-printed JSON, creating parent directories if needed.
    ///
    /// Writes atomically so a crash mid-write never produces a truncated file.
    public func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomicWrite)
    }
}
