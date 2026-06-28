import XCTest
@testable import AgentPetCore

final class DragAccumulatorTests: XCTestCase {
    // TC-B2-FUNC-07 拖出去又拖回原点：净位移 0 但 maxAbs 保持 → 判 drag（本批真正修复点）
    func test_accumulate_dragOutAndBack_classifiedAsDrag() {
        var acc = DragAccumulator()
        acc.accumulate(dx: 20, dy: 0)   // 拖出
        acc.accumulate(dx: 0, dy: 0)    // 回到原点（净位移 0）
        XCTAssertEqual(acc.maxAbsDx, 20)
        XCTAssertEqual(acc.gesture(threshold: 8), .drag)
    }
    // TC-B2-FUNC-08 全程小抖动 → click
    func test_accumulate_jitterOnly_classifiedAsClick() {
        var acc = DragAccumulator()
        for d in [3.0, -2.0, 1.0, -3.0, 2.0] { acc.accumulate(dx: d, dy: -d) }
        XCTAssertEqual(acc.maxAbsDx, 3)
        XCTAssertEqual(acc.gesture(threshold: 8), .click)
    }
    // TC-B2-FUNC-09 reset 后重新计数
    func test_reset_clearsMax() {
        var acc = DragAccumulator()
        acc.accumulate(dx: 50, dy: 50)
        acc.reset()
        XCTAssertEqual(acc.maxAbsDx, 0)
        XCTAssertEqual(acc.gesture(threshold: 8), .click)
    }
    // TC-B2-PARAM-10 负位移取绝对值
    func test_accumulate_negativeDisplacement_usesAbs() {
        var acc = DragAccumulator()
        acc.accumulate(dx: -12, dy: -1)
        XCTAssertEqual(acc.maxAbsDx, 12)
        XCTAssertEqual(acc.gesture(threshold: 8), .drag)
    }
}
