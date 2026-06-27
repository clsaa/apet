import XCTest
@testable import AppShellKit

final class EventTailReaderTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(UUID().uuidString + ".ndjson")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let data = text.data(using: .utf8)!
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        fh.write(data)
    }

    override func tearDown() {
        // temp files are UUID-named; OS cleans /tmp eventually; nothing to tear down here
        super.tearDown()
    }

    // MARK: - Test 1: Two full lines from nil checkpoint

    func testReadTwoFullLines() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append("line one\nline two\n", to: url)

        let reader = EventTailReader()
        let result = try reader.readNewLines(path: url.path, from: nil)

        XCTAssertEqual(result.lines, ["line one", "line two"])

        // next offset should be at end-of-file
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! UInt64
        XCTAssertEqual(result.next.offset, fileSize)
    }

    // MARK: - Test 2: Incremental read from previous checkpoint

    func testIncrementalRead() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append("line one\nline two\n", to: url)

        let reader = EventTailReader()
        let first = try reader.readNewLines(path: url.path, from: nil)
        XCTAssertEqual(first.lines.count, 2)

        try append("line three\n", to: url)

        let second = try reader.readNewLines(path: url.path, from: first.next)
        XCTAssertEqual(second.lines, ["line three"])
    }

    // MARK: - Test 3: Partial line (no trailing newline) is NOT returned

    func testPartialLineNotReturned() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append("complete\npartial", to: url)

        let reader = EventTailReader()
        let result = try reader.readNewLines(path: url.path, from: nil)

        // Only "complete" should be returned; "partial" has no trailing newline
        XCTAssertEqual(result.lines, ["complete"])

        // offset stays at byte position after the last newline (after "complete\n" = 9 bytes)
        XCTAssertEqual(result.next.offset, UInt64("complete\n".utf8.count))
    }

    func testPartialLineCompletedOnNextRead() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append("complete\npartial", to: url)

        let reader = EventTailReader()
        let first = try reader.readNewLines(path: url.path, from: nil)
        XCTAssertEqual(first.lines, ["complete"])

        // Now complete the partial line
        try append(" line\n", to: url)

        let second = try reader.readNewLines(path: url.path, from: first.next)
        XCTAssertEqual(second.lines, ["partial line"])
    }

    // MARK: - Test 4: Rotation detection (new inode → read from 0)

    func testRotationDetectedByInode() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append("old line\n", to: url)

        let reader = EventTailReader()
        let first = try reader.readNewLines(path: url.path, from: nil)
        XCTAssertEqual(first.lines, ["old line"])

        // Replace file entirely (new inode)
        try FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try append("new line after rotation\n", to: url)

        let second = try reader.readNewLines(path: url.path, from: first.next)
        XCTAssertEqual(second.lines, ["new line after rotation"])
    }

    // MARK: - Test 5: Truncation detected (offset > file size → read from 0)

    func testTruncationDetected() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append("first content\n", to: url)

        let reader = EventTailReader()
        let first = try reader.readNewLines(path: url.path, from: nil)
        XCTAssertEqual(first.lines, ["first content"])

        // Truncate file and write shorter content
        try "short\n".write(to: url, atomically: true, encoding: .utf8)

        // The previous checkpoint has a larger offset than new file size → re-read from 0
        let second = try reader.readNewLines(path: url.path, from: first.next)
        XCTAssertEqual(second.lines, ["short"])
    }

    // MARK: - Test 6: CRLF line endings stripped

    func testCRLFLineEndingsStripped() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append("windows line\r\nanother line\r\n", to: url)

        let reader = EventTailReader()
        let result = try reader.readNewLines(path: url.path, from: nil)

        XCTAssertEqual(result.lines, ["windows line", "another line"])
    }

    // MARK: - Test 7: Missing file returns empty without throwing

    func testMissingFileReturnsEmpty() throws {
        let reader = EventTailReader()
        let result = try reader.readNewLines(path: "/tmp/nonexistent-\(UUID().uuidString).ndjson", from: nil)
        XCTAssertEqual(result.lines, [])
        XCTAssertEqual(result.next.offset, 0)
    }

    // MARK: - Test 8: Empty file returns empty lines and zero offset

    func testEmptyFileReturnsEmpty() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = EventTailReader()
        let result = try reader.readNewLines(path: url.path, from: nil)

        XCTAssertEqual(result.lines, [])
        XCTAssertEqual(result.next.offset, 0)
    }

    // MARK: - Test 9: Checkpoint fileId is consistent across reads (same file, no rotation)

    func testFileIdConsistentWithoutRotation() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try append("line1\n", to: url)

        let reader = EventTailReader()
        let first = try reader.readNewLines(path: url.path, from: nil)

        try append("line2\n", to: url)

        let second = try reader.readNewLines(path: url.path, from: first.next)

        XCTAssertEqual(first.next.fileId, second.next.fileId,
                       "fileId must remain stable across reads of the same file incarnation")
    }
}
