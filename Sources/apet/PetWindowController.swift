import AppKit
import SwiftUI
import AgentPetCore
import AppShellKit

// MARK: - PetWindowController

/// Manages the transparent borderless always-on-top floating pet window.
///
/// Responsibilities:
/// - Shows ``PetView`` driven by ``PetPresentation`` from ``PetPresenter``
/// - Supports drag-to-reposition (position persisted in UserDefaults)
/// - Click toggles a popover ``SessionPanel``
/// - `update(summary:sessions:)` refreshes view and open popover in-place
@MainActor
final class PetWindowController: NSObject {

    // MARK: - Constants

    private static let positionKey = "com.clsaa.apet.PetWindowPosition"
    private let windowSize = NSSize(width: 140, height: 160)
    private let compactWindowSize = NSSize(width: 160, height: 40)

    // MARK: - State

    private var window: NSWindow?
    private var hostingView: NSHostingView<PetView>?
    /// 防连击叠加阻塞弹窗(实现评审:与 MenuBarController 同款守卫)。
    private var isShowingTapAlert = false
    private var popover: NSPopover?
    private var currentPresentation: PetPresentation
    private var currentSessions: [Session] = []
    /// Currently selected pet (builtin name or custom photo id).
    private var currentSelection: PetKind
    /// 精简条模式。
    private var currentCompact: Bool

    /// 打开首选项的回调。桌宠面板的「首选项」按钮通过它进入设置——
    /// 这是**不依赖状态栏图标**的首选项入口（状态栏图标可能被刘海/菜单栏溢出区藏住，
    /// 那样用户就只剩这条路）。由 AppCoordinator 注入。
    var onOpenPreferences: (() -> Void)?
    /// 面板「全部标记已读」回调，由 AppCoordinator 注入 store.acknowledgeAll。
    var onAcknowledgeAll: (() -> Void)?
    /// F7：收藏/取消收藏，由 AppCoordinator 注入（写 SessionMetaStore + 刷新）。
    var onToggleFavorite: ((SessionKey) -> Void)?
    /// F7：重命名（nil=恢复默认名），由 AppCoordinator 注入。
    var onRenameSession: ((SessionKey, String?) -> Void)?
    // M3-D-B/C:tab + 分组(AppCoordinator 注入,与菜单栏共用同一套闭包)。
    var selectedTabProvider: (() -> SessionTab)?
    var sessionGroupsProvider: (() -> [String])?
    var onSelectTab: ((SessionTab) -> Void)?
    var onToggleGroupMembership: ((SessionKey, String) -> Void)?
    var onCommitNewGroupFor: ((String, SessionKey?) -> Void)?
    var onDeleteGroup: ((String) -> Void)?
    /// F3：状态圆点配色，由 AppCoordinator 从 config 注入。
    var dotPalette: DotPalette = .system

    // MARK: - Dependencies

    private let focusService: TerminalFocusService
    private let customStore: CustomPetStore

    /// 用户点开一个会话（跳转终端）后回调，AppCoordinator 据此把会话标记为"已读"（红→黄）。
    var onAcknowledge: ((SessionKey) -> Void)?
    /// 面板顶部快捷键提示字符串，如 "⌥⌘P 打开/关闭"。
    var hotkeyHint: String?

    // MARK: - Init

    /// - Parameters:
    ///   - focusService: Service used to jump to the terminal that owns a session.
    ///   - selection: Initial pet selection (builtin name or custom photo id).  Defaults to `.builtin("shiba")`.
    ///   - customStore: Store for custom pet photos (injected by AppCoordinator).
    ///   - compact: 精简条模式（仅显示计数条）。Defaults to false.
    init(
        focusService: TerminalFocusService,
        selection: PetKind = .builtin("shiba"),
        customStore: CustomPetStore,
        compact: Bool = false
    ) {
        self.focusService = focusService
        self.currentSelection = selection
        self.customStore = customStore
        self.currentCompact = compact
        self.currentPresentation = PetPresenter.make(
            from: PetSummary(
                state: .idle,
                runningCount: 0,
                waitingCount: 0,
                attentionCount: 0,
                staleCount: 0
            )
        )
        super.init()
        setupWindow()
    }

    // MARK: - Public API

