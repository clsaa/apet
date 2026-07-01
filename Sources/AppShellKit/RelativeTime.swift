import Foundation

/// 纯函数：把 Unix 秒时间戳渲染为相对时间中文文案。`now` 注入，UTC 日跨午夜确定。
///
/// 分档：<60s「刚刚」· <1h「N 分钟前」· 同 UTC 日「N 小时前」· 昨日「昨天」· 更早「N 天前」。
public enum RelativeTime {
    public static func short(from ts: Double, now: Double) -> String {
        let diff = now - ts
        if diff < 0 { return "刚刚" }              // 未来时间当「刚刚」（时钟漂移兜底）
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }

        let dayNow = Int(now / 86_400)
        let dayTs  = Int(ts / 86_400)
        let dayDiff = dayNow - dayTs

        if dayDiff == 0 { return "\(Int(diff / 3600)) 小时前" }
        if dayDiff == 1 { return "昨天" }
        return "\(dayDiff) 天前"
    }
}
