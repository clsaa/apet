import AppKit

/// 瞬时「已复制」反馈(交互评审 B3/P1-3:复制类动作此前完全静默,用户不知是否成功)。
/// 屏幕中心一个自动消失的小 HUD,~0.9s 后淡出。@MainActor。
enum CopyHUD {
    private static var window: NSWindow?

    /// 任意线程可调:内部切主线程建 HUD。
    static func flash(_ text: String = "已复制") {
        DispatchQueue.main.async { renderFlash(text) }
    }

    @MainActor
    private static func renderFlash(_ text: String) {
        window?.close()

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let padding: CGFloat = 16
        let w = max(120, label.frame.width + padding * 2)
        let h = label.frame.height + padding

        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        content.material = .hudWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        label.frame = NSRect(x: 0, y: (h - label.frame.height) / 2, width: w, height: label.frame.height)
        content.addSubview(label)

        let win = NSPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.ignoresMouseEvents = true
        win.contentView = content
        win.hasShadow = true

        // 定位在鼠标所在屏的顶部居中偏下(靠近菜单栏/面板操作点,而非主屏正中——交互评审)。
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            win.setFrameOrigin(NSPoint(x: vf.midX - w / 2, y: vf.maxY - h - 48))
        }
        win.alphaValue = 0
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            win.animator().alphaValue = 1
        }
        window = win

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak win] in
            guard let win, win == window else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                win.animator().alphaValue = 0
            }, completionHandler: {
                win.close()
                if window == win { window = nil }
            })
        }
    }
}