    /// Refresh the pet image and update the open popover (if any).
    func update(summary: PetSummary, sessions: [Session]) {
        let presentation = PetPresenter.make(from: summary)

        // MINOR-9: guard rootView replacement when nothing changed.
        // NSHostingView.rootView setter rebuilds the SwiftUI graph, resetting @State
        // variables and producing a visible animation frame skip every 8 s (the jsonl
        // watcher tick interval). Skip if both presentation and sessions are unchanged.
        let sessionsChanged = sessions != currentSessions
        guard presentation != currentPresentation || sessionsChanged else {
            // Nothing changed — still update the popover if it is open.
            if let popover, popover.isShown,
               let panelVC = popover.contentViewController as? SessionPanelHostController {
                panelVC.update(sessions: sessions)
            }
            return
        }

        currentPresentation = presentation
        currentSessions = sessions
        let img = PetAssetLoader.image(
            selection: currentSelection,
            assetState: presentation.assetState,
            customStore: customStore
        )
        let isCustom: Bool
        if case .custom = currentSelection { isCustom = true } else { isCustom = false }
        hostingView?.rootView = PetView(
            presentation: presentation,
            resolvedImage: img,
            isCustomPet: isCustom,
            compact: currentCompact
        )

        // Update popover session list in-place when visible
        if let popover, popover.isShown,
           let panelVC = popover.contentViewController as? SessionPanelHostController {
            panelVC.update(sessions: sessions)
        }
    }

