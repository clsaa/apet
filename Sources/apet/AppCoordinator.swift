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
    /// F7：会话元数据持久化（收藏/自定义名）+ 进程内镜像。
    private var sessionMetaStore: SessionMetaStore?
    private var sessionMetas: [String: SessionMeta] = [:]
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
    /// M3-C：QoderWork（agents.db）轮询源。M3-C+ 评审：无条件注册（安装顺序不应击穿零配置）。
    private var qoderWorkWatcher: QoderWorkWatcher?
    /// M3-C+：OpenCode（opencode.db）轮询源。同上无条件注册。
    private var openCodeWatcher: DBPollWatcher?
    /// OpenCode 最近一轮读取结果的健康信号（Task 8b 决策表输入；主线程独占——timer queue=.main）。
    private var openCodeLastOutcome: OpenCodeReadOutcome?
    private var openCodeDBPath: String = ""
    /// 最近一次 OpenCode 健康(去抖:状态变化才更新/记日志)。Preferences 健康区读取。
    private(set) var openCodeHealth: OpenCodeHealth = .ok

    /// Task 8b:健康决策去抖上报(scan 闭包每轮调用,状态未变零成本)。
    private func reportOpenCodeHealthIfChanged() {
        guard let outcome = openCodeLastOutcome else { return }
        let root = (openCodeDBPath as NSString).deletingLastPathComponent
        let health = OpenCodeHealthDecider.decide(
            outcome: outcome,
            dbExists: FileManager.default.fileExists(atPath: openCodeDBPath),
            legacyStorageExists: FileManager.default.fileExists(
                atPath: (root as NSString).appendingPathComponent("storage/session")),
            configDirExists: FileManager.default.fileExists(
                atPath: OpenCodeDBReader.defaultConfigDir(env: ProcessInfo.processInfo.environment)))
        guard health != openCodeHealth else { return }
        openCodeHealth = health
        if let msg = health.userMessage { appendToLog("[warn] \(msg)\n") }
    }
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

        // F7：会话元数据（收藏/自定义名）持久化，落 Application Support。
        let metaAppSupport = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/AgentPet")
        let metaURL = URL(fileURLWithPath: (metaAppSupport as NSString).appendingPathComponent("session-meta.json"))
        let metaStore = SessionMetaStore(url: metaURL)
        self.sessionMetaStore = metaStore
        self.sessionMetas = metaStore.load()
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
                emit: { [weak self] result in self?.applyScanResult(result) },
                // 归一键对齐 hook 路径(emit-event.sh 用 "claude-code"):此前 watcher 默认
                // "claude" 与 hook 的 "claude-code" 不同键 → 同一会话经两源各显一行(重复),
                // 且 M1.5「hook+jsonl 同一 store 融合」因键不同而失效。用 root.agent 统一。
                agent: root.agent
            )
            jsonlWatchers.append(w)
        }

        // ─── 2a-1b. Qoder CLI 数据根（M3-C）：~/.qoder 存在即挂 jsonl watcher（agent=qoder-cli）──
        // CLI 与 Claude Code 同构，transcript 预期 ~/.qoder/projects/**；目录未生成时扫描安全为空。
        // 非 Claude 无 stateRules：内容信号解析失败自动退化 mtime 粗略态（M3-C 降级设计）。
        let qoderCliRoot = (NSHomeDirectory() as NSString).appendingPathComponent(".qoder")
        if FileManager.default.fileExists(atPath: qoderCliRoot) {
            let qcProjects = (qoderCliRoot as NSString).appendingPathComponent("projects")
            let qw = JSONLDirectoryWatcher(
                projectsDir: qcProjects,
                root: qoderCliRoot,
                now: { Date().timeIntervalSince1970 },
                parse: { JSONLParse.parse(path: $0, root: qoderCliRoot) },
                emit: { [weak self] result in self?.applyScanResult(result) },
                agent: "qoder-cli"
            )
            jsonlWatchers.append(qw)
            appendToLog("[info] 发现 ~/.qoder，已挂 Qoder CLI 会话监控（agent=qoder-cli）\n")
        }

        // ─── 2a-1b'. Codex CLI 数据根(M3-C++,2026-07-05 实测):~/.codex/sessions 存在即挂 ──
        // rollout jsonl 首行 session_meta;标题用 session_index.jsonl 的 thread_name(白送);
        // task_started/complete 轮次信号 → CodexRolloutParse 映射,复用 scanner 状态派生。
        let codexRoot = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        let codexSessions = (codexRoot as NSString).appendingPathComponent("sessions")
        if FileManager.default.fileExists(atPath: codexSessions) {
            let codexIndex = CodexSessionIndex(
                path: (codexRoot as NSString).appendingPathComponent("session_index.jsonl"))
            let cw = JSONLDirectoryWatcher(
                projectsDir: codexSessions,
                root: codexRoot,
                now: { Date().timeIntervalSince1970 },
                parse: { CodexRolloutParse.parse(path: $0, root: codexRoot,
                                                 titleLookup: { sid in codexIndex.title(for: sid) }) },
                emit: { [weak self] result in self?.applyScanResult(result) },
                agent: "codex"
            )
            jsonlWatchers.append(cw)
            appendToLog("[info] 发现 ~/.codex/sessions，已挂 Codex 会话监控（agent=codex）\n")
        }

        // ─── 2a-1c. Qoder IDE 数据根（M3-C）：SharedClientCache/cli/projects 存在即挂 ──
        // 实测（2026-07-02）：`task-<id>.session.execution.jsonl`，user/assistant 行 + ISO 时间戳
        // + sessionId/cwd/isSidechain，与 Claude 格式同构，现有 JSONLParse 直接兼容。
        let qoderIDECli = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Qoder/SharedClientCache/cli")
        let qoderIDEProjects = (qoderIDECli as NSString).appendingPathComponent("projects")
        if FileManager.default.fileExists(atPath: qoderIDEProjects) {
            let qi = JSONLDirectoryWatcher(
                projectsDir: qoderIDEProjects,
                root: qoderIDECli,
                now: { Date().timeIntervalSince1970 },
                parse: { JSONLParse.parse(path: $0, root: qoderIDECli) },
                emit: { [weak self] result in self?.applyScanResult(result) },
                agent: "qoder-ide"
            )
            jsonlWatchers.append(qi)
            appendToLog("[info] 发现 Qoder IDE 会话目录，已挂监控（agent=qoder-ide）\n")
        }

        // ─── 2a-2. QoderWork 源（M3-C）：无条件注册——reader 对文件不存在返回 []，
        // 常驻成本趋零；后装 QoderWork 无需重启 apet（M3-C+ 评审：安装顺序击穿零配置）。──
        let qwDBPath = QoderWorkDBReader.defaultDBPath
        let qwReader = QoderWorkDBReader(dbPath: qwDBPath)
        let qwRoot = (qwDBPath as NSString).deletingLastPathComponent // …/QoderWork/data
        qoderWorkWatcher = QoderWorkWatcher(
            read: { qwReader.read() },
            root: qwRoot,
            now: { Date().timeIntervalSince1970 },
            emit: { [weak self] result in self?.applyScanResult(result) }
        )
        appendToLog("[info] QoderWork 会话监控已挂载（粗略状态；DB 出现即生效）\n")

        // ─── 2a-3. OpenCode 源（M3-C+）：只读轮询 opencode.db，静默通道。──
        // 路径解析含 launchctl getenv 兜底（评审 Blocker：GUI 进程读不到 shell rc 的 XDG）。
        let ocPath = OpenCodeDBReader.defaultDBPath(env: ProcessInfo.processInfo.environment)
        openCodeDBPath = ocPath
        let ocReader = OpenCodeDBReader(dbPath: ocPath)
        let ocRoot = (ocPath as NSString).deletingLastPathComponent
        openCodeWatcher = DBPollWatcher(
            scan: { [weak self] now in
                // 契约：DBPollWatcher timer queue=.main——openCodeLastOutcome 主线程独占
                //（评审：该假设只有注释保障，precondition 让漂移当场爆）。
                dispatchPrecondition(condition: .onQueue(.main))
                let outcome = ocReader.read()
                self?.openCodeLastOutcome = outcome
                self?.reportOpenCodeHealthIfChanged()   // Task 8b：去抖上报
                guard let rows = outcome.rows else { return nil }   // .failed → 整轮跳过
                return OpenCodeScanner.scan(rows: rows, root: ocRoot, now: now)
            },
            now: { Date().timeIntervalSince1970 },
            emit: { [weak self] result in self?.applyScanResult(result) }
        )
        appendToLog("[info] OpenCode 会话监控已挂载（路径：\(ocPath)；内容信号优先）\n")
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
            },
            // F1：横幅/声音开关，每次读最新 config（即时生效）。
            channelProvider: { [weak self] in
                (banner: self?.config.notifyBannerEnabled ?? true,
                 sound:  self?.config.notifySoundEnabled  ?? true)
            },
            // B1：点击通知 → 标记已读（红→黄）。store 变更经既有 changeHandler 刷新面板/桌宠。
            onAcknowledge: { [weak self] key in self?.store?.acknowledge(key: key) }
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
            // 桌宠面板的「首选项」按钮入口——不依赖状态栏图标（图标可能被刘海/溢出区藏住）。
            pw.onOpenPreferences = { [weak self] in self?.openPreferences() }
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
            // 面板「全部标记已读」→ 一次性清空所有 waiting 的未读态。
            let ackAll: () -> Void = { [weak self] in
                _ = self?.store?.acknowledgeAll()
            }
            mb.onAcknowledgeAll = ackAll
            pw.onAcknowledgeAll = ackAll

            // F7：收藏（按当前态取反）+ 重命名，写 SessionMetaStore 后立即刷新。
            let toggleFav: (SessionKey) -> Void = { [weak self] key in
                guard let self else { return }
                let cur = self.sessionMetas[SessionMetaMerger.metaKey(key)]?.favorite ?? false
                self.updateMeta(key) { $0.favorite = !cur }
            }
            let rename: (SessionKey, String?) -> Void = { [weak self] key, name in
                self?.updateMeta(key) { $0.customName = name }
            }
            mb.onToggleFavorite = toggleFav
            pw.onToggleFavorite = toggleFav
            mb.onRenameSession = rename
            pw.onRenameSession = rename

            // M3-D-B/C:tab + 分组接线。
            let selTabProvider: () -> SessionTab = { [weak self] in SessionTab(encoded: self?.config.selectedTab ?? "all") }
            let groupsProvider: () -> [String] = { [weak self] in self?.config.sessionGroups ?? [] }
            let selectTab: (SessionTab) -> Void = { [weak self] tab in
                guard let self else { return }
                self.config.selectedTab = tab.encoded
                try? self.configStore.save(self.config)
            }
            let toggleGroupMem: (SessionKey, String) -> Void = { [weak self] key, group in
                self?.updateMeta(key) { $0.groups = GroupMembership.toggle(group, in: $0.groups) }
            }
            // 内联提交:面板已实时校验+去重,这里兜底 isValidName(防非 UI 调用)。
            let commitNewGroup: (String, SessionKey?) -> Void = { [weak self] rawName, keyOrNil in
                guard let self else { return }
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard GroupMembership.isValidName(name) else { return }
                if !self.config.sessionGroups.contains(name) { self.config.sessionGroups.append(name) }
                self.config.selectedTab = SessionTab.group(name).encoded  // 建组后切到该 tab
                try? self.configStore.save(self.config)
                if let key = keyOrNil {
                    self.updateMeta(key) { m in if !m.groups.contains(name) { m.groups.append(name) } }
                } else {
                    self.refreshSessionUI()
                }
            }
            let deleteGroup: (String) -> Void = { [weak self] g in
                guard let self else { return }
                // 确认已在面板二段式内联完成,这里直接执行。
                self.config.sessionGroups.removeAll { $0 == g }
                if self.config.selectedTab == SessionTab.group(g).encoded { self.config.selectedTab = "all" }
                try? self.configStore.save(self.config)
                for (mk, meta) in self.sessionMetas where meta.groups.contains(g) {
                    var m = meta; m.groups.removeAll { $0 == g }
                    self.sessionMetas[mk] = (m == SessionMeta()) ? nil : m
                }
                try? self.sessionMetaStore?.save(self.sessionMetas)
                self.refreshSessionUI()
            }
            mb.selectedTabProvider = selTabProvider; pw.selectedTabProvider = selTabProvider
            mb.sessionGroupsProvider = groupsProvider; pw.sessionGroupsProvider = groupsProvider
            mb.onSelectTab = selectTab; pw.onSelectTab = selectTab
            mb.onToggleGroupMembership = toggleGroupMem; pw.onToggleGroupMembership = toggleGroupMem
            mb.onCommitNewGroupFor = commitNewGroup; pw.onCommitNewGroupFor = commitNewGroup
            mb.onDeleteGroup = deleteGroup; pw.onDeleteGroup = deleteGroup
            // M3-D-F:面板尺寸持久化(仅菜单栏可缩放窗口)。
            mb.panelSizeProvider = { [weak self] in
                CGSize(width: self?.config.panelWidth ?? 360, height: self?.config.panelHeight ?? 480)
            }
            mb.panelFrameProvider = { [weak self] in
                guard let self, self.config.panelPositioned else { return nil }
                return NSRect(x: self.config.panelX, y: self.config.panelY,
                              width: self.config.panelWidth, height: self.config.panelHeight)
            }
            mb.onPanelFrameChange = { [weak self] f in
                guard let self else { return }
                self.config.panelX = Double(f.origin.x)
                self.config.panelY = Double(f.origin.y)
                self.config.panelWidth = Double(f.size.width)
                self.config.panelHeight = Double(f.size.height)
                self.config.panelPositioned = true
                try? self.configStore.save(self.config)
            }
            mb.panelPinnedProvider = { [weak self] in self?.config.panelPinned ?? false }
            mb.onTogglePin = { [weak self] in
                guard let self else { return }
                self.config.panelPinned.toggle()
                try? self.configStore.save(self.config)
            }

            // 面板顶部快捷键提示
            let hint = config.panelHotKey.displayString + " 打开/关闭"
            mb.hotkeyHint = hint
            pw.hotkeyHint = hint

            // 状态栏样式（F2）：counts=彩色计数 / pawprint=单图标。
            mb.menuBarStyle = config.menuBarStyle

            // F3：状态圆点配色
            let palette = DotPalette(from: config.stateColors)
            mb.dotPalette = palette
            pw.dotPalette = palette

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
            let hotkeyOK = hkm.register(keyCode: config.panelHotKey.keyCode, modifiers: config.panelHotKey.modifiers)
            self.hotKeyManager = hkm
            if !hotkeyOK {
                // 评审修复（产品 M4）：失败不再静默——面板 hint 换成失败提示（假提示比没提示更伤信任）。
                appendToLog("[warn] 全局热键 \(config.panelHotKey.displayString) 注册失败（可能被其他 App 占用）\n")
                mb.hotkeyHint = "⚠️ 快捷键注册失败（可能被占用），请在首选项改键"
                pw.hotkeyHint = mb.hotkeyHint
            }

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
            let sessions = self.applyMetas(store.activeSessions())
            self.menuBar?.update(summary: summary, sessions: sessions)
            self.petWindow?.update(summary: summary, sessions: sessions)
        }

        // 4. Replay existing file content (replay: true)
        let replayNow = Date().timeIntervalSince1970
        let replayMode = currentNotifyMode
        do {
            let result = try reader.readNewLines(path: eventsPath, from: nil)
            for line in result.lines {
                // 重放用事件自身 ts 当 now(否则 lastActiveAt 被刷成启动时刻,
                // 旧会话每次重启都"复活"、永不老化)。排序仍由 seq 保证。
                guard let event = AgentEvent.decode(line: Substring(line)) else { continue }
                let eventNow = EventTsParser.epoch(event.ts, fallback: replayNow)
                ingestor.ingest(event: event, now: eventNow, replay: true)
                // replay: true — NotificationGate suppresses all; call for correct flag propagation.
                let key = SessionKey(event: event)
                ns.consider(event: event, session: sessionStore.sessions[key],
                            mode: replayMode, replay: true)
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
        qoderWorkWatcher?.scanOnce()                 // QoderWork seed（同 jsonl 语义：静默、面板可见）
        qoderWorkWatcher?.start(every: 10)           // DB 轮询稍稀，减少读放大
        openCodeWatcher?.scanOnce()                  // OpenCode seed（M3-C+，同款语义）
        openCodeWatcher?.start(every: 10)

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
                       waitingEndedAfter: self.config.waitingEndedAfterSec,
                       // P2:终端还开着(/dev/tty 存在)的闲置会话不老化驱逐,用户随时回来。
                       isAlive: { TtyLiveness.isAlive(tty: $0.terminal?.tty, pid: $0.terminal?.pid) })
            let timerSessions = self.applyMetas(store.activeSessions())
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
        qoderWorkWatcher?.stop()
        openCodeWatcher?.stop()   // M3-C+ 评审：漏停则 teardown 后 timer 继续打事件
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
            customStore: customStore,
            openCodeHealthProvider: { [weak self] in self?.openCodeHealth ?? .ok }
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
        // 面板私有字段(selectedTab/sessionGroups/panelWidth/Height)由面板运行时直接写 config,
        // 不经 Preferences。Preferences 存盘用打开时的旧快照——直接 config=newConfig 会把面板期间
        // 建的分组/切的 tab/拖的尺寸回滚(架构评审 config clobber)。故保留 live 值。
        var merged = newConfig
        merged.selectedTab   = config.selectedTab
        merged.sessionGroups = config.sessionGroups
        merged.panelWidth    = config.panelWidth
        merged.panelHeight   = config.panelHeight
        merged.panelPinned   = config.panelPinned
        merged.panelX        = config.panelX
        merged.panelY        = config.panelY
        merged.panelPositioned = config.panelPositioned
        config = merged

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
        var hotkeyOK = true
        if newConfig.panelHotKey != oldHotKey {
            hotkeyOK = hotKeyManager?.register(keyCode: newConfig.panelHotKey.keyCode,
                                               modifiers: newConfig.panelHotKey.modifiers) ?? true
        }

        // Update panel hotkey hint（评审修复 产品M4：失败显真话，不显假提示）。
        let hint = hotkeyOK
            ? newConfig.panelHotKey.displayString + " 打开/关闭"
            : "⚠️ 快捷键注册失败（可能被占用），请在首选项改键"
        menuBar?.hotkeyHint = hint
        petWindow?.hotkeyHint = hint

        // 状态栏样式（F2）+ 状态圆点配色（F3）立即生效：更新后用当前 summary 重绘。
        let palette = DotPalette(from: newConfig.stateColors)
        menuBar?.dotPalette = palette
        petWindow?.dotPalette = palette
        if let store = store {
            menuBar?.menuBarStyle = newConfig.menuBarStyle
            let sessions = applyMetas(store.activeSessions())
            menuBar?.update(summary: store.summary(), sessions: sessions)
            petWindow?.update(summary: store.summary(), sessions: sessions)
        }
    }

    // MARK: - Private: F7 会话元数据

    /// 把持久化的 meta（收藏/自定义名）镜像进会话列表，供 UI 渲染。
    private func applyMetas(_ sessions: [Session]) -> [Session] {
        guard !sessionMetas.isEmpty else { return sessions }
        return sessions.map { s in
            SessionMetaMerger.apply(into: s, meta: sessionMetas[SessionMetaMerger.metaKey(s.key)])
        }
    }




    private func updateMeta(_ key: SessionKey, _ mutate: (inout SessionMeta) -> Void) {
        let mk = SessionMetaMerger.metaKey(key)
        var meta = sessionMetas[mk] ?? SessionMeta()
        mutate(&meta)
        if meta == SessionMeta() { sessionMetas[mk] = nil } else { sessionMetas[mk] = meta }
        try? sessionMetaStore?.save(sessionMetas)
        refreshSessionUI()
    }

    /// 用当前 store 快照 + meta 重绘菜单栏与桌宠面板。
    private func refreshSessionUI() {
        guard let store = store else { return }
        let sessions = applyMetas(store.activeSessions())
        menuBar?.update(summary: store.summary(), sessions: sessions)
        petWindow?.update(summary: store.summary(), sessions: sessions)
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
            // 评审修复（架构 M2/产品 M1/测试 B2 三重确认）：本方法不再手动刷新 UI。
            // store 的每次变更都会 emit → changeHandler → applyMetas 后刷新；原先此处的
            // 裸 activeSessions() 刷新会用无 favorite/customName 的列表覆盖面板（F7 闪烁回归）。
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
                // M3-C：QoderWork/Qoder IDE 会话点击 → 激活对应 App（无终端概念，App 级跳转）。
                // opencode 不注入 terminal：TUI 宿主终端未知，诚实降级（M3-C+ 评审 B3）。
                if key.agent == "qoder-work" {
                    ev.terminal = TerminalRef(kind: .other, bundleId: "com.qoder.work")
                } else if key.agent == "qoder-ide" {
                    ev.terminal = TerminalRef(kind: .other, bundleId: "com.qoder.ide")
                } else if key.agent == "codex-desktop" {
                    // Codex 桌面端会话:点击激活 Codex.app(仅切到 App 档);CLI 端(codex)无终端信息不注入。
                    ev.terminal = TerminalRef(kind: .other, bundleId: "com.openai.codex")
                }
                jsonlSeqCounter += 1
                _ = ingestor.ingest(event: ev, now: now, replay: false)
                // ⚠️ 绝不调用 notificationService.consider（jsonl 不发通知，架构-B1）
                // 评审修复（架构 m6）：QoderWork 是**粗略态**（仅按活动时间，无内容信号），
                // 其 waitingStop 不代表真实「等你」——预置已读（黄点），不进「等你」置顶、
                // 不污染未读徽标；真实 attention 语义只留给有内容信号的源。
                // M3-C+ 评审 B2：集合判定取代 agent 字符串 if（别每接一源加一个分支）。
                if AgentManifest.dbBackedAgents.contains(key.agent), kind == .stop {
                    _ = store.acknowledge(key: key)
                }

            case .stale:
                // 文件消失/过期：仅 jsonl 来源的会话才打灰（hook 会话由 hook 路径或定时器管理）。
                _ = store.markStaleSessionIfJSONL(key, now: now)
            }
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
