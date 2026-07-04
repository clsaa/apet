import AppKit

/// 可缩放会话面板窗口(M3-D-F:取代 NSPopover,用户拖拽改大小,尺寸持久化)。
/// borderless-titled 浮窗:无标题栏视觉、可 key、失焦自隐(近似 popover transient)。
final class PanelResizeWindow: NSWindow, NSWindowDelegate {
    /// 用户拖拽 resize/move 后回调完整 frame(去抖持久化位置+尺寸)。
    var onFrameChange: ((NSRect) -> Void)?
    private var frameDebounce: DispatchWorkItem?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        delegate = self
    }

    // borderless-ish 浮窗需显式声明可 key,否则输入框/按钮拿不到焦点。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }
    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }

    private func scheduleFrameSave() {
        let f = frame
        frameDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onFrameChange?(f) }
        frameDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
