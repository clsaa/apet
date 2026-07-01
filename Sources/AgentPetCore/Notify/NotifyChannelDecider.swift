/// 纯函数：在「基础通知决定」之上叠加横幅/声音两个独立开关（F1）。
///
/// 语义：横幅关 → 完全不发（用户不想要弹窗）；横幅开、声音关 → 静默横幅；两者皆开 → 有声横幅。
public enum NotifyChannelDecider {
    public static func decide(baseShouldNotify: Bool, bannerEnabled: Bool, soundEnabled: Bool)
        -> (post: Bool, withSound: Bool) {
        let post = baseShouldNotify && bannerEnabled
        return (post: post, withSound: post && soundEnabled)
    }
}
