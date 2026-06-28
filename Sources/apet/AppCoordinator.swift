import Foundation
import AppKit
@preconcurrency import UserNotifications
import AgentPetCore
import AppShellKit

/// 应用协调者：持有 SessionStore + NDJSONIngestor，监听 events.ndjson 增量变更，
/// 启动时回放历史，运行期间实时 ingest，定期 markStale + reap。
/// 必须在 @MainActor 上持有（满足 SessionStore 非线程安全约束）。
@MainActor
final class AppCoordinator {

    // MARK: - Config (persistent)

    let eventsPath: String
    let logPath: String

    /// apet-managed hook marker；单一事实源 HookConstants.marker（消除重复字面量，M2-E）。
    static let hookMarker = HookConstants.marker

    private let configStore: ConfigStore
    private var config: AppConfig

    private let tickInterval: Double = 60         // 1 min

    // MARK: - State

    private var store: SessionStore?
    private var ingestor: NDJSONIngestor?
    private let reader = EventTailReader()
    private var checkpoint: Checkpoint?

    private var notificationService: NotificationService?
    private var menuBar: MenuBarController?
    private var petWindow: PetWindowController?

    private var watchSource: DispatchSourceFileSystemObject?
    private var watchFd: Int32 = -1
    private var reapTimer: DispatchSourceTimer?
    private var isStopped = false

    private var jsonlWatchers: [JSONLDirectoryWatcher] = []
    private var hotKeyManager: HotKeyManager?
    /// 进程内单调计数器，用于 jsonl 合成事件的唯一 eventId（替代 UUID，防 seenEventIds 慢泄漏）。
    private var jsonlSeqCounter: Int = 0

    private var preferencesController: PreferencesWindowController?

    /// Shared custom-pet store (created once when not headless; nil in headless mode).
    private var customStore: CustomPetStore?
    /// Controls the upload → cutout → apply-pet flow; nil in headless mode.
    private var uploadController: PetUploadController?

    // MARK: - Derived config helpers

    /// Convert the string-encoded notifyMode into the typed enum consumed by NotificationDecider.
    private var currentNotifyMode: NotifyMode {
        config.notifyMode == "everyStop" ? .everyStop : .attentionOnly
    }

    // MARK: - Init

    init() {
        let env = ProcessInfo.processInfo.environment
        let appSupport = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/AgentPet")
        self.eventsPath = env["AGENTPET_EVENTS"] ?? AppPaths.eventsFile
        self.logPath = env["AGENTPET_LOG"]
            ?? (appSupport as NSString).appendingPathComponent("apet.log")

        let configURL = URL(fileURLWithPath: appSupport)
            .appendingPathComponent("config.json")
        let store = ConfigStore(url: configURL)
        self.configStore = store
        self.config = store.load()
    }

    // MARK: - Lifecycle

