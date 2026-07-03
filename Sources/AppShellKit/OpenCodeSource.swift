import Foundation
import SQLite3
import AgentPetCore

// MARK: - OpenCodeSessionRow

/// 最后一条 assistant 消息的结构性信号(上游 getCurrentAssistant 同款判据,projector.ts:134-151)。
/// M3-C+ 计划评审 v3:取代 ε 时间比较——part 的 upsert 只更新 data、time_created 冻结
/// (projector.ts:319-324),长工具/长文本期间活动时间链停摆,任何窗口判据都会误降;
/// in-flight 布尔不受影响。
public enum AssistantSignal: Equatable {
    case none        // 无 assistant 消息(会话刚建/降级读取)
    case inFlight    // $.time.completed IS NULL → 本轮进行中
    case completed   // 非 NULL(任意类型,ISO 串也算)→ 本轮真实完成
}

/// OpenCode(opencode.db,源码核实 v1.17.13)一条会话的轻量投影。
/// 时间为 **Unix 秒**(Reader 层已从 epoch 毫秒换算);directory/title 空串已映射 nil(约束 5)。
public struct OpenCodeSessionRow: Equatable {
    public let sessionId: String
    public let directory: String?
    public let title: String?
    /// 最近**行插入**时间:MAX(part.time_created) → session_message → session.time_updated 降级链。
    /// 仅用于年龄降档(stale/排除),不用于 running 判定(见 AssistantSignal)。
    public let lastActivity: Double
    public let assistantSignal: AssistantSignal
    public let createdAt: Double

    public init(sessionId: String, directory: String?, title: String?,
                lastActivity: Double, assistantSignal: AssistantSignal, createdAt: Double) {
        self.sessionId = sessionId; self.directory = directory; self.title = title
        self.lastActivity = lastActivity; self.assistantSignal = assistantSignal
        self.createdAt = createdAt
    }
}

// MARK: - OpenCodeScanner(纯函数)

/// 状态派生(spec §3.1 v3):
/// 1. 年龄降档先行:age>=staleHorizon 排除;age>=idleWindow → stale(灰显不蒸发——常开 TUI
///    挂机 30 分钟就消失违背用户直觉;亦是 in-flight 的 kill 兜底:进程死后 completed 永为
///    NULL,靠年龄出场)。
/// 2. 活跃窗口内:.inFlight → running;.completed → waitingStop(不等窗口);
///    .none → age<runningWindow ? running : waitingStop(窗口兜底,prompt-touch 保活)。
public enum OpenCodeScanner {
    public static func scan(
        rows: [OpenCodeSessionRow],
        root: String,
        now: Double,
        runningWindow: Double = 120,
        idleWindow: Double = 1800,
        staleHorizon: Double = 86400
    ) -> [ScanResult] {
        rows.compactMap { row in
            guard row.lastActivity > 0 else { return nil }   // 0/负值:坏数据,静默排除
            let age = now - row.lastActivity
            guard age < staleHorizon else { return nil }
            let key = SessionKey(agent: "opencode", root: root, sessionId: row.sessionId)
            let state: ScanState
            if age >= idleWindow {
                state = .stale
            } else {
                switch row.assistantSignal {
                case .inFlight:  state = .running
                case .completed: state = .waitingStop
                case .none:      state = age < runningWindow ? .running : .waitingStop
                }
            }
            return .observe(state: state, key: key, cwd: row.directory, title: row.title)
        }
    }
}

// MARK: - OpenCodeDBReader(IO 缝,只读 SQLite)

/// 读取结果三态(评审 Blocker:失败路径必须携带版本信号):
/// ok(rows: [], ...) = 不存在/空库(「装了没跑过」是常态);failed = 打不开/prepare 失败/半读。
public enum OpenCodeReadOutcome: Equatable {
    case ok(rows: [OpenCodeSessionRow], maxMigrationId: String?)
    case failed(maxMigrationId: String?)

    public var rows: [OpenCodeSessionRow]? {
        if case .ok(let rows, _) = self { return rows }
        return nil
    }
    public var maxMigrationId: String? {
        switch self {
        case .ok(_, let id), .failed(let id): return id
        }
    }
}

/// 只读打开 opencode.db(READONLY,WAL 兼容)。上游对该 DB 无 stability 承诺,防御为先。
public struct OpenCodeDBReader {
    private let dbPath: String
    private let busyTimeoutMs: Int32

    public init(dbPath: String, busyTimeoutMs: Int32 = 200) {
        self.dbPath = dbPath; self.busyTimeoutMs = busyTimeoutMs
    }

    /// 已验证的上游迁移 id 上界(**全名**,v1.17.13 / commit 04d236c;上游落库 id 形如
    /// `<14位时间戳>_<名字>`,migration.ts:30-35——裸时间戳比较会在已验证版本上恒误报)。
    /// ⚠️ 维护流程(上游 ~8 迁移/月,此值常态过期):上游出新迁移后
    /// ① 重跑 spec §2 事实核对;② 本常量改为新迁移全名;
    /// ③ `APET_OPENCODE_LIVE=1 swift test --filter OpenCodeLiveTests` 重跑;
    /// ④ 同步 README「已验证版本」行。
    public static let verifiedMaxMigrationId = "20260622202450_simplify_session_input"

