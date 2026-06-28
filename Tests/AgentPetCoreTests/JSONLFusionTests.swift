import XCTest
@testable import AgentPetCore

final class JSONLFusionTests: XCTestCase {

    // MARK: - Helper

    /// 构造 AgentEvent（agent="claude", root="/r"），用于融合场景测试。
    private func ev(_ id: String, _ kind: EventKind, _ sid: String) -> AgentEvent {
        AgentEvent(v: 1, eventId: id, agent: "claude", kind: kind,
                   sessionId: sid, root: "/r", ts: "")
    }

    // MARK: - Tests

    /// 融合场景1：hook 将会话置为 .ended 后，jsonl 的 busy 不能令其复活。
    ///
    /// 验证终态 .ended 恒胜；source=.jsonl 无法绕过终态保护（架构-B1/M2）。
    /// 注意：必须先 sessionStart 建会话，sessionEnd 作首事件不建会话（面板 B3）。
    func test_hook_ended_not_revived_by_jsonl_running() {
        // Arrange: 单一 NDJSONIngestor 实例（唯一 seq 源）
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s1")

        // Act 1: sessionStart → 建立会话，state=.running
        _ = ing.ingest(event: ev("start", .sessionStart, "s1"), now: 90, replay: false)
        // Act 2: sessionEnd → 会话推入终态 .ended
        _ = ing.ingest(event: ev("end", .sessionEnd, "s1"), now: 100, replay: false)
        // Act 3: jsonl 合成 busy（模拟 watcher 检测到文件仍活跃），尝试复活
        var j = ev("jsonl:s1:x", .busy, "s1")
        j.source = .jsonl
        _ = ing.ingest(event: j, now: 110, replay: false)

        // Assert: 终态不可回退，会话仍为 .ended
        XCTAssertEqual(store.sessions[key]?.state, .ended,
                       "ended 是终态，jsonl source=.jsonl 的 busy 不应令其复活")
    }

    /// 融合场景2：jsonl 回流 running→stop→running（三个 eventId 各不同）应能翻回 .running。
    ///
    /// 验证 eventId 唯一时 seenEventIds 不阻塞状态翻转，
    /// stop→busy 能正确从 .waiting(.stop) 回到 .running（架构-m2/M4）。
    func test_reflow_running_stop_running_flips_back() {
        // Arrange: 单一 NDJSONIngestor 实例（唯一 seq 源）
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        let key = SessionKey(agent: "claude", root: "/r", sessionId: "s1")

        // Act: busy(j1) → stop(j2) → busy(j3)，eventId 各不同保证无去重拦截
        // 场景为 jsonl 回流，事件标 source=.jsonl 与命名一致
        func jsonlEv(_ id: String, _ kind: EventKind) -> AgentEvent {
            var e = ev(id, kind, "s1"); e.source = .jsonl; return e
        }
        _ = ing.ingest(event: jsonlEv("j1", .busy), now: 100, replay: false)
        _ = ing.ingest(event: jsonlEv("j2", .stop), now: 200, replay: false)
        _ = ing.ingest(event: jsonlEv("j3", .busy), now: 300, replay: false)

        // Assert: 第三次 busy 应从 .waiting(.stop) 翻回 .running
        XCTAssertEqual(store.sessions[key]?.state, .running,
                       "eventId 各唯一时，stop→busy 应能翻回 running（无状态散列去重卡死）")
    }
}
