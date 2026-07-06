import AgentPetCore

// MARK: - Models

/// 会话列表分组维度。
public enum GroupDimension: Equatable { case status, date, agent }

public struct SessionGroup: Equatable {
    public let title: String
    public let rows: [SessionRowModel]
    public init(title: String, rows: [SessionRowModel]) {
        self.title = title
        self.rows = rows
    }
}

/// 组织后的面板数据：`pinned`=未读「等你」置顶高亮区；`groups`=其余按维度分组。
public struct OrganizedList: Equatable {
    public let pinned: [SessionRowModel]
    public let groups: [SessionGroup]
    public init(pinned: [SessionRowModel], groups: [SessionGroup]) {
        self.pinned = pinned
        self.groups = groups
    }
}

// MARK: - SessionListOrganizer

/// 纯函数：搜索过滤 + 置顶未读「等你」+ 按维度分组。`filter` 一等入参、`now` 注入。
public enum SessionListOrganizer {

    public static func organize(
        sessions: [Session],
        dimension: GroupDimension,
        filter: String,
        now: Double,
        tzOffset: Double = 0
    ) -> OrganizedList {
        // 1) 搜索过滤（大小写不敏感 contains，匹配 customName / title / cwd / sessionId）。
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = sessions.filter { needle.isEmpty || matches($0, needle) }

        // 2) 置顶：未读 waiting（红/橙），其余进分组。收藏优先（F8「收藏置顶」），组内保留输入顺序。
        var pinned: [SessionRowModel] = []
        var rest: [Session] = []
        for s in matched {
            if isUnreadWaiting(s) { pinned.append(SessionRowMapper.make(s, now: now, tzOffset: tzOffset)) }
            else { rest.append(s) }
        }
        pinned.sort { $0.favorite && !$1.favorite }
        // 收藏优先进组（稳定排序保 seq 序）。
        rest = rest.enumerated().sorted { a, b in
            if a.element.favorite != b.element.favorite { return a.element.favorite }
            return a.offset < b.offset
        }.map { $0.element }

        // 3) 分组。
        let groups = group(rest, by: dimension, now: now, tzOffset: tzOffset)
        return OrganizedList(pinned: pinned, groups: groups)
    }

    // MARK: - Private

    /// 供面板 tab 计数复用的搜索匹配(与 organize 同规则)。
    public static func matchesPublic(_ s: Session, _ needle: String) -> Bool { matches(s, needle) }

    private static func matches(_ s: Session, _ needle: String) -> Bool {
        // customName 展示时优先于 title，搜索也必须能命中（F7 × 搜索，产品评审 M5）
        if let n = s.customName, n.lowercased().contains(needle) { return true }
        if let t = s.title, t.lowercased().contains(needle) { return true }
        if let note = s.note, note.lowercased().contains(needle) { return true }   // 手动摘要可搜(2026-07-06 spec)
        if let c = s.cwd, c.lowercased().contains(needle) { return true }
        if s.key.sessionId.lowercased().contains(needle) { return true }
        if s.key.agent.lowercased().contains(needle) { return true }   // B4:搜 agent 名
        return false
    }

    private static func isUnreadWaiting(_ s: Session) -> Bool {
        if case .waiting = s.state, !s.acknowledged { return true }
        return false
    }

    private static func group(_ sessions: [Session], by dimension: GroupDimension, now: Double, tzOffset: Double) -> [SessionGroup] {
        switch dimension {
        case .status: return groupByStatus(sessions, now: now, tzOffset: tzOffset)
        case .agent:  return groupByKey(sessions, now: now, tzOffset: tzOffset) { $0.key.agent }
        case .date:   return groupByDate(sessions, now: now, tzOffset: tzOffset)
        }
    }

