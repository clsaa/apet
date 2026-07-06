import Foundation

// MARK: - SessionMeta

/// 会话的持久化元数据（不含状态机真值 acknowledged）。只持久化状态机不碰的字段：
/// favorite / customName / firstSeenAt / cachedSummary / summaryAnchor。
public struct SessionMeta: Codable, Equatable {
    public var favorite: Bool
    public var customName: String?
    public var firstSeenAt: Double?
    public var cachedSummary: String?
    public var summaryAnchor: Int?
    public var groups: [String]
    /// 手动摘要(用户手写的一句话,2026-07-06 spec;与 customName 同 merge 语义)。
    public var note: String?

    public init(favorite: Bool = false, customName: String? = nil, firstSeenAt: Double? = nil,
                cachedSummary: String? = nil, summaryAnchor: Int? = nil,
                groups: [String] = [], note: String? = nil) {
        self.favorite = favorite
        self.customName = customName
        self.firstSeenAt = firstSeenAt
        self.cachedSummary = cachedSummary
        self.summaryAnchor = summaryAnchor
        self.groups = groups
        self.note = note
    }

    // 向后兼容：缺字段用默认。
    private enum CodingKeys: String, CodingKey {
        case favorite, customName, firstSeenAt, cachedSummary, summaryAnchor, groups, note
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        firstSeenAt = try c.decodeIfPresent(Double.self, forKey: .firstSeenAt)
        cachedSummary = try c.decodeIfPresent(String.self, forKey: .cachedSummary)
        summaryAnchor = try c.decodeIfPresent(Int.self, forKey: .summaryAnchor)
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// 合并两条 meta：customName/cachedSummary/summaryAnchor last-non-nil-wins；
    /// favorite 或（`new` 显式 true 覆盖）；firstSeenAt 取 min。
    public static func merge(_ old: SessionMeta, _ new: SessionMeta) -> SessionMeta {
        SessionMeta(
            favorite: new.favorite || old.favorite,
            customName: new.customName ?? old.customName,
            firstSeenAt: minOptional(old.firstSeenAt, new.firstSeenAt),
            cachedSummary: new.cachedSummary ?? old.cachedSummary,
            summaryAnchor: new.summaryAnchor ?? old.summaryAnchor,
            groups: Array(Set(old.groups).union(new.groups)).sorted(),
            note: new.note ?? old.note
        )
    }

    private static func minOptional(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (x?, y?): return Swift.min(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }
}

// MARK: - SessionMetaMerger

/// 纯函数：归一键 + 把 meta 镜像进 Session。core 只对已注入 Double 做 min，绝不读文件/调 Date()。
public enum SessionMetaMerger {

    /// 归一键 `agent::root::sessionId`（**含 root**，对齐 CLAUDE.md #3，杜绝多 profile 串味）。
    public static func metaKey(_ key: SessionKey) -> String {
        "\(key.agent)::\(key.root)::\(key.sessionId)"
    }

    /// 把 meta 镜像进 Session：favorite/customName 直接覆盖；createdAt 与 firstSeenAt 取 min。
    public static func apply(into session: Session, meta: SessionMeta?) -> Session {
        guard let meta else { return session }
        var s = session
        s.favorite = meta.favorite
        s.customName = meta.customName
        s.groups = meta.groups
        s.note = meta.note
        if let firstSeen = meta.firstSeenAt {
            if let existing = s.createdAt {
                s.createdAt = Swift.min(existing, firstSeen)
            } else {
                s.createdAt = firstSeen
            }
        }
        return s
    }
}
