import XCTest
@testable import AppShellKit

final class ForegroundCutterTests: XCTestCase {
    func test_success_setAsPet() {
        XCTAssertEqual(CutoutDecision.decide(result: .success(()), cutoutPath: "/c.png"),
                       .setAsPet(cutoutPath: "/c.png"))
    }
    func test_noForeground_keepCurrent() {
        XCTAssertEqual(CutoutDecision.decide(result: .failure(.noForegroundDetected), cutoutPath: "/c.png"),
                       .keepCurrent(message: "未识别到宠物主体，请换张主体清晰的照片"))
    }
    func test_writeFailed_keepCurrent_diskMsg() {
        XCTAssertEqual(CutoutDecision.decide(result: .failure(.outputWriteFailed("x")), cutoutPath: "/c.png"),
                       .keepCurrent(message: "存储空间不足，抠图未完成"))
    }
    func test_platformUnsupported_keepCurrent() {
        XCTAssertEqual(CutoutDecision.decide(result: .failure(.platformUnsupported), cutoutPath: "/c.png"),
                       .keepCurrent(message: "抠图需 macOS 14 及以上，可直接用原图"))
    }
    func test_unavailableCutter_throws() async {
        do { try await UnavailableForegroundCutter().cutout(srcPath: "/a", dstPath: "/b"); XCTFail() }
        catch { XCTAssertEqual(error as? CutoutError, .platformUnsupported) }
    }
}
