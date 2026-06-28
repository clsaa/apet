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
                panelVC.update(rows: sessions.map(SessionRowMapper.make))
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
            panelVC.update(rows: sessions.map(SessionRowMapper.make))
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
        // 用户点开会话 → 标记已读（红→黄）。仅对 waiting 态生效（acknowledge 内部守卫）。
        onAcknowledge?(session.key)
        let terminal = session.terminal
        let fs = focusService
        // osascript blocks; run off main thread (same pattern as MenuBarController / Fix B2).
        Task.detached {
            _ = fs.focus(terminal)
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

        let rows = currentSessions.map(SessionRowMapper.make)
        let panelVC = SessionPanelHostController(
            rows: rows,
            hotkeyHint: hotkeyHint,
            onTap: { [weak self] id in self?.handleSessionTap(id: id) },
            onOpenPreferences: { [weak self] in self?.onOpenPreferences?() },
            onAcknowledgeAll: { [weak self] in self?.onAcknowledgeAll?() }
        )
        let p = NSPopover()
        p.contentViewController = panelVC
        p.behavior = .transient
        // 顶部快捷键提示约占 28px；底部页脚现含「全部已读」「首选项」「退出」三按钮(约 110px)，整体加高避免列表被截断。
        p.contentSize = NSSize(width: 320, height: hotkeyHint != nil ? 512 : 484)
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
    // 累积拖动过程中两轴的最大绝对位移，交给 ClickDragClassifier 判定，
    // 避免"拖出去又拖回原点"被误判为点击。
    private var maxAbsDx: CGFloat = 0
    private var maxAbsDy: CGFloat = 0
    // 8pt：4pt 太小，正常点击（尤其触控板）的微小抖动会被误判成拖动→保存位置而不弹面板（点击修复）。
    private let dragThreshold: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = NSEvent.mouseLocation
        windowOriginAtDragStart = window?.frame.origin ?? .zero
        maxAbsDx = 0
        maxAbsDy = 0
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartLocation.x
        let dy = current.y - dragStartLocation.y
        maxAbsDx = max(maxAbsDx, abs(dx))
        maxAbsDy = max(maxAbsDy, abs(dy))
        window?.setFrameOrigin(NSPoint(
            x: windowOriginAtDragStart.x + dx,
            y: windowOriginAtDragStart.y + dy
        ))
    }

    override func mouseUp(with event: NSEvent) {
        switch ClickDragClassifier.classify(maxAbsDx: maxAbsDx, maxAbsDy: maxAbsDy, threshold: dragThreshold) {
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
    let rows: [SessionRowModel]
    let hotkeyHint: String?
    let onTap: (String) -> Void
    let onOpenPreferences: () -> Void
    let onAcknowledgeAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SessionPanel(rows: rows, onTap: onTap, hotkeyHint: hotkeyHint)
            Divider()
            if !rows.isEmpty {
                Button {
                    onAcknowledgeAll()
                } label: {
                    Label("全部标记已读", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
            }
            Button {
                onOpenPreferences()
            } label: {
                Label("首选项…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            // 退出入口——状态栏图标被刘海/溢出区藏住时，这是唯一能退出 App 的地方（A1）。
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出 apet", systemImage: "power")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - SessionPanelHostController

/// Minimal NSViewController that wraps ``PetPanelRootView`` in a popover.
private final class SessionPanelHostController: NSViewController {

    private var rows: [SessionRowModel]
    private let hotkeyHint: String?
    private let onTap: (String) -> Void
    private let onOpenPreferences: () -> Void
    private let onAcknowledgeAll: () -> Void
    private var hostingController: NSHostingController<PetPanelRootView>?

    init(
        rows: [SessionRowModel],
        hotkeyHint: String?,
        onTap: @escaping (String) -> Void,
        onOpenPreferences: @escaping () -> Void,
        onAcknowledgeAll: @escaping () -> Void
    ) {
        self.rows = rows
        self.hotkeyHint = hotkeyHint
        self.onTap = onTap
        self.onOpenPreferences = onOpenPreferences
        self.onAcknowledgeAll = onAcknowledgeAll
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func makeRoot() -> PetPanelRootView {
        PetPanelRootView(rows: rows, hotkeyHint: hotkeyHint, onTap: onTap,
                         onOpenPreferences: onOpenPreferences, onAcknowledgeAll: onAcknowledgeAll)
    }

    override func loadView() {
        let hc = NSHostingController(rootView: makeRoot())
        hc.view.frame = NSRect(x: 0, y: 0, width: 320, height: 436)
        self.view = hc.view
        addChild(hc)
        hostingController = hc
    }

    func update(rows: [SessionRowModel]) {
        self.rows = rows
        hostingController?.rootView = makeRoot()
    }
}
