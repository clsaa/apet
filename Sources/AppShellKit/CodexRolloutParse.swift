import Foundation
import AgentPetCore

// MARK: - CodexSessionIndex

/// 读 `~/.codex/session_index.jsonl` → `[sessionId: thread_name]`(Codex 自带的现成标题)。
/// 按 (path, mtime) 缓存,索引不变不重读。行坏 JSON 跳过(不可信输入)。
public final class CodexSessionIndex {
    private var cache: [String: String] = [:]
    private var cachedMtime: Double = -1
    private let path: String

    public init(path: String) { self.path = path }

    public func title(for sessionId: String) -> String? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if mtime != cachedMtime {
            cache = Self.load(path: path)
            cachedMtime = mtime
        }
        return cache[sessionId]
    }

    static func load(path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String, !name.isEmpty else { continue }
            out[id] = name   // 同 id 后行覆盖前行(索引按时间追加,取最新)
        }
        return out
    }
}

// MARK: - CodexRolloutParse

/// Codex CLI rollout jsonl → `ScannedFile`(喂给现有 `JSONLSessionScanner.scan` 复用状态派生)。
///
/// 实测 schema(codex 0.118.0,见 2026-07-05 spec):
/// - 首行 `session_meta`:payload.id(sessionId)/cwd;resume 会追加多条 meta,取首行
/// - `event_msg` payload.type:`task_started`/`task_complete`(轮次信号)/`user_message`(纯文本)
/// - 行时间戳 ISO8601
///
/// 状态映射:尾部最后 task_complete ≥ 最后 task_started → `stopReason="end_turn"`(→ waitingStop);
/// started 更新(跑到一半)→ stopReason=nil + lastAssistantTs=最新信号 ts(→ runningWindow 内 running)。
public enum CodexRolloutParse {
    public static func parse(
        path: String,
        root: String,
        titleLookup: (String) -> String? = { _ in nil },
        maxLines: Int = 200,
        maxBytes: Int = 1_048_576
    ) -> ScannedFile? {
        // 1. 首行 session_meta → sessionId/cwd(非 rollout 文件 → nil)
        guard let first = TailLineReader.firstLine(path: path),
              let meta = decode(first),
              (meta["type"] as? String) == "session_meta",
              let mp = meta["payload"] as? [String: Any],
              let sessionId = (mp["id"] as? String) ?? (mp["session_id"] as? String),
              !sessionId.isEmpty else { return nil }
        let cwd = mp["cwd"] as? String

        // 2. mtime
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        // 3. 尾部行:轮次信号 + 最后用户消息 + 末行 ts
        guard case .ok(let lines) = TailLineReader.lastLines(path: path, maxLines: maxLines, maxBytes: maxBytes),
              !lines.isEmpty else { return nil }

        var lastStartedTs: Double? = nil
        var lastCompleteTs: Double? = nil
        var lastUserMessage: String? = nil
        var lastConversationTs: Double? = nil

        for line in lines {
            guard let obj = decode(line) else { continue }
            let ts = epoch(obj["timestamp"] as? String)
            if let ts { lastConversationTs = ts }   // 行序即时间序,末次赋值 = 末行
            guard let payload = obj["payload"] as? [String: Any],
                  let pt = payload["type"] as? String else { continue }
            switch pt {
            case "task_started":  lastStartedTs = ts ?? lastStartedTs
            case "task_complete": lastCompleteTs = ts ?? lastCompleteTs
            case "user_message":
                if let m = payload["message"] as? String, !m.isEmpty { lastUserMessage = m }
            default: break
            }
        }

        // 4. 轮次信号 → stopReason 映射
        var stopReason: String? = nil
        var lastAssistantTs: Double? = nil
        switch (lastStartedTs, lastCompleteTs) {
        case (nil, nil):
            break   // 无轮次信号(尾窗太短/会话刚建):mtime 兜底,scanner 判 stale/窗口
        case (let s?, nil):
            lastAssistantTs = s        // 跑到一半(complete 不在尾窗):按窗口判 running
        case (nil, let c?):
            stopReason = "end_turn"; lastAssistantTs = c
        case (let s?, let c?):
            if c >= s { stopReason = "end_turn"; lastAssistantTs = c }
            else { lastAssistantTs = s }
        }

        return ScannedFile(
            sessionId: sessionId,
            root: root,
            cwd: cwd,
            title: titleLookup(sessionId),
            lastPrompt: lastUserMessage,
            mtime: mtime,
            lastAssistantStopReason: stopReason,
            lastAssistantTs: lastAssistantTs,
            lastConversationTs: lastConversationTs,
            isSidechain: false,
            isSubagentPath: false
        )
    }

    private static func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// ISO8601(含小数秒/不含)→ epoch。复用 EventTsParser 的解析器语义(此处无需未来钳制)。
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func epoch(_ s: String?) -> Double? {
        guard let s else { return nil }
        return iso.date(from: s)?.timeIntervalSince1970 ?? isoNoFrac.date(from: s)?.timeIntervalSince1970
    }
}