    /// maxId 是否新于已验证版本:取两侧**前导数字前缀**比较(等长 14 位时间戳,字典序=数值序);
    /// 无数字前缀 → false(保守不误报)。
    public static func isNewerThanVerified(_ maxId: String) -> Bool {
        let lhs = maxId.prefix(while: { $0.isASCII && $0.isNumber })
        let rhs = verifiedMaxMigrationId.prefix(while: { $0.isASCII && $0.isNumber })
        guard !lhs.isEmpty else { return false }
        return lhs > rhs
    }

    /// DB 路径解析(评审 Blocker:GUI 进程读不到 shell rc 的环境变量):
    /// 1. `OPENCODE_DB`(env → launchctl):绝对路径整体覆盖;**相对路径 join 到数据目录**
    ///    (上游 database.ts:44-47 语义,评审 m1:勿按"忽略相对"实现);
    /// 2. `XDG_DATA_HOME`(env → launchctl;绝对非空才算设了);默认 `~/.local/share`;
    /// 3. 目录内 glob `opencode*.db` 取 mtime 最新(channel 后缀;`.db` 后缀天然排除 -wal/-shm)。
    public static func defaultDBPath(
        env: [String: String],
        launchctlGetenv: (String) -> String? = Self.launchctlGetenv,
        listDir: ((String) -> [(name: String, mtime: Double)])? = nil
    ) -> String {
        func lookup(_ name: String) -> String? {
            if let v = env[name], !v.isEmpty { return v }
            return launchctlGetenv(name)
        }
        let dataHome: String
        if let xdg = lookup("XDG_DATA_HOME"), xdg.hasPrefix("/") {
            dataHome = xdg
        } else {
            dataHome = NSHomeDirectory() + "/.local/share"
        }
        let dir = dataHome + "/opencode"
        if let ov = lookup("OPENCODE_DB"), !ov.isEmpty {
            return ov.hasPrefix("/") ? ov : dir + "/" + ov
        }
        let list = listDir ?? Self.realListDir
        let candidates = list(dir).filter { $0.name.hasPrefix("opencode") && $0.name.hasSuffix(".db") }
        if let newest = candidates.max(by: { $0.mtime < $1.mtime }) {
            return dir + "/" + newest.name
        }
        return dir + "/opencode.db"
    }

