import Foundation

/// 纯函数：把 Unix 秒时间戳渲染为相对时间中文文案。`now`/`tzOffset` 注入（不读 Date()/TimeZone）。
///
/// 分档：<60s「刚刚」· <1h「N 分钟前」· 同本地日「N 小时前」· 昨日「昨天」· 更早「N 天前」。
/// `tzOffset`（秒）由 IO 边界注入 `TimeZone.current.secondsFromGMT()`——UTC 日界会让
/// 东八区用户每天 0:00–8:00 的「今天/昨天」错位（评审修复，三视角确认）。
public enum RelativeTime {
    public static func short(from ts: Double, now: Double, tzOffset: Double = 0) -> String {
        let diff = now - ts
        if diff < 0 { return "刚刚" }              // 未来时间当「刚刚」（时钟漂移兜底）
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }

        let dayNow = Int((now + tzOffset) / 86_400)
        let dayTs  = Int((ts + tzOffset) / 86_400)
        let dayDiff = dayNow - dayTs

        if dayDiff == 0 { return "\(Int(diff / 3600)) 小时前" }
        if dayDiff == 1 { return "昨天" }
        return "\(dayDiff) 天前"
    }
}
