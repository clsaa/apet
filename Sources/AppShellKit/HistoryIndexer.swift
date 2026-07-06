import Foundation
import AgentPetCore

/// 历史会话条目(2026-07-06 spec:全量档案,便于搜索查找;非活跃窗口约束)。
public struct HistoryEntry: Equatable, Identifiable {
    public var id: String { "\(agent)|\(root)|\(sessionId)" }
    public let agent: String
    public let root: String
    public let sessionId: String
    public var cwd: String?
    public var title: String?
    public var lastTs: Double

    public init(agent: String, root: String, sessionId: String,
                cwd: String? = nil, title: String? = nil, lastTs: Double) {
        self.agent = agent; self.root = root; self.sessionId = sessionId
        self.cwd = cwd; self.title = title; self.lastTs = lastTs
    }
}

/// 历史索引:聚合各家磁盘档案,(path, mtime) 缓存防重复解析(claude 会批量 touch mtime,
/// 缓存失效只多解析不丢数据)。IO 全走注入缝,纯逻辑可测。
public final class HistoryIndexer {
    /// path → (mtime, entry):jsonl 未变不重析。
    private var cache: [String: (mtime: Double, entry: HistoryEntry)] = [:]

    public init() {}

    // MARK: - claude 同构 jsonl(claude / qoder-cli / qoder-ide)

    /// 枚举 <root>/projects/**.jsonl(跳过 subagents),parse 注入(生产用 JSONLParse 限行)。
    public func claudeStyleEntries(
        agent: String,
        root: String,
        listFiles: () -> [(path: String, mtime: Double)],
        parse: (String) -> (sessionId: String, cwd: String?, title: String?)?
    ) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        for f in listFiles() {
            if let hit = cache[f.path], hit.mtime == f.mtime {
                out.append(hit.entry); continue
            }
            guard let p = parse(f.path) else { continue }
            let e = HistoryEntry(agent: agent, root: root, sessionId: p.sessionId,
                                 cwd: p.cwd, title: p.title, lastTs: f.mtime)
            cache[f.path] = (f.mtime, e)
            out.append(e)
        }
        return out
    }

    // MARK: - codex(session_index thread_name ∪ rollout 枚举)

    /// rollout 文件名尾段 `-<uuid>.jsonl` 提取 sessionId;标题查 titles(session_index)。
    public func codexEntries(
        root: String,
        listRollouts: () -> [(path: String, mtime: Double)],
        titles: [String: String],
        parseMeta: (String) -> (sessionId: String, cwd: String?, isDesktop: Bool)?
    ) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        for f in listRollouts() {
            if let hit = cache[f.path], hit.mtime == f.mtime {
                out.append(hit.entry); continue
            }
            guard let m = parseMeta(f.path) else { continue }
            let e = HistoryEntry(agent: m.isDesktop ? "codex-desktop" : "codex",
                                 root: root, sessionId: m.sessionId,
                                 cwd: m.cwd, title: titles[m.sessionId], lastTs: f.mtime)
            cache[f.path] = (f.mtime, e)
            out.append(e)
        }
        return out
    }

    /// 聚合去重(同 id 取 lastTs 最新)+ 时间倒序。
    public static func merged(_ groups: [[HistoryEntry]]) -> [HistoryEntry] {
        var byId: [String: HistoryEntry] = [:]
        for g in groups {
            for e in g {
                if let old = byId[e.id], old.lastTs >= e.lastTs { continue }
                byId[e.id] = e
            }
        }
        return byId.values.sorted { $0.lastTs > $1.lastTs }
    }
}
