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
    let ui: PanelUIState
    let onTap: (String) -> Void
    let onToggleFavorite: (String) -> Void
    let onCopyId: (String) -> Void
    let onCopyResume: (String) -> Void
    var onSummarize: (String, Bool) async -> SummaryResult = { _, _ in .error("未接入") }
    let onTogglePet: () -> Void
    let onOpenPreferences: () -> Void
    let onQuit: () -> Void
    let onAcknowledgeAll: () -> Void
    // M3-D-B/C:tab + 分组
    var selectedTab: SessionTab = .all
    var onSelectTab: (SessionTab) -> Void = { _ in }
    var groups: [String] = []
    var onToggleGroup: (String, String) -> Void = { _, _ in }
    var onCommitNewGroup: (String, String?) -> Void = { _, _ in }
    var onDeleteGroup: (String) -> Void = { _ in }
    var onCommitRename: (String, String) -> Void = { _, _ in }
    var onCommitNote: (String, String) -> Void = { _, _ in }
    var historyProvider: (() -> [Session])? = nil
    var pinned: Bool = false
    var onTogglePin: () -> Void = {}

    /// 是否存在未读 waiting 会话——仅此时显示「全部已读」（产品评审 MAJOR-1）。
    private var hasUnread: Bool {
        sessions.contains { s in
            if case .waiting = s.state, !s.acknowledged { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionPanel(sessions: sessions, now: now, ui: ui, onTap: onTap,
                         onToggleFavorite: onToggleFavorite,
                         onCopyId: onCopyId, onCopyResume: onCopyResume,
                         onSummarize: onSummarize,
                         onOpenHookSetup: onOpenPreferences,
                         hotkeyHint: hotkeyHint, palette: palette,
                         selectedTab: selectedTab, onSelectTab: onSelectTab,
                         groups: groups, onToggleGroup: onToggleGroup,
                         onCommitNewGroup: onCommitNewGroup, onDeleteGroup: onDeleteGroup,
                         onCommitRename: onCommitRename, onCommitNote: onCommitNote,
                         historyProvider: historyProvider)
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
                // E6/U3:已读常驻,无未读时置灰(此前「有未读才显」点完塌成3按钮抖动)。
                PanelFooterButton(icon: "checkmark.circle", label: "已读", action: onAcknowledgeAll,
                                  enabled: hasUnread, help: "把所有「等你」会话标为已读")
                PanelFooterButton(icon: pinned ? "pin.fill" : "pin",
                                  label: pinned ? "已固定" : "固定", action: onTogglePin,
                                  help: pinned ? "取消固定:点别处自动隐藏" : "固定:常驻不自动隐藏")
                PanelFooterButton(icon: petVisible ? "eye.slash" : "eye",
                                  label: petVisible ? "隐藏" : "显示", action: onTogglePet,
                                  help: petVisible ? "隐藏桌面宠物" : "显示桌面宠物")
                PanelFooterButton(icon: "gearshape", label: "首选项", action: onOpenPreferences, help: "打开首选项")
                PanelFooterButton(icon: "power", label: "退出", action: onQuit, help: "退出 AgentPet")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)  // 可缩放窗口:内容随窗口宽
    }
}

