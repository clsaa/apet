import AgentPetCore

// MARK: - MenuBarCountsPresenter

/// 状态栏「彩色计数」样式：把 ``PetSummary`` 映射为一排彩点+数字（🟢2 🔴1 🟡3 ⚪1）。
///
/// 与悬浮宠物条（``PetPresenter``）**共用同一套桶**，杜绝两处不一致：
/// - 🟢 green         = `runningCount`（进行中）
/// - 🟠/🔴 done       = `waitingCount - acknowledgedCount`（停下等你/未读）；
///                     `attentionCount > 0`（emphasize）时为橙 🟠，否则红 🔴——与宠物条一致
/// - 🟡 yellow        = `acknowledgedCount`（已读）
/// - ⚪ gray          = `staleCount`（超时/结束）
///
/// 某状态计数为 0 时**不显示**该段；全 0 时回退 `🐾`。
public enum StatusCountColor: Equatable {
    case green, orange, red, yellow, gray

    /// 展示用彩点 emoji。
    public var dot: String {
        switch self {
        case .green:  return "🟢"
        case .orange: return "🟠"
        case .red:    return "🔴"
        case .yellow: return "🟡"
        case .gray:   return "⚪"
        }
    }
}

public struct StatusCountSegment: Equatable {
    public let color: StatusCountColor
    public let count: Int
    public init(color: StatusCountColor, count: Int) {
        self.color = color
        self.count = count
    }
}

public enum MenuBarCountsPresenter {

    /// 有序、非零的计数段（顺序：绿→橙/红→黄→灰）。全 0 时返回 `[]`。
    /// 复用 ``PetPresenter`` 的桶与 emphasize（橙/红）规则，确保与宠物条完全一致。
    public static func segments(from s: PetSummary) -> [StatusCountSegment] {
        let p = PetPresenter.make(from: s)
        let doneColor: StatusCountColor = p.emphasize ? .orange : .red
        let pairs: [(StatusCountColor, Int)] = [
            (.green,    p.runningCount),
            (doneColor, p.doneCount),
            (.yellow,   p.readCount),
            (.gray,     p.idleCount),
        ]
        return pairs
            .filter { $0.1 > 0 }
            .map { StatusCountSegment(color: $0.0, count: $0.1) }
    }

    /// 菜单栏标题文本，如 "🟢2 🔴1 🟡3 ⚪1"；全 0 时 "🐾"。
    public static func text(from s: PetSummary) -> String {
        let segs = segments(from: s)
        guard !segs.isEmpty else { return "🐾" }
        return segs.map { "\($0.color.dot)\($0.count)" }.joined(separator: " ")
    }
}
