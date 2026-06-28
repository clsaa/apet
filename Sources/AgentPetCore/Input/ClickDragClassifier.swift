import CoreGraphics

/// 点击/拖动判定的纯逻辑。`DragDetectorView` 采集鼠标移动的最大位移后调用本函数，
/// 自身不持有任何 GUI/可变状态，便于单测覆盖抖动/微移/拖动边界。
public enum Gesture: Equatable { case click; case drag }

public enum ClickDragClassifier {
    /// 任一轴的最大绝对位移达到 `threshold` 即判为拖动；否则点击。
    public static func classify(maxAbsDx: CGFloat, maxAbsDy: CGFloat, threshold: CGFloat) -> Gesture {
        (maxAbsDx >= threshold || maxAbsDy >= threshold) ? .drag : .click
    }
}
