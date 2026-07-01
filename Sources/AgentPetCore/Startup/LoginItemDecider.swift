import Foundation

/// 开机自启的一步动作。由期望态与当前注册态决定，纯值、无副作用。
public enum LoginItemAction: Equatable {
    case register
    case unregister
    case noop
}

/// 纯决策：想要开启但未注册 → register；想要关闭但已注册 → unregister；否则 noop。
public enum LoginItemDecider {
    public static func plan(desiredEnabled: Bool, currentlyRegistered: Bool) -> LoginItemAction {
        switch (desiredEnabled, currentlyRegistered) {
        case (true, false):  return .register
        case (false, true):  return .unregister
        default:             return .noop
        }
    }
}
