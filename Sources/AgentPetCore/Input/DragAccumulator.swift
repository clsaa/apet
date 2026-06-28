/// 拖动过程中两轴最大绝对位移的累积器（纯逻辑，可单测）。
///
/// B2 的真正修复点：旧实现用 sticky 布尔，新实现累积**每次移动**的最大绝对位移，
/// 从而正确处理"拖出去又拖回原点"（净位移为 0 但 maxAbs 仍大 → 判 drag）。
/// `DragDetectorView` 仅做事件采集，判定逻辑全在此处。
public struct DragAccumulator {
    public private(set) var maxAbsDx: Double = 0
    public private(set) var maxAbsDy: Double = 0

    public init() {}

    public mutating func reset() {
        maxAbsDx = 0
        maxAbsDy = 0
    }

    public mutating func accumulate(dx: Double, dy: Double) {
        maxAbsDx = max(maxAbsDx, abs(dx))
        maxAbsDy = max(maxAbsDy, abs(dy))
    }

    public func gesture(threshold: Double) -> Gesture {
        ClickDragClassifier.classify(maxAbsDx: maxAbsDx, maxAbsDy: maxAbsDy, threshold: threshold)
    }
}
