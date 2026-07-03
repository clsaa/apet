import AppKit
import SwiftUI
import AppShellKit

// MARK: - OnboardingView

/// 精简两屏引导 SwiftUI View
private struct OnboardingView: View {

    /// 当用户点击"知道了，开始用"后回调，调用者负责关闭窗口并持久化标志
    let onDone: () -> Void

    @State private var page: Int = 0

    var body: some View {
        Group {
            if page == 0 {
                firstScreen
            } else {
                secondScreen
            }
        }
        .frame(width: 440, height: 320)
        .padding(32)
    }

    // MARK: - Screen 1: 菜单栏定位 + 隐私承诺

    private var firstScreen: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 标题 + 菜单栏指引
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("它在这 ↑")
                        .font(.title2.bold())
                    Text("AgentPet 常驻菜单栏，不占 Dock，随时可用。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // 隐私承诺
            VStack(alignment: .leading, spacing: 8) {
                Label("隐私承诺", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("""
                全程本地、零网络请求。
                只读取会话记录的元数据（时间/标题/目录）与每个会话头尾几行用于判断状态；
                不留存、不上传你的对话内容。
                """)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Spacer()
                Button("知道了，开始用") {
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])

                Button("了解更多 →") {
                    withAnimation { page = 1 }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Screen 2: 权限说明（延后 just-in-time）

    private var secondScreen: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("权限？用到时再说")
                        .font(.title2.bold())
                    Text("AgentPet 不会在启动时预先索要权限。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("""
            想要"完成通知"或"精确跳回终端 Tab"？
            当你第一次用到这些功能时，我再向你申请对应权限。
            不用就永远不问。
            """)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Button("← 返回") {
                    withAnimation { page = 0 }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Spacer()

                Button("知道了，开始用") {
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }
}

// MARK: - OnboardingWindowController

/// 托管 ``OnboardingView`` 的 NSWindow 控制器
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    private var hostingController: NSHostingController<OnboardingView>?
    /// 完成回调（Optional 实现幂等：按钮"知道了"与点 × 关窗都只触发一次）。
    private var completion: (() -> Void)?

    init(onComplete: @escaping () -> Void) {
        self.completion = onComplete
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "欢迎使用 AgentPet"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        // 按钮"知道了"也走同一幂等 complete()，与 × 关窗统一。
        let view = OnboardingView(onDone: { [weak self] in self?.complete() })
        let hc = NSHostingController(rootView: view)
        hostingController = hc
        window.contentViewController = hc
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 幂等完成：触发一次 completion 并关窗。按钮与 × 两条路径都汇聚于此（Task11 评审 Important）。
    private func complete() {
        guard let c = completion else { return }
        completion = nil
        c()
        window?.close()
    }

    /// 点 × 关窗也置首启标志，避免下次启动重复弹窗。
    func windowWillClose(_ notification: Notification) {
        complete()
    }
}

// MARK: - OnboardingWindow (静态入口)

/// 首启引导窗口入口
///
/// 提供两个静态工厂方法：
/// - ``showIfFirstRun(onboardingShown:onDone:)``：根据 `OnboardingGate.shouldShow` 决定是否弹窗
/// - ``show(onDone:)``：无条件弹窗（首选项"重跑向导"入口）
@MainActor
enum OnboardingWindow {

    // 强持有控制器，防止 ARC 过早释放
    private static var controller: OnboardingWindowController?

    /// 首启检测：仅当 `onboardingShown == false` 时弹出引导窗。
    ///
    /// - Parameters:
    ///   - onboardingShown: 从 `UserDefaults` 读取的"已展示"标志。
    ///   - onDone: 用户点击"知道了"后的回调（典型用法：将 `UserDefaults` 标志置 true 并关闭窗口）。
    static func showIfFirstRun(onboardingShown: Bool, onDone: @escaping () -> Void) {
        guard OnboardingGate.shouldShow(onboardingShown: onboardingShown) else { return }
        show(onDone: onDone)
    }

    /// 无条件弹出引导窗（供"重跑向导"入口调用）。
    ///
    /// - Parameter onDone: 用户点击"知道了"后的回调。
    static func show(onDone: @escaping () -> Void) {
        // onComplete 由控制器在按钮/× 任一路径幂等触发一次；这里只负责释放强引用 + 转发 onDone。
        let wc = OnboardingWindowController {
            OnboardingWindow.controller = nil
            onDone()
        }
        controller = wc
        wc.show()
    }
}
