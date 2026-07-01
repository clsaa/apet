import XCTest
@testable import AppShellKit
import AgentPetCore

/// `SessionMetaStore` 持久化测试：round-trip + 损坏 json 回退空。
final class SessionMetaStoreTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apet-meta-\(UUID().uuidString).json")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func test_load_missingFile_returnsEmpty() {
        XCTAssertEqual(SessionMetaStore(url: url).load(), [:])
    }

    func test_roundTrip() throws {
        let store = SessionMetaStore(url: url)
        let metas = [
            "claude-code::/r::a": SessionMeta(favorite: true, customName: "甲"),
            "claude-code::/r::b": SessionMeta(firstSeenAt: 123),
        ]
        try store.save(metas)
        XCTAssertEqual(store.load(), metas)
    }

    func test_load_corruptJson_returnsEmpty() throws {
        try "{ not valid json ".data(using: .utf8)!.write(to: url)
        XCTAssertEqual(SessionMetaStore(url: url).load(), [:])
    }
}
