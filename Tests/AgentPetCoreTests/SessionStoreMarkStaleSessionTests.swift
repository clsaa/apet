import XCTest
@testable import AgentPetCore

final class SessionStoreMarkStaleSessionTests: XCTestCase {

    // MARK: - 辅助工厂

    private func makeEvent(eventId: String, agent: String = "claude", root: String = "/r",
                           sessionId: String = "s", kind: EventKind,
                           source: SessionSource = .hook) -> AgentEvent {
        var ev = AgentEvent(v: 1, eventId: eventId, agent: agent, kind: kind,
                            sessionId: sessionId, root: root, ts: "t")
        ev.source = source
        return ev
    }

    // MARK: - TC-MSS-FUNC-001: running → stale

    func test_marks_running_stale() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .busy), seq: 1, now: 100, replay: false)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")

        let changes = store.markStaleSession(key, now: 200)

        XCTAssertFalse(changes.isEmpty, "changes 非空")
        XCTAssertEqual(changes, [.upserted(key)])
        XCTAssertEqual(store.sessions[key]?.state, .stale)
        XCTAssertEqual(store.sessions[key]?.lastActiveAt, 200, "lastActiveAt 应刷新为 now")
    }

    // MARK: - TC-MSS-FUNC-002: waiting → stale（.stop 事件造 waiting，测试-MINOR9）

    func test_marks_waiting_stale() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .sessionStart), seq: 1, now: 100, replay: false)
        _ = store.apply(makeEvent(eventId: "e2", kind: .stop), seq: 2, now: 200, replay: false)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")
        XCTAssertEqual(store.sessions[key]?.state, .waiting(.stop), "前置：应为 waiting(.stop)")

        let changes = store.markStaleSession(key, now: 300)

        XCTAssertFalse(changes.isEmpty, "waiting 会话应返回非空 changes")
        XCTAssertEqual(store.sessions[key]?.state, .stale)
    }

    // MARK: - TC-MSS-ERR-001: ended 终态保护，不可复活

    func test_ended_not_revived() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .sessionStart), seq: 1, now: 100, replay: false)
        _ = store.apply(makeEvent(eventId: "e2", kind: .sessionEnd), seq: 2, now: 200, replay: false)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")
        XCTAssertEqual(store.sessions[key]?.state, .ended, "前置：应为 ended")

        let changes = store.markStaleSession(key, now: 300)

        XCTAssertEqual(changes, [], "ended 终态不可被复活，返回 []")
        XCTAssertEqual(store.sessions[key]?.state, .ended, "状态仍为 ended")
    }

    // MARK: - TC-MSS-ERR-002: 已是 stale → noop

    func test_already_stale_is_noop() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .busy), seq: 1, now: 100, replay: false)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")
        _ = store.markStale(now: 9999, timeout: 600)
        XCTAssertEqual(store.sessions[key]?.state, .stale, "前置：已为 stale")

        let changes = store.markStaleSession(key, now: 10000)

        XCTAssertEqual(changes, [], "已是 stale 不重复广播，返回 []")
        XCTAssertEqual(store.sessions[key]?.state, .stale)
    }

    // MARK: - TC-MSS-PARAM-001: 不存在的 key → []

    func test_missing_noop() {
        let store = SessionStore()
        let key = SessionKey(agent: "ghost", root: "/r", sessionId: "x")

        let changes = store.markStaleSession(key, now: 100)

        XCTAssertEqual(changes, [], "不存在的 key 返回 []")
    }

    // MARK: - TC-MSS-FUNC-003: 定时 markStale 跳过 jsonl 来源

    func test_timed_markStale_skips_jsonl_source() {
        let store = SessionStore()
        var ev = AgentEvent(v: 1, eventId: "e", agent: "claude", kind: .busy,
                            sessionId: "s", root: "/r", ts: "t")
        ev.source = .jsonl
        _ = store.apply(ev, seq: 1, now: 100, replay: false)

        _ = store.markStale(now: 100 + 9999, timeout: 600)   // 大幅超时

        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")
        XCTAssertEqual(store.sessions[key]?.state, .running,
                       "jsonl 来源会话不应被定时 markStale 打灰")
    }

    // MARK: - TC-MSS-FUNC-004: 对照——hook 来源仍正常被打灰，证明只跳过 jsonl

    func test_timed_markStale_still_marks_hook_source() {
        let store = SessionStore()

        // jsonl 会话
        var evJson = AgentEvent(v: 1, eventId: "ej", agent: "claude", kind: .busy,
                                sessionId: "sj", root: "/r", ts: "t")
        evJson.source = .jsonl
        _ = store.apply(evJson, seq: 1, now: 100, replay: false)

        // hook 会话
        var evHook = AgentEvent(v: 1, eventId: "eh", agent: "claude", kind: .busy,
                                sessionId: "sh", root: "/r", ts: "t")
        evHook.source = .hook
        _ = store.apply(evHook, seq: 2, now: 100, replay: false)

        _ = store.markStale(now: 100 + 9999, timeout: 600)

        let keyJson = SessionKey(agent: "claude", root: "/r", sessionId: "sj")
        let keyHook = SessionKey(agent: "claude", root: "/r", sessionId: "sh")
        XCTAssertEqual(store.sessions[keyJson]?.state, .running, "jsonl 不被打灰")
        XCTAssertEqual(store.sessions[keyHook]?.state, .stale, "hook 正常被打灰")
    }

    // MARK: - Fix 4: markStaleSessionIfJSONL 来源守卫

    /// TC-MSS-FUNC-005：hook 来源会话调用 markStaleSessionIfJSONL → 返回 []，状态保持 running
    func test_markStaleSessionIfJSONL_skips_hook_source() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .busy, source: .hook),
                        seq: 1, now: 100, replay: false)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")
        XCTAssertEqual(store.sessions[key]?.state, .running, "前置：hook 会话为 running")

        let changes = store.markStaleSessionIfJSONL(key, now: 200)

        XCTAssertEqual(changes, [], "hook 来源应返回 []，不打灰")
        XCTAssertEqual(store.sessions[key]?.state, .running, "hook 会话状态保持 running")
    }

    /// TC-MSS-FUNC-006：jsonl 来源会话调用 markStaleSessionIfJSONL → 置为 stale
    func test_markStaleSessionIfJSONL_marks_jsonl_source() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .busy, source: .jsonl),
                        seq: 1, now: 100, replay: false)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")
        XCTAssertEqual(store.sessions[key]?.state, .running, "前置：jsonl 会话为 running")

        let changes = store.markStaleSessionIfJSONL(key, now: 200)

        XCTAssertEqual(changes, [.upserted(key)], "jsonl 来源应返回 .upserted")
        XCTAssertEqual(store.sessions[key]?.state, .stale, "jsonl 会话被打灰为 stale")
        XCTAssertEqual(store.sessions[key]?.lastActiveAt, 200, "lastActiveAt 刷新为 now")
    }

    /// TC-MSS-PARAM-002：不存在的 key → []（无来源可判）
    func test_markStaleSessionIfJSONL_missing_key_noop() {
        let store = SessionStore()
        let key = SessionKey(agent: "ghost", root: "/r", sessionId: "x")

        XCTAssertEqual(store.markStaleSessionIfJSONL(key, now: 100), [],
                       "不存在的 key 返回 []")
    }

    // MARK: - MAJOR-1: markStaleSession 清除 acknowledged（防止幽灵已读态）

    /// TC-MSS-FUNC-007：waiting+acknowledged 会话 markStaleSession → stale 且 acknowledged==false
    func test_markStaleSession_clears_acknowledged() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .stop), seq: 1, now: 100, replay: false)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")
        _ = store.acknowledge(key: key)
        XCTAssertEqual(store.sessions[key]?.state, .waiting(.stop), "前置：waiting")
        XCTAssertEqual(store.sessions[key]?.acknowledged, true, "前置：已读")

        let changes = store.markStaleSession(key, now: 200)

        XCTAssertEqual(changes, [.upserted(key)], "应广播 upserted")
        XCTAssertEqual(store.sessions[key]?.state, .stale, "状态应为 stale")
        XCTAssertEqual(store.sessions[key]?.acknowledged, false,
                       "MAJOR-1: 打灰后 acknowledged 必须清除，防止幽灵已读态")
    }

    /// TC-MSS-FUNC-008：markStaleSession 后收到 .stop 事件 → waiting 且 acknowledged==false（新未读）
    func test_markStaleSession_thenStop_isNewUnread() {
        let store = SessionStore()
        _ = store.apply(makeEvent(eventId: "e1", kind: .stop), seq: 1, now: 100, replay: false)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s")
        _ = store.acknowledge(key: key)
        _ = store.markStaleSession(key, now: 200)
        XCTAssertEqual(store.sessions[key]?.state, .stale, "前置：stale")
        XCTAssertEqual(store.sessions[key]?.acknowledged, false, "前置：acknowledged 已清")

        // 新的 .stop 事件让会话从 stale 复活为 waiting（新一轮未读）
        _ = store.apply(makeEvent(eventId: "e2", kind: .stop), seq: 2, now: 300, replay: false)

        XCTAssertEqual(store.sessions[key]?.state, .waiting(.stop), "应恢复为 waiting(.stop)")
        XCTAssertEqual(store.sessions[key]?.acknowledged, false, "新一轮 waiting 应为未读")
    }
}
