import XCTest
@testable import AppShellKit

/// 纯函数 `RelativeTime.short(from:now:)`：相对时间文案，now 注入，UTC 日跨午夜确定性。
final class RelativeTimeTests: XCTestCase {

    // 基准 now：第 100 UTC 日 + 12:00（正午），远离午夜，便于「同日 X 小时前」。
    private let now = 86_400.0 * 100 + 43_200

    func test_justNow_under60s() {
        XCTAssertEqual(RelativeTime.short(from: now - 30, now: now), "刚刚")
    }

    func test_minutesAgo() {
        XCTAssertEqual(RelativeTime.short(from: now - 300, now: now), "5 分钟前")
    }

    func test_hoursAgo_sameDay() {
        XCTAssertEqual(RelativeTime.short(from: now - 3600 * 3, now: now), "3 小时前")
    }

    func test_yesterday() {
        // 昨天正午（UTC 日差 1）
        XCTAssertEqual(RelativeTime.short(from: now - 86_400, now: now), "昨天")
    }

    func test_daysAgo() {
        XCTAssertEqual(RelativeTime.short(from: now - 86_400 * 5, now: now), "5 天前")
    }

    // 跨午夜（分钟档）：3 分钟前即使跨 UTC 日，仍应显「3 分钟前」——近期以 recency 为准。
    func test_crossMidnight_minutesRange_staysMinutes() {
        let midnight = 86_400.0 * 100
        let n = midnight + 60              // 00:01
        let ts = midnight - 120            // 前一日 23:58（3 分钟前）
        XCTAssertEqual(RelativeTime.short(from: ts, now: n), "3 分钟前")
    }

    // 跨午夜（小时档）：2 小时前且跨 UTC 日 → 「昨天」（小时档才受日界影响）。
    func test_crossMidnight_hoursRange_isYesterday() {
        let midnight = 86_400.0 * 100
        let n = midnight + 1800            // 00:30
        let ts = midnight - 5400           // 前一日 22:30（2 小时前）
        XCTAssertEqual(RelativeTime.short(from: ts, now: n), "昨天")
    }

    // 时区注入（评审修复：UTC 日界对东八区每天 0:00-8:00 错位）。
    // 场景：本地 UTC+8 上午 09:00 看 2 小时前（本地 07:00）的会话——两时刻同一本地日、
    // 但跨 UTC 午夜（UTC 23:00 前日 vs 01:00 当日）。本地日界应显「2 小时前」；UTC 日界误判「昨天」。
    func test_tzOffset_localSameDay_staysHours() {
        let tz = 8.0 * 3600
        let utcDayStart = 86_400.0 * 100
        let n = utcDayStart + 3600           // UTC 01:00 = 本地 09:00
        let ts = n - 2 * 3600                // UTC 前日 23:00 = 本地 07:00（同本地日）
        XCTAssertEqual(RelativeTime.short(from: ts, now: n, tzOffset: tz), "2 小时前")
        // 对照：不注入时区（UTC 日界）会误判「昨天」——这正是要修的错位
        XCTAssertEqual(RelativeTime.short(from: ts, now: n), "昨天")
    }

    // 本地日界正确翻页：本地昨天 23:00 的会话，在本地今天 06:00 看 → 「昨天」。
    func test_tzOffset_localYesterday() {
        let tz = 8.0 * 3600
        let localMidnight = 86_400.0 * 100 - tz   // 本地第 100 日 00:00 的 UTC 时刻
        let n = localMidnight + 6 * 3600          // 本地 06:00
        let ts = localMidnight - 3600             // 本地前一日 23:00（7 小时前）
        XCTAssertEqual(RelativeTime.short(from: ts, now: n, tzOffset: tz), "昨天")
    }
}
