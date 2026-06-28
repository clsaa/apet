public enum SessionState: Equatable {
    case running
    case waiting(WaitingReason)
    case ended
    case stale
}

public struct Session: Equatable {
    public let key: SessionKey
    public var state: SessionState
    public var cwd: String?
    public var title: String?
    public var terminal: TerminalRef?
    public var lastSeq: Int
    public var lastActiveAt: Double   // 注入的 now（Unix 秒），用于 STALE 计时
    /// 进程内来源标记（不进 wire）。
    public var source: SessionSource
    /// "已读"标记：用户从面板点开一个 waiting（停下等你/完成）会话后置 true，圆点由红变黄。
    /// 会话重新变 running 时自动清除（见 SessionStore.applyInner）。仅进程内态，不进 wire。
    public var acknowledged: Bool

    public init(key: SessionKey, state: SessionState, cwd: String? = nil, title: String? = nil,
                terminal: TerminalRef? = nil, lastSeq: Int, lastActiveAt: Double,
                source: SessionSource = .hook, acknowledged: Bool = false) {
        self.key = key; self.state = state; self.cwd = cwd; self.title = title
        self.terminal = terminal; self.lastSeq = lastSeq; self.lastActiveAt = lastActiveAt
        self.source = source
        self.acknowledged = acknowledged
    }

    /// 多 profile 区分标签：从 root 派生。`~/.claude-profiles/work` → "work"；普通 `~/.claude` → nil。
    public var profileLabel: String? {
        let marker = ".claude-profiles/"
        guard let r = key.root.range(of: marker) else { return nil }
        let tail = key.root[r.upperBound...]
        return tail.split(separator: "/").first.map(String.init)
    }
}