    /// 状态维度固定顺序：进行中 → 已读 → 超时（置顶已取走未读 waiting）。
    private static func groupByStatus(_ sessions: [Session], now: Double, tzOffset: Double) -> [SessionGroup] {
        let order: [(String, (Session) -> Bool)] = [
            ("进行中", { if case .running = $0.state { return true }; return false }),
            ("已读",   { if case .waiting = $0.state, $0.acknowledged { return true }; return false }),
            ("超时",   { if case .stale = $0.state { return true }; return false }),
        ]
        return order.compactMap { title, pred in
            let rows = sessions.filter(pred).map { SessionRowMapper.make($0, now: now, tzOffset: tzOffset) }
            return rows.isEmpty ? nil : SessionGroup(title: title, rows: rows)
        }
    }

    /// 按 key 分组，保留首次出现顺序。
    private static func groupByKey(_ sessions: [Session], now: Double, tzOffset: Double, _ key: (Session) -> String) -> [SessionGroup] {
        var order: [String] = []
        var buckets: [String: [SessionRowModel]] = [:]
        for s in sessions {
            let k = key(s)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(SessionRowMapper.make(s, now: now, tzOffset: tzOffset))
        }
        return order.map { SessionGroup(title: $0, rows: buckets[$0] ?? []) }
    }

    /// 日期维度：以**本地日**（floor((ts+tzOffset)/86400)）比较；tzOffset 由 IO 边界注入
    /// TimeZone.current.secondsFromGMT()。默认 0（UTC）保测试确定性（评审修复：东八区错位）。
    private static func groupByDate(_ sessions: [Session], now: Double, tzOffset: Double) -> [SessionGroup] {
        let nowDay = Int((now + tzOffset) / 86_400)
        let order: [(String, (Int) -> Bool)] = [
            ("今天", { $0 == nowDay }),
            ("昨天", { $0 == nowDay - 1 }),
            ("本周", { $0 < nowDay - 1 && $0 > nowDay - 7 }),
            ("更早", { $0 <= nowDay - 7 }),
        ]
        return order.compactMap { title, pred in
            let rows = sessions.filter { pred(Int(($0.lastActiveAt + tzOffset) / 86_400)) }.map { SessionRowMapper.make($0, now: now, tzOffset: tzOffset) }
            return rows.isEmpty ? nil : SessionGroup(title: title, rows: rows)
        }
    }
}


// MARK: - OrganizedFlat（M3-D-B：Tab 取代分区）

public struct OrganizedFlat: Equatable {
    public let pinned: [SessionRowModel]
    public let rest: [SessionRowModel]
    public init(pinned: [SessionRowModel], rest: [SessionRowModel]) {
        self.pinned = pinned; self.rest = rest
    }
}

public extension SessionListOrganizer {
    /// 平铺出口（tab 取代分区，无 section 标题）。
    /// U1（交互评审 P0-1）：未读 waiting「等你」pinned **跨 tab 常驻**——tab 过滤只作用于 rest。
    static func organizeFlat(
        sessions: [Session], tab: SessionTab, filter: String,
        now: Double, tzOffset: Double = 0
    ) -> OrganizedFlat {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let searched = sessions.filter { needle.isEmpty || matches($0, needle) }
        var pinnedS: [Session] = []
        var others: [Session] = []
        for s in searched {
            if isUnreadWaiting(s) { pinnedS.append(s) } else { others.append(s) }
        }
        let restFiltered = SessionTabFilter.filter(others, tab: tab)
        // pinned 稳定排序:收藏优先 + offset 兜底(与 rest 一致;Array.sort 非稳定,同 favorite
        // 值的多个等你行每次刷新可能换序致抖动——测试评审/架构评审)。
        let pinned = pinnedS.enumerated().sorted { a, b in
            if a.element.favorite != b.element.favorite { return a.element.favorite }
            return a.offset < b.offset
        }.map { SessionRowMapper.make($0.element, now: now, tzOffset: tzOffset) }
        let restSorted = restFiltered.enumerated().sorted { a, b in
            if a.element.favorite != b.element.favorite { return a.element.favorite }
            return a.offset < b.offset
        }.map { SessionRowMapper.make($0.element, now: now, tzOffset: tzOffset) }
        return OrganizedFlat(pinned: pinned, rest: restSorted)
    }
}
