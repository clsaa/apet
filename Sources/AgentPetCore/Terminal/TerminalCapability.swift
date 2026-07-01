import Foundation

/// 某终端「能被定位到多精确」的能力分级。是决定聚焦策略与 UI 降级提示的单一事实源，
/// 由 `TerminalFocusPlanner`（决定 osascript vs activate）与 `SessionRowModel`（决定是否显
/// 「仅激活应用」提示）共同消费，杜绝两处各判各的分歧。
public enum TerminalCapability: Equatable {
    /// 能选中具体 tab（iTerm2：session id → 精确到 tab）。
    case preciseTab
    /// 能选中窗口但不到 tab（Terminal.app：tty → 选中所在窗口/标签）。
    case preciseWindow
    /// 仅能激活应用，无窗口/tab 级定位（Warp / Ghostty / 未知终端）。
    case activateOnly
    /// 仅能激活应用，且需用户手动切到对应标签页（VSCode/Cursor 内置终端）。
    case activateOnlyManualTab

    /// `true` 表示无法做窗口/tab 级精确跳转——UI 应提示「仅激活应用」。
    public var isActivateOnly: Bool {
        switch self {
        case .preciseTab, .preciseWindow: return false
        case .activateOnly, .activateOnlyManualTab: return true
        }
    }

    /// `true` 表示激活应用后还需用户手动找 tab——UI 额外提示。
    public var needsManualTabHint: Bool {
        self == .activateOnlyManualTab
    }
}

/// 纯函数：`TerminalKind` → `TerminalCapability`。
public enum TerminalCapabilities {
    public static func capability(for kind: TerminalKind) -> TerminalCapability {
        switch kind {
        case .iterm2:   return .preciseTab
        case .terminal: return .preciseWindow
        case .warp:     return .activateOnly
        case .other:    return .activateOnly
        }
    }
}
