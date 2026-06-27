public enum NotifyMode { case attentionOnly, everyStop }

public struct NotificationContent: Equatable {
    public let title: String
    public let body: String
    public init(title: String, body: String) { self.title = title; self.body = body }
}

public struct NotificationDecision: Equatable {
    public let shouldNotify: Bool
    public let content: NotificationContent?
    public init(shouldNotify: Bool, content: NotificationContent? = nil) {
        self.shouldNotify = shouldNotify; self.content = content
    }
}

public enum NotificationDecider {
    public static func decide(event: AgentEvent, session: Session?,
                              mode: NotifyMode, replay: Bool) -> NotificationDecision {
        if replay { return NotificationDecision(shouldNotify: false) }

        // 显式 notify 覆盖优先
        if let n = event.notify {
            switch n {
            case .none:    return NotificationDecision(shouldNotify: false)
            case .alert:   return ring(event, session, "")
            case .passive: break  // passive 走默认分类逻辑
            }
        }

        switch event.kind {
        case .attention:
            return ring(event, session, "需要你输入")
        case .stop:
            return mode == .everyStop ? ring(event, session, "本轮已完成") : NotificationDecision(shouldNotify: false)
        case .pluginError:
            return ring(event, session, event.message ?? "插件错误")
        case .sessionStart, .busy, .sessionEnd, .unknown:
            return NotificationDecision(shouldNotify: false)
        }
    }

    private static func ring(_ event: AgentEvent, _ session: Session?, _ defaultBody: String) -> NotificationDecision {
        let title = event.title ?? session?.title ?? event.agent
        let body = defaultBody.isEmpty ? (event.title ?? "需要你关注") : defaultBody
        return NotificationDecision(shouldNotify: true,
                                    content: NotificationContent(title: title, body: body))
    }
}
