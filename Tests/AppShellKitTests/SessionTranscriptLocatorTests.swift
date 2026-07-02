import XCTest
@testable import AppShellKit

/// `SessionTranscriptLocator.find`：按 root+sessionId 定位 jsonl 文件（临时目录真实文件）。
final class SessionTranscriptLocatorTests: XCTestCase {

    private var root: String!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apet-loc-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(
            atPath: root + "/projects/-Users-x-proj", withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
        super.tearDown()
    }

    func test_findsSessionFile() throws {
        let path = root + "/projects/-Users-x-proj/abc-123.jsonl"
        try "x".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionTranscriptLocator.find(root: root, sessionId: "abc-123"), path)
    }

    func test_missing_returnsNil() {
        XCTAssertNil(SessionTranscriptLocator.find(root: root, sessionId: "nope"))
    }

    func test_ignoresSubagentFiles() throws {
        // subagents 目录下同名不该命中
        let subDir = root + "/projects/-Users-x-proj/abc-123/subagents"
        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)
        try "x".write(toFile: subDir + "/agent-abc-123.jsonl", atomically: true, encoding: .utf8)
        XCTAssertNil(SessionTranscriptLocator.find(root: root, sessionId: "abc-123"))
    }
}
