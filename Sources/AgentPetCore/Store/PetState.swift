public enum PetState: Equatable { case busy, calling, idle }

/// 富聚合快照：状态 + 各类计数，供 UI 一次性读取（面板 B1）。
public struct PetSummary: Equatable {
    public let state: PetState
    public let runningCount: Int
    public let waitingCount: Int
    public let attentionCount: Int
    public let staleCount: Int
    /// "已读"会话数：waiting 态且 acknowledged==true（stop/attention 都算）。红→黄态。
    public let acknowledgedCount: Int
    public var hasWaiting: Bool { waitingCount > 0 }
    /// 角标计数：优先 attention（紧急），否则 waiting。语义="最需要用户关注的数量"。
    public var badgeCount: Int { attentionCount > 0 ? attentionCount : waitingCount }
    public init(state: PetState, runningCount: Int, waitingCount: Int,
                attentionCount: Int, staleCount: Int, acknowledgedCount: Int = 0) {
        self.state = state; self.runningCount = runningCount; self.waitingCount = waitingCount
        self.attentionCount = attentionCount; self.staleCount = staleCount
        self.acknowledgedCount = acknowledgedCount
    }
}
