import Foundation

public struct DNDWindow: Equatable {
    public var enabled: Bool
    public var startMin: Int
    public var endMin: Int

    public init(enabled: Bool, startMin: Int, endMin: Int) {
        self.enabled = enabled
        self.startMin = startMin
        self.endMin = endMin
    }

    public func isQuiet(nowMinOfDay: Int) -> Bool {
        guard enabled else { return false }
        if startMin == endMin { return false }
        if startMin < endMin {
            return nowMinOfDay >= startMin && nowMinOfDay < endMin
        }
        return nowMinOfDay >= startMin || nowMinOfDay < endMin
    }
}
