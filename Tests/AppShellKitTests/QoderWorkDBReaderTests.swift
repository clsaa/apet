import XCTest
import SQLite3
@testable import AppShellKit
import AgentPetCore

/// `QoderWorkDBReader`：对着按实测 schema 造的临时 SQLite 读取。
final class QoderWorkDBReaderTests: XCTestCase {

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("apet-qw-\(UUID().uuidString).db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        let ddl = """
        CREATE TABLE projects (id text PRIMARY KEY, name text, path text);
        CREATE TABLE chats (id text PRIMARY KEY, name text, project_id text,
                            created_at integer, updated_at integer, deleted_at integer);
        CREATE TABLE sub_chats (id text PRIMARY KEY, chat_id text, session_id text,
                                created_at integer, updated_at integer);
        INSERT INTO projects VALUES ('p1','workspace','/Users/x/ws');
        INSERT INTO chats VALUES ('c1','修 bug','p1',1000,2000,NULL);
        INSERT INTO chats VALUES ('c2','已删','p1',1000,2000,999);
        INSERT INTO sub_chats VALUES ('s1','c1','8dd7ca5f-e655-47b7-8a5f-ad28336c1d34',1000,2500);
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func test_readsJoinedRow_skipsDeleted_takesMaxUpdatedAt() {
        let rows = QoderWorkDBReader(dbPath: dbPath).read()
        XCTAssertEqual(rows?.count, 1, "deleted_at 非空的不读")
        XCTAssertEqual(rows?[0].chatId, "c1")
        XCTAssertEqual(rows?[0].name, "修 bug")
        XCTAssertEqual(rows?[0].projectPath, "/Users/x/ws")
        XCTAssertEqual(rows?[0].sessionId, "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34")
        XCTAssertEqual(rows?[0].updatedAt, 2500, "取 chats/sub_chats 里较新的 updated_at")
    }

    // 评审修复（测试 M5）：DB 不存在是「无会话」（空数组）；打不开/半读才是失败（nil）。
    func test_missingDB_returnsEmptyNotNil() {
        XCTAssertEqual(QoderWorkDBReader(dbPath: "/nonexistent/x.db").read(), [])
    }

    // 评审修复（测试 M5）：双 sub_chat 不得产出重复会话行（GROUP BY 去重，取较新时间）。
    func test_doubleSubChat_dedupedToOneRow() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        let sql = "INSERT INTO sub_chats VALUES ('s2','c1','ffffffff-0000-0000-0000-000000000000',1000,3000);"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)

