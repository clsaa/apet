import AppKit
import SwiftUI
import AgentPetCore
import AppShellKit

// MARK: - PanelRootView

/// Wraps ``SessionPanel`` with action footer buttons. Private to this file.
private struct PanelRootView: View {
    let sessions: [Session]
    let now: Double
    let palette: DotPalette
    let petVisible: Bool
    /// Fix 6: whether the hook is already installed for any data root.
    /// When `true`, the panel surfaces "已启用" instead of the call-to-action button.
    let hookInstalled: Bool
    /// 面板顶部快捷键提示，如 "⌥⌘P 打开/关闭"。
    let hotkeyHint: String?
    let onTap: (String) -> Void
    let onToggleFavorite: (String) -> Void
    let onRename: (String) -> Void
    let onCopyId: (String) -> Void
    let onCopyResume: (String) -> Void
    let onLocalSummary: (String) -> Void
    let onTogglePet: () -> Void
    let onOpenPreferences: () -> Void
    let onQuit: () -> Void
    let onAcknowledgeAll: () -> Void

    /// 是否存在未读 waiting 会话——仅此时显示「全部已读」（产品评审 MAJOR-1）。
    private var hasUnread: Bool {
        sessions.contains { s in
            if case .waiting = s.state, !s.acknowledged { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionPanel(sessions: sessions, now: now, onTap: onTap,
                         onToggleFavorite: onToggleFavorite, onRename: onRename,
                         onCopyId: onCopyId, onCopyResume: onCopyResume,
                         onLocalSummary: onLocalSummary,
                         hotkeyHint: hotkeyHint, palette: palette)
            Divider()

            // 未装 hook 时的 slim 开启入口；已装则完全隐藏（省空间，去掉冗余「已启用」状态行）。
            if !hookInstalled {
                Button { onOpenPreferences() } label: {
                    Label("开启精确跳转/通知…", systemImage: "bolt.badge.a")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor.opacity(0.75))
                Divider()
            }

            // 紧凑操作行：图标按钮，一行搞定，不再挤占列表空间。
            HStack(spacing: 0) {
                if hasUnread {
                    PanelFooterButton(icon: "checkmark.circle", label: "已读", action: onAcknowledgeAll)
                }
                PanelFooterButton(icon: petVisible ? "eye.slash" : "eye",
                                  label: petVisible ? "隐藏" : "显示", action: onTogglePet)
                PanelFooterButton(icon: "gearshape", label: "首选项", action: onOpenPreferences)
                PanelFooterButton(icon: "power", label: "退出", action: onQuit)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(width: 320)
    }
}

/// 面板底部紧凑图标按钮（图标 + 极小文字，等宽平铺）。菜单栏与宠物 popover 共用。
struct PanelFooterButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 13))
                Text(label).font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// MARK: - MenuBarController

/// Owns the `NSStatusItem` and keeps the menu bar icon + popover panel up to date.
///
/// Call ``update(summary:sessions:)`` on every store change (already on `@MainActor`
/// via `AppCoordinator.changeHandler`).
@MainActor
final class MenuBarController: NSObject {

    // MARK: - Dependencies

    private let statusItem: NSStatusItem
    private let focusService: TerminalFocusService

