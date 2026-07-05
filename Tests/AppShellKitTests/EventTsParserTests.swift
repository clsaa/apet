import XCTest
@testable import AppShellKit

/// 重放老化修复:事件 ts → epoch,失败/未来时间回退 fallback。
final class EventTsParserTests: XCTestCase {
    func test_parsesFractionalAndPlain() {
        XCTAssertEqual(EventTsParser.epoch("2026-07-04T10:00:00.000Z", fallback: 9e9),
                       1_783_159_200, accuracy: 1)
        XCTAssertEqual(EventTsParser.epoch("2026-07-04T10:00:00Z", fallback: 9e9),
                       1_783_159_200, accuracy: 1)
    }
    func test_garbage_fallsBack() {
        XCTAssertEqual(EventTsParser.epoch("not-a-date", fallback: 123), 123)
        XCTAssertEqual(EventTsParser.epoch("", fallback: 456), 456)
    }
    func test_futureTs_clampedToFallback() {
        // 不可信输入:ts 在未来(时钟漂移/伪造)→ 回退,防会话"永远新鲜"。
        XCTAssertEqual(EventTsParser.epoch("2099-01-01T00:00:00Z", fallback: 1_783_159_200),
                       1_783_159_200)
    }
}
