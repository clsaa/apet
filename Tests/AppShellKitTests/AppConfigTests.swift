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
}