    func start(headless: Bool = false) {
        // 1. Create parent dirs; touch events file if missing
        let fm = FileManager.default
        for path in [eventsPath, logPath] {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: eventsPath) {
            fm.createFile(atPath: eventsPath, contents: nil)
        }

        // 2. Create store + ingestor
        let sessionStore = SessionStore()
        let ingestor = NDJSONIngestor(store: sessionStore)
        self.store = sessionStore
        self.ingestor = ingestor

        // ─── 2a. Setup JSONL directory watchers（多 root 并行，M2-B）──────────────
        // 共享同一 NDJSONIngestor（唯一 seq 源）；source=.jsonl；replay=false；不接 NotificationService。
        // ⚠️ 仅在此创建 watchers；seed 扫描(scanOnce) + start 推迟到 change handler 注册与 hook replay 之后
        //    （Step 4 末），否则 seed 事件在 handler 注册前发射 → 当前会话不会立即上屏（Task8 评审 I#1）。

        // 通过 DataRootDiscovery 合并"已配置 roots"与"自动发现 roots"（M2-B）。
        // config.dataRoots 中的路径已经是 absolute expanded path（defaults 用 .path），直接传入。
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let disc = DataRootDiscovery.discover(
            home: home,
            existing: config.dataRoots,
            excluded: config.excludedRoots,
            fileOps: RealFileOps()
        )

        // 知情同意 + 持久化：自动发现的新 root 追加到 config 并持久化，避免每次启动重复发现。
        // M2-B Fix MAJOR-2：标记 isAutoDiscovered=true，供首选项面板显示"自动发现"徽标；
        //                   同时发一条系统通知（懒授权：已授权才发，不向未授权用户强制弹请求）。
        if !disc.newlyDiscovered.isEmpty {
            let newRoots = disc.newlyDiscovered.map { root -> DataRoot in
                var r = root
                r.isAutoDiscovered = true
                return r
            }
            config.dataRoots.append(contentsOf: newRoots)
            try? configStore.save(config)
            let count = disc.newlyDiscovered.count
            appendToLog("[info] 自动发现并加入 \(count) 个 Claude profile，可在首选项移除\n")
            sendDiscoveryNotification(count: count)
        }

        for root in disc.roots {
            let rootPath = root.path
            let projectsDir = (rootPath as NSString).appendingPathComponent("projects")
            let w = JSONLDirectoryWatcher(
                projectsDir: projectsDir,
                root: rootPath,
                now: { Date().timeIntervalSince1970 },
                parse: { JSONLParse.parse(path: $0, root: rootPath) },
                emit: { [weak self] result in self?.applyScanResult(result) }
            )
            jsonlWatchers.append(w)
        }
        // ──────────────────────────────────────────────────────────────────────────
        // 2b. Create and start NotificationService (safe to call before replay).
        // Single shared TerminalFocusService instance injected into both consumers (Fix M-3).
        let focusService = TerminalFocusService()
        let ns = NotificationService(
            focusService: focusService,
            sessionLookup: { [weak self] key in self?.store?.sessions[key] },
            // Closure reads the latest config each time it is called (after applyConfig), so
            // DND changes take effect on the very next notification without a restart.
            dndProvider: { [weak self] in
                DNDWindow(
                    enabled:  self?.config.dndEnabled   ?? false,
                    startMin: self?.config.dndStartMin  ?? 0,
                    endMin:   self?.config.dndEndMin    ?? 0
                )
            }
        )
        notificationService = ns
        ns.start()

        // 2c. Create MenuBarController + PetWindowController for real GUI app (skip in headless mode)
        if !headless {
            let isCompact = config.displayMode == "compact"
            let mb = MenuBarController(focusService: focusService)
            // Build a shared CustomPetStore; rootDir under ~/Library/Application Support/AgentPet/pets-custom.
            let appSupport = (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/Application Support/AgentPet")
            let petsCustomDir = (appSupport as NSString).appendingPathComponent("pets-custom")
            let customStore = CustomPetStore(
                rootDir: petsCustomDir,
                fileOps: RealFileOps(),
                idProvider: { UUID().uuidString }
            )
            self.customStore = customStore

            // Wire up the applyPet callback: updates live pet window + persists config.
            // Fix MAJOR-1：保存完毕后通知首选项窗口刷新 selectedPet，防止旧快照在"保存"时覆盖新宠物。
            let applyPetClosure: (PetKind) -> Void = { [weak self] kind in
                guard let self else { return }
                self.petWindow?.applyPet(kind)
                self.config.selectedPet = Self.petKindToString(kind)
                try? self.configStore.save(self.config)
                self.preferencesController?.refreshConfig(self.config)
            }
            self.uploadController = PetUploadController(
                store: customStore,
                applyPet: applyPetClosure
            )

            let initialSelection = PetSelection.parse(config.selectedPet)
            let pw = PetWindowController(
                focusService: focusService,
                selection: initialSelection,
                customStore: customStore,
                compact: isCompact
            )
            mb.petVisibilityProvider = { [weak pw] in pw?.isVisible ?? false }
            mb.onTogglePet = { [weak pw] in
                guard let pw else { return }
                pw.setVisible(!pw.isVisible)
            }
            mb.onOpenPreferences = { [weak self] in
                self?.openPreferences()
            }
            mb.summaryProvider = { [weak self] in
                (running: self?.store?.summary().runningCount ?? 0,
                 waiting: self?.store?.summary().waitingCount ?? 0)
            }
            // Fix 6：面板感知 hook 是否已装——任一 data root 的 settings.json 含 apet marker 即视为已启用。
            mb.hookInstalledProvider = { [weak self] in
                guard let self else { return false }
                let installer = HookInstaller()
                for root in self.config.dataRoots {
                    let url = URL(fileURLWithPath: root.path).appendingPathComponent("settings.json")
                    if (try? installer.isInstalled(settingsURL: url, marker: AppCoordinator.hookMarker)) == true {
                        return true
                    }
                }
                return false
            }
            // 点开会话 → 标记已读（红→黄）。acknowledge 内部 emit 变更，
            // 已注册的 changeHandler 会随之刷新 menuBar/petWindow，无需手动刷新。
            let ack: (SessionKey) -> Void = { [weak self] key in
                self?.store?.acknowledge(key: key)
            }
            mb.onAcknowledge = ack
            pw.onAcknowledge = ack

            // 面板顶部快捷键提示
            let hint = config.panelHotKey.displayString + " 打开/关闭"
            mb.hotkeyHint = hint
            pw.hotkeyHint = hint

            menuBar = mb
            petWindow = pw

            // Apply display mode from config.（pet 和 compact 都算"显示窗口"，仅 menuBarOnly 隐藏）
            let showPet = config.displayMode != "menuBarOnly"
            if showPet {
                pw.setVisible(true)
            }
            // Activate the app once so AppKit delivers window-order events properly.
            NSApp.activate(ignoringOtherApps: true)

            // 注册全局热键（不需辅助功能权限）
            let hkm = HotKeyManager()
            hkm.onActivate = { [weak self] in self?.togglePanel() }
            hkm.register(keyCode: config.panelHotKey.keyCode, modifiers: config.panelHotKey.modifiers)
            self.hotKeyManager = hkm

            // ── 首启引导（just-in-time，非 headless 模式专属）──────────────────────
            // 用 UserDefaults 持久化"已展示"标志，避免 AppConfig 改动；
            // key 固定为 "apet.onboardingShown" 便于测试环境重置。
            let onboardingKey = "apet.onboardingShown"
            let onboardingShown = UserDefaults.standard.bool(forKey: onboardingKey)
            OnboardingWindow.showIfFirstRun(onboardingShown: onboardingShown) {
                UserDefaults.standard.set(true, forKey: onboardingKey)
            }
            // ──────────────────────────────────────────────────────────────────────
        }

        // 3. Register change handler: log every store mutation + refresh menu bar
        sessionStore.addChangeHandler { [weak self] changes, isReplay in
            guard let self, let store = self.store else { return }
            let summary = store.summary()
            let line = "[change] \(changes) replay=\(isReplay) summary=\(summary)\n"
            self.appendToLog(line)
            let sessions = store.activeSessions()
            self.menuBar?.update(summary: summary, sessions: sessions)
            self.petWindow?.update(summary: summary, sessions: sessions)
        }

        // 4. Replay existing file content (replay: true)
        let replayNow = Date().timeIntervalSince1970
        let replayMode = currentNotifyMode
        do {
            let result = try reader.readNewLines(path: eventsPath, from: nil)
            for line in result.lines {
                ingestor.ingest(line: Substring(line), now: replayNow, replay: true)
                // replay: true — NotificationGate suppresses all; call for correct flag propagation.
                if let event = AgentEvent.decode(line: Substring(line)) {
                    let key = SessionKey(event: event)
                    ns.consider(event: event, session: sessionStore.sessions[key],
                                mode: replayMode, replay: true)
                }
            }
            checkpoint = result.next
            appendToLog("[start] replay done, lines=\(result.lines.count), offset=\(result.next.offset)\n")
        } catch {
            appendToLog("[error] replay failed: \(error)\n")
        }

        // 4b. jsonl seed：change handler 已注册、hook replay 已完成后再种子扫描，
        //     使当前正在跑的会话立即上屏（hook 的 ended 终态仍保护，不被 jsonl 复活）。
        jsonlWatchers.forEach { $0.scanOnce() }     // seed（replay=false；jsonl 不接 NotificationService，天然静默）
        jsonlWatchers.forEach { $0.start(every: 8) } // 每 8 秒定期扫描，queue:.main

        // 5. Live file watch via DispatchSource
        openWatchSource()

        // 6. Reap timer: every 60 s, markStale + reap + refresh menu bar
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let store = self.store else { return }
            let now = Date().timeIntervalSince1970
            _ = store.markStale(now: now, timeout: self.config.staleAfterSec)
            _ = store.ageReadToStale(now: now, readGrayAfter: self.config.readGrayAfterSec)
            store.reap(now: now,
                       endedAfter: self.config.endedAfterSec,
                       waitingEndedAfter: self.config.waitingEndedAfterSec)
            let timerSessions = store.activeSessions()
            self.menuBar?.update(summary: store.summary(), sessions: timerSessions)
            self.petWindow?.update(summary: store.summary(), sessions: timerSessions)
        }
        timer.resume()
        reapTimer = timer
    }

