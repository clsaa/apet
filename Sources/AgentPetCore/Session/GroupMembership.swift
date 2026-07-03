import Foundation

/// 自定义分组成员操作 + 组名校验(纯函数,M3-D-C)。
public enum GroupMembership {
    /// 有则移除、无则追加(去重)。
    public static func toggle(_ group: String, in groups: [String]) -> [String] {
        if groups.contains(group) { return groups.filter { $0 != group } }
        return groups + [group]
    }
    /// 组名合法:trim 非空、≤30 字符、无控制字符/bidi(防注入/UI 破坏)。
    public static func isValidName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 30 else { return false }
        let bidi: Set<Character> = ["\u{202A}","\u{202B}","\u{202C}","\u{202D}","\u{202E}",
                                    "\u{2066}","\u{2067}","\u{2068}","\u{2069}"]
        return !t.contains { c in
            guard let u = c.unicodeScalars.first else { return true }
            if u.value < 0x20 || (u.value >= 0x7F && u.value <= 0x9F) { return true }
            return bidi.contains(c)
        }
    }
}
