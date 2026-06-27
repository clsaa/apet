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

    public init(key: SessionKey, state: SessionState, cwd: String? = nil, title: String? = nil,
                terminal: TerminalRef? = nil, lastSeq: Int, lastActiveAt: Double) {
        self.key = key; self.state = state; self.cwd = cwd; self.title = title
        self.terminal = terminal; self.lastSeq = lastSeq; self.lastActiveAt = lastActiveAt
    }
}
