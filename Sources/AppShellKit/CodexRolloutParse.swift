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
              !sessionId.isEmpty,
              // 白名单:uuid 形态(hex+dash),防伪 id 进 store/「复制 sessionID」剪贴板(架构评审 Minor-2)
              sessionId.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        let cwd = mp["cwd"] as? String
        // Desktop vs CLI 分流(用户需求:区分两端)。取**首条** meta——真机实锤有会话先 Desktop
        // 后 CLI 混用,身份摇摆会导致 SessionKey 漂移会话分裂。
        // 明确 Desktop 信号(source=="vscode" / originator 含 Desktop)→ codex-desktop(激活 App);
        // 其余(source=="cli"/originator=codex-tui/老版本无 source)→ codex(CLI,诚实无跳转)——
        // 未知默认 CLI:宁可少给跳转,不乱激活 App(false-jump 会误标已读)。
        let source = (mp["source"] as? String) ?? ""
        let originator = (mp["originator"] as? String) ?? ""
        let isDesktop = source == "vscode" || originator.localizedCaseInsensitiveContains("desktop")
        let agentOverride: String? = isDesktop ? "codex-desktop" : nil

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
        // assistant 侧活动(response_item/agent_message/token_count 等):长轮次 >maxLines 行时
        // task_started 会被挤出尾窗,(nil,nil) 需用活动 ts 兜底,否则热文件误判 stale(测试评审 M3)。
        var lastActivityTs: Double? = nil
        // resume/每轮追加的 session_meta/turn_context 带最新 cwd(换目录 resume 后首行 cwd 过期,AI 评审 Minor-3)。
        var latestCwd: String? = nil

        for line in lines {
            guard let obj = decode(line) else { continue }
            let ts = epoch(obj["timestamp"] as? String)
            if let ts { lastConversationTs = ts }   // 行序即时间序,末次赋值 = 末行
            let type = obj["type"] as? String
            guard let payload = obj["payload"] as? [String: Any] else { continue }
            if type == "session_meta" || type == "turn_context",
               let c = payload["cwd"] as? String, !c.isEmpty { latestCwd = c }
            let pt = payload["type"] as? String
            if type == "response_item" { lastActivityTs = ts ?? lastActivityTs }
            switch pt {
            case "task_started":  lastStartedTs = ts ?? lastStartedTs
            case "task_complete": lastCompleteTs = ts ?? lastCompleteTs
            // 用户 Esc 中断轮次:盘上是 turn_aborted 而非 task_complete(上游 policy.rs 实证)。
            // 视作轮次终结,否则中断后 ≤runningWindow 误显 running(AI 评审 Major-1)。
            // 注:error 事件不持久化(同 policy 实证),流错误只能窗口兜底——数据源固有局限。
            case "turn_aborted": lastCompleteTs = ts ?? lastCompleteTs
            case "agent_message", "token_count": lastActivityTs = ts ?? lastActivityTs
            case "user_message":
                if let m = payload["message"] as? String, !m.isEmpty,
                   !m.trimmingCharacters(in: .whitespacesAndNewlines)
                     .hasPrefix("# Files mentioned by the user") {   // CLI 粘贴附件清单注入,非用户正文
                    lastUserMessage = m
                }
            default: break
            }
        }

        // 4. 轮次信号 → stopReason 映射
        var stopReason: String? = nil
        var lastAssistantTs: Double? = nil
        switch (lastStartedTs, lastCompleteTs) {
        case (nil, nil):
            // 双信号掉出尾窗(长轮次)→ 用 assistant 侧活动 ts 兜底判 running/窗口;
            // 真·刚建会话(只有 meta,无任何活动)→ nil → scanner 判 stale(不误报等你)。
            lastAssistantTs = lastActivityTs
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
            cwd: latestCwd ?? cwd,
            title: titleLookup(sessionId),
            lastPrompt: lastUserMessage,
            mtime: mtime,
            lastAssistantStopReason: stopReason,
            lastAssistantTs: lastAssistantTs,
            lastConversationTs: lastConversationTs,
            isSidechain: false,
            isSubagentPath: false,
            agentOverride: agentOverride
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

// MARK: - CodexConversationTail

/// codex rollout 行 → `ConversationTurn`(解锁快速/AI 摘要;与 Claude 的 ConversationTailParser 对位)。
/// user 回合 ← `event_msg user_message`(纯文本;跳过 `# Files mentioned` 附件注入);
/// assistant 回合 ← `event_msg agent_message`;尾部 task_complete 后最后一条 assistant 标 end_turn。
public enum CodexConversationTail {
    public static func turns(lines: [String]) -> [ConversationTurn] {
        var out: [ConversationTurn] = []
        var sawComplete = false
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let pt = payload["type"] as? String else { continue }
            switch pt {
            case "user_message":
                if let m = payload["message"] as? String, !m.isEmpty,
                   !m.trimmingCharacters(in: .whitespacesAndNewlines)
                     .hasPrefix("# Files mentioned by the user") {
                    out.append(ConversationTurn(role: "user", text: m))
                }
            case "agent_message":
                if let m = payload["message"] as? String, !m.isEmpty {
                    out.append(ConversationTurn(role: "assistant", text: m))
                }
            case "task_complete":
                sawComplete = true
            default: break
            }
        }
        // 尾部轮次已完成 → 最后 assistant 标 end_turn(scanner/摘要语义对齐)
        if sawComplete, let i = out.lastIndex(where: { $0.role == "assistant" }) {
            out[i] = ConversationTurn(role: "assistant", text: out[i].text, stopReason: "end_turn")
        }
        return out
    }
}
