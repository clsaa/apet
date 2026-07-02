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

    /// 读取全部未删除任务会话。DB 不存在/打不开 → []（QoderWork 未安装是常态）。
    public func read() -> [QoderWorkChatRow] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close_v2(db) }

        // sub_chats 与 chats 一一对应（实测）；LEFT JOIN 容忍缺 sub_chat/project 的行。
        let sql = """
        SELECT c.id, c.name, p.path, s.session_id, MAX(c.updated_at, IFNULL(s.updated_at, 0))
        FROM chats c
        LEFT JOIN projects p ON p.id = c.project_id
        LEFT JOIN sub_chats s ON s.chat_id = c.id
        WHERE c.deleted_at IS NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        func text(_ col: Int32) -> String? {
            sqlite3_column_text(stmt, col).map { String(cString: $0) }
        }

        var rows: [QoderWorkChatRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let chatId = text(0) else { continue }
            rows.append(QoderWorkChatRow(
                chatId: chatId,
                name: text(1),
                projectPath: text(2),
                sessionId: text(3),
                updatedAt: Double(sqlite3_column_int64(stmt, 4))
            ))
        }
        return rows
    }
}

// MARK: - QoderWorkWatcher

/// 定时轮询 agents.db → 纯扫描 → 差分 emit（对齐 JSONLDirectoryWatcher 的差分/幽灵语义）。
/// 粗略状态只在窗口边界翻转，无需滞回。
public final class QoderWorkWatcher {
    private let read: () -> [QoderWorkChatRow]
    private let root: String
    private let now: () -> Double
    private let emit: (ScanResult) -> Void
    private let runningWindow: Double
    private let idleWindow: Double

    private var lastEmitted: [SessionKey: ScanState] = [:]
    private var timer: DispatchSourceTimer?

    public init(
        read: @escaping () -> [QoderWorkChatRow],
        root: String,
        now: @escaping () -> Double,
        emit: @escaping (ScanResult) -> Void,
        runningWindow: Double = 120,
        idleWindow: Double = 1800
    ) {
        self.read = read; self.root = root; self.now = now; self.emit = emit
        self.runningWindow = runningWindow; self.idleWindow = idleWindow
    }

    public func scanOnce() {
        let results = QoderWorkScanner.scan(rows: read(), root: root, now: now(),
                                            runningWindow: runningWindow, idleWindow: idleWindow)
        var observed: Set<SessionKey> = []
        for result in results {
            guard case .observe(let state, let key, _, _) = result else { continue }
            observed.insert(key)
            if lastEmitted[key] != state {
                emit(result)
                lastEmitted[key] = state
            }
        }
        // 幽灵对账：上轮活跃、本轮消失/过老 → 补发 stale 打灰。
        let ghosts = lastEmitted.keys.filter { !observed.contains($0) }
        for key in ghosts {
            emit(.observe(state: .stale, key: key, cwd: nil, title: nil))
            lastEmitted.removeValue(forKey: key)
        }
    }

    public func start(every interval: Double) {
        let src = DispatchSource.makeTimerSource(queue: .main)
        src.schedule(deadline: .now() + interval, repeating: interval)
        src.setEventHandler { [weak self] in self?.scanOnce() }
        src.resume()
        timer = src
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }
}