    /// Show or hide the window.
    func setVisible(_ visible: Bool) {
        if visible {
            // `orderFrontRegardless()` is required for borderless LSUIElement (accessory) apps:
            // `makeKeyAndOrderFront` is silently ignored when the app has no dock icon /
            // cannot become the key app. orderFrontRegardless() bypasses that check.
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        } else {
            window?.orderOut(nil)
            popover?.performClose(nil)
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Switch the displayed pet.
    ///
    /// Call from ``AppCoordinator/applyConfig(_:)`` whenever `selectedPet` changes.
    /// The swap is live — the hosting view is updated immediately.
    func applyPet(_ selection: PetKind) {
        guard selection != currentSelection else { return }
        currentSelection = selection
        let img = PetAssetLoader.image(
            selection: currentSelection,
            assetState: currentPresentation.assetState,
            customStore: customStore
        )
        let isCustom: Bool
        if case .custom = currentSelection { isCustom = true } else { isCustom = false }
        hostingView?.rootView = PetView(
            presentation: currentPresentation,
            resolvedImage: img,
            isCustomPet: isCustom,
            compact: currentCompact
        )
    }

    /// 切换精简条模式。窗口尺寸随之调整，宿主视图立即更新。
    ///
    /// Call from ``AppCoordinator/applyConfig(_:)`` whenever `displayMode` changes between
    /// `"pet"` and `"compact"`.
    func applyCompact(_ compact: Bool) {
        guard compact != currentCompact else { return }
        currentCompact = compact
        let newSize = compact ? compactWindowSize : windowSize
        // Resize window; keep top-left anchor (macOS y=0 is bottom, so adjust origin).
        if let w = window {
            let oldFrame = w.frame
            let newOriginY = oldFrame.maxY - newSize.height
            w.setFrame(NSRect(origin: NSPoint(x: oldFrame.origin.x, y: newOriginY), size: newSize), display: true)
        }
        // Resize subviews（contentView 由 setFrame 自动填满，无需手动设——评审 MINOR-4；
        // 子视图无 autoresizingMask 需显式 resize）。
        if let contentView = window?.contentView {
            for sub in contentView.subviews {
                sub.frame = NSRect(origin: .zero, size: newSize)
            }
        }
        let img = PetAssetLoader.image(
            selection: currentSelection,
            assetState: currentPresentation.assetState,
            customStore: customStore
        )
        let isCustom: Bool
        if case .custom = currentSelection { isCustom = true } else { isCustom = false }
        hostingView?.rootView = PetView(
            presentation: currentPresentation,
            resolvedImage: img,
            isCustomPet: isCustom,
            compact: compact
        )
    }

    // MARK: - Private: session tap (mirrors MenuBarController.handleSessionTap)

    private func handleSessionTap(id: String) {
        guard let session = currentSessions.first(where: {
            "\($0.key.agent)|\($0.key.root)|\($0.key.sessionId)" == id
        }) else { return }
        // B1 修复(交互评审 P0-2):仅 focus 成功才标已读,失败保留未读(勿丢等你会话)。
        let sessionKey = session.key
        let terminal = session.terminal
        let fs = focusService
        let isOpenCode = (session.key.agent == "opencode")
        Task.detached { [weak self] in
            let result = fs.focus(terminal)
            if result == .focused || result == .activatedOnly {   // 到达(含计划内仅激活)→标已读
                await MainActor.run { [weak self] in self?.onAcknowledge?(sessionKey) }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, !self.isShowingTapAlert else { return }
                self.isShowingTapAlert = true
                defer { self.isShowingTapAlert = false }
                if isOpenCode {
                    SessionRowActions.showOpenCodeNoJumpAlert(session)
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "无法跳转到会话"
                alert.informativeText = "无法跳转到会话终端（可能已关闭，或终端信息不可用）。"
                alert.alertStyle = .informational
                // B2:有恢复命令给复制按钮(与 MenuBar/OpenCode 对齐)。
                if SessionRowActions.hasResumeCommand(agent: session.key.agent, sessionId: session.key.sessionId) {
                    alert.addButton(withTitle: "复制恢复命令")
                    alert.addButton(withTitle: "好的")
                    if alert.runModal() == .alertFirstButtonReturn { SessionRowActions.copyResume(session) }
                } else {
                    alert.addButton(withTitle: "好的")
                    alert.runModal()
                }
            }
        }
        popover?.performClose(nil)
    }

    // MARK: - Private: window setup

    private func setupWindow() {
        let size = currentCompact ? compactWindowSize : windowSize
        let origin = savedPosition() ?? defaultOrigin()
        let contentRect = NSRect(origin: origin, size: size)

        let w = ApeFloatingWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.level = .floating
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = false  // DragDetectorView handles movement
        w.hidesOnDeactivate = false
        w.isExcludedFromWindowsMenu = true

        // Hosting view for SwiftUI content
        let setupImg = PetAssetLoader.image(
            selection: currentSelection,
            assetState: currentPresentation.assetState,
            customStore: customStore
        )
        let setupIsCustom: Bool
        if case .custom = currentSelection { setupIsCustom = true } else { setupIsCustom = false }
        let hv = NSHostingView(rootView: PetView(
            presentation: currentPresentation,
            resolvedImage: setupImg,
            isCustomPet: setupIsCustom,
            compact: currentCompact
        ))
        hv.frame = NSRect(origin: .zero, size: size)
        hostingView = hv

        // Drag/click overlay (transparent, sits on top of the hosting view)
        let overlay = DragDetectorView(frame: NSRect(origin: .zero, size: size))
        overlay.onClicked = { [weak self] in
            self?.togglePopover()
        }
        overlay.onDragEnded = { [weak self] in
            self?.savePosition()
        }

        // Container holds both subviews
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(hv)
        container.addSubview(overlay)  // overlay is topmost (event capturing)
        w.contentView = container

        self.window = w
        // Visibility is controlled by `setVisible(_:)`. AppCoordinator calls
        // `setVisible(true)` on startup so the window starts hidden here.
    }

    // MARK: - Private: position persistence

    /// Compute the default bottom-right origin, clamped to the visible area.
    ///
    /// Uses `NSScreen.main ?? NSScreen.screens.first` so the result is valid
    /// even when `NSScreen.main` is temporarily nil during early app launch.
    private func defaultOrigin() -> NSPoint {
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Bottom-right with 20 pt margin (macOS: y=0 is bottom)
        let x = visibleFrame.maxX - windowSize.width - 20
        let y = visibleFrame.minY + 20
        return NSPoint(x: x, y: y)
    }

    /// Load the persisted position, clamped inside the union of all visible
    /// screen rects so a stale position from a disconnected monitor never
    /// places the window off-screen.
    private func savedPosition() -> NSPoint? {
        guard let data = UserDefaults.standard.data(forKey: Self.positionKey),
              let saved = try? JSONDecoder().decode(CGPoint.self, from: data)
        else { return nil }

        // Build union of all visible frames so multi-monitor positions are respected.
        let allVisible = NSScreen.screens.reduce(NSRect.null) { $0.union($1.visibleFrame) }
        guard !allVisible.isNull else { return NSPoint(x: saved.x, y: saved.y) }

        // Clamp so the window is at least partially visible (uses window size for bounds).
        let clampedX = max(allVisible.minX,
                           min(saved.x, allVisible.maxX - windowSize.width))
        let clampedY = max(allVisible.minY,
                           min(saved.y, allVisible.maxY - windowSize.height))
        return NSPoint(x: clampedX, y: clampedY)
    }

    private func savePosition() {
        guard let w = window else { return }
        let origin = CGPoint(x: w.frame.origin.x, y: w.frame.origin.y)
        if let data = try? JSONEncoder().encode(origin) {
            UserDefaults.standard.set(data, forKey: Self.positionKey)
        }
    }

    // MARK: - Popover (internal: AppCoordinator may call togglePopover via hot key)

    /// 切换会话面板 popover 的显示/隐藏状态。
    /// AppCoordinator 在接收到全局热键事件时调用此方法（非 private）。
    func togglePopover() {
        guard let w = window, let contentView = w.contentView else { return }

        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        // 确保窗口/App 处于可锚定状态——LSUIElement 背景 App 在非激活态下，
        // transient popover 锚到非 key 窗口可能不显示或秒关。激活 + 置 key 后再弹（点击修复）。
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()

        let panelVC = SessionPanelHostController(
            sessions: currentSessions,
            palette: dotPalette,
            hotkeyHint: hotkeyHint,
            onTap: { [weak self] id in self?.handleSessionTap(id: id) },
            onToggleFavorite: { [weak self] id in self?.handleToggleFavorite(id: id) },
            onCopyId: { [weak self] id in self?.handleCopyId(id: id) },
            onCopyResume: { [weak self] id in self?.handleCopyResume(id: id) },
            onLocalSummary: { [weak self] id in self?.handleLocalSummary(id: id) },
            onOpenPreferences: { [weak self] in self?.onOpenPreferences?() },
            onAcknowledgeAll: { [weak self] in self?.onAcknowledgeAll?() }
        )
        // M3-D-B/C:桌宠面板也接 tab/分组(默认显示模式,不能留死控件)。
        panelVC.selectedTabProvider = { [weak self] in self?.selectedTabProvider?() ?? .all }
        panelVC.sessionGroupsProvider = { [weak self] in self?.sessionGroupsProvider?() ?? [] }
        panelVC.onSelectTab = { [weak self] tab in self?.onSelectTab?(tab) }
        panelVC.onToggleGroup = { [weak self] key, g in self?.onToggleGroupMembership?(key, g) }
        panelVC.onCommitNewGroup = { [weak self] name, key in self?.onCommitNewGroupFor?(name, key) }
        panelVC.onCommitRename = { [weak self] key, name in self?.onRenameSession?(key, name.isEmpty ? nil : name) }
        panelVC.onDeleteGroup = { [weak self] g in self?.onDeleteGroup?(g) }
        let p = NSPopover()
        p.contentViewController = panelVC
        p.behavior = .transient
        // 顶部快捷键提示约 28px + 搜索框 ~40px + 列表 + 紧凑页脚(一行图标 ~44px)。页脚瘦身后整体降高。
        p.contentSize = NSSize(width: 320, height: hotkeyHint != nil ? 452 : 424)
        self.popover = p

        // Anchor to center of content view; let NSPopover pick the best edge
        let anchor = NSRect(
            x: contentView.bounds.midX,
            y: contentView.bounds.midY,
            width: 1,
            height: 1
        )
        // 弹出后下一 runloop 校验是否真的显示——LSUIElement 背景 App 锚到刚激活的非 key
        // 窗口偶发吞首击。未显示且有剩余次数则重试（PopoverShowPlanner），已显示则不再 show
        // （杜绝 double-show）。最多 2 次。
        let planner = PopoverShowPlanner()
        func attemptShow(_ attempt: Int) {
            p.show(relativeTo: anchor, of: contentView, preferredEdge: .maxY)
            DispatchQueue.main.async { [weak self] in
                guard let self, let live = self.popover, live === p else { return }
                switch planner.planAfterOpen(isShownNow: live.isShown, attempt: attempt, maxAttempts: 2) {
                case .ok, .giveUp: break
                case .retry:       attemptShow(attempt + 1)
                }
            }
        }
        attemptShow(1)
    }

    // MARK: - F7/F11 row actions

    private func sessionForId(_ id: String) -> Session? {
        currentSessions.first { "\($0.key.agent)|\($0.key.root)|\($0.key.sessionId)" == id }
    }
    private func handleToggleFavorite(id: String) {
        sessionForId(id).map { onToggleFavorite?($0.key) }
    }
    private func handleCopyId(id: String) { sessionForId(id).map(SessionRowActions.copyId) }
    private func handleCopyResume(id: String) { sessionForId(id).map(SessionRowActions.copyResume) }
    private func handleLocalSummary(id: String) { sessionForId(id).map(SessionRowActions.showLocalSummary) }
}

// MARK: - ApeFloatingWindow

/// Borderless floating NSWindow subclass.
///
/// Overrides `canBecomeKey` and `canBecomeMain` so that:
/// - NSPopover can anchor to this window (requires a key-capable window).
/// - The window can receive keyboard events if needed in future.
///
/// A plain `.borderless` NSWindow returns `false` for both properties by default,
/// which prevents `makeKeyAndOrderFront` from working in an LSUIElement app.
private final class ApeFloatingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - DragDetectorView

/// Transparent overlay that captures mouse events for drag-to-move and click-to-open.
/// Rendering is handled by the SwiftUI ``NSHostingView`` beneath it.
private final class DragDetectorView: NSView {

    var onClicked: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragStartLocation: NSPoint = .zero
    private var windowOriginAtDragStart: NSPoint = .zero
    // 累积两轴最大绝对位移并判定点击/拖动（纯逻辑下沉 AgentPetCore，可单测）。
    private var dragAccumulator = DragAccumulator()
    // 8pt：4pt 太小，正常点击（尤其触控板）的微小抖动会被误判成拖动→保存位置而不弹面板（点击修复）。
    private let dragThreshold: Double = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = NSEvent.mouseLocation
        windowOriginAtDragStart = window?.frame.origin ?? .zero
        dragAccumulator.reset()
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartLocation.x
        let dy = current.y - dragStartLocation.y
        dragAccumulator.accumulate(dx: Double(dx), dy: Double(dy))
        window?.setFrameOrigin(NSPoint(
            x: windowOriginAtDragStart.x + dx,
            y: windowOriginAtDragStart.y + dy
        ))
    }

    override func mouseUp(with event: NSEvent) {
        switch dragAccumulator.gesture(threshold: dragThreshold) {
        case .drag:  onDragEnded?()
        case .click: onClicked?()
        }
    }

    // Capture all hit-test queries so events don't fall through to SwiftUI
    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(point) ? self : nil
    }
}

// MARK: - PetPanelRootView

/// ``SessionPanel`` + 一个「首选项…」页脚按钮。
///
/// 桌宠面板必须自带通往首选项的入口，**不能只依赖状态栏图标**——状态栏图标会被
/// 刘海 / 菜单栏溢出区藏掉，那样用户就再也打不开首选项（实测踩坑）。
private struct PetPanelRootView: View {
    let sessions: [Session]
    let now: Double
    let palette: DotPalette
    let hotkeyHint: String?
    let onTap: (String) -> Void
    let onToggleFavorite: (String) -> Void
    let onCopyId: (String) -> Void
    let onCopyResume: (String) -> Void
    let onLocalSummary: (String) -> Void
    let onOpenPreferences: () -> Void
    let onAcknowledgeAll: () -> Void
    var selectedTab: SessionTab = .all
    var onSelectTab: (SessionTab) -> Void = { _ in }
    var groups: [String] = []
    var onToggleGroup: (String, String) -> Void = { _, _ in }
    var onCommitNewGroup: (String, String?) -> Void = { _, _ in }
    var onDeleteGroup: (String) -> Void = { _ in }
    var onCommitRename: (String, String) -> Void = { _, _ in }

