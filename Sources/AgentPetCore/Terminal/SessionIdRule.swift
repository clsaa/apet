import Foundation

/// 会话 ID 白名单规则(防注入红线的共享表达;ResumeCommand 与 AgentManifest 共用)。
/// 校验失败 → 恢复命令渲染返回 nil。M4 JSON Schema 化预定按
/// {prefix, charset(封闭枚举), minLength/maxLength} 建模(开源评审:防单案例锁死),
/// 本枚举是其 Swift 先行形态。不用正则:避免 ReDoS 与转义面。
public enum SessionIdRule: Equatable {
    /// 严格 UUID(8-4-4-4-12,仅 ASCII hex——全角十六进制必须被拒,评审 m9 语料)。
    case uuid
    /// 前缀 + 定长 ASCII base62。`length` 指**前缀外**位数(opencode:"ses_"+26,全长 30)。
    /// 逐 Unicode 标量白名单:字素计数会被组合字符欺骗(é = e+U+0301)。
    case prefixedBase62(prefix: String, length: Int)

    public func validate(_ s: String) -> Bool {
        switch self {
        case .uuid:
            let groups = [8, 4, 4, 4, 12]
            let parts = s.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == groups.count else { return false }
            for (part, expected) in zip(parts, groups) {
                guard part.count == expected, part.allSatisfy({ c in
                    (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
                }) else { return false }
            }
            return true
        case .prefixedBase62(let prefix, let length):
            guard s.hasPrefix(prefix) else { return false }
            let body = s.dropFirst(prefix.count).unicodeScalars
            guard body.count == length else { return false }
            return body.allSatisfy { c in
                (c >= "0" && c <= "9") || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
            }
        }
    }
}