        let rows = QoderWorkDBReader(dbPath: dbPath).read()
        XCTAssertEqual(rows?.count, 1, "同一 chat 双 sub_chat 必须去重为一行")
        XCTAssertEqual(rows?[0].updatedAt, 3000, "取全组最新 updated_at")
    }

    // 评审修复（测试 M5）：无 sub_chat 的 chat 走 LEFT JOIN，sessionId 为 nil、时间取 chats 的。
    func test_chatWithoutSubChat_nilSessionId() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO chats VALUES ('c3','孤儿','p1',100,1234,NULL);", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)

        let rows = QoderWorkDBReader(dbPath: dbPath).read()?.sorted { $0.chatId < $1.chatId }
        XCTAssertEqual(rows?.count, 2)
        XCTAssertNil(rows?[1].sessionId)
        XCTAssertEqual(rows?[1].updatedAt, 1234)
    }

    // 评审修复（AI M5/架构 M3）：读失败轮 watcher 必须整轮跳过——不差分、不发幽灵 stale。
    func test_watcher_skipsRoundOnReadFailure() {
        var emitted: [ScanResult] = []
        var readResult: [QoderWorkChatRow]? = [QoderWorkChatRow(
            chatId: "c1", name: nil, projectPath: nil,
            sessionId: nil, updatedAt: 1000)]
        let watcher = QoderWorkWatcher(
            read: { readResult }, root: "/qw", now: { 1060 },
            emit: { emitted.append($0) },
            runningWindow: 120, idleWindow: 1800
        )
        watcher.scanOnce()
        XCTAssertEqual(emitted.count, 1, "第一轮正常 emit running")
        // 模拟锁竞争读失败：nil ≠ 空——绝不能把活跃会话打灰
        readResult = nil
        watcher.scanOnce()
        XCTAssertEqual(emitted.count, 1, "读失败轮不 emit 任何东西（不发幽灵 stale）")
        // 恢复后不重复 emit（差分基线未被破坏）
        readResult = [QoderWorkChatRow(chatId: "c1", name: nil, projectPath: nil, sessionId: nil, updatedAt: 1000)]
        watcher.scanOnce()
        XCTAssertEqual(emitted.count, 1, "恢复后同状态不重复 emit")
    }

    func test_watcher_diffAndGhost() {
        var emitted: [ScanResult] = []
        var nowVal = 2600.0
        var rows = QoderWorkDBReader(dbPath: dbPath).read()
        let watcher = QoderWorkWatcher(
            read: { rows }, root: "/qw", now: { nowVal },
            emit: { emitted.append($0) },
            runningWindow: 120, idleWindow: 1800
        )
        // 第一轮：updatedAt=2500, now=2600 → running，emit 1 条
        watcher.scanOnce()
        XCTAssertEqual(emitted.count, 1)
        guard case .observe(let st1, _, _, _) = emitted[0] else { return XCTFail() }
        XCTAssertEqual(st1, .running)
        // 同状态第二轮：不重复 emit（差分）
        watcher.scanOnce()
        XCTAssertEqual(emitted.count, 1)
        // 时间推进出 running 窗口 → waitingStop
        nowVal = 2500 + 600
        watcher.scanOnce()
        XCTAssertEqual(emitted.count, 2)
        guard case .observe(let st2, _, _, _) = emitted[1] else { return XCTFail() }
        XCTAssertEqual(st2, .waitingStop)
        // 行消失 → 幽灵补发 stale
        rows = []
        watcher.scanOnce()
        XCTAssertEqual(emitted.count, 3)
        guard case .observe(let st3, _, _, _) = emitted[2] else { return XCTFail() }
        XCTAssertEqual(st3, .stale)
    }

    // ── 评审 B4(OpenCode 接入计划):DBPollWatcher 泛化前的行为回归网 ──

    /// 复活语义:running → 消失(stale)→ 复活,必须重新 emit running(3 条精确序列)。
    /// 依赖 lastEmitted.removeValue 这一行为——泛化时最易丢。
    func test_watcher_reappearAfterGhost_reEmitsRunning() {
        var rows: [QoderWorkChatRow] = [
            QoderWorkChatRow(chatId: "c1", name: "任务", projectPath: "/w",
                             sessionId: "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34", updatedAt: 1000)
        ]
        var emitted: [ScanResult] = []
        let watcher = QoderWorkWatcher(
            read: { rows }, root: "/root", now: { 1010 },
            emit: { emitted.append($0) })
        watcher.scanOnce()                                   // running
        rows = []
        watcher.scanOnce()                                   // ghost → stale
        rows = [QoderWorkChatRow(chatId: "c1", name: "任务", projectPath: "/w",
                                 sessionId: "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34", updatedAt: 1005)]
        watcher.scanOnce()                                   // 复活 → 必须重新 emit
        let key = SessionKey(agent: "qoder-work", root: "/root",
                             sessionId: "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34")
        XCTAssertEqual(emitted, [
            .observe(state: .running, key: key, cwd: "/w", title: "任务"),
            .observe(state: .stale, key: key, cwd: nil, title: nil),
            .observe(state: .running, key: key, cwd: "/w", title: "任务"),
        ], "消失后复活必须重新 emit(lastEmitted 须被 stale 清除)")
    }

    /// 读失败轮(nil)夹在中间:失败轮绝不发幽灵 stale;行真正消失的 stale 恰好 1 条、发生在恢复轮。
    func test_watcher_readFailureRound_thenEmptyRows_staleExactlyOnceOnRecovery() {
        var phase = 0
        var emitted: [ScanResult] = []
        let watcher = QoderWorkWatcher(
            read: {
                switch phase {
                case 0: return [QoderWorkChatRow(chatId: "c1", name: nil, projectPath: nil,
                                                 sessionId: nil, updatedAt: 1000)]
                case 1: return nil          // 锁抖动半读
                default: return []          // 恢复,行确实没了
                }
            },
            root: "/r", now: { 1010 }, emit: { emitted.append($0) })
        watcher.scanOnce(); phase = 1
        watcher.scanOnce(); phase = 2       // nil 轮:整轮跳过,不 emit
        watcher.scanOnce()
        let staleCount = emitted.filter {
            if case .observe(state: .stale, _, _, _) = $0 { return true }; return false
        }.count
        XCTAssertEqual(emitted.count, 2, "running + stale,失败轮零 emit")
        XCTAssertEqual(staleCount, 1, "stale 恰好 1 条且在恢复轮")
    }

    /// 双 key 交错:一个转态 + 一个消失,同轮 emit 集合精确。
    func test_watcher_twoKeys_transitionAndGhost_sameRound() {
        let idA = "aaaaaaaa-0000-0000-0000-000000000001"
        let idB = "bbbbbbbb-0000-0000-0000-000000000002"
        var rows: [QoderWorkChatRow] = [
            QoderWorkChatRow(chatId: "a", name: "A", projectPath: "/a", sessionId: idA, updatedAt: 1000),
            QoderWorkChatRow(chatId: "b", name: "B", projectPath: "/b", sessionId: idB, updatedAt: 1000),
        ]
        var emitted: [ScanResult] = []
        let watcher = QoderWorkWatcher(
            read: { rows }, root: "/r", now: { 1010 },
            emit: { emitted.append($0) })
        watcher.scanOnce()
        XCTAssertEqual(emitted.count, 2, "首轮两条 running")
        emitted.removeAll()
        // A 转 waitingStop(age 进入 120..1800),B 消失。
        rows = [QoderWorkChatRow(chatId: "a", name: "A", projectPath: "/a", sessionId: idA, updatedAt: 700)]
        watcher.scanOnce()
        let keyA = SessionKey(agent: "qoder-work", root: "/r", sessionId: idA)
        let keyB = SessionKey(agent: "qoder-work", root: "/r", sessionId: idB)
        XCTAssertTrue(emitted.contains(.observe(state: .waitingStop, key: keyA, cwd: "/a", title: "A")))
        XCTAssertTrue(emitted.contains(.observe(state: .stale, key: keyB, cwd: nil, title: nil)))
        XCTAssertEqual(emitted.count, 2)
    }

    /// start 幂等 + stop 真断言(实现评审 Major:同 key 差分抑制使旧断言恒真——
    /// 每 tick 换 chatId 使 emit 单调增,stop 后冻结才是有效断言)。
    func test_watcher_startIdempotent_stopActuallySilences() {
        var tick = 0
        var emitted = 0
        let watcher = QoderWorkWatcher(
            read: {
                tick += 1
                return [QoderWorkChatRow(chatId: "c\(tick)", name: nil, projectPath: nil,
                                         sessionId: nil, updatedAt: 1000)]
            },
            root: "/r", now: { 1001 }, emit: { _ in emitted += 1 })
        watcher.start(every: 0.05)
        watcher.start(every: 0.05)   // 幂等:不得产生双 timer
        let exp = expectation(description: "ticks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 5)
        watcher.stop()
        let after = emitted
        XCTAssertGreaterThanOrEqual(after, 1)
        let exp2 = expectation(description: "silence after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp2.fulfill() }
        wait(for: [exp2], timeout: 5)
        XCTAssertEqual(emitted, after, "stop 后不得再 emit(每 tick 新 key,计数不会自然冻结)")
    }
}