    /// Returns whether the floating pet window is currently visible.
    var petVisibilityProvider: (() -> Bool)?
    /// Invoked when the user taps 隐藏/显示宠物; AppCoordinator toggles the pet window.
    var onTogglePet: (() -> Void)?
    /// Invoked when the user taps 首选项…; AppCoordinator shows the preferences window.
    var onOpenPreferences: (() -> Void)?
    /// Returns the current running + waiting counts for the right-click menu summary row.
    var summaryProvider: (() -> (running: Int, waiting: Int))?
    /// Fix 6: returns whether the precise-jump/notifications hook is installed for any data root.
    /// Injected by AppCoordinator; when nil or `false`, the panel shows the call-to-action button.
    var hookInstalledProvider: (() -> Bool)?
    /// 用户点开一个会话（跳转终端）后回调，AppCoordinator 据此把会话标记为"已读"（红→黄）。
    var onAcknowledge: ((SessionKey) -> Void)?
    /// 面板「全部标记已读」回调，由 AppCoordinator 注入 store.acknowledgeAll。
    var onAcknowledgeAll: (() -> Void)?
    /// F7：收藏/取消收藏，由 AppCoordinator 注入（写 SessionMetaStore + 刷新）。
    var onToggleFavorite: ((SessionKey) -> Void)?
    /// F7：重命名（nil=恢复默认名），由 AppCoordinator 注入。
    var onRenameSession: ((SessionKey, String?) -> Void)?
    /// F3：状态圆点配色，由 AppCoordinator 从 config 注入。
    var dotPalette: DotPalette = .system
    /// 面板顶部快捷键提示字符串，如 "⌥⌘P 打开/关闭"。nil 表示不显示 header。
    var hotkeyHint: String?
    /// 状态栏样式（F2）：`"counts"`（🟢🔴🟡⚪+数字）| `"pawprint"`（单图标+主色+总数）。
    var menuBarStyle: String = "counts"

    // MARK: - State

    /// Latest session list from the store; used to resolve row tap IDs.
    private var currentSessions: [Session] = []
    /// Live popover (nil until first click).
    private var popover: NSPopover?
    /// Hosting controller retained for rootView live-updates.
    private var panelHosting: NSHostingController<PanelRootView>?
    /// Guard: only one "无法跳转" alert at a time (prevents rapid-click alert stacking).
    private var isShowingTapAlert = false
    /// Part C: throttles just-in-time hook hints to at most once per session, capped globally.
    private var hookHintThrottle = HookHintThrottle()

    // MARK: - Init

    init(focusService: TerminalFocusService) {
        self.focusService = focusService
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
    }

    // MARK: - Public API

    /// Refresh icon, tint, badge, and session panel rows.
    func update(summary: PetSummary, sessions: [Session]) {
        currentSessions = sessions
        renderStatusButton(summary: summary)
        // Push new rows into the live hosting controller so the popover updates in-place.
        panelHosting?.rootView = makePanelRootView()
    }

    /// 按当前 `menuBarStyle` 选择渲染方式。
    private func renderStatusButton(summary: PetSummary) {
        if menuBarStyle == "counts" {
            applyCountsPresentation(MenuBarCountsPresenter.text(from: summary))
        } else {
            applyPresentation(MenuBarPresenter.make(from: summary))
        }
    }

    // MARK: - Private: button setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.action = #selector(statusButtonClicked(_:))
        button.target = self
        // Listen for both left and right mouse-up so we can route right-click to NSMenu.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Keep statusItem.menu nil — assigning it would intercept left-clicks permanently.
        statusItem.menu = nil
        // 启动即可见：立即渲染 idle 态，避免首次 update() 调用前按钮为空白。
        let idleSummary = PetSummary(
            state: .idle,
            runningCount: 0,
            waitingCount: 0,
            attentionCount: 0,
            staleCount: 0,
            acknowledgedCount: 0
        )
        renderStatusButton(summary: idleSummary)
    }

    // MARK: - Private: button appearance

    /// 彩色计数样式：标题即为 "🟢2 🔴1 …"（emoji 自带颜色），无 SF Symbol 图标、无 tint。
    private func applyCountsPresentation(_ text: String) {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.contentTintColor = nil
        button.title = text
        button.imagePosition = .noImage
    }

