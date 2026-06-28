import XCTest
@testable import AppShellKit

final class HookHintThrottleTests: XCTestCase {

    // MARK: - Test 1: Same key, first call → true

    func testSameKeyFirstCallIsTrue() {
        var throttle = HookHintThrottle()
        XCTAssertTrue(throttle.shouldHint(sessionKey: "session-A"),
                      "first call for a new key must be true")
    }

    // MARK: - Test 2: Same key, second call → false

    func testSameKeySecondCallIsFalse() {
        var throttle = HookHintThrottle()
        _ = throttle.shouldHint(sessionKey: "session-A")
        XCTAssertFalse(throttle.shouldHint(sessionKey: "session-A"),
                       "second call for the same key must be false")
    }

    // MARK: - Test 3: Same key, many repeated calls → always false after first

    func testSameKeyRepeatedCallsAlwaysFalse() {
        var throttle = HookHintThrottle(maxTotal: 99)
        _ = throttle.shouldHint(sessionKey: "key")
        for _ in 0..<5 {
            XCTAssertFalse(throttle.shouldHint(sessionKey: "key"),
                           "every subsequent call for the same key must be false")
        }
    }

    // MARK: - Test 4: Different keys each return true once (within maxTotal)

    func testDifferentKeysEachTrueOnceUpToMaxTotal() {
        var throttle = HookHintThrottle(maxTotal: 3)
        XCTAssertTrue(throttle.shouldHint(sessionKey: "A"), "key A first call")
        XCTAssertTrue(throttle.shouldHint(sessionKey: "B"), "key B first call")
        XCTAssertTrue(throttle.shouldHint(sessionKey: "C"), "key C first call")
        // maxTotal reached — new key must return false
        XCTAssertFalse(throttle.shouldHint(sessionKey: "D"),
                       "new key after maxTotal must be false")
    }

    // MARK: - Test 5: After maxTotal reached, new keys all return false

    func testAfterMaxTotalNewKeysReturnFalse() {
        var throttle = HookHintThrottle(maxTotal: 2)
        _ = throttle.shouldHint(sessionKey: "X")
        _ = throttle.shouldHint(sessionKey: "Y")
        XCTAssertFalse(throttle.shouldHint(sessionKey: "Z"),
                       "key Z after maxTotal=2 must be false")
        XCTAssertFalse(throttle.shouldHint(sessionKey: "W"),
                       "key W after maxTotal=2 must be false")
    }

    // MARK: - Test 6: Default maxTotal is 3

    func testDefaultMaxTotalIsThree() {
        var throttle = HookHintThrottle()
        XCTAssertTrue(throttle.shouldHint(sessionKey: "1"))   // count=1
        XCTAssertTrue(throttle.shouldHint(sessionKey: "2"))   // count=2
        XCTAssertTrue(throttle.shouldHint(sessionKey: "3"))   // count=3
        XCTAssertFalse(throttle.shouldHint(sessionKey: "4"),
                       "4th distinct key must be false with default maxTotal=3")
    }

    // MARK: - Test 7: Repeated call for already-seen key does NOT increment global count

    func testAlreadySeenKeyDoesNotConsumeQuota() {
        var throttle = HookHintThrottle(maxTotal: 2)
        XCTAssertTrue(throttle.shouldHint(sessionKey: "A"))   // count=1
        // Repeated call for A — should not count
        XCTAssertFalse(throttle.shouldHint(sessionKey: "A"))  // seen, false
        // Second distinct key — should still be within quota
        XCTAssertTrue(throttle.shouldHint(sessionKey: "B"))   // count=2
        // maxTotal reached
        XCTAssertFalse(throttle.shouldHint(sessionKey: "C"),
                       "C must be false: quota exhausted")
    }

    // MARK: - Test 8: maxTotal=0 → always false

    func testMaxTotalZeroAlwaysFalse() {
        var throttle = HookHintThrottle(maxTotal: 0)
        XCTAssertFalse(throttle.shouldHint(sessionKey: "any"),
                       "maxTotal=0 must always return false")
    }

    // MARK: - Test 9: maxTotal=1 → first new key true, all others false

    func testMaxTotalOne() {
        var throttle = HookHintThrottle(maxTotal: 1)
        XCTAssertTrue(throttle.shouldHint(sessionKey: "first"))
        XCTAssertFalse(throttle.shouldHint(sessionKey: "second"),
                       "second distinct key with maxTotal=1 must be false")
        XCTAssertFalse(throttle.shouldHint(sessionKey: "first"),
                       "re-call on first key must also be false")
    }
}
