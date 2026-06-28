import Foundation
import AgentPetCore

/// 通知点击的纯决策：从 userInfo 解析 SessionKey，输出"先标已读再聚焦"动作序列。
/// 放 AppShellKit 而非 apet，使其可单测（apet 无测试 target、UNNotificationResponse 不可构造）。
public enum SessionAction: Equatable {
    case acknowledge(SessionKey)
    case focus(SessionKey)
}

public enum NotificationClickResolver {
    public static func resolve(userInfo: [String: Any]) -> [SessionAction] {
        guard let agent = userInfo["agent"] as? String,
              let root = userInfo["root"] as? String,
              let sessionId = userInfo["sessionId"] as? String else { return [] }
        let key = SessionKey(agent: agent, root: root, sessionId: sessionId)
        return [.acknowledge(key), .focus(key)]
    }
}