    func stop() {
        isStopped = true
        watchSource?.cancel()
        watchSource = nil
        if watchFd >= 0 {
            Darwin.close(watchFd)
            watchFd = -1
        }
        reapTimer?.cancel()
        reapTimer = nil
        jsonlWatchers.forEach { $0.stop() }
        jsonlWatchers.removeAll()
        hotKeyManager?.unregister()
        hotKeyManager = nil
    }

    // MARK: - Preferences

    /// Open the Preferences window, creating it if needed.
    ///
    /// If the window is already visible, it is simply brought to front.
    func openPreferences() {
        if let pc = preferencesController, pc.window?.isVisible == true {
            pc.show()
            return
        }
        let pc = PreferencesWindowController(
            config: config,
            configStore: configStore,
            onSave: { [weak self] newConfig in
                self?.applyConfig(newConfig)
            },
            uploadController: uploadController,
            customStore: customStore
        )
        preferencesController = pc
        pc.show()
    }

    // MARK: - Config application

    /// Apply a newly-saved configuration at runtime (no restart needed for thresholds/mode).
    ///
    /// - Thresholds (`staleAfterSec`, `endedAfterSec`, `waitingEndedAfterSec`) take effect
    ///   on the **next** reap-timer tick.
    /// - `notifyMode` takes effect on the **next** inbound event.
    /// - `displayMode`, `panelHotKey`, `selectedPet` are applied immediately.
    private func applyConfig(_ newConfig: AppConfig) {
        let oldHotKey = config.panelHotKey
        config = newConfig

        // Apply display mode immediately.
        if let pw = petWindow {
            let shouldShow = newConfig.displayMode != "menuBarOnly"
            if shouldShow != pw.isVisible {
                pw.setVisible(shouldShow)
            }
            // Apply selected pet sprite immediately (Fix I-2).
            pw.applyPet(PetSelection.parse(newConfig.selectedPet))
            // Apply compact mode immediately.
            pw.applyCompact(newConfig.displayMode == "compact")
        }

        // Re-register hot key if changed.
        if newConfig.panelHotKey != oldHotKey {
            hotKeyManager?.register(keyCode: newConfig.panelHotKey.keyCode,
                                    modifiers: newConfig.panelHotKey.modifiers)
        }

        // Update panel hotkey hint.
        let hint = newConfig.panelHotKey.displayString + " 打开/关闭"
        menuBar?.hotkeyHint = hint
        petWindow?.hotkeyHint = hint
    }

