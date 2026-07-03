import Foundation

/// 面板副标题路径折叠(M3-D-E1):home→`~`;仍超 maxLen → `…/<父>/<叶>`(纯函数)。
public enum PathAbbreviator {
    public static func abbreviate(_ path: String, home: String, maxLen: Int = 32) -> String {
        guard !path.isEmpty else { return "" }
        var p = path
        if !home.isEmpty, p == home || p.hasPrefix(home + "/") {
            p = "~" + p.dropFirst(home.count)
        }
        if p.count <= maxLen { return p }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return p }
        let leaf = parts[parts.count - 1], parent = parts[parts.count - 2]
        return "…/\(parent)/\(leaf)"
    }
}
