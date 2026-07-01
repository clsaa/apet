import XCTest
@testable import AppShellKit
import AgentPetCore

/// 纯函数 `MenuBarCountsPresenter` 的单元测试：PetSummary → 彩色计数段/文本。
/// 颜色映射：🟢=running，🔴=未读 waiting（waiting-acknowledged），🟡=已读（acknowledged），⚪=stale。
final class MenuBarCountsPresenterTests: XCTestCase {

    private func summary(running: Int = 0, waiting: Int = 0, attention: Int = 0,
                         stale: Int = 0, acknowledged: Int = 0) -> PetSummary {
        // state 按 SessionStore.summary() 同一规则派生：running>0→busy，否则 waiting>0→calling，否则 idle。
        let state: PetState = running > 0 ? .busy : (waiting > 0 ? .calling : .idle)
        return PetSummary(state: state, runningCount: running, waitingCount: waiting,
                          attentionCount: attention, staleCount: stale, acknowledgedCount: acknowledged)
    }

    // MARK: - segments

    func test_segments_allFourStates() {
        // running2, waiting4(其中已读3→未读1), stale1
        let segs = MenuBarCountsPresenter.segments(from: summary(running: 2, waiting: 4, stale: 1, acknowledged: 3))
        XCTAssertEqual(segs, [
            .init(color: .green, count: 2),
            .init(color: .red, count: 1),
            .init(color: .yellow, count: 3),
            .init(color: .gray, count: 1),
        ])
    }

    func test_segments_omitsZeroBuckets() {
        // 只有未读 waiting=2（无 attention）→ 红
        let segs = MenuBarCountsPresenter.segments(from: summary(waiting: 2))
        XCTAssertEqual(segs, [.init(color: .red, count: 2)])
    }

    func test_segments_attention_makesDoneOrange() {
        // 与宠物条一致：attentionCount>0 时「停下等你」桶为橙，不是红
        let segs = MenuBarCountsPresenter.segments(from: summary(waiting: 2, attention: 2, stale: 2))
        XCTAssertEqual(segs, [
            .init(color: .orange, count: 2),
            .init(color: .gray, count: 2),
        ])
    }

    func test_text_attention_orange() {
        // 复现用户截图：waiting2(attention2) + stale2 → 🟠2 ⚪2（与宠物条同色）
        let t = MenuBarCountsPresenter.text(from: summary(waiting: 2, attention: 2, stale: 2))
        XCTAssertEqual(t, "🟠2 ⚪2")
    }

    func test_segments_empty_whenAllZero() {
        XCTAssertEqual(MenuBarCountsPresenter.segments(from: summary()), [])
    }

    func test_segments_allWaitingRead_noRed() {
        // waiting3 全部已读 → 只有黄，无红
        let segs = MenuBarCountsPresenter.segments(from: summary(waiting: 3, acknowledged: 3))
        XCTAssertEqual(segs, [.init(color: .yellow, count: 3)])
    }

    // MARK: - text

    func test_text_fourStates() {
        let t = MenuBarCountsPresenter.text(from: summary(running: 2, waiting: 4, stale: 1, acknowledged: 3))
        XCTAssertEqual(t, "🟢2 🔴1 🟡3 ⚪1")
    }

    func test_text_pawprint_whenAllZero() {
        XCTAssertEqual(MenuBarCountsPresenter.text(from: summary()), "🐾")
    }

    func test_text_singleBucket() {
        XCTAssertEqual(MenuBarCountsPresenter.text(from: summary(running: 5)), "🟢5")
    }
}