    // MARK: - Private: helpers

    /// Converts a ``PetKind`` to the string form stored in ``AppConfig.selectedPet``.
    private static func petKindToString(_ kind: PetKind) -> String {
        switch kind {
        case .builtin(let name): return name
        case .custom(let id):   return "custom:\(id)"
        }
    }

    // MARK: - Private: panel toggle (hot key target)

    /// 全局热键触发：根据显示模式决定在哪个入口切换面板。
    private func togglePanel() {
        if let pw = petWindow, pw.isVisible {
            // pet 或 compact 模式：切换 pet 窗口上的 popover
            pw.togglePopover()
        } else {
            // menuBarOnly 或 pet 窗口不可见：切换菜单栏 popover
            menuBar?.showPanel()
        }
    }

    // MARK: - Private: JSONL watcher result handler

    /// JSONLDirectoryWatcher emit 回调——在 DispatchQueue.main 上触发（watcher timer 已 queue:.main），
    /// @MainActor 上下文安全，直接调用 ingestor.ingest / store.markStaleSession。
    /// 绝不调用 NotificationService（jsonl 路径永不发 OS 通知，架构-B1）。
    private func applyScanResult(_ result: ScanResult) {
        guard let ingestor = self.ingestor, let store = self.store else { return }
        switch result {
        case .ignore:
            return

        case .observe(let state, let key, let cwd, let title):
            let now = Date().timeIntervalSince1970
            var changed = false
            switch state {
            case .running, .waitingStop:
                // .running → 合成 busy；.waitingStop → 合成 stop（会话进入 waiting 等用户）
                let kind: EventKind = (state == .running) ? .busy : .stop
                var ev = AgentEvent(
                    v: 1,
                    eventId: "jsonl:\((key.root as NSString).lastPathComponent):\(key.sessionId):\(jsonlSeqCounter)",
                    agent: key.agent,
                    kind: kind,
                    sessionId: key.sessionId,
                    root: key.root,
                    cwd: cwd,
                    title: title,
                    ts: ""
                )
                ev.source = .jsonl
                jsonlSeqCounter += 1
                changed = !ingestor.ingest(event: ev, now: now, replay: false).isEmpty
                // ⚠️ 绝不调用 notificationService.consider（jsonl 不发通知，架构-B1）

            case .stale:
                // 文件消失/过期：仅 jsonl 来源的会话才打灰（hook 会话由 hook 路径或定时器管理）。
                // Fix 4：守卫逻辑收敛到 store.markStaleSessionIfJSONL（便于单测、保证 hook 不被降级）。
                changed = !store.markStaleSessionIfJSONL(key, now: now).isEmpty
            }

            // 仅在 store 真有变更时刷新 UI（避免每 8s 对未变会话空算，Task8 评审 Minor#1）
            guard changed else { return }
            let summary = store.summary()
            let sessions = store.activeSessions()
            menuBar?.update(summary: summary, sessions: sessions)
            petWindow?.update(summary: summary, sessions: sessions)
        }
    }

