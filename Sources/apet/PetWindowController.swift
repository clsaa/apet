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

    // MARK: - State

    private var window: NSWindow?
    private var hostingView: NSHostingView<PetView>?
    private var popover: NSPopover?
    private var currentPresentation: PetPresentation
    private var currentSessions: [Session] = []
    /// Currently rendered pet sprite name ("shiba" | "bichon").
    private var currentPet: String

    // MARK: - Dependencies

    private let focusService: TerminalFocusService

    /// 用户点开一个会话（跳转终端）后回调，AppCoordinator 据此把会话标记为"已读"（红→黄）。
    var onAcknowledge: ((SessionKey) -> Void)?

    // MARK: - Init

    /// - Parameters:
    ///   - focusService: Service used to jump to the terminal that owns a session.
    ///   - pet: Initial pet sprite ("shiba" or "bichon").  Defaults to "shiba".
    init(focusService: TerminalFocusService, pet: String = "shiba") {
        self.focusService = focusService
        self.currentPet = pet
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
        currentPresentation = presentation
        currentSessions = sessions
        hostingView?.rootView = PetView(presentation: presentation, pet: currentPet)

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

    /// Switch the displayed pet sprite.
    ///
    /// Call from ``AppCoordinator/applyConfig(_:)`` whenever `selectedPet` changes.
    /// The swap is live — the hosting view is updated immediately.
    func applyPet(_ pet: String) {
        guard pet != currentPet else { return }
        currentPet = pet
        hostingView?.rootView = PetView(presentation: currentPresentation, pet: currentPet)
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
        let origin = savedPosition() ?? defaultOrigin()
        let contentRect = NSRect(origin: origin, size: windowSize)

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
        let hv = NSHostingView(rootView: PetView(presentation: currentPresentation, pet: currentPet))
        hv.frame = NSRect(origin: .zero, size: windowSize)
        hostingView = hv

        // Drag/click overlay (transparent, sits on top of the hosting view)
        let overlay = DragDetectorView(frame: NSRect(origin: .zero, size: windowSize))
        overlay.onClicked = { [weak self] in
            self?.togglePopover()
        }
        overlay.onDragEnded = { [weak self] in
            self?.savePosition()
        }

        // Container holds both subviews
        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
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

    // MARK: - Private: popover

    private func togglePopover() {
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
        let panelVC = SessionPanelHostController(rows: rows, onTap: { [weak self] id in
            self?.handleSessionTap(id: id)
        })
        let p = NSPopover()
        p.contentViewController = panelVC
        p.behavior = .transient
        p.contentSize = NSSize(width: 320, height: 400)
        self.popover = p

        // Anchor to center of content view; let NSPopover pick the best edge
        let anchor = NSRect(
            x: contentView.bounds.midX,
            y: contentView.bounds.midY,
            width: 1,
            height: 1
        )
        p.show(relativeTo: anchor, of: contentView, preferredEdge: .maxY)
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
    private var hasDragged = false
    // 8pt：4pt 太小，正常点击（尤其触控板）的微小抖动会被误判成拖动→保存位置而不弹面板（点击修复）。
    private let dragThreshold: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = NSEvent.mouseLocation
        windowOriginAtDragStart = window?.frame.origin ?? .zero
        hasDragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartLocation.x
        let dy = current.y - dragStartLocation.y
        if abs(dx) >= dragThreshold || abs(dy) >= dragThreshold {
            hasDragged = true
        }
        window?.setFrameOrigin(NSPoint(
            x: windowOriginAtDragStart.x + dx,
            y: windowOriginAtDragStart.y + dy
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if hasDragged {
            onDragEnded?()
        } else {
            onClicked?()
        }
    }

    // Capture all hit-test queries so events don't fall through to SwiftUI
    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(point) ? self : nil
    }
}

// MARK: - SessionPanelHostController

/// Minimal NSViewController that wraps ``SessionPanel`` in a popover.
private final class SessionPanelHostController: NSViewController {

    private var rows: [SessionRowModel]
    private let onTap: (String) -> Void
    private var hostingController: NSHostingController<SessionPanel>?

    init(rows: [SessionRowModel], onTap: @escaping (String) -> Void) {
        self.rows = rows
        self.onTap = onTap
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let panel = SessionPanel(rows: rows, onTap: onTap)
        let hc = NSHostingController(rootView: panel)
        hc.view.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        self.view = hc.view
        addChild(hc)
        hostingController = hc
    }

    func update(rows: [SessionRowModel]) {
        self.rows = rows
        hostingController?.rootView = SessionPanel(rows: rows, onTap: onTap)
    }
}
