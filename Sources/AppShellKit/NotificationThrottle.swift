import Foundation

/// Throttles notifications on a per-(key, kind) basis with cooldown.
/// Maintains a record of the last allowed time for each (key, kind) pair.
/// A new notification is allowed only if it's the first call OR enough time has passed (strictly greater than cooldown).
/// Blocked calls do NOT update the record, ensuring the timer is based on the first successful allow.
public struct NotificationThrottle {
    /// Map from "{key}|{kind}" to last-allowed Unix timestamp (Double, in seconds)
    private var lastAllowed: [String: Double] = [:]

    /// Initialize an empty throttle.
    public init() {}

    /// Check if a notification is allowed and update the throttle state.
    ///
    /// - Parameters:
    ///   - key: The session key (typically stringified SessionKey).
    ///   - kind: The notification kind (e.g., "attention", "stop").
    ///   - now: Current Unix timestamp in seconds (injected for testability).
    ///   - cooldown: Cooldown duration in seconds.
    ///
    /// - Returns: `true` if the notification is allowed (first call or cooldown elapsed);
    ///            `false` if within cooldown window. When `true`, updates the throttle state.
    ///            When `false`, the state remains unchanged (blocked call does NOT push timer forward).
    public mutating func allow(key: String, kind: String, now: Double, cooldown: Double) -> Bool {
        let pair = "\(key)|\(kind)"

        // Check if we have a record for this (key, kind) pair
        if let lastTime = lastAllowed[pair] {
            // We have a prior allow; check if cooldown has elapsed
            let elapsed = now - lastTime
            if elapsed > cooldown {
                // Cooldown has elapsed; allow and update
                lastAllowed[pair] = now
                return true
            } else {
                // Still within cooldown window; block without updating
                return false
            }
        } else {
            // First call for this (key, kind) pair; allow and record
            lastAllowed[pair] = now
            return true
        }
    }
}
