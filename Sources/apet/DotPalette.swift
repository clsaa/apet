import SwiftUI
import AppShellKit

/// 5 状态圆点的解析后 SwiftUI 颜色（F3 自定义色）。由 `StateColorConfig`（hex）解析而来，
/// 解析失败的分量回退系统默认。菜单栏彩色计数用 emoji（固定色），不受此影响。
struct DotPalette {
    let running: Color
    let attention: Color
    let doneWaiting: Color
    let read: Color
    let stale: Color

    /// 系统默认（与 `StateColorConfig.defaults` 对应）。
    static let system = DotPalette(
        running: .green, attention: .orange, doneWaiting: .red, read: .yellow, stale: .gray
    )

    /// 从配置解析；某状态 hex 非法/缺失 → 用系统默认对应色。
    init(from config: StateColorConfig) {
        running     = DotPalette.color(config.running,     fallback: .green)
        attention   = DotPalette.color(config.attention,   fallback: .orange)
        doneWaiting = DotPalette.color(config.doneWaiting,  fallback: .red)
        read        = DotPalette.color(config.read,         fallback: .yellow)
        stale       = DotPalette.color(config.stale,        fallback: .gray)
    }

    private init(running: Color, attention: Color, doneWaiting: Color, read: Color, stale: Color) {
        self.running = running; self.attention = attention; self.doneWaiting = doneWaiting
        self.read = read; self.stale = stale
    }

    private static func color(_ hex: String?, fallback: Color) -> Color {
        guard let hex, let rgba = HexColor.parse(hex) else { return fallback }
        return Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    /// 供 `SessionRowModel.Dot` 取色。
    func color(for dot: Dot) -> Color {
        switch dot {
        case .running:     return running
        case .attention:   return attention
        case .doneWaiting: return doneWaiting
        case .read:        return read
        case .stale:       return stale
        }
    }
}