    /// GUI 进程(launchd 拉起)env 兜底:`launchctl getenv`。只在启动路径解析时调用一次,非轮询热路径。
    /// public 仅因默认参数引用需要;不建议单独调用。
    public static func launchctlGetenv(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["getenv", name]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty ?? true) ? nil : out
    }

    private static func realListDir(_ dir: String) -> [(name: String, mtime: Double)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.map { name in
            let attrs = try? fm.attributesOfItem(atPath: dir + "/" + name)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return (name, mtime)
        }
    }

    public func read() -> OpenCodeReadOutcome {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .ok(rows: [], maxMigrationId: nil)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return .failed(maxMigrationId: nil)
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, busyTimeoutMs)

        // 表存在性探测:session 缺 → 空库常态;part/session_message 缺 → 降级 session-only。
        guard let tables = tableNames(db) else { return .failed(maxMigrationId: nil) }
        // 版本探测**先于**主查询(评审 Blocker:排后面则 schema 破坏性升级时主查询先失败,
        // 版本信号永远带不出来——恰是唯一需要它的场景)。migration 表结构 5 个月未变,最稳。
        let maxMigration: String? = tables.contains("migration") ? maxMigrationId(db) : nil
        guard tables.contains("session") else {
            return .ok(rows: [], maxMigrationId: maxMigration)
        }
        let hasPart = tables.contains("part")
        let hasMsg = tables.contains("session_message")

        // 活动降级链(评审 B1/M1:time_updated 只在提问时刷新;part/message 只有**行插入**时间可靠,
        // upsert 更新不刷 time_created——running 判定不依赖这里,靠 assistantSignal)。
        var activityExprs = ["s.time_updated"]
        if hasMsg {
            activityExprs.insert("(SELECT MAX(m.time_created) FROM session_message m WHERE m.session_id = s.id)", at: 0)
        }
        if hasPart {
            activityExprs.insert("(SELECT MAX(p.time_created) FROM part p WHERE p.session_id = s.id)", at: 0)
        }
        // assistant 信号:NULL=无 assistant 行(none);0=completed IS NULL(inFlight);1=completed(completed)。
        // CASE 包裹使 ISO 串等未来编码也归 completed(非 NULL 即完成,评审 m3)。
        // ⚠️ json_valid 护栏(实现评审 Blocker):json_extract 对 malformed JSON 是**抛错**而非
        // 返回 NULL——错误发生在 step 期间会把整轮打成 .failed,单条坏 data 毒化全库读取。
        // 坏 data → NULL → .none 走窗口兜底,与 spec §3.1「json_extract 失败 → 信号缺席」一致。
        let signalExpr = hasMsg
            ? """
              (SELECT CASE WHEN json_valid(m.data) = 0 THEN NULL
                           WHEN json_extract(m.data, '$.time.completed') IS NULL THEN 0
                           ELSE 1 END
                 FROM session_message m
                WHERE m.session_id = s.id AND m.type = 'assistant'
                ORDER BY m.seq DESC LIMIT 1)
              """
            : "NULL"
        // 窗口过滤在 Swift 层(scanner)做:不能按 time_updated 下推(B1 同根)。
        // SQLite 的 COALESCE 至少 2 参——session-only 降级时单表达式不包裹。
        let activityExpr = activityExprs.count > 1
            ? "COALESCE(\(activityExprs.joined(separator: ", ")))"
            : activityExprs[0]
        let sql = """
        SELECT s.id, s.directory, s.title, s.time_created,
               \(activityExpr) AS last_activity,
               \(signalExpr) AS assistant_signal
        FROM session s
        WHERE s.parent_id IS NULL AND s.time_archived IS NULL
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .failed(maxMigrationId: maxMigration)
        }
        defer { sqlite3_finalize(stmt) }

        func text(_ col: Int32) -> String? {
            sqlite3_column_text(stmt, col).map { String(cString: $0) }
        }
        func emptyAsNil(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

        var rows: [OpenCodeSessionRow] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let id = text(0) {
                let signal: AssistantSignal
                if sqlite3_column_type(stmt, 5) == SQLITE_NULL {
                    signal = .none
                } else {
                    signal = sqlite3_column_int64(stmt, 5) == 0 ? .inFlight : .completed
                }
                rows.append(OpenCodeSessionRow(
                    sessionId: id,
                    directory: emptyAsNil(text(1)),
                    title: emptyAsNil(text(2)),
                    lastActivity: sqlite3_column_double(stmt, 4) / 1000.0,
                    assistantSignal: signal,
                    createdAt: sqlite3_column_double(stmt, 3) / 1000.0
                ))
            }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else {
            return .failed(maxMigrationId: maxMigration)   // 半读(BUSY/IOERR)不可信
        }
        return .ok(rows: rows, maxMigrationId: maxMigration)
    }

    /// `SELECT MAX(id) FROM migration`;查询失败 → nil(不拦整体读取)。
    private func maxMigrationId(_ db: OpaquePointer) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(id) FROM migration", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    /// sqlite_master 表名集合;查询失败(BUSY 等)→ nil。
    private func tableNames(_ db: OpaquePointer) -> Set<String>? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let n = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) { names.insert(n) }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { return nil }
        return names
    }
}

// MARK: - OpenCodeHealth(纯决策表,用户可见健康提示)

/// spec §3.3:「未安装」与「版本不匹配/路径失明/旧版」必须可区分——
/// 「会话昨天还在、今天消失且无解释」是最差体验(评审)。
public enum OpenCodeHealth: Equatable {
    case ok
    case notInstalled                          // 无 db 无任何痕迹:常态,不打扰
    case dbNotFound                            // 无 db 但有 ~/.config/opencode 痕迹(XDG 失明嫌疑)
    case legacyStorage                         // 无 db 但有旧 JSON storage:请升级 OpenCode
    case readFailed                            // 本轮读失败(锁抖动/损坏),版本未超
    case versionTooNew(maxMigrationId: String) // 读失败 ∧ migration 新于已验证

    /// 用户可见文案;nil = 不展示(ok/notInstalled)。
    public var userMessage: String? {
        switch self {
        case .ok, .notInstalled:
            return nil
        case .dbNotFound:
            return "OpenCode:找到配置但未找到数据库——若你在 shell 里设置了 XDG_DATA_HOME,GUI 应用读不到它;可用 `launchctl setenv XDG_DATA_HOME <路径>` 后重启 apet"
        case .legacyStorage:
            return "OpenCode:检测到旧版 JSON 存储(未迁 SQLite),apet 不支持——请升级 OpenCode"
        case .readFailed:
            return "OpenCode:数据库暂时读不出(可能被占用),会自动重试"
        case .versionTooNew(let id):
            return "OpenCode:数据库 schema(\(id))新于 apet 已验证版本,暂不支持——请升级 apet 或提 issue"
        }
    }
}

public enum OpenCodeHealthDecider {
    public static func decide(
        outcome: OpenCodeReadOutcome,
        dbExists: Bool,
        legacyStorageExists: Bool,
        configDirExists: Bool
    ) -> OpenCodeHealth {
        if case .failed(let maxId) = outcome {
            if let maxId, OpenCodeDBReader.isNewerThanVerified(maxId) {
                return .versionTooNew(maxMigrationId: maxId)
            }
            return .readFailed
        }
        guard !dbExists else { return .ok }
        if legacyStorageExists { return .legacyStorage }
        if configDirExists { return .dbNotFound }
        return .notInstalled
    }
}
