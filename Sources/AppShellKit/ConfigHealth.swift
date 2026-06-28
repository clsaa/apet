// ConfigHealth.swift
// 配置健康状态决策表（纯逻辑，无副作用，零外部依赖）

public enum NotificationStatus: Equatable {
    case authorized
    case denied
    case notDetermined
}

public enum HookStatus: Equatable {
    case installed(path: String)
    case notInstalled
    case failed(reason: String)
}

public enum JSONLSourceStatus: Equatable {
    case found(count: Int)
    case pathMissing
    case unreadable(path: String)
}

public enum OverallHealth: Equatable {
    case ready
    case readyEnhanced
    case degraded(reason: String)
}

public struct ConfigHealth: Equatable {
    public let notification: NotificationStatus
    public let hook: HookStatus
    public let jsonlSource: JSONLSourceStatus
    public let dataRoots: [String]

    public init(
        notification: NotificationStatus,
        hook: HookStatus,
        jsonlSource: JSONLSourceStatus,
        dataRoots: [String]
    ) {
        self.notification = notification
        self.hook = hook
        self.jsonlSource = jsonlSource
        self.dataRoots = dataRoots
    }

    /// 决策表（严格按 spec 顺序）：
    /// 1. jsonlSource 不可用 → degraded
    /// 2. 通知被拒 → degraded
    /// 3. hook 已安装 → readyEnhanced
    /// 4. 其余 → ready
    public var overall: OverallHealth {
        switch jsonlSource {
        case .pathMissing, .unreadable:
            return .degraded(reason: "jsonl 数据源不可用")
        case .found:
            if notification == .denied {
                return .degraded(reason: "通知被拒：完成提醒收不到")
            }
            if case .installed = hook {
                return .readyEnhanced
            }
            return .ready
        }
    }
}
