import XCTest
import SQLite3
@testable import AppShellKit
import AgentPetCore

/// OpenCodeDBReader:对着按上游 schema 造的临时 WAL SQLite 读取。
/// fixture DDL 来源:https://github.com/sst/opencode(MIT,Copyright (c) 2025 opencode)
/// packages/core/src/database/schema.gen.ts @ 04d236c——与真表在 apet 触达列上同形
/// (含 NOT NULL 约束),其余列省略;真机实测门后以 `.schema` 快照校正。
final class OpenCodeDBReaderTests: XCTestCase {

    private var dbPath: String!

    private func exec(_ db: OpaquePointer?, _ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, file: file, line: line)
    }

    /// 建标准 fixture(WAL;session/part/session_message/migration 四表)。
    /// 注:关闭最后一个连接时 SQLite 自动 checkpoint 并删 -wal——journal_mode=WAL 持久化在库头;
    /// 「已提交未 checkpoint」形态由专项测试用常开写者连接构造(评审:勿声称此处保留 -wal)。
    private func makeFixture(populate: (OpaquePointer?) -> Void) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        exec(db, "PRAGMA journal_mode=WAL;")
        exec(db, """
        CREATE TABLE session (
          id text PRIMARY KEY, project_id text NOT NULL, parent_id text,
          directory text NOT NULL, title text NOT NULL, version text NOT NULL,
          time_created integer NOT NULL, time_updated integer NOT NULL,
          time_archived integer);
        CREATE TABLE part (
          id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL,
          time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
        CREATE TABLE session_message (
          id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
          seq integer NOT NULL, time_created integer NOT NULL,
          time_updated integer NOT NULL, data text NOT NULL);
        CREATE TABLE migration (id text PRIMARY KEY, time_completed integer NOT NULL);
        """)
        populate(db)
        sqlite3_close_v2(db)
    }

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("apet-oc-\(UUID().uuidString).db").path
    }
    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        super.tearDown()
    }

    // ── 正常读:活动降级链 + assistant 信号 + 毫秒→秒 + 全名 migration id ──
    func test_readsRow_activityFromPart_signalFromAssistantMessage() throws {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_a', 'p1', NULL, '/w', '修 bug', '1.17.13',
                                        1782554400000, 1782554400000, NULL);
            INSERT INTO part VALUES ('prt_1', 'msg_1', 'ses_a', 1782554460000, 1782554460000, '{}');
            INSERT INTO session_message VALUES
              ('msg_0', 'ses_a', 'user', 1, 1782554400000, 1782554400000, '{}'),
              ('msg_1', 'ses_a', 'assistant', 2, 1782554455000, 1782554455000,
               '{"time":{"created":1782554455000,"completed":1782554460123}}');
            INSERT INTO migration VALUES ('20260622202450_simplify_session_input', 1782554400000);
            """)
        }
        let outcome = OpenCodeDBReader(dbPath: dbPath).read()
        let rows = try XCTUnwrap(outcome.rows)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.sessionId, "ses_a")
        XCTAssertEqual(row.directory, "/w")
        XCTAssertEqual(row.title, "修 bug")
        // 整千毫秒可精确相等(评审:毫秒精度断言写法)。
        XCTAssertEqual(row.lastActivity, 1782554460.0)
        XCTAssertEqual(row.assistantSignal, .completed)
        XCTAssertEqual(row.createdAt, 1782554400.0)
        XCTAssertEqual(outcome.maxMigrationId, "20260622202450_simplify_session_input",
                       "⚠️ 上游 id 是全名,非裸时间戳(评审 Blocker)")
    }

    func test_assistantInFlight_completedNull() throws {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1782554400000,1782554400000,NULL);
            INSERT INTO session_message VALUES
              ('msg_1','ses_a','assistant',2,1782554455000,1782554455000,
               '{"time":{"created":1782554455000}}');
            """)
        }
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        XCTAssertEqual(row.assistantSignal, .inFlight, "completed IS NULL → 进行中(评审 M1)")
    }

    func test_noAssistantMessage_signalNone() throws {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1000000,2000000,NULL);
            INSERT INTO session_message VALUES ('msg_0','ses_a','user',1,2000000,2000000,'{}');
            """)
        }
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        XCTAssertEqual(row.assistantSignal, AssistantSignal.none)
        XCTAssertEqual(row.lastActivity, 2000, "user 消息行插入时间进活动链")
    }

    /// spec §3.1:json_extract 失败 → 完成信号缺席(窗口兜底),绝不 failed 整轮。
    /// SQLite 的 json_extract 对 malformed JSON **抛错**——不设 json_valid 护栏会毒化全库读取
    /// (实现评审 Blocker:单条坏 data → 每轮 .failed → 面板 OpenCode 全部消失且无解释)。
    func test_malformedAssistantData_doesNotPoisonWholeRead() throws {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_bad','p',NULL,'/w','t','v',1000000,2000000,NULL);
            INSERT INTO session_message VALUES ('m1','ses_bad','assistant',1,2000000,2000000,'not-json');
            INSERT INTO session VALUES ('ses_good','p',NULL,'/g','t2','v',1000000,2000000,NULL);
            """)
        }
        let rows = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows,
                                 "单条坏 data 不得毒化整轮(spec §3.1)")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.sessionId == "ses_bad" })?.assistantSignal,
                       AssistantSignal.none, "信号缺席 → 窗口兜底")
    }

    /// 上游 getCurrentAssistant 同构:取 seq 最大的 assistant——旧轮 completed 不遮蔽新轮 in-flight
    /// (实现评审 Major:fixture 全是单 assistant,写成 ASC/MAX(completed) 照样全绿)。
    func test_multiTurn_latestAssistantWins_inFlight() throws {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1000000,1000000,NULL);
            INSERT INTO session_message VALUES
              ('m1','ses_a','assistant',2,1000000,1000000,'{"time":{"completed":1000000}}'),
              ('m2','ses_a','user',3,2000000,2000000,'{}'),
              ('m3','ses_a','assistant',4,2100000,2100000,'{"time":{"created":2100000}}');
            """)
        }
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        XCTAssertEqual(row.assistantSignal, .inFlight, "seq 最大的 assistant 说了算")
    }

    func test_multiTurn_latestAssistantWins_completed() throws {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1000000,1000000,NULL);
            INSERT INTO session_message VALUES
              ('m1','ses_a','assistant',2,1000000,1000000,'{"time":{"created":1000000}}'),
              ('m3','ses_a','assistant',4,2100000,2100000,'{"time":{"completed":2200000}}');
            """)
        }
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        XCTAssertEqual(row.assistantSignal, .completed, "镜像:最新 completed,旧轮 in-flight 不遮蔽")
    }

    /// 代码注释宣称「ISO 串等未来编码也归 completed(非 NULL 即完成)」——给它测试背书。
    func test_isoStringCompleted_countsAsCompleted() throws {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1000000,2000000,NULL);
            INSERT INTO session_message VALUES ('m1','ses_a','assistant',1,2000000,2000000,
              '{"time":{"completed":"2026-07-03T10:00:00Z"}}');
            """)
        }
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        XCTAssertEqual(row.assistantSignal, .completed)
    }

    /// 方言一致性 tripwire(评审:防 /1000 两次的静默失败——那会让面板永远空)。
    func test_millisecondConversion_matchesTimestampDialect() throws {
        makeFixture { db in
            exec(db, "INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1782554400123,1782554400123,NULL);")
        }
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        let viaDialect = try XCTUnwrap(TimestampDialect.epochMillis.parse("1782554400123"))
        XCTAssertEqual(row.lastActivity, viaDialect, accuracy: 0.0005,
                       "Reader 换算与 manifest 方言(epochMillis)必须同一真相")
    }

    // ── WAL:已提交、未 checkpoint、只在 -wal 的行 → 读者可见(评审:真机常态形态)──
    func test_WAL_committedButUncheckpointedRow_visible() {
        makeFixture { _ in }                       // 只建表
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &writer), SQLITE_OK)
        defer { sqlite3_close_v2(writer) }         // 保持打开直到读取完成
        exec(writer, "PRAGMA wal_autocheckpoint=0;")
        exec(writer, "INSERT INTO session VALUES ('ses_w','p',NULL,'/w','t','v',1000000,1000000,NULL);")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath + "-wal"),
                      "行已 COMMIT 但只存在于 -wal")
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read().rows?.map(\.sessionId), ["ses_w"])
    }

    func test_WAL_concurrentWriteTransaction_readStillSucceeds() {
        makeFixture { db in
            exec(db, "INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1000000,1000000,NULL);")
        }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &writer), SQLITE_OK)
        exec(writer, "BEGIN IMMEDIATE;")
        exec(writer, "INSERT INTO session VALUES ('ses_b','p',NULL,'/w','t2','v',2000000,2000000,NULL);")
        defer { exec(writer, "ROLLBACK;"); sqlite3_close_v2(writer) }
        // WAL 下读者取快照,不被写事务阻塞(评审:opencode 正在跑时轮询不空转)。
        XCTAssertNotNil(OpenCodeDBReader(dbPath: dbPath).read().rows)
    }

    // ── 失败 ≠ 空:三态语义(评审:失败路径必须携带版本信号)──
    func test_missingFile_okEmptyRows() {
        XCTAssertEqual(OpenCodeDBReader(dbPath: "/nonexistent/oc.db").read(),
                       .ok(rows: [], maxMigrationId: nil))
    }
    func test_emptyDatabaseNoSessionTable_okEmptyRows() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)  // 建空库即关
        sqlite3_close_v2(db)
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read(),
                       .ok(rows: [], maxMigrationId: nil),
                       "空库=「装了没跑过」是常态,归 ok([]) 而非 failed(否则每轮永久跳过)")
    }
    func test_garbageFile_failed() {
        try! "not a sqlite db".write(toFile: dbPath, atomically: true, encoding: .utf8)
        guard case .failed = OpenCodeDBReader(dbPath: dbPath).read() else {
            return XCTFail("垃圾文件应 failed")
        }
    }
    /// 评审 Blocker 的规范化:缺列(schema 破坏性演进)→ failed,但 **migration 版本信号必须带出来**。
    func test_missingColumns_failedButCarriesMigrationId() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        exec(db, "CREATE TABLE session (id text PRIMARY KEY, title text);")
        exec(db, "CREATE TABLE migration (id text PRIMARY KEY, time_completed integer NOT NULL);")
        exec(db, "INSERT INTO migration VALUES ('20990101000000_future_break', 1);")
        sqlite3_close_v2(db)
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read(),
                       .failed(maxMigrationId: "20990101000000_future_break"),
                       "migration 探测先于主查询——「版本过新」提示的唯一数据来源")
    }
    func test_busyExclusiveLock_failed() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        exec(db, "CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, directory text NOT NULL, title text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer);")
        exec(db, "BEGIN EXCLUSIVE;")
        defer { exec(db, "ROLLBACK;"); sqlite3_close_v2(db) }
        guard case .failed = OpenCodeDBReader(dbPath: dbPath, busyTimeoutMs: 0).read() else {
            return XCTFail("非 WAL + EXCLUSIVE 应 failed(半读不可信)")
        }
    }

    // ── 辅助表缺失 → session-only 降级(评审:reset 型迁移防御)──
    func test_auxTablesMissing_degradesToSessionOnly() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        exec(db, "CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, directory text NOT NULL, title text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer);")
        exec(db, "INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1000000,2000000,NULL);")
        sqlite3_close_v2(db)
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        XCTAssertEqual(row.lastActivity, 2000, "降级:活动=time_updated")
        XCTAssertEqual(row.assistantSignal, AssistantSignal.none, "降级:无消息信号,回窗口兜底")
    }

    // ── 过滤 ──
    func test_filters_parentAndArchived() {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1000000,1000000,NULL);
            INSERT INTO session VALUES ('ses_sub','p','ses_a','/w','子','v',1000000,1000000,NULL);
            INSERT INTO session VALUES ('ses_arc','p',NULL,'/w','归档','v',1000000,1000000,999);
            """)
        }
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read().rows?.map(\.sessionId), ["ses_a"])
    }
    func test_archivedZero_hidden_parentEmptyString_hidden() {
        // 上游自身 truthy/isNull 不一致;我们随 list 语义:非 NULL 即隐藏(含 0/空串)。钉死为决策。
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_z','p',NULL,'/w','t','v',1000000,1000000,0);
            INSERT INTO session VALUES ('ses_e','p','','/w','t','v',1000000,1000000,NULL);
            """)
        }
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read().rows, [])
    }

    // ── 空串映射(约束 5)+ 占位标题 + 内嵌 NUL ──
    func test_emptyDirectoryAndTitle_mapNil() throws {
        makeFixture { db in
            exec(db, "INSERT INTO session VALUES ('ses_a','p',NULL,'','',  'v',1000000,1000000,NULL);")
        }
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        XCTAssertNil(row.directory, "legacy 空目录(上游 path.ts 注释)→ nil ≠ \"\"")
        XCTAssertNil(row.title)
    }
    func test_placeholderTitle_keptVerbatim() {
        makeFixture { db in
            exec(db, "INSERT INTO session VALUES ('ses_a','p',NULL,'/w','New session - 2026-07-03T10:00:00.000Z','v',1000000,1000000,NULL);")
        }
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read().rows?.first?.title,
                       "New session - 2026-07-03T10:00:00.000Z",
                       "决策:不模式匹配上游占位文案,原样展示(spec §2)")
    }
    /// SQLite text 可含 \0;String(cString:) 截断。行为钉死:不崩、逐行原样、Reader 层不归并
    /// (截断 id 与真实行撞 key 的归并发生在 store 层,是既有归一语义)。
    func test_embeddedNUL_idAndTitle_truncate_noReaderMerge() {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_ab' || char(0) || 'cd','p',NULL,'/w','t' || char(0) || 'x','v',1000000,1000000,NULL);
            INSERT INTO session VALUES ('ses_ab','p',NULL,'/other','真身','v',2000000,2000000,NULL);
            """)
        }
        let rows = OpenCodeDBReader(dbPath: dbPath).read().rows
        XCTAssertEqual(rows?.count, 2, "Reader 层不归并(评审:截断撞 key 是 store 层归一语义)")
        XCTAssertEqual(rows?.first(where: { $0.directory == "/w" })?.title, "t", "title NUL 截断为前缀")
        XCTAssertEqual(rows?.first(where: { $0.directory == "/w" })?.sessionId, "ses_ab",
                       "截断 id 过不了 SessionIdRule(26 位)→ 无恢复命令,fail-closed")
    }

    // ── isNewerThanVerified(评审 Blocker:全名前缀比较)──
    func test_isNewerThanVerified_numericPrefixComparison() {
        XCTAssertFalse(OpenCodeDBReader.isNewerThanVerified("20260622202450_simplify_session_input"),
                       "已验证版本自身不得误报(裸时间戳字符串比较会在这里恒 true)")
        XCTAssertFalse(OpenCodeDBReader.isNewerThanVerified("20260127222353_familiar_lady_ursula"))
        XCTAssertTrue(OpenCodeDBReader.isNewerThanVerified("20260701000000_new_migration"))
        XCTAssertFalse(OpenCodeDBReader.isNewerThanVerified("garbage_no_digits"),
                       "无数字前缀 → 不误报(保守)")
    }

    // ── defaultDBPath(env:launchctlGetenv:listDir:)(评审:GUI 不继承 shell env)──
    func test_defaultDBPath_envMatrix() {
        let noFiles: (String) -> [(name: String, mtime: Double)] = { _ in [] }
        let noLaunchctl: (String) -> String? = { _ in nil }
        let home = NSHomeDirectory()
        func path(_ env: [String: String]) -> String {
            OpenCodeDBReader.defaultDBPath(env: env, launchctlGetenv: noLaunchctl, listDir: noFiles)
        }
        XCTAssertEqual(path([:]), home + "/.local/share/opencode/opencode.db")
        XCTAssertEqual(path(["XDG_DATA_HOME": "/custom/data"]), "/custom/data/opencode/opencode.db")
        XCTAssertEqual(path(["XDG_DATA_HOME": ""]), home + "/.local/share/opencode/opencode.db",
                       "空串视为未设(xdg 规范)")
        XCTAssertEqual(path(["XDG_DATA_HOME": "rel/path"]), home + "/.local/share/opencode/opencode.db",
                       "相对路径忽略(xdg 规范)")
        XCTAssertEqual(path(["OPENCODE_DB": "/x/y.db"]), "/x/y.db", "OPENCODE_DB 绝对路径整体覆盖")
        XCTAssertEqual(path(["OPENCODE_DB": "custom.db"]),
                       home + "/.local/share/opencode/custom.db",
                       "OPENCODE_DB 相对路径 join 到数据目录(上游 database.ts:44-47 语义,评审 m1)")
    }
    func test_defaultDBPath_launchctlFallback_forGUIProcess() {
        // GUI 进程 env 无 XDG → launchctl getenv 补探(评审 Blocker:XDG 机器静默失明)。
        let path = OpenCodeDBReader.defaultDBPath(
            env: [:],
            launchctlGetenv: { name in name == "XDG_DATA_HOME" ? "/launchd/data" : nil },
            listDir: { _ in [] })
        XCTAssertEqual(path, "/launchd/data/opencode/opencode.db")
    }
    func test_defaultDBPath_channelGlob_newestWins_excludesWal() {
        let listDir: (String) -> [(name: String, mtime: Double)] = { _ in
            [("opencode.db", 100), ("opencode-dev.db", 200),
             ("opencode-dev.db-wal", 300), ("other.db", 400)]
        }
        let path = OpenCodeDBReader.defaultDBPath(env: [:], launchctlGetenv: { _ in nil },
                                                  listDir: listDir)
        XCTAssertTrue(path.hasSuffix("/opencode/opencode-dev.db"),
                      "opencode*.db 取 mtime 最新;-wal 与非 opencode 前缀排除,got \(path)")
    }
}
