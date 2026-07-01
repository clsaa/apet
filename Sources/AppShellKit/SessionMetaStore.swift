import Foundation
import AgentPetCore

/// 会话元数据持久化（`~/Library/Application Support/AgentPet/session-meta.json`）。
/// key = `SessionMetaMerger.metaKey`。损坏 json → 回退空 map（对标 ``ConfigStore``）。
/// save 仅由**显式用户操作**触发（收藏/重命名/总结完成），状态机自主翻转不落盘。
public struct SessionMetaStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// 载入全部 meta；文件不存在或损坏 → 空 map。
    public func load() -> [String: SessionMeta] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: SessionMeta].self, from: data)
        } catch {
            return [:]
        }
    }

    /// 原子写盘，自动建父目录。
    public func save(_ metas: [String: SessionMeta]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metas)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomicWrite)
    }
}
