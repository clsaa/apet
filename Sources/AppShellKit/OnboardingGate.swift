// OnboardingGate.swift
// 首启谓词：仅当 Onboarding 尚未展示过时返回 true

public enum OnboardingGate {
    /// 返回是否应展示 Onboarding 界面。
    /// - Parameter onboardingShown: 历史是否已展示过（通常持久化在 UserDefaults）
    /// - Returns: `true` = 首次启动，应展示；`false` = 已展示，跳过
    public static func shouldShow(onboardingShown: Bool) -> Bool {
        !onboardingShown
    }
}
