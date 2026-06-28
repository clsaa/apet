import AppKit
import SwiftUI
import AgentPetCore
import AppShellKit

// MARK: - PanelRootView

/// Wraps ``SessionPanel`` with action footer buttons. Private to this file.
private struct PanelRootView: View {
    let rows: [SessionRowModel]
    let petVisible: Bool
    let onTap: (String) -> Void
    let onTogglePet: () -> Void
    let onOpenPreferences: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SessionPanel(rows: rows, onTap: onTap)
            Divider()

            // 隐藏/显示宠物
            Button {
                onTogglePet()
            } label: {
                Text(petVisible ? "隐藏宠物" : "显示宠物")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            // 首选项…（齿轮入口）
            Button {
                onOpenPreferences()
            } label: {
                Label("首选项…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)

            // Part D: 低调常驻增强入口——让只看面板的用户也知道有精确跳转/通知可开启。
            Button {
                onOpenPreferences()
            } label: {
                Label("开启精确跳转/通知…", systemImage: "bolt.badge.a.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor.opacity(0.6))
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)

            // 退出
            Button {
                onQuit()
            } label: {
                Text("退出 AgentPet")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
        .frame(width: 320)
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
        applyPresentation(MenuBarPresenter.make(from: summary))
        // Push new rows into the live hosting controller so the popover updates in-place.
        panelHosting?.rootView = makePanelRootView()
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
    }

    // MARK: - Private: button appearance

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

    /// Build the SwiftUI root view with current rows and callbacks.
    private func makePanelRootView() -> PanelRootView {
        let rows = currentSessions.map(SessionRowMapper.make)
        return PanelRootView(
            rows: rows,
            petVisible: petVisibilityProvider?() ?? false,
            onTap: { [weak self] id in self?.handleSessionTap(id: id) },
            onTogglePet: { [weak self] in
                self?.onTogglePet?()
                // Re-render the panel so the button label flips immediately.
                self?.panelHosting?.rootView = self?.makePanelRootView() ?? PanelRootView(
                    rows: [], petVisible: false,
                    onTap: { _ in }, onTogglePet: {}, onOpenPreferences: {}, onQuit: {}
                )
            },
            onOpenPreferences: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onOpenPreferences?()
            },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
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

        let terminal = session.terminal
        // Part C: jsonl-inferred sessions have no terminal info at all.
        // Capture before going off-main so we can check it in the alert block.
        let isJsonlSession = (terminal == nil)
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
                    let alert = NSAlert()
                    alert.messageText = "无法跳转到会话"
                    // .targetGone=窗口已关；.unsupported=无终端信息（如 jsonl 推断会话）。文案兼顾两者。
                    var infoText = "无法跳转到会话终端（可能已关闭，或终端信息不可用）。"
                    // Part C: just-in-time hook hint — only for jsonl-inferred sessions,
                    // throttled to once per session and capped globally by HookHintThrottle.
                    if isJsonlSession && self.hookHintThrottle.shouldHint(sessionKey: id) {
                        infoText += "\n\n💡 安装 Hook 可精确跳到这个 tab（会改 settings.json，自动备份/一键卸载）→ 在「首选项」中开启。"
                    }
                    alert.informativeText = infoText
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "好的")
                    alert.runModal()
                    self.isShowingTapAlert = false
                }
            }
        }
    }
}
