import XCTest
@testable import AppShellKit
final class TailLineReaderTests: XCTestCase {
    private func tmp(_ c: String) -> String {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID()).jsonl")
        try! c.data(using: .utf8)!.write(to: u); return u.path
    }
    func test_tail_in_order() {
        XCTAssertEqual(TailLineReader.lastLines(path: tmp("a\nb\nc\nd\ne\n"), maxLines: 2, maxBytes: 1000), .ok(lines: ["d","e"]))
    }
    func test_drops_partial_first_line_when_byte_capped() {
        // 文件33字节，取尾15字节="HIJ\nKLMNOPQRST\n"，start>0丢残行"HIJ"→["KLMNOPQRST"]
        XCTAssertEqual(TailLineReader.lastLines(path: tmp("0123456789\nABCDEFGHIJ\nKLMNOPQRST\n"), maxLines: 10, maxBytes: 15), .ok(lines: ["KLMNOPQRST"]))
    }
    func test_firstLine() { XCTAssertEqual(TailLineReader.firstLine(path: tmp("HEAD\nb\n")), "HEAD") }
    func test_unreadable() { XCTAssertEqual(TailLineReader.lastLines(path: "/no/such", maxLines: 1, maxBytes: 10), .unreadable(path: "/no/such")) }
}
