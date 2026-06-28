import Foundation

public enum MenuCommand: Equatable {
    case sessionSummary, preferences, about, quit
}

public struct MenuRow: Equatable {
    public let title: String
    public let command: MenuCommand
    public let enabled: Bool
    public let shortcut: String?

    public init(title: String, command: MenuCommand, enabled: Bool, shortcut: String?) {
        self.title = title
        self.command = command
        self.enabled = enabled
        self.shortcut = shortcut
    }
}

public enum MenuBarMenuModel {
    public static func rows(runningCount: Int, waitingCount: Int) -> [MenuRow] {
        let summary = (runningCount == 0 && waitingCount == 0)
            ? "暂无活跃会话" : "\(runningCount) 进行中 · \(waitingCount) 等待中"
        return [
            MenuRow(title: summary, command: .sessionSummary, enabled: false, shortcut: nil),
            MenuRow(title: "首选项…", command: .preferences, enabled: true, shortcut: ","),
            MenuRow(title: "关于 apet", command: .about, enabled: true, shortcut: nil),
            MenuRow(title: "退出 apet", command: .quit, enabled: true, shortcut: "q"),
        ]
    }
}
