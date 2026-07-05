import Foundation

/// 面板展示文本消毒(标题/副标题):滤 C0/C1 控制字符与 bidi 覆写符(RTL 视觉伪装,
/// 如 `排查\u{202E}gpj.exe` 渲染成 `排查exe.jpg`),换行/Tab 拉平为空格。
/// 标题来源是**半可信输入**(Claude ai-title / codex thread_name 由模型从 prompt 生成,
/// prompt 可被恶意仓库内容污染)——一律在展示边界过一遍(测试评审 M4)。
public enum DisplaySanitizer {
    private static let bidi: Set<Character> = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                                               "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]
    public static func sanitize(_ s: String) -> String {
        String(s.map { c -> Character in
            (c == "\n" || c == "\r" || c == "\t") ? " " : c
        }).filter { c in
            guard let u = c.unicodeScalars.first else { return false }
            if u.value < 0x20 || (u.value >= 0x7F && u.value <= 0x9F) { return false }
            return !bidi.contains(c)
        }
    }
}
