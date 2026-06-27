import XCTest
@testable import AppShellKit

final class NotificationThrottleTests: XCTestCase {

    // MARK: - Test 1: First call is always allowed

    func testFirstCallIsAllowed() {
        var throttle = NotificationThrottle()
        let result = throttle.allow(key: "session1", kind: "attention", now: 100.0, cooldown: 30.0)
        XCTAssertTrue(result, "first call should be allowed")
    }

    // MARK: - Test 2: Second call within cooldown is blocked

    func testSecondCallWithinCooldownIsBlocked() {
        var throttle = NotificationThrottle()
        _ = throttle.allow(key: "session1", kind: "attention", now: 100.0, cooldown: 30.0)

        let result = throttle.allow(key: "session1", kind: "attention", now: 110.0, cooldown: 30.0)
        XCTAssertFalse(result, "second call within cooldown should be blocked")
    }

    // MARK: - Test 3: Call after cooldown is allowed

    func testCallAfterCooldownIsAllowed() {
        var throttle = NotificationThrottle()
        _ = throttle.allow(key: "session1", kind: "attention", now: 100.0, cooldown: 30.0)

        let result = throttle.allow(key: "session1", kind: "attention", now: 131.0, cooldown: 30.0)
        XCTAssertTrue(result, "call after cooldown should be allowed (100 + 30 = 130, so 131 > 130)")
    }

    // MARK: - Test 4: Boundary test: now - last == cooldown → false (strictly greater required)

    func testBoundaryAtExactCooldown() {
        var throttle = NotificationThrottle()
        _ = throttle.allow(key: "session1", kind: "attention", now: 100.0, cooldown: 30.0)

        // Exactly at cooldown boundary: 100 + 30 = 130
        let result = throttle.allow(key: "session1", kind: "attention", now: 130.0, cooldown: 30.0)
        XCTAssertFalse(result, "at exact cooldown boundary (now - last == cooldown), should be blocked")
    }

    // MARK: - Test 5: Boundary test: now - last > cooldown → true (strictly greater)

    func testBoundaryAfterCooldown() {
        var throttle = NotificationThrottle()
        _ = throttle.allow(key: "session1", kind: "attention", now: 100.0, cooldown: 30.0)

        // Just after cooldown boundary: 100 + 30 = 130, call at 130.1
        let result = throttle.allow(key: "session1", kind: "attention", now: 130.1, cooldown: 30.0)
        XCTAssertTrue(result, "after cooldown boundary (now - last > cooldown), should be allowed")
    }

    // MARK: - Test 6: Different key is independent

    func testDifferentKeyIsIndependent() {
        var throttle = NotificationThrottle()
        _ = throttle.allow(key: "session1", kind: "attention", now: 100.0, cooldown: 30.0)

        // Different key should not be throttled
        let result = throttle.allow(key: "session2", kind: "attention", now: 110.0, cooldown: 30.0)
        XCTAssertTrue(result, "different key should be independent")
    }

    // MARK: - Test 7: Different kind is independent

    func testDifferentKindIsIndependent() {
        var throttle = NotificationThrottle()
        _ = throttle.allow(key: "session1", kind: "attention", now: 100.0, cooldown: 30.0)

        // Same key but different kind should not be throttled
        let result = throttle.allow(key: "session1", kind: "stop", now: 110.0, cooldown: 30.0)
        XCTAssertTrue(result, "different kind should be independent")
    }

    // MARK: - Test 8: Blocked call does NOT update the record (timer based on first allow)

    func testBlockedCallDoesNotUpdateRecord() {
        var throttle = NotificationThrottle()
        _ = throttle.allow(key: "session1", kind: "attention", now: 100.0, cooldown: 30.0)

        // Block at 110 (within 30s cooldown)
        let block1 = throttle.allow(key: "session1", kind: "attention", now: 110.0, cooldown: 30.0)
        XCTAssertFalse(block1, "first blocked call")

        // Next allowed should be based on original 100, not 110
        // 100 + 30 = 130, so 130.1 should be allowed
        let result = throttle.allow(key: "session1", kind: "attention", now: 130.1, cooldown: 30.0)
        XCTAssertTrue(result, "call after original cooldown should be allowed (timer based on first allow, not blocked attempt)")
    }

