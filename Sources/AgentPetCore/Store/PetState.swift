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
    /// 角标计数：未读 waiting 数量（waiting - acknowledged），已读不再计入角标。
    public var badgeCount: Int { max(0, waitingCount - acknowledgedCount) }
    public init(state: PetState, runningCount: Int, waitingCount: Int,
                attentionCount: Int, staleCount: Int, acknowledgedCount: Int = 0) {
        self.state = state; self.runningCount = runningCount; self.waitingCount = waitingCount
        self.attentionCount = attentionCount; self.staleCount = staleCount
        self.acknowledgedCount = acknowledgedCount
    }
}
