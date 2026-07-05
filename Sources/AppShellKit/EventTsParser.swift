import Foundation

/// 事件 `ts`(ISO8601 字符串)→ epoch 秒。**仅用于重放老化**,排序唯一事实仍是 seq(硬约束 3)。
///
/// 背景:重放 events.ndjson 时如果给每条历史事件传「启动时刻」当 now,所有旧会话的
/// lastActiveAt 都被刷新 → stale/ended/清理计时器每次重启归零 → 几天前的会话永不老化。
/// 重放必须用事件自己的 ts;live 路径仍用真实 now(事件刚发生,一致)。
public enum EventTsParser {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 解析失败 / 时间在未来(时钟漂移·不可信输入)→ 回退 fallback(通常=启动时刻)。
    public static func epoch(_ ts: String, fallback: Double) -> Double {
        let parsed = iso.date(from: ts)?.timeIntervalSince1970
            ?? isoNoFrac.date(from: ts)?.timeIntervalSince1970
        guard let p = parsed, p <= fallback else { return fallback }
        return p
    }
}
