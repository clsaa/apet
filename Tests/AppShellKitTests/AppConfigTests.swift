import XCTest
@testable import AppShellKit

final class AppConfigTests: XCTestCase {

    var tempDir: URL!
    var configURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configURL = tempDir.appendingPathComponent("config.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - load()

    func testLoadMissingFileReturnsDefaults() {
        let store = ConfigStore(url: configURL)
        let config = store.load()
        XCTAssertEqual(config, AppConfig.defaults)
    }

    func testCorruptJsonReturnsDefaults() throws {
        try "not valid json {{{".write(to: configURL, atomically: true, encoding: .utf8)
        let store = ConfigStore(url: configURL)
        let config = store.load()
        XCTAssertEqual(config, AppConfig.defaults)
    }

    // MARK: - save() + load() round-trip

    func testSaveThenLoadRoundTrips() throws {
        let store = ConfigStore(url: configURL)
        var custom = AppConfig.defaults
        custom.displayMode = "menuBarOnly"
        custom.notifyMode = "everyStop"
        custom.selectedPet = "bichon"
        custom.staleAfterSec = 120
        custom.dataRoots = [DataRoot(path: "/tmp/custom-root", agent: "claude-code")]
        try store.save(custom)
        let loaded = store.load()
        XCTAssertEqual(loaded, custom)
    }

    func testSaveCreatesParentDirectoryIfMissing() throws {
        let nested = tempDir
            .appendingPathComponent("deep")
            .appendingPathComponent("nested")
            .appendingPathComponent("config.json")
        let store = ConfigStore(url: nested)
        try store.save(AppConfig.defaults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testSaveProducesPrettyPrintedJson() throws {
        let store = ConfigStore(url: configURL)
        try store.save(AppConfig.defaults)
        let raw = try String(contentsOf: configURL, encoding: .utf8)
        // Pretty-printed JSON contains newlines and indentation
        XCTAssertTrue(raw.contains("\n"))
        XCTAssertTrue(raw.contains("  "))
    }

    // MARK: - Defaults

    func testDefaultsHasClaudeRoot() {
        let defaults = AppConfig.defaults
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let expectedRoot = homeDir.appendingPathComponent(".claude").path
        XCTAssertEqual(defaults.dataRoots.first?.path, expectedRoot)
        XCTAssertEqual(defaults.displayMode, "pet")
        XCTAssertEqual(defaults.notifyMode, "attentionOnly")
        XCTAssertEqual(defaults.selectedPet, "shiba")
    }

    func testDefaultsAgent() {
        let defaults = AppConfig.defaults
        XCTAssertEqual(defaults.dataRoots.first?.agent, "claude-code")
    }

    func testDefaultsThresholds() {
        let d = AppConfig.defaults
        XCTAssertEqual(d.staleAfterSec, 600)
        XCTAssertEqual(d.endedAfterSec, 14400)
        XCTAssertEqual(d.waitingEndedAfterSec, 28800)
    }

    // MARK: - Equatable

    func testEquatableDistinguishesNotifyMode() {
        var a = AppConfig.defaults
        var b = AppConfig.defaults
        a.notifyMode = "attentionOnly"
        b.notifyMode = "everyStop"
        XCTAssertNotEqual(a, b)
    }

    func testEquatableDistinguishesDataRoots() {
        var a = AppConfig.defaults
        var b = AppConfig.defaults
        a.dataRoots = [DataRoot(path: "/a", agent: "claude-code")]
        b.dataRoots = [DataRoot(path: "/b", agent: "claude-code")]
        XCTAssertNotEqual(a, b)
    }

    // MARK: - DataRoot

    func testDataRootIdIsPath() {
        let root = DataRoot(path: "/some/path", agent: "claude-code")
        XCTAssertEqual(root.id, "/some/path")
    }

    func testDataRootDefaultAgent() {
        let root = DataRoot(path: "/x")
        XCTAssertEqual(root.agent, "claude-code")
    }

    /// MAJOR-2：旧版 JSON 中 DataRoot 没有 isAutoDiscovered 字段时，
    /// 解码应成功（不抛 keyNotFound），且 isAutoDiscovered 默认为 false，
    /// 同时 path / agent 等其他字段完整保留。
    func test_DataRoot_decode_oldJson_withoutIsAutoDiscovered_defaults_false() throws {
        // TC-AppConfig-PARAM-001: 旧 JSON DataRoot 无 isAutoDiscovered 字段的向后兼容
        let oldJson = """
        {
          "agent": "claude-code",
          "path": "/home/alice/.claude"
        }
        """
        let data = oldJson.data(using: .utf8)!
        let root = try JSONDecoder().decode(DataRoot.self, from: data)

        XCTAssertEqual(root.path, "/home/alice/.claude",
                       "path 字段应从旧 JSON 中正确解码")
        XCTAssertEqual(root.agent, "claude-code",
                       "agent 字段应从旧 JSON 中正确解码")
        XCTAssertEqual(root.isAutoDiscovered, false,
                       "旧 JSON 无 isAutoDiscovered 时应默认 false（向后兼容）")
    }

    /// MAJOR-2：isAutoDiscovered=true 能被正常 encode 并 round-trip decode 回 true。
    func test_DataRoot_isAutoDiscovered_roundTrip() throws {
        // TC-AppConfig-FUNC-001: DataRoot.isAutoDiscovered round-trip
        let root = DataRoot(path: "/tmp/auto", agent: "claude-code", isAutoDiscovered: true)
        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(DataRoot.self, from: data)
        XCTAssertEqual(decoded.path, "/tmp/auto")
        XCTAssertEqual(decoded.isAutoDiscovered, true,
                       "isAutoDiscovered=true 应能 encode 并 decode 回 true")
    }

    /// MAJOR-2：AppConfig 中含 isAutoDiscovered=true 的 DataRoot 能整体 round-trip。
    func test_AppConfig_withAutoDiscoveredRoot_roundTrip() throws {
        // TC-AppConfig-FUNC-002: AppConfig 含自动发现根 round-trip
        let store = ConfigStore(url: configURL)
        var cfg = AppConfig.defaults
        cfg.dataRoots = [
            DataRoot(path: "/home/alice/.claude", agent: "claude-code", isAutoDiscovered: false),
            DataRoot(path: "/home/alice/.claude-profiles/work", agent: "claude-code", isAutoDiscovered: true),
        ]
        try store.save(cfg)
        let loaded = store.load()
        XCTAssertEqual(loaded.dataRoots.count, 2)
        XCTAssertEqual(loaded.dataRoots[0].isAutoDiscovered, false)
        XCTAssertEqual(loaded.dataRoots[1].isAutoDiscovered, true,
                       "自动发现根的 isAutoDiscovered=true 应在 round-trip 后保留")
    }

    // MARK: - F2：menuBarStyle 字段（状态栏样式）

    /// defaults 中 menuBarStyle == "counts"（默认展示彩色计数）
    func test_defaults_menuBarStyle_isCounts() {
        XCTAssertEqual(AppConfig.defaults.menuBarStyle, "counts")
    }

    /// round-trip：save + load 保留 menuBarStyle
    func test_menuBarStyle_roundTrip() throws {
        let store = ConfigStore(url: configURL)
        var custom = AppConfig.defaults
        custom.menuBarStyle = "pawprint"
        try store.save(custom)
        XCTAssertEqual(store.load().menuBarStyle, "pawprint")
    }

    /// 旧版 config.json（无 menuBarStyle 字段）解码：其他设置保留，新字段默认 "counts"。
    func test_decode_oldJson_withoutMenuBarStyle_defaultsCounts() throws {
        let oldJson = """
        {
          "dataRoots": [{"agent": "claude-code", "path": "/tmp/root"}],
          "displayMode": "menuBarOnly",
          "endedAfterSec": 7200,
          "notifyMode": "everyStop",
          "selectedPet": "bichon",
          "staleAfterSec": 300,
          "waitingEndedAfterSec": 3600
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: oldJson.data(using: .utf8)!)
        XCTAssertEqual(config.displayMode, "menuBarOnly", "既有字段应保留")
        XCTAssertEqual(config.menuBarStyle, "counts", "旧 json 无此字段时应默认 counts")
    }

    // MARK: - F1/F3：新字段默认 + 向后兼容

    func test_defaults_notifyChannels_andColors() {
        let d = AppConfig.defaults
        XCTAssertTrue(d.notifyBannerEnabled)
        XCTAssertTrue(d.notifySoundEnabled)
        XCTAssertEqual(d.stateColors, .defaults)
    }

    func test_decode_oldJson_withoutNewFields_usesDefaults() throws {
        let oldJson = """
        {
          "dataRoots": [{"agent": "claude-code", "path": "/tmp/root"}],
          "displayMode": "pet",
          "endedAfterSec": 7200,
          "notifyMode": "attentionOnly",
          "selectedPet": "shiba",
          "staleAfterSec": 300,
          "waitingEndedAfterSec": 3600
        }
        """
        let c = try JSONDecoder().decode(AppConfig.self, from: oldJson.data(using: .utf8)!)
        XCTAssertTrue(c.notifyBannerEnabled, "旧 json 无此字段 → 默认 true")
        XCTAssertTrue(c.notifySoundEnabled)
        XCTAssertEqual(c.stateColors, .defaults, "旧 json 无 stateColors → 默认系统色")
    }

    func test_stateColors_roundTrip() throws {
        let store = ConfigStore(url: configURL)
        var custom = AppConfig.defaults
        custom.stateColors.running = "#123456"
        custom.notifySoundEnabled = false
        try store.save(custom)
        let loaded = store.load()
        XCTAssertEqual(loaded.stateColors.running, "#123456")
        XCTAssertFalse(loaded.notifySoundEnabled)
    }

    // MARK: - 精修 3：readGrayAfterSec 字段

    /// defaults 中 readGrayAfterSec == 3600
    func test_defaults_readGrayAfterSec_is3600() {
        XCTAssertEqual(AppConfig.defaults.readGrayAfterSec, 3600)
    }

    /// round-trip：save + load 保留 readGrayAfterSec
    func test_readGrayAfterSec_roundTrip() throws {
        let store = ConfigStore(url: configURL)
        var custom = AppConfig.defaults
        custom.readGrayAfterSec = 7200
        try store.save(custom)
        let loaded = store.load()
        XCTAssertEqual(loaded.readGrayAfterSec, 7200)
    }

    /// 旧版 config.json（无 readGrayAfterSec 字段）解码后：其他设置完整保留，新字段默认 3600。
    func test_decode_oldJson_withoutReadGrayAfter_keepsSettings_defaults3600() throws {
        let oldJson = """
        {
          "dataRoots": [{"agent": "claude-code", "path": "/tmp/root"}],
          "displayMode": "menuBarOnly",
          "endedAfterSec": 7200,
          "notifyMode": "everyStop",
          "selectedPet": "bichon",
          "staleAfterSec": 300,
          "waitingEndedAfterSec": 3600
        }
        """
        let data = oldJson.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        // 既有字段完整保留（不被 keyNotFound 踢回 defaults）
        XCTAssertEqual(config.displayMode, "menuBarOnly", "displayMode 应保留")
        XCTAssertEqual(config.notifyMode, "everyStop", "notifyMode 应保留")
        XCTAssertEqual(config.selectedPet, "bichon", "selectedPet 应保留")
        XCTAssertEqual(config.staleAfterSec, 300, "staleAfterSec 应保留")
        XCTAssertEqual(config.endedAfterSec, 7200, "endedAfterSec 应保留")
        XCTAssertEqual(config.waitingEndedAfterSec, 3600, "waitingEndedAfterSec 应保留")
        XCTAssertEqual(config.dataRoots.first?.path, "/tmp/root", "dataRoots 应保留")

        // 新字段 → 默认 3600
        XCTAssertEqual(config.readGrayAfterSec, 3600, "旧 json 无此字段时应默认 3600")
    }

    // MARK: - panelHotKey 字段

    /// defaults.panelHotKey == .defaultPanel（⌥⌘P）
    func test_defaults_panelHotKey_isDefaultPanel() {
        XCTAssertEqual(AppConfig.defaults.panelHotKey, HotKeyConfig.defaultPanel)
    }

    /// 旧版 json（无 panelHotKey 字段）解码后：其他设置完整保留，panelHotKey == .defaultPanel。
    func test_decode_oldJson_withoutHotKey_keepsSettings_defaultHotKey() throws {
        let oldJson = """
        {
          "dataRoots": [{"agent": "claude-code", "path": "/tmp/root"}],
          "displayMode": "menuBarOnly",
          "endedAfterSec": 7200,
          "notifyMode": "everyStop",
          "selectedPet": "bichon",
          "staleAfterSec": 300,
          "waitingEndedAfterSec": 3600,
          "readGrayAfterSec": 1800
        }
        """
        let data = oldJson.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        // 既有字段完整保留
        XCTAssertEqual(config.displayMode, "menuBarOnly", "displayMode 应保留")
        XCTAssertEqual(config.notifyMode, "everyStop", "notifyMode 应保留")
        XCTAssertEqual(config.selectedPet, "bichon", "selectedPet 应保留")
        XCTAssertEqual(config.staleAfterSec, 300, "staleAfterSec 应保留")
        XCTAssertEqual(config.readGrayAfterSec, 1800, "readGrayAfterSec 应保留")
        XCTAssertEqual(config.dataRoots.first?.path, "/tmp/root", "dataRoots 应保留")

        // 无 panelHotKey → 默认 .defaultPanel
        XCTAssertEqual(config.panelHotKey, HotKeyConfig.defaultPanel, "旧 json 无 panelHotKey 时应默认 .defaultPanel")
    }

    /// round-trip：设置非默认 panelHotKey 后 save+load，值完整保留（验证进了 CodingKeys）。
    func test_panelHotKey_roundTrip_nonDefault() throws {
        let store = ConfigStore(url: configURL)
        var custom = AppConfig.defaults
        custom.panelHotKey = HotKeyConfig(keyCode: 12, modifiers: 4096 | 256, keyLabel: "Q")
        try store.save(custom)
        let loaded = store.load()
        XCTAssertEqual(loaded.panelHotKey, custom.panelHotKey)
        XCTAssertEqual(loaded.panelHotKey.keyCode, 12)
        XCTAssertEqual(loaded.panelHotKey.modifiers, 4096 | 256)
        XCTAssertEqual(loaded.panelHotKey.keyLabel, "Q")
    }

    // MARK: - M2 dndEnabled / dndStartMin / dndEndMin / excludedRoots 字段

    /// 旧版 config.json（仅含原始 7 个必需字段，无可选字段）解码后：
    /// 既有字段完整保留，4 个新字段全部取默认值。
    func test_decode_oldJson_withoutDndAndExcluded_keepsSettings_defaults() throws {
        let oldJson = """
        {
          "dataRoots": [{"agent": "claude-code", "path": "/tmp/root"}],
          "displayMode": "menuBarOnly",
          "endedAfterSec": 7200,
          "notifyMode": "everyStop",
          "selectedPet": "bichon",
          "staleAfterSec": 300,
          "waitingEndedAfterSec": 3600
        }
        """
        let data = oldJson.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        // 既有字段完整保留
        XCTAssertEqual(config.selectedPet, "bichon",       "selectedPet 应保留")
        XCTAssertEqual(config.notifyMode, "everyStop",     "notifyMode 应保留")
        XCTAssertEqual(config.displayMode, "menuBarOnly",  "displayMode 应保留")
        XCTAssertEqual(config.dataRoots.first?.path, "/tmp/root", "dataRoots 应保留")
        XCTAssertEqual(config.staleAfterSec, 300,          "staleAfterSec 应保留")
        XCTAssertEqual(config.endedAfterSec, 7200,         "endedAfterSec 应保留")
        XCTAssertEqual(config.waitingEndedAfterSec, 3600,  "waitingEndedAfterSec 应保留")
        // 可选字段也应取默认值
        XCTAssertEqual(config.readGrayAfterSec, 3600,      "旧 json 无此字段时应默认 3600")
        XCTAssertEqual(config.panelHotKey, HotKeyConfig.defaultPanel, "旧 json 无 panelHotKey 时应默认 .defaultPanel")

        // M2 新字段 → 默认值
        XCTAssertEqual(config.dndEnabled, false,           "旧 json 无 dndEnabled 时应默认 false")
        XCTAssertEqual(config.dndStartMin, 0,              "旧 json 无 dndStartMin 时应默认 0")
        XCTAssertEqual(config.dndEndMin, 0,                "旧 json 无 dndEndMin 时应默认 0")
        XCTAssertEqual(config.excludedRoots, [],           "旧 json 无 excludedRoots 时应默认 []")
    }

    /// round-trip：dndEnabled/dndStartMin/dndEndMin/excludedRoots encode→decode 值完整保留。
    func test_roundTrip_withDndAndExcluded() throws {
        let store = ConfigStore(url: configURL)
        var custom = AppConfig.defaults
        custom.dndEnabled   = true
        custom.dndStartMin  = 1380   // 23:00
        custom.dndEndMin    = 420    // 07:00
        custom.excludedRoots = ["/a/b"]
        try store.save(custom)
        let loaded = store.load()
        XCTAssertEqual(loaded.dndEnabled,    true,    "dndEnabled 应 round-trip")
        XCTAssertEqual(loaded.dndStartMin,   1380,    "dndStartMin 应 round-trip")
        XCTAssertEqual(loaded.dndEndMin,     420,     "dndEndMin 应 round-trip")
        XCTAssertEqual(loaded.excludedRoots, ["/a/b"], "excludedRoots 应 round-trip")
    }

    // M3-D 面板 UX 四字段:默认 + 向后兼容 + 往返
    func test_defaults_panelUXFields() {
        let d = AppConfig.defaults
        XCTAssertEqual(d.selectedTab, "all")
        XCTAssertEqual(d.sessionGroups, [])
        XCTAssertEqual(d.panelWidth, 360)
        XCTAssertEqual(d.panelHeight, 480)
    }
    func test_decode_oldJson_withoutPanelUXFields_usesDefaults() throws {
        let oldJson = """
        {"dataRoots": [{"agent":"claude-code","path":"/tmp/root"}],
         "displayMode":"pet","endedAfterSec":7200,"notifyMode":"attentionOnly",
         "selectedPet":"shiba","staleAfterSec":300,"waitingEndedAfterSec":3600}
        """
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(oldJson.utf8))
        XCTAssertEqual(c.selectedTab, "all")
        XCTAssertEqual(c.sessionGroups, [])
        XCTAssertEqual(c.panelWidth, 360)
        XCTAssertEqual(c.panelHeight, 480)
    }
    func test_roundTrip_panelUXFields() throws {
        var custom = AppConfig.defaults
        custom.selectedTab = "group:工作:含冒号"
        custom.sessionGroups = ["工作", "重要", ""]
        custom.panelWidth = 512.5
        custom.panelHeight = 640
        let data = try JSONEncoder().encode(custom)
        let loaded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(loaded.selectedTab, "group:工作:含冒号")
        XCTAssertEqual(loaded.sessionGroups, ["工作", "重要", ""])
        XCTAssertEqual(loaded.panelWidth, 512.5)
        XCTAssertEqual(loaded.panelHeight, 640)
    }
}
