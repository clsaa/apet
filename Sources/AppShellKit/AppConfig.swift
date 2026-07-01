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
    /// 是否由自动发现机制添加（非用户手动配置）。
    /// 旧版 JSON 不含此字段时解码默认 false，保证向后兼容（M2-B Fix MAJOR-2）。
    public var isAutoDiscovered: Bool

    // 显式 CodingKeys：让自定义 init(from:) 与合成 encode(to:) 协同覆盖全部字段。
    private enum CodingKeys: String, CodingKey {
        case path, agent, isAutoDiscovered
    }

    public init(path: String, agent: String = "claude-code", isAutoDiscovered: Bool = false) {
        self.path = path
        self.agent = agent
        self.isAutoDiscovered = isAutoDiscovered
    }

    /// 自定义解码：旧版 JSON 缺少 `isAutoDiscovered` 字段时默认 false，其余字段正常读取。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path             = try c.decode(String.self, forKey: .path)
        agent            = try c.decode(String.self, forKey: .agent)
        isAutoDiscovered = try c.decodeIfPresent(Bool.self, forKey: .isAutoDiscovered) ?? false
    }
}

// MARK: - AppConfig

/// User-persisted application configuration.
///
/// Stored as JSON at `~/Library/Application Support/AgentPet/config.json` via ``ConfigStore``.
/// 5 状态圆点的自定义颜色（hex，nil=用内置默认）。绿=running 橙=attention 红=doneWaiting 黄=read 灰=stale。
public struct StateColorConfig: Codable, Equatable {
    public var running: String?
    public var attention: String?
    public var doneWaiting: String?
    public var read: String?
    public var stale: String?

    public init(running: String? = nil, attention: String? = nil, doneWaiting: String? = nil,
                read: String? = nil, stale: String? = nil) {
        self.running = running; self.attention = attention; self.doneWaiting = doneWaiting
        self.read = read; self.stale = stale
    }

    /// 内置默认（系统语义色）。
    public static let defaults = StateColorConfig(
        running: "#34C759", attention: "#FF9500", doneWaiting: "#FF3B30",
        read: "#FFCC00", stale: "#8E8E93"
    )
}

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
    /// 免打扰模式开关。默认 false（不开启）。
    public var dndEnabled: Bool
    /// 免打扰开始时间（分钟，0 = 00:00）。默认 0。
    public var dndStartMin: Int
    /// 免打扰结束时间（分钟，0 = 00:00）。默认 0。
    public var dndEndMin: Int
    /// 从多 root 自动发现中排除的路径列表。默认空（不排除任何路径）。
    public var excludedRoots: [String]
    /// 状态栏样式：`"counts"`（彩色计数 🟢🔴🟡⚪+数字）| `"pawprint"`（单 pawprint 图标+主色+总数）。
    public var menuBarStyle: String
    /// 5 状态圆点自定义颜色（F3）。缺省用 `StateColorConfig.defaults`。
    public var stateColors: StateColorConfig
    /// F1：通知横幅开关（关→完全不弹）。默认 true。
    public var notifyBannerEnabled: Bool
    /// F1：通知声音开关（关→静默横幅）。默认 true。
    public var notifySoundEnabled: Bool

    // CodingKeys：含全部字段，供自定义 decoder 和 synthesized encoder 共同使用。
    private enum CodingKeys: String, CodingKey {
        case dataRoots, displayMode, notifyMode, staleAfterSec, endedAfterSec,
             waitingEndedAfterSec, selectedPet, readGrayAfterSec, panelHotKey,
             dndEnabled, dndStartMin, dndEndMin, excludedRoots, menuBarStyle, stateColors,
             notifyBannerEnabled, notifySoundEnabled
    }

    /// 自定义解码：旧版 config.json 缺少可选字段时用默认值，不丢失其他已有设置。
    /// - `readGrayAfterSec` 缺失 → 3600
    /// - `panelHotKey` 缺失 → `.defaultPanel`（⌥⌘P）
    /// - `dndEnabled` 缺失 → false
    /// - `dndStartMin` 缺失 → 0
    /// - `dndEndMin` 缺失 → 0
    /// - `excludedRoots` 缺失 → []
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
        dndEnabled           = try c.decodeIfPresent(Bool.self,          forKey: .dndEnabled)    ?? false
        dndStartMin          = try c.decodeIfPresent(Int.self,           forKey: .dndStartMin)   ?? 0
        dndEndMin            = try c.decodeIfPresent(Int.self,           forKey: .dndEndMin)     ?? 0
        excludedRoots        = try c.decodeIfPresent([String].self,      forKey: .excludedRoots) ?? []
        menuBarStyle         = try c.decodeIfPresent(String.self,        forKey: .menuBarStyle)  ?? "counts"
        stateColors          = try c.decodeIfPresent(StateColorConfig.self, forKey: .stateColors) ?? .defaults
        notifyBannerEnabled  = try c.decodeIfPresent(Bool.self, forKey: .notifyBannerEnabled) ?? true
        notifySoundEnabled   = try c.decodeIfPresent(Bool.self, forKey: .notifySoundEnabled)  ?? true
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
        panelHotKey: HotKeyConfig = .defaultPanel,
        dndEnabled: Bool = false,
        dndStartMin: Int = 0,
        dndEndMin: Int = 0,
        excludedRoots: [String] = [],
        menuBarStyle: String = "counts",
        stateColors: StateColorConfig = .defaults,
        notifyBannerEnabled: Bool = true,
        notifySoundEnabled: Bool = true
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
        self.dndEnabled = dndEnabled
        self.dndStartMin = dndStartMin
        self.dndEndMin = dndEndMin
        self.excludedRoots = excludedRoots
        self.menuBarStyle = menuBarStyle
        self.stateColors = stateColors
        self.notifyBannerEnabled = notifyBannerEnabled
        self.notifySoundEnabled = notifySoundEnabled
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
            panelHotKey: .defaultPanel,
            dndEnabled: false,
            dndStartMin: 0,
            dndEndMin: 0,
            excludedRoots: []
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
