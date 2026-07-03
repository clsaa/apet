import Foundation

/// 面板顶部标签页(取代分区,M3-D-B)。group 为自定义分组名。
public enum SessionTab: Equatable {
    case all, favorites, running, read
    case group(String)

    /// config 持久化编码。group 用 "group:" 前缀(名内允许冒号,只切首个前缀)。
    public var encoded: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .running: return "running"
        case .read: return "read"
        case .group(let n): return "group:" + n
        }
    }
    public init(encoded: String) {
        switch encoded {
        case "all": self = .all
        case "favorites": self = .favorites
        case "running": self = .running
        case "read": self = .read
        default:
            if encoded.hasPrefix("group:") { self = .group(String(encoded.dropFirst("group:".count))) }
            else { self = .all }
        }
    }
}

public enum SessionTabFilter {
    public static func filter(_ sessions: [Session], tab: SessionTab) -> [Session] {
        switch tab {
        case .all: return sessions
        case .favorites: return sessions.filter { $0.favorite }
        case .running: return sessions.filter { if case .running = $0.state { return true }; return false }
        case .read: return sessions.filter {
            guard case .waiting = $0.state else { return false }
            return $0.acknowledged
        }
        case .group(let name): return sessions.filter { $0.groups.contains(name) }
        }
    }
}
