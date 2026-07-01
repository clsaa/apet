import Foundation
import AgentPetCore

// MARK: - FocusAction

/// 终端聚焦决策结果（纯数据，无副作用）。由 ``TerminalFocusPlanner/plan(for:)`` 生成，
/// 由 `TerminalFocusService`（apet 可执行目标）执行。
public enum FocusAction: Equatable {
    /// 通过 osascript 精确跳转（iTerm2 session id 可用时）。
    case osascript(ScriptInvocation)
    /// 激活指定 bundleId 的 App（其它终端或 iTerm2 fallback）。
    case activateBundle(String)
    /// 无法聚焦（ref 为 nil 或 .other 且无 bundleId）。
    case unsupported
}

// MARK: - TerminalFocusPlanner

/// 纯函数：根据 ``TerminalRef`` 决定聚焦策略（``FocusAction``）。
/// 不依赖任何系统副作用，可在测试中直接断言。
public enum TerminalFocusPlanner {

    /// 根据 `ref` 返回聚焦动作。
    ///
    /// - `nil` → `.unsupported`
    /// - `.iterm2` + 有效 `itermSessionId` → `.osascript(<ITerm2Locator 生成的 ScriptInvocation>)`
    /// - `.iterm2` + 无效/缺失 `itermSessionId` → `.activateBundle(bundleId ?? "com.googlecode.iterm2")`
    /// - `.terminal` → `.activateBundle(bundleId ?? "com.apple.Terminal")`
    /// - `.warp` → `.activateBundle(bundleId ?? "dev.warp.Warp")`
    /// - `.other` + 有 bundleId → `.activateBundle(bundleId)`
    /// - `.other` + 无 bundleId → `.unsupported`
    public static func plan(for ref: TerminalRef?) -> FocusAction {
        guard let ref else { return .unsupported }

        switch ref.kind {
        case .iterm2:
            do {
                let inv = try ITerm2Locator().focusInvocation(for: ref)
                return .osascript(inv)
            } catch {
                // itermSessionId 缺失或非法 → activate-only 兜底
                return .activateBundle(ref.bundleId ?? "com.googlecode.iterm2")
            }

        case .terminal:
            // 有合法 tty → 窗口级 osascript；否则激活应用兜底。
            if let tty = ref.tty, TTYPath.isValid(tty) {
                do {
                    let inv = try TerminalAppLocator().focusInvocation(for: ref)
                    return .osascript(inv)
                } catch {
                    return .activateBundle(ref.bundleId ?? "com.apple.Terminal")
                }
            }
            return .activateBundle(ref.bundleId ?? "com.apple.Terminal")

        case .warp:
            // 稳定版 Warp 的 bundle id 是 dev.warp.Warp-Stable（非 dev.warp.Warp）。
            return .activateBundle(ref.bundleId ?? "dev.warp.Warp-Stable")

        case .ghostty:
            return .activateBundle(ref.bundleId ?? "com.mitchellh.ghostty")

        case .vscode:
            // VSCode/Cursor 内置终端：仅激活应用，需用户手动切 tab（能力分级 activateOnlyManualTab）
            return .activateBundle(ref.bundleId ?? "com.microsoft.VSCode")

        case .other:
            if let bundleId = ref.bundleId {
                return .activateBundle(bundleId)
            }
            return .unsupported
        }
    }
}
