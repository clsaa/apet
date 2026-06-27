public enum PetState: Equatable { case busy, calling, idle }

/// 富聚合快照：状态 + 各类计数，供 UI 一次性读取（面板 B1）。
public struct PetSummary: Equatable {
    public let state: PetState
    public let runningCount: Int
    public let waitingCount: Int
    public let attentionCount: Int
    public let staleCount: Int
    public var hasWaiting: Bool { waitingCount > 0 }
    public init(state: PetState, runningCount: Int, waitingCount: Int,
                attentionCount: Int, staleCount: Int) {
        self.state = state; self.runningCount = runningCount; self.waitingCount = waitingCount
        self.attentionCount = attentionCount; self.staleCount = staleCount
    }
}
