import XCTest
@testable import AgentPetCore

final class ClickDragClassifierTests: XCTestCase {
    // TC-B2-FUNC-01 静止 → click
    func test_classify_returnsClick_whenNoMovement() {
        XCTAssertEqual(ClickDragClassifier.classify(maxAbsDx: 0, maxAbsDy: 0, threshold: 8), .click)
    }
    // TC-B2-FUNC-02 阈值内微抖 → click（触控板抖动不应误判拖动）
    func test_classify_returnsClick_whenJitterBelowThreshold() {
        XCTAssertEqual(ClickDragClassifier.classify(maxAbsDx: 7, maxAbsDy: 3, threshold: 8), .click)
    }
    // TC-B2-FUNC-03 达到阈值 → drag
    func test_classify_returnsDrag_whenReachesThresholdX() {
        XCTAssertEqual(ClickDragClassifier.classify(maxAbsDx: 8, maxAbsDy: 0, threshold: 8), .drag)
    }
    // TC-B2-PARAM-04 任一轴超阈值即 drag
    func test_classify_returnsDrag_whenYExceedsThreshold() {
        XCTAssertEqual(ClickDragClassifier.classify(maxAbsDx: 1, maxAbsDy: 20, threshold: 8), .drag)
    }
    // TC-B2-PARAM-05 阈值减极小量 → click（>= 的下边界精确锁定）
    func test_classify_returnsClick_justBelowThreshold() {
        XCTAssertEqual(ClickDragClassifier.classify(maxAbsDx: 7.999, maxAbsDy: 7.999, threshold: 8), .click)
    }
    // TC-B2-PARAM-06 threshold=0 退化：任何位移(含 0)都判 drag（0>=0）
    func test_classify_returnsDrag_whenThresholdZero() {
        XCTAssertEqual(ClickDragClassifier.classify(maxAbsDx: 0, maxAbsDy: 0, threshold: 0), .drag)
    }
}
