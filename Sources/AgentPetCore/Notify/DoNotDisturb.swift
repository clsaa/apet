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

    /// Pure function: returns `true` when the notification should be suppressed.
    ///
    /// Extracted as a static method so it can be unit-tested without touching system state
    /// (`Date()` is never called here; the caller supplies `nowMinOfDay`).
    public static func shouldSuppress(dnd: DNDWindow, nowMinOfDay: Int) -> Bool {
        dnd.isQuiet(nowMinOfDay: nowMinOfDay)
    }
}
