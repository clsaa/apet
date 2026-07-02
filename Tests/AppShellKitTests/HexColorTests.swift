import XCTest
@testable import AppShellKit

/// 纯函数 `HexColor.parse`：十六进制颜色串 → RGBA(0...1)。非法输入 → nil。
final class HexColorTests: XCTestCase {

    private func assertRGBA(_ got: HexColor.RGBA?, _ r: Double, _ g: Double, _ b: Double, _ a: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let got else { return XCTFail("expected RGBA, got nil", file: file, line: line) }
        XCTAssertEqual(got.r, r, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(got.g, g, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(got.b, b, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(got.a, a, accuracy: 0.001, file: file, line: line)
    }

    func test_rrggbb() {
        assertRGBA(HexColor.parse("#FF0000"), 1, 0, 0, 1)
        assertRGBA(HexColor.parse("#00FF00"), 0, 1, 0, 1)
    }

    func test_withoutHash() {
        assertRGBA(HexColor.parse("0000FF"), 0, 0, 1, 1)
    }

    func test_shortRGB() {
        assertRGBA(HexColor.parse("#F00"), 1, 0, 0, 1)
    }

    func test_rrggbbaa() {
        assertRGBA(HexColor.parse("#FF000080"), 1, 0, 0, 0.502)
    }

    func test_caseInsensitive_andTrimmed() {
        assertRGBA(HexColor.parse("  #ff0000  "), 1, 0, 0, 1)
    }

    func test_invalid_returnsNil() {
        XCTAssertNil(HexColor.parse(""))
        XCTAssertNil(HexColor.parse("#GG0000"))
        XCTAssertNil(HexColor.parse("#12345"))
        XCTAssertNil(HexColor.parse("nope"))
    }

    // 评审修复（测试 m9）：全角 hex"数字"必须拒绝，不得静默解析成黑色。
    func test_fullWidthHex_returnsNil() {
        XCTAssertNil(HexColor.parse("ＦＦ００００"))
        XCTAssertNil(HexColor.parse("#ＦＦ0000"))
    }
}