    // MARK: - Test 9: Blocked call at exactly cooldown boundary does NOT unlock the gate

    func testRepeatedBlockedCallsDoNotPushTimer() {
        var throttle = NotificationThrottle()
        _ = throttle.allow(key: "session1", kind: "attention", now: 100.0, cooldown: 30.0)

        // Multiple blocked calls at different times
        _ = throttle.allow(key: "session1", kind: "attention", now: 110.0, cooldown: 30.0)
        _ = throttle.allow(key: "session1", kind: "attention", now: 120.0, cooldown: 30.0)
        _ = throttle.allow(key: "session1", kind: "attention", now: 128.0, cooldown: 30.0)

        // Timer is still based on original 100.0, so 130.1 should be allowed
        let result = throttle.allow(key: "session1", kind: "attention", now: 130.1, cooldown: 30.0)
        XCTAssertTrue(result, "timer should be based on FIRST allowed call, not blocked attempts")
    }

    // MARK: - Test 10: Multiple (key, kind) pairs are independent

    func testMultiplePairsAreIndependent() {
        var throttle = NotificationThrottle()

        // Allow for (session1, attention)
        _ = throttle.allow(key: "session1", kind: "attention", now: 100.0, cooldown: 30.0)
        // Allow for (session1, stop)
        _ = throttle.allow(key: "session1", kind: "stop", now: 100.0, cooldown: 30.0)
        // Allow for (session2, attention)
        _ = throttle.allow(key: "session2", kind: "attention", now: 100.0, cooldown: 30.0)

        // All should be blocked at 110 (within 30s cooldown from each respective first call)
        let r1 = throttle.allow(key: "session1", kind: "attention", now: 110.0, cooldown: 30.0)
        let r2 = throttle.allow(key: "session1", kind: "stop", now: 110.0, cooldown: 30.0)
        let r3 = throttle.allow(key: "session2", kind: "attention", now: 110.0, cooldown: 30.0)

        XCTAssertFalse(r1)
        XCTAssertFalse(r2)
        XCTAssertFalse(r3)

        // All should be allowed at 131 (after 30s cooldown from each respective first call)
        let r1_allowed = throttle.allow(key: "session1", kind: "attention", now: 131.0, cooldown: 30.0)
        let r2_allowed = throttle.allow(key: "session1", kind: "stop", now: 131.0, cooldown: 30.0)
        let r3_allowed = throttle.allow(key: "session2", kind: "attention", now: 131.0, cooldown: 30.0)

        XCTAssertTrue(r1_allowed)
        XCTAssertTrue(r2_allowed)
        XCTAssertTrue(r3_allowed)
    }

    // MARK: - Test 11: After allowing, the second allow resets the timer

    func testSecondAllowResetsTimer() {
        var throttle = NotificationThrottle()

        // First allow at 100
        _ = throttle.allow(key: "session1", kind: "attention", now: 100.0, cooldown: 30.0)

        // Second allow at 131 (after cooldown)
        _ = throttle.allow(key: "session1", kind: "attention", now: 131.0, cooldown: 30.0)

        // Third call at 150 should be blocked (within 30s of second allow at 131: 131 + 30 = 161)
        let result = throttle.allow(key: "session1", kind: "attention", now: 150.0, cooldown: 30.0)
        XCTAssertFalse(result, "third call should be blocked (within cooldown of second allow)")
    }

    // MARK: - Test 12: Empty throttle (no prior calls)

    func testEmptyThrottle() {
        var throttle = NotificationThrottle()
        let result = throttle.allow(key: "new", kind: "event", now: 1000.0, cooldown: 60.0)
        XCTAssertTrue(result, "first call to any (key, kind) should be allowed")
    }
}
