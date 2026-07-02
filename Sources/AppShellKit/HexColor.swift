import Foundation

/// 纯函数：十六进制颜色串解析为 RGBA（各分量 0...1）。视图层据此构造 SwiftUI Color。
/// 支持 `#RGB` / `#RRGGBB` / `#RRGGBBAA`，可带或不带 `#`、大小写、首尾空格。非法 → nil。
public enum HexColor {
    public struct RGBA: Equatable {
        public let r, g, b, a: Double
        public init(r: Double, g: Double, b: Double, a: Double) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
    }

    public static func parse(_ raw: String) -> RGBA? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        // 仅 ASCII hex（评审修复 测试 m9：isHexDigit 接受全角"数字"，会被静默解析成黑色）。
        guard s.allSatisfy({ c in (c >= "0" && c <= "9") || (c >= "a" && c <= "f") }) else { return nil }

        let hex: String
        switch s.count {
        case 3: // RGB → RRGGBB
            hex = s.map { "\($0)\($0)" }.joined() + "ff"
        case 6:
            hex = s + "ff"
        case 8:
            hex = s
        default:
            return nil
        }

        func comp(_ start: Int) -> Double {
            let i = hex.index(hex.startIndex, offsetBy: start)
            let j = hex.index(i, offsetBy: 2)
            return Double(UInt8(hex[i..<j], radix: 16) ?? 0) / 255.0
        }
        return RGBA(r: comp(0), g: comp(2), b: comp(4), a: comp(6))
    }
}
