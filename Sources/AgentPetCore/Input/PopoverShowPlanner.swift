/// popover 弹出后的重试决策纯状态机。
/// LSUIElement 背景 App 下 transient popover 锚到刚激活的非 key 窗口偶发吞首击；
/// 弹出后若未显示且仍有重试次数则 retry，已显示则 ok（绝不重复弹），次数耗尽 giveUp。
public enum PostOpenAction: Equatable { case ok; case retry; case giveUp }

public struct PopoverShowPlanner {
    public init() {}
    public func planAfterOpen(isShownNow: Bool, attempt: Int, maxAttempts: Int) -> PostOpenAction {
        if isShownNow { return .ok }
        return attempt < maxAttempts ? .retry : .giveUp
    }
}
