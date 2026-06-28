import Foundation
import AgentPetCore

/// 通知点击的纯决策：从 userInfo 解析 SessionKey，输出"先标已读再聚焦"动作序列。
/// 放 AppShellKit 而非 apet，使其可单测（apet 无测试 target、UNNotificationResponse 不可构造）。
public enum SessionAction: Equatable {
    case acknowledge(SessionKey)
    case focus(SessionKey)
}

public enum NotificationClickResolver {
    /// 接收 `[AnyHashable: Any]`（UNNotification.userInfo 的真实类型），内部按 String 键取值——
    /// 把"`[AnyHashable:Any]→[String:Any]` 转型"这一步纳入可测范围（架构评审 M-1）。
    public static func resolve(userInfo: [AnyHashable: Any]) -> [SessionAction] {
        guard let agent = userInfo["agent"] as? String,
              let root = userInfo["root"] as? String,
              let sessionId = userInfo["sessionId"] as? String else { return [] }
        let key = SessionKey(agent: agent, root: root, sessionId: sessionId)
        return [.acknowledge(key), .focus(key)]
    }
}