    // MARK: - Private: file watch

    private func openWatchSource() {
        guard !isStopped else { return }
        guard let ingestor else { return }

        let fd = Darwin.open(eventsPath, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            appendToLog("[warn] cannot open events file for kqueue watch: \(eventsPath)\n")
            return
        }
        watchFd = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data

            if flags.contains(.delete) || flags.contains(.rename) {
                // File rotated — cancel current source, reopen after short delay
                source.cancel()
                Darwin.close(fd)
                self.watchFd = -1
                self.checkpoint = nil
                self.watchSource = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.openWatchSource()
                }
                return
            }

            // .write / .extend: read new content
            let now = Date().timeIntervalSince1970
            let liveMode = self.currentNotifyMode
            do {
                let result = try self.reader.readNewLines(path: self.eventsPath, from: self.checkpoint)
                for line in result.lines {
                    // Decode once: ingest(event:) avoids a second decode for notification dispatch.
                    if let event = AgentEvent.decode(line: Substring(line)) {
                        ingestor.ingest(event: event, now: now, replay: false)
                        if let ns = self.notificationService {
                            let key = SessionKey(event: event)
                            ns.consider(event: event, session: self.store?.sessions[key],
                                        mode: liveMode, replay: false)
                        }
                    }
                }
                if !result.lines.isEmpty {
                    self.checkpoint = result.next
                }
            } catch {
                self.appendToLog("[error] tail read: \(error)\n")
            }
        }

        source.setCancelHandler {
            // fd already closed by caller; nothing to do here
        }

        source.resume()
        watchSource = source

        // Eager drain: read any lines written between replay-end and source-resume
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped, let ingestor = self.ingestor else { return }
            let now = Date().timeIntervalSince1970
            let drainMode = self.currentNotifyMode
            do {
                let result = try self.reader.readNewLines(path: self.eventsPath, from: self.checkpoint)
                for line in result.lines {
                    // Decode once: reuse the same event for ingest + notification.
                    if let event = AgentEvent.decode(line: Substring(line)) {
                        ingestor.ingest(event: event, now: now, replay: false)
                        if let ns = self.notificationService {
                            let key = SessionKey(event: event)
                            ns.consider(event: event, session: self.store?.sessions[key],
                                        mode: drainMode, replay: false)
                        }
                    }
                }
                if !result.lines.isEmpty {
                    self.checkpoint = result.next
                }
            } catch {
                self.appendToLog("[error] eager drain: \(error)\n")
            }
        }
    }

    // MARK: - Private: discovery notification (MAJOR-2)

    /// 自动发现新 Claude profile 时发一条系统通知，告知用户已纳入监控。
    ///
    /// 策略：懒授权——仅在用户已授权时发送；若尚未授权，静默跳过，不弹权限请求。
    /// （session 事件通知才会触发 just-in-time 授权请求）。
    private func sendDiscoveryNotification(count: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break   // 已授权，可以发
            default:
                return  // 未授权 / 被拒绝 → 静默跳过，不弹请求
            }
            let content = UNMutableNotificationContent()
            content.title = "apet 发现 \(count) 个 Claude profile"
            content.body  = "已加入监控，可在首选项移除"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "apet.discovery.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            Task { @MainActor in
                center.add(request) { _ in }
            }
        }
    }

    // MARK: - Private: logging

    private func appendToLog(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: logPath) {
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            }
        } else {
            fm.createFile(atPath: logPath, contents: data)
        }
    }
}
