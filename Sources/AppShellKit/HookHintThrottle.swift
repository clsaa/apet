import Foundation

/// Throttles "please install the hook" hints on a per-session basis with a global cap.
///
/// ### Semantics
/// - A given `sessionKey` is hinted **at most once** (the first call returns `true`;
///   every subsequent call for the same key returns `false`).
/// - The **total** number of hints across all keys is capped at `maxTotal`. Once that
///   cap is reached every call — including calls for brand-new keys — returns `false`.
///
/// ### Design notes
/// This is a pure value type (struct + mutating). It does **not** use `Date` or any
/// wall-clock input; throttling is based solely on identity (seen/unseen) and a counter.
public struct HookHintThrottle {

    // MARK: - Private state

    /// Keys for which a hint has already been shown.
    private var hinted: Set<String> = []

    /// Running total of hints delivered so far.
    private var totalCount: Int = 0

    /// Upper bound on lifetime hints.
    private let maxTotal: Int

    // MARK: - Init

    /// - Parameter maxTotal: Maximum number of distinct hints this throttle will ever allow.
    ///   Defaults to `3`. Pass `0` to suppress hints entirely.
    public init(maxTotal: Int = 3) {
        self.maxTotal = maxTotal
    }

    // MARK: - Public API

    /// Returns `true` if a hint should be shown for `sessionKey`, updating internal state.
    ///
    /// Returns `false` when:
    /// - `sessionKey` has already been hinted (per-key dedup), **or**
    /// - The global `maxTotal` cap has been reached.
    ///
    /// - Parameter sessionKey: An opaque string identifying the session (e.g. a stringified
    ///   `SessionKey`). Must be stable across the session's lifetime.
    /// - Returns: `true` on the first call for a new key while under the global cap;
    ///   `false` in all other cases.
    public mutating func shouldHint(sessionKey: String) -> Bool {
        // Guard 1: global cap
        guard totalCount < maxTotal else { return false }
        // Guard 2: per-key dedup
        guard !hinted.contains(sessionKey) else { return false }

        hinted.insert(sessionKey)
        totalCount += 1
        return true
    }
}
