import Foundation
import SQLite3
import AgentPetCore

// MARK: - QoderWorkChatRow

/// QoderWork（agents.db，实测 schema）里一条任务会话的轻量投影。
/// 来源：`chats` JOIN `projects` JOIN `sub_chats`；时间为 **epoch 秒**（实测）。
public struct QoderWorkChatRow: Equatable {
    public let chatId: String
    public let name: String?
    public let projectPath: String?
    public let sessionId: String?
    public let updatedAt: Double

    public init(chatId: String, name: String?, projectPath: String?,
                sessionId: String?, updatedAt: Double) {
        self.chatId = chatId; self.name = name; self.projectPath = projectPath
        self.sessionId = sessionId; self.updatedAt = updatedAt
    }
}

// MARK: - QoderWorkScanner（纯函数）

/// 状态派生「粗略」（M3-C 设计：非 Claude 无 stateRules → 仅按最近活动时间窗口）：
/// `now-updatedAt < runningWindow` → running；`< idleWindow` → waitingStop；更老 → 不进面板。
public enum QoderWorkScanner {
    public static func scan(
        rows: [QoderWorkChatRow],
        root: String,
        now: Double,
        runningWindow: Double,
        idleWindow: Double
    ) -> [ScanResult] {
        rows.compactMap { row in
            let age = now - row.updatedAt
            guard age < idleWindow else { return nil }
            let state: ScanState = age < runningWindow ? .running : .waitingStop
            let key = SessionKey(agent: "qoder-work", root: root,
                                 sessionId: row.sessionId ?? row.chatId)
            return .observe(state: state, key: key, cwd: row.projectPath, title: row.name)
        }
    }
}

// MARK: - QoderWorkDBReader（IO 缝，只读 SQLite）

/// 只读打开 QoderWork 的 agents.db（SQLITE_OPEN_READONLY，WAL 兼容），
/// 取活跃任务会话。SQLite3 为系统库（Apple SDK），不违反零第三方依赖。
public struct QoderWorkDBReader {
    private let dbPath: String
    public init(dbPath: String) { self.dbPath = dbPath }

    /// 默认 DB 位置（实测）：`~/Library/Application Support/QoderWork/data/agents.db`。
    public static var defaultDBPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/QoderWork/data/agents.db")
    }

    /// 读取全部未删除任务会话。
    /// 语义（评审修复 AI M5/架构 M3/测试 M5）：**失败 ≠ 空**——
    /// - DB 文件不存在 → `[]`（QoderWork 未安装是常态，确实无会话）
    /// - 打不开 / prepare 失败 / step 遇 BUSY 等半读 → `nil`（本轮读取失败，调用方应跳过）
    public func read() -> [QoderWorkChatRow]? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close_v2(db) }
        // 锁竞争缓解：QoderWork 写库时等待至多 200ms 而非立即 SQLITE_BUSY。
        sqlite3_busy_timeout(db, 200)

        // GROUP BY 去重（测试 M5：双 sub_chat 不得产出重复会话行）；
        // 外层 MAX(聚合) 包内层 MAX(标量) 取 chats/sub_chats 全组最新时间。
        let sql = """
        SELECT c.id, c.name, p.path, MAX(s.session_id), MAX(MAX(c.updated_at, IFNULL(s.updated_at, 0)))
        FROM chats c
        LEFT JOIN projects p ON p.id = c.project_id
        LEFT JOIN sub_chats s ON s.chat_id = c.id
        WHERE c.deleted_at IS NULL
        GROUP BY c.id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }

        func text(_ col: Int32) -> String? {
            sqlite3_column_text(stmt, col).map { String(cString: $0) }
        }

        var rows: [QoderWorkChatRow] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let chatId = text(0) {
                rows.append(QoderWorkChatRow(
                    chatId: chatId,
                    name: text(1),
                    projectPath: text(2),
                    sessionId: text(3),
                    updatedAt: Double(sqlite3_column_int64(stmt, 4))
                ))
            }
            rc = sqlite3_step(stmt)
        }
        // 非正常收尾（SQLITE_BUSY/IOERR…）→ 半读结果不可信，按失败上报。
        guard rc == SQLITE_DONE else { return nil }
        return rows
    }
}

// MARK: - QoderWorkWatcher

/// 定时轮询 agents.db → 纯扫描 → 差分 emit（对齐 JSONLDirectoryWatcher 的差分/幽灵语义）。
/// 实现已泛化为 DBPollWatcher（M3-C+ OpenCode 接入,评审 B4:回归网先行后重构），
/// 此处保持公开签名、内部委托——读失败 nil 整轮跳过等语义随泛化件保持。
public final class QoderWorkWatcher {
    private let inner: DBPollWatcher

    public init(
        read: @escaping () -> [QoderWorkChatRow]?,
        root: String,
        now: @escaping () -> Double,
        emit: @escaping (ScanResult) -> Void,
        runningWindow: Double = 120,
        idleWindow: Double = 1800
    ) {
        inner = DBPollWatcher(
            scan: { now in
                read().map {
                    QoderWorkScanner.scan(rows: $0, root: root, now: now,
                                          runningWindow: runningWindow, idleWindow: idleWindow)
                }
            },
            now: now, emit: emit)
    }

    public func scanOnce() { inner.scanOnce() }
    public func start(every interval: Double) { inner.start(every: interval) }
    public func stop() { inner.stop() }
}