    private func applyPresentation(_ p: MenuBarPresentation) {
        guard let button = statusItem.button else { return }

        let img = NSImage(systemSymbolName: p.symbolName, accessibilityDescription: nil)
        img?.isTemplate = (p.tint == .none)
        button.image = img

        switch p.tint {
        case .none:   button.contentTintColor = nil
        case .green:  button.contentTintColor = .systemGreen
        case .orange: button.contentTintColor = .systemOrange
        case .red:    button.contentTintColor = .systemRed
        }

        if let badge = p.badge {
            button.title = " \(badge)"
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // MARK: - Private: popover

    /// Build the SwiftUI root view with current sessions and callbacks.
    private func makePanelRootView() -> PanelRootView {
        return PanelRootView(
            sessions: currentSessions,
            now: Date().timeIntervalSince1970,
            palette: dotPalette,
            petVisible: petVisibilityProvider?() ?? false,
            hookInstalled: hookInstalledProvider?() ?? false,
            hotkeyHint: hotkeyHint,
            onTap: { [weak self] id in self?.handleSessionTap(id: id) },
            onToggleFavorite: { [weak self] id in self?.handleToggleFavorite(id: id) },
            onRename: { [weak self] id in self?.handleRename(id: id) },
            onCopyId: { [weak self] id in self?.handleCopyId(id: id) },
            onCopyResume: { [weak self] id in self?.handleCopyResume(id: id) },
            onLocalSummary: { [weak self] id in self?.handleLocalSummary(id: id) },
            onTogglePet: { [weak self] in
                self?.onTogglePet?()
                self?.panelHosting?.rootView = self?.makePanelRootView() ?? PanelRootView(
                    sessions: [], now: 0, palette: .system, petVisible: false, hookInstalled: false, hotkeyHint: nil,
                    onTap: { _ in }, onToggleFavorite: { _ in }, onRename: { _ in },
                    onCopyId: { _ in }, onCopyResume: { _ in }, onLocalSummary: { _ in },
                    onTogglePet: {}, onOpenPreferences: {}, onQuit: {}, onAcknowledgeAll: {}
                )
            },
            onOpenPreferences: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onOpenPreferences?()
            },
            onQuit: { NSApplication.shared.terminate(nil) },
            onAcknowledgeAll: { [weak self] in self?.onAcknowledgeAll?() }
        )
    }

    // MARK: - Private: F7/F11 row actions

    private func sessionForId(_ id: String) -> Session? {
        currentSessions.first { "\($0.key.agent)|\($0.key.root)|\($0.key.sessionId)" == id }
    }

    private func handleToggleFavorite(id: String) {
        guard let s = sessionForId(id) else { return }
        onToggleFavorite?(s.key)
    }

    private func handleRename(id: String) {
        guard let s = sessionForId(id) else { return }
        if case .set(let name) = SessionRowActions.promptRename(s) {
            onRenameSession?(s.key, name)
        }
    }

    private func handleCopyId(id: String) {
        sessionForId(id).map(SessionRowActions.copyId)
    }

    private func handleCopyResume(id: String) {
        sessionForId(id).map(SessionRowActions.copyResume)
    }

    private func handleLocalSummary(id: String) {
        sessionForId(id).map(SessionRowActions.showLocalSummary)
    }

    /// 以编程方式打开/切换会话面板 popover（供全局热键在 menuBarOnly 模式下调用）。
    func showPanel() {
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        // Toggle: close if already visible.
        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }

        let rootView = makePanelRootView()
        let hc = NSHostingController(rootView: rootView)
        panelHosting = hc

        let p = NSPopover()
        p.contentViewController = hc
        p.behavior = .transient
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover = p
    }

    // MARK: - Actions

    /// AppKit delivers this on the main thread; `nonisolated` satisfies the `@objc` requirement,
    /// and we hop back to `@MainActor` immediately (same pattern as the existing B2 fix).
    /// Right-click routes to the standard NSMenu; left-click routes to the popover.
    @objc nonisolated func statusButtonClicked(_ sender: AnyObject) {
        // AppKit 保证此处在主线程；在让渡给 Swift concurrency 前同步捕获事件类型，
        // 避免 Task 执行时 NSApp.currentEvent 已被替换的时序漏洞（Task2 评审 Important）。
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        Task { @MainActor [weak self] in
            if isRightClick {
                self?.showRightClickMenu()
                return
            }
            self?.showPopover()
        }
    }

