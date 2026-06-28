import XCTest
@testable import AgentPetCore

final class PetStateTests: XCTestCase {
    private func push(_ s: SessionStore, _ id: String, _ kind: EventKind, sid: String, seq: Int) {
        _ = s.apply(AgentEvent(v: 1, eventId: id, agent: "a", kind: kind, sessionId: sid, root: "r", ts: "t"),
                    seq: seq, now: 0, replay: false)
    }

    func test_any_running_means_busy() {
        let s = SessionStore()
        push(s, "E1", .stop, sid: "A", seq: 1)        // A waiting
        push(s, "E2", .sessionStart, sid: "B", seq: 2) // B running
        XCTAssertEqual(s.aggregateState(), .busy)
    }

    func test_no_running_but_waiting_means_calling() {
        let s = SessionStore()
        push(s, "E1", .stop, sid: "A", seq: 1)
        XCTAssertEqual(s.aggregateState(), .calling)
    }

    func test_all_ended_means_idle() {
        let s = SessionStore()
        push(s, "E1", .sessionEnd, sid: "A", seq: 1)
        XCTAssertEqual(s.aggregateState(), .idle)
    }

    func test_empty_means_idle() {
        XCTAssertEqual(SessionStore().aggregateState(), .idle)
    }

    func test_activeSessions_excludes_ended() {
        let s = SessionStore()
        push(s, "E1", .sessionStart, sid: "A", seq: 1)
        push(s, "E2", .sessionEnd, sid: "B", seq: 2)
        let active = s.activeSessions()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.key.sessionId, "A")
    }

    /// B1: 忙碌时仍能读到等待计数（rich summary）
    func test_summary_reports_waiting_even_when_busy() {
        let s = SessionStore()
        push(s, "E1", .sessionStart,   sid: "A", seq: 1)   // running
        push(s, "E2", .stop,           sid: "B", seq: 2)   // waiting(.stop)
        push(s, "E3", .attention,      sid: "C", seq: 3)   // waiting(.attention)
        let sum = s.summary()
        XCTAssertEqual(sum.state, .busy)
        XCTAssertTrue(sum.hasWaiting)
        XCTAssertEqual(sum.waitingCount, 2)
        XCTAssertEqual(sum.attentionCount, 1)
        XCTAssertEqual(sum.runningCount, 1)
    }

    /// B1: stale 计数正确，且 state 为 idle（无 running/waiting）
    func test_summary_counts_stale() {
        let s = SessionStore()
        push(s, "E1", .sessionStart, sid: "A", seq: 1)
        _ = s.markStale(now: 9999, timeout: 600)
        let sum = s.summary()
        XCTAssertEqual(sum.staleCount, 1)
        XCTAssertEqual(sum.state, .idle)
    }

    // MARK: - H2 补强

    /// 全部变 stale → aggregateState == .idle（stale 不算 running）
    func test_all_stale_means_idle() {
        let s = SessionStore()
        push(s, "E1", .sessionStart, sid: "A", seq: 1)
        _ = s.markStale(now: 9999, timeout: 600)
        XCTAssertEqual(s.aggregateState(), .idle)
    }

    /// stale + waiting → .calling（stale 不贡献 running）
    func test_stale_plus_waiting_is_calling() {
        let s = SessionStore()
        push(s, "E1", .sessionStart, sid: "A", seq: 1)
        _ = s.markStale(now: 9999, timeout: 600)
        push(s, "E2", .stop, sid: "B", seq: 2)
        XCTAssertEqual(s.aggregateState(), .calling)
    }

    // MARK: - H3-7: PetSummary.badgeCount

    /// 1 running + 1 waiting(.stop) + 1 waiting(.attention)，ack=0 → badgeCount == waitingCount - ack == 2
    /// MINOR-2: 新公式 max(0, waitingCount - acknowledgedCount)；已读后角标随之下降
    func test_badgeCount_equals_unread_waiting() {
        let s = SessionStore()
        push(s, "E1", .sessionStart, sid: "A", seq: 1)   // running
        push(s, "E2", .stop,         sid: "B", seq: 2)   // waiting(.stop)
        push(s, "E3", .attention,    sid: "C", seq: 3)   // waiting(.attention)
        let sum = s.summary()
        XCTAssertEqual(sum.attentionCount, 1)
        XCTAssertEqual(sum.waitingCount, 2)
        XCTAssertEqual(sum.acknowledgedCount, 0)
        XCTAssertEqual(sum.badgeCount, 2, "未读 waiting 数 = waitingCount - acknowledgedCount")
    }

    /// 1 running + 2 waiting(.stop) → badgeCount == waitingCount == 2（无 attention）
    func test_badgeCount_falls_back_to_waitingCount_when_no_attention() {
        let s = SessionStore()
        push(s, "E1", .sessionStart, sid: "A", seq: 1)
        push(s, "E2", .stop,         sid: "B", seq: 2)
        push(s, "E3", .stop,         sid: "C", seq: 3)
        let sum = s.summary()
        XCTAssertEqual(sum.attentionCount, 0)
        XCTAssertEqual(sum.badgeCount, 2)
    }

    // MARK: - H3 新增：summary 空/全 ended + 仅 attention

    /// 空 store → summary 全 0、state==.idle、badgeCount==0
    func test_summary_empty_all_zeros() {
        let s = SessionStore()
        let sum = s.summary()
        XCTAssertEqual(sum.state, .idle)
        XCTAssertEqual(sum.runningCount, 0)
        XCTAssertEqual(sum.waitingCount, 0)
        XCTAssertEqual(sum.attentionCount, 0)
        XCTAssertEqual(sum.staleCount, 0)
        XCTAssertEqual(sum.badgeCount, 0)
    }

    /// 全 ended（建会话→sessionEnd）→ summary 全 0、state==.idle、badgeCount==0
    func test_summary_all_ended_all_zeros() {
        let s = SessionStore()
        push(s, "E1", .sessionStart, sid: "A", seq: 1)
        push(s, "E2", .sessionEnd, sid: "A", seq: 2)
        let sum = s.summary()
        XCTAssertEqual(sum.state, .idle)
        XCTAssertEqual(sum.runningCount, 0)
        XCTAssertEqual(sum.waitingCount, 0)
        XCTAssertEqual(sum.badgeCount, 0)
    }

    /// 1 个 waiting(.attention) → attentionCount==1, waitingCount==1, badgeCount==1
    func test_summary_only_attention() {
        let s = SessionStore()
        push(s, "E1", .attention, sid: "A", seq: 1)
        let sum = s.summary()
        XCTAssertEqual(sum.attentionCount, 1)
        XCTAssertEqual(sum.waitingCount, 1)
        XCTAssertEqual(sum.badgeCount, 1)
    }

    /// stale 会话出现在 activeSessions（未被 ended 过滤）
    func test_stale_remains_in_activeSessions() {
        let s = SessionStore()
        push(s, "E1", .sessionStart, sid: "A", seq: 1)
        _ = s.markStale(now: 9999, timeout: 600)
        let active = s.activeSessions()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.state, .stale)
    }
}