    /// 是否存在未读 waiting 会话（红/橙点）。
    /// 避免全绿/全已读时按钮可见却点了无反应（产品评审 MAJOR-1）。
    private var hasUnread: Bool {
        sessions.contains { s in
            if case .waiting = s.state, !s.acknowledged { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionPanel(sessions: sessions, now: now, onTap: onTap,
                         onToggleFavorite: onToggleFavorite,
                         onCopyId: onCopyId, onCopyResume: onCopyResume,
                         onLocalSummary: onLocalSummary,
                         hotkeyHint: hotkeyHint, palette: palette,
                         showsTabBar: true,
                         selectedTab: selectedTab, onSelectTab: onSelectTab,
                         groups: groups, onToggleGroup: onToggleGroup,
                         onCommitNewGroup: onCommitNewGroup, onDeleteGroup: onDeleteGroup,
                         onCommitRename: onCommitRename)
            Divider()
            // 紧凑操作行：已读常驻置灰(U3)/首选项/退出。
            HStack(spacing: 0) {
                PanelFooterButton(icon: "checkmark.circle", label: "已读", action: onAcknowledgeAll,
                                  enabled: hasUnread, help: "把所有「等你」会话标为已读")
                PanelFooterButton(icon: "gearshape", label: "首选项", action: onOpenPreferences, help: "打开首选项")
                PanelFooterButton(icon: "power", label: "退出",
                                  action: { NSApplication.shared.terminate(nil) }, help: "退出 AgentPet")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - SessionPanelHostController

/// Minimal NSViewController that wraps ``PetPanelRootView`` in a popover.
private final class SessionPanelHostController: NSViewController {

    private var sessions: [Session]
    private let palette: DotPalette
    private let hotkeyHint: String?
    private let onTap: (String) -> Void
    private let onToggleFavorite: (String) -> Void
    private let onCopyId: (String) -> Void
    private let onCopyResume: (String) -> Void
    private let onLocalSummary: (String) -> Void
    private let onOpenPreferences: () -> Void
    private let onAcknowledgeAll: () -> Void
    private var hostingController: NSHostingController<PetPanelRootView>?
    // M3-D-B/C:tab + 分组(由 PetWindowController 注入,读 config/写回)。
    var selectedTabProvider: (() -> SessionTab)?
    var sessionGroupsProvider: (() -> [String])?
    var onSelectTab: ((SessionTab) -> Void)?
    var onToggleGroup: ((SessionKey, String) -> Void)?
    var onCommitNewGroup: ((String, SessionKey?) -> Void)?
    var onCommitRename: ((SessionKey, String) -> Void)?
    var onDeleteGroup: ((String) -> Void)?

    init(
        sessions: [Session],
        palette: DotPalette,
        hotkeyHint: String?,
        onTap: @escaping (String) -> Void,
        onToggleFavorite: @escaping (String) -> Void,
        onCopyId: @escaping (String) -> Void,
        onCopyResume: @escaping (String) -> Void,
        onLocalSummary: @escaping (String) -> Void,
        onOpenPreferences: @escaping () -> Void,
        onAcknowledgeAll: @escaping () -> Void
    ) {
        self.sessions = sessions
        self.palette = palette
        self.hotkeyHint = hotkeyHint
        self.onTap = onTap
        self.onToggleFavorite = onToggleFavorite
        self.onCopyId = onCopyId
        self.onCopyResume = onCopyResume
        self.onLocalSummary = onLocalSummary
        self.onOpenPreferences = onOpenPreferences
        self.onAcknowledgeAll = onAcknowledgeAll
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func petSessionForId(_ id: String) -> Session? {
        sessions.first { "\($0.key.agent)|\($0.key.root)|\($0.key.sessionId)" == id }
    }

    private func makeRoot() -> PetPanelRootView {
        PetPanelRootView(sessions: sessions, now: Date().timeIntervalSince1970,
                         palette: palette,
                         hotkeyHint: hotkeyHint, onTap: onTap,
                         onToggleFavorite: onToggleFavorite,
                         onCopyId: onCopyId, onCopyResume: onCopyResume,
                         onLocalSummary: onLocalSummary,
                         onOpenPreferences: onOpenPreferences, onAcknowledgeAll: onAcknowledgeAll,
                         selectedTab: selectedTabProvider?() ?? .all,
                         onSelectTab: { [weak self] tab in
                             self?.onSelectTab?(tab)
                             if let self { self.hostingController?.rootView = self.makeRoot() }
                         },
                         groups: sessionGroupsProvider?() ?? [],
                         onToggleGroup: { [weak self] id, g in
                             guard let self, let sess = self.petSessionForId(id) else { return }
                             self.onToggleGroup?(sess.key, g)
                         },
                         onCommitNewGroup: { [weak self] name, idOrNil in
                             guard let self else { return }
                             let key = idOrNil.flatMap { self.petSessionForId($0)?.key }
                             self.onCommitNewGroup?(name, key)
                         },
                         onDeleteGroup: { [weak self] g in self?.onDeleteGroup?(g) },
                         onCommitRename: { [weak self] id, name in
                             guard let self, let sess = self.petSessionForId(id) else { return }
                             self.onCommitRename?(sess.key, name)
                         })
    }

    override func loadView() {
        let hc = NSHostingController(rootView: makeRoot())
        hc.view.frame = NSRect(x: 0, y: 0, width: 320, height: 436)
        self.view = hc.view
        addChild(hc)
        hostingController = hc
    }

    func update(sessions: [Session]) {
        self.sessions = sessions
        hostingController?.rootView = makeRoot()
    }
}