    private func showRightClickMenu() {
        guard let button = statusItem.button else { return }
        let s = summaryProvider?() ?? (running: 0, waiting: 0)
        let menu = NSMenu()
        for row in MenuBarMenuModel.rows(runningCount: s.running, waitingCount: s.waiting) {
            if row.command == .sessionSummary {
                let it = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
                menu.addItem(.separator())
                continue
            }
            let it = NSMenuItem(
                title: row.title,
                action: #selector(handleMenuCommand(_:)),
                keyEquivalent: row.shortcut ?? ""
            )
            it.target = self
            it.representedObject = row.command
            menu.addItem(it)
        }
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        button.highlight(false)
    }

    @objc private func handleMenuCommand(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? MenuCommand else { return }
        switch cmd {
        case .preferences:   onOpenPreferences?()
        case .quit:          NSApplication.shared.terminate(nil)
        case .about:         NSApp.orderFrontStandardAboutPanel(nil)
        case .sessionSummary: break
        }
    }

    private func handleSessionTap(id: String) {
        // Resolve the session by its stable id.
        guard let session = currentSessions.first(where: {
            "\($0.key.agent)|\($0.key.root)|\($0.key.sessionId)" == id
        }) else { return }

        // 用户点开会话 → 标记已读（红→黄）。仅对 waiting 态生效（acknowledge 内部守卫）。
        onAcknowledge?(session.key)

        let terminal = session.terminal
        // Part C / Fix 2: jsonl-inferred sessions are identified by their process-internal
        // source tag (硬约束 #9：用 session.source == .jsonl 判定来源，不用 terminal == nil 当代理).
        // Capture before going off-main so we can check it in the alert block.
        let isJsonlSession = (session.source == .jsonl)
        // M3-C+：hook 提示限定 Claude 系（评审：对 opencode 推销 ~/.claude/settings.json
        // 完全错误且耗节流配额）；opencode 走专属弹窗（诚实降级 + 复制恢复命令）。
        let isClaude = ["claude", "claude-code"].contains(session.key.agent)
        let isOpenCode = (session.key.agent == "opencode")
        let fs = focusService
        // Dismiss the popover before the off-main focus attempt.
        popover?.performClose(nil)

        // Off-main — osascript blocks (Fix I-1 / B2 pattern).
        Task.detached {
            let result = fs.focus(terminal)
            // Inform the user when the terminal window can't be reached.
            // .targetGone  — osascript ran but the session tab no longer exists.
            // .unsupported — no terminal info at all (e.g. jsonl-inferred session).
            if result == .targetGone || result == .unsupported {
                await MainActor.run { [weak self] in
                    guard let self, !self.isShowingTapAlert else { return } // 防连击叠加阻塞弹窗（Task9 评审 Important）
                    self.isShowingTapAlert = true
                    defer { self.isShowingTapAlert = false }
                    if isOpenCode {
                        SessionRowActions.showOpenCodeNoJumpAlert(session)
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = "无法跳转到会话"
                    // .targetGone=窗口已关；.unsupported=无终端信息（如 jsonl 推断会话）。文案兼顾两者。
                    var infoText = "无法跳转到会话终端（可能已关闭，或终端信息不可用）。"
                    // Part C: just-in-time hook hint — only for jsonl-inferred sessions,
                    // throttled to once per session and capped globally by HookHintThrottle.
                    if isJsonlSession && isClaude && self.hookHintThrottle.shouldHint(sessionKey: id) {
                        infoText += "\n\n💡 安装 Hook 可精确跳到这个 tab（会改 settings.json，自动备份/一键卸载）→ 在「首选项」中开启。"
                    }
                    alert.informativeText = infoText
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "好的")
                    alert.runModal()
                }
            }
        }
    }
}