/// 面板底部紧凑图标按钮（图标 + 极小文字，等宽平铺）。菜单栏与宠物 popover 共用。
struct PanelFooterButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var enabled: Bool = true
    var help: String = ""
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
        .disabled(!enabled)                    // E6:无未读时置灰而非消失(消除页脚抖动)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
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
    var onSetNote: ((SessionKey, String?) -> Void)?
    /// F3：状态圆点配色，由 AppCoordinator 从 config 注入。
    var dotPalette: DotPalette = .system
    /// 面板顶部快捷键提示字符串，如 "⌥⌘P 打开/关闭"。nil 表示不显示 header。
    var hotkeyHint: String?
    /// 状态栏样式（F2）：`"counts"`（🟢🔴🟡⚪+数字）| `"pawprint"`（单图标+主色+总数）。
    var menuBarStyle: String = "counts"
    // M3-D-B/C:tab + 分组(AppCoordinator 注入)。
    var selectedTabProvider: (() -> SessionTab)?
    var sessionGroupsProvider: (() -> [String])?
    var onSelectTab: ((SessionTab) -> Void)?
    var onToggleGroupMembership: ((SessionKey, String) -> Void)?
    var onCommitNewGroupFor: ((String, SessionKey?) -> Void)?    // 内联提交:name + 可选加入的会话
    var onDeleteGroup: ((String) -> Void)?
    // M3-D-F:面板窗口尺寸持久化。
    var panelFrameProvider: (() -> NSRect?)?
    var panelSizeProvider: (() -> CGSize)?
    var onPanelFrameChange: ((NSRect) -> Void)?
    var panelPinnedProvider: (() -> Bool)?
    var onTogglePin: (() -> Void)?
    /// 历史档案(AppCoordinator 注入缓存快照;选历史 tab 时触发异步重建)。
    var historySessionsProvider: (() -> [Session])?
    var onHistoryTabSelected: (() -> Void)?
    /// 面板 UI 触发状态:跨 rootView 替换存活(菜单闭包写 @State 会丢,见 PanelUIState)。
    let panelUI = PanelUIState()
    private var keyMonitor: Any?

    // MARK: - State

    /// Latest session list from the store; used to resolve row tap IDs.
    private var currentSessions: [Session] = []
    /// M3-D-F:可缩放面板窗口(取代 popover;用户选 A 拖拽改大小)。
    private var panelWindow: PanelResizeWindow?
    /// Hosting controller retained for rootView live-updates.
    private var panelHosting: NSHostingController<PanelRootView>?
    /// Guard: only one "无法跳转" alert at a time (prevents rapid-click alert stacking).
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
            ui: panelUI,
            onTap: { [weak self] id in self?.handleSessionTap(id: id) },
            onToggleFavorite: { [weak self] id in self?.handleToggleFavorite(id: id) },
            onCopyId: { [weak self] id in self?.handleCopyId(id: id) },
            onCopyResume: { [weak self] id in self?.handleCopyResume(id: id) },
            onSummarize: { [weak self] id, useAI in await self?.summarize(id: id, useAI: useAI) ?? .error("面板已关闭") },
            onTogglePet: { [weak self] in
                self?.onTogglePet?()
                self?.panelHosting?.rootView = self?.makePanelRootView() ?? PanelRootView(
                    sessions: [], now: 0, palette: .system, petVisible: false, hookInstalled: false, hotkeyHint: nil,
                    ui: PanelUIState(),
                    onTap: { _ in }, onToggleFavorite: { _ in },
                    onCopyId: { _ in }, onCopyResume: { _ in },
                    onTogglePet: {}, onOpenPreferences: {}, onQuit: {}, onAcknowledgeAll: {}
                )
            },
            onOpenPreferences: { [weak self] in
                self?.panelWindow?.close()
                self?.onOpenPreferences?()
            },
            onQuit: { NSApplication.shared.terminate(nil) },
            onAcknowledgeAll: { [weak self] in self?.onAcknowledgeAll?() },
            selectedTab: selectedTabProvider?() ?? .all,
            onSelectTab: { [weak self] tab in
                if case .history = tab { self?.onHistoryTabSelected?() }
                self?.onSelectTab?(tab)
                self?.panelHosting?.rootView = self?.makePanelRootView() ?? PanelRootView(
                    sessions: [], now: 0, palette: .system, petVisible: false, hookInstalled: false, hotkeyHint: nil,
                    ui: PanelUIState(),
                    onTap: { _ in }, onToggleFavorite: { _ in },
                    onCopyId: { _ in }, onCopyResume: { _ in },
                    onTogglePet: {}, onOpenPreferences: {}, onQuit: {}, onAcknowledgeAll: {})
            },
            groups: sessionGroupsProvider?() ?? [],
            onToggleGroup: { [weak self] id, group in
                guard let self, let s = self.sessionForId(id) else { return }
                self.onToggleGroupMembership?(s.key, group)
            },
            onCommitNewGroup: { [weak self] name, attachId in
                guard let self else { return }
                let key = attachId.flatMap { self.sessionForId($0)?.key }
                self.onCommitNewGroupFor?(name, key)
            },
            onDeleteGroup: { [weak self] g in self?.onDeleteGroup?(g) },
            onCommitRename: { [weak self] id, name in
                guard let self, let s = self.sessionForId(id) else { return }
                self.onRenameSession?(s.key, name.isEmpty ? nil : name)
            },
            onCommitNote: { [weak self] id, note in
                guard let self, let s = self.sessionForId(id) else { return }
                self.onSetNote?(s.key, note.isEmpty ? nil : note)
            },
            historyProvider: { [weak self] in self?.historySessionsProvider?() ?? [] },
            pinned: panelPinnedProvider?() ?? false,
            onTogglePin: { [weak self] in
                self?.onTogglePin?()
                if let self, let w = self.panelWindow {
                    w.hidesOnDeactivate = !(self.panelPinnedProvider?() ?? false)
                    self.panelHosting?.rootView = self.makePanelRootView()
                }
            }
        )
    }

    // MARK: - Private: F7/F11 row actions

    private func sessionForId(_ id: String) -> Session? {
        currentSessions.first { "\($0.key.agent)|\($0.key.root)|\($0.key.sessionId)" == id }
            // 历史行不在活跃列表:回退历史索引(右键动作/摘要/点击提示条都经此查找)。
            ?? historySessionsProvider?().first { "\($0.key.agent)|\($0.key.root)|\($0.key.sessionId)" == id }
    }

    func summarize(id: String, useAI: Bool) async -> SummaryResult {
        SessionRowActions.summaryDebug("[menubar] summarize called id=\(id) useAI=\(useAI)")
        guard let s = sessionForId(id) else {
            SessionRowActions.summaryDebug("[menubar] sessionForId 未命中 id=\(id)")
            return .error("会话不存在")
        }
        return useAI ? await SessionRowActions.aiSummary(s) : SessionRowActions.quickSummary(s)
    }


    private func handleToggleFavorite(id: String) {
        guard let s = sessionForId(id) else { return }
        onToggleFavorite?(s.key)
    }


    private func handleCopyId(id: String) {
        sessionForId(id).map(SessionRowActions.copyId)
    }

    private func handleCopyResume(id: String) {
        sessionForId(id).map(SessionRowActions.copyResume)
    }


    /// 以编程方式打开/切换会话面板 popover（供全局热键在 menuBarOnly 模式下调用）。
    func showPanel() {
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }

        // Toggle: 已显示则隐藏(复用窗口,不重建——防泄漏)。
        if let w = panelWindow, w.isVisible {
            w.orderOut(nil)
            return
        }

        panelUI.resetTransient()   // 开面板清旧提示条/半途重命名/删组确认等(巩固评审 Minor)
        let savedFrame = panelFrameProvider?()   // 已保存的完整 frame(位置+尺寸)
        let size = clampPanelSize(panelSizeProvider?() ?? CGSize(width: 360, height: 480))
        let win: PanelResizeWindow
        if let existing = panelWindow {
            win = existing
            win.hidesOnDeactivate = !(panelPinnedProvider?() ?? false)
            panelHosting?.rootView = makePanelRootView()
        } else {
            let hc = NSHostingController(rootView: makePanelRootView())
            panelHosting = hc
            let w = PanelResizeWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.isMovableByWindowBackground = true
            w.level = .floating
            w.hidesOnDeactivate = !(panelPinnedProvider?() ?? false)
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 300, height: 240)
            w.contentViewController = hc
            w.onFrameChange = { [weak self] f in self?.onPanelFrameChange?(f) }
            win = w
            panelWindow = w
            installKeyMonitor()
        }

        // 定位:有保存的 frame(用户拖过)→ 精确恢复;否则首开锚到菜单栏图标下方。
        if let saved = savedFrame, saved.width >= 300, saved.height >= 240 {
            win.setFrame(clampFrameOnScreen(saved), display: true)
        } else if let screen = button.window?.screen ?? NSScreen.main,
                  let btnFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) {
            var x = btnFrame.maxX - size.width
            x = max(screen.visibleFrame.minX + 8, x)
            let y = btnFrame.minY - size.height - 4
            win.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 键盘流(B):面板为 key 窗口且焦点不在文本框时,↑↓ 选行/回车跳转/Esc 关面板/⌘F 聚焦搜索。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let win = self.panelWindow, event.window === win else { return event }
            // 文本编辑中(搜索/重命名/摘要/建组):除 ⌘F 外全部放行给字段编辑器。
            let inTextField = win.firstResponder is NSTextView
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                self.panelUI.focusSearchToken += 1
                return nil
            }
            guard !inTextField else { return event }
            switch event.keyCode {
            case 125:   // ↓
                self.panelUI.moveDelta = 1; self.panelUI.moveSeq += 1; return nil
            case 126:   // ↑
                self.panelUI.moveDelta = -1; self.panelUI.moveSeq += 1; return nil
            case 36:    // 回车:跳转选中行
                if let id = self.panelUI.keyboardSelectedId {
                    self.handleSessionTap(id: id); return nil
                }
                return event
            case 53:    // Esc:关面板
                win.orderOut(nil); return nil
            default:
                return event
            }
        }
    }

    private func clampPanelSize(_ s: CGSize) -> CGSize {
        CGSize(width: max(300, s.width), height: max(240, s.height))
    }

    /// 保证窗口至少部分在可见屏内(防保存位置落在已拔掉的外接屏上→找不回)。
    private func clampFrameOnScreen(_ f: NSRect) -> NSRect {
        let visible = (NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var r = f
        r.size.width = max(300, min(r.width, visible.width))
        r.size.height = max(240, min(r.height, visible.height))
        r.origin.x = min(max(r.origin.x, visible.minX), visible.maxX - r.width)
        r.origin.y = min(max(r.origin.y, visible.minY), visible.maxY - r.height)
        return r
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

        // B1 修复(交互评审 P0-2):**不再**在跳转前无条件标已读——若终端已关(跳转失败),
        // 会话会被静默标已读、掉出「等你」,一个还等你的会话就这么丢了。改为仅在 focus
        // 成功(focused/activatedOnly)时标已读;失败(targetGone/unsupported)保留未读。
        let sessionKey = session.key
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
        // 巩固评审 Major②:不再预关窗——失败时提示条要就地可见(与桌宠侧对齐);
        // 成功才关(未固定时焦点去终端也会 hidesOnDeactivate 自隐,双保险)。

        // Off-main — osascript blocks (Fix I-1 / B2 pattern).
        Task.detached { [weak self] in
            let result = fs.focus(terminal)
            // .focused/.activatedOnly = 用户确实到达了(至少 App 被激活)→ 标已读;
            // .targetGone/.unsupported = 没到达 → 保留未读(B1)。
            if result == .focused || result == .activatedOnly {   // 到达(含计划内仅激活)→标已读
                await MainActor.run { [weak self] in
                    self?.onAcknowledge?(sessionKey)
                    self?.panelWindow?.orderOut(nil)   // 成功:面板让路
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 跳转失败 → 行内提示条(取代全屏 NSAlert,零打断;UI/交互:优雅克制)。
                let hookHint = isJsonlSession && isClaude && self.hookHintThrottle.shouldHint(sessionKey: id)
                self.panelUI.notice = SessionRowActions.jumpFailureNotice(session, hookHint: hookHint)
                self.panelUI.noticeRowId = id
                self.panelHosting?.rootView = self.makePanelRootView()
            }
        }
    }
}
