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
}
