import AppKit
import SwiftUI
import AppShellKit
import UserNotifications

// MARK: - HookRowView

/// Per-data-root hook install/uninstall row with gated confirmation.
///
/// ⛔ The install action only executes **after** the user explicitly confirms the
/// confirmation dialog — it never writes silently to settings.json.
private struct HookRowView: View {

    let root: DataRoot
    let hookMarker: String
    let runnerPath: String
    let onRemove: () -> Void

    @State private var isInstalled: Bool = false
    @State private var showInstallConfirm: Bool = false
    @State private var showUninstallConfirm: Bool = false
    @State private var errorText: String?
    /// Pre-computed preview of hook entries shown inside the install confirmation dialog.
    @State private var installPreviewText: String = ""

    private var settingsURL: URL {
        URL(fileURLWithPath: root.path).appendingPathComponent("settings.json")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Root info row ─────────────────────────────────────────────
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(root.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(root.agent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("移除此数据根")
            }

            // ── Hook status + action row ──────────────────────────────────
            HStack(spacing: 10) {
                // Status badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(isInstalled ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(isInstalled ? "Hook 已安装" : "Hook 未安装")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isInstalled {
                    Button("卸载 Hook") { showUninstallConfirm = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("安装 Hook") {
                        // Part A: Pre-compute preview so it's shown in the confirmation dialog.
                        installPreviewText = HookInstaller.previewLines(
                            scriptPath: runnerPath,
                            eventsPath: AppPaths.eventsFile,
                            rootPath: root.path
                        )
                        showInstallConfirm = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            // ── Error label ───────────────────────────────────────────────
            if let err = errorText {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .onAppear { refreshStatus() }

        // ── Install confirmation ──────────────────────────────────────────
        .confirmationDialog(
            "安装 Claude Code Hook",
            isPresented: $showInstallConfirm,
            titleVisibility: .visible
        ) {
            Button("确认安装") { performInstall() }
            Button("取消", role: .cancel) {}
        } message: {
            // Part A: include previewLines so the user sees exactly what will be written
            // before confirming. installPreviewText is populated when the button is tapped.
            Text("""
                将在以下文件中写入 apet hook 条目，并自动备份原文件：
                \(settingsURL.path)
                → 备份路径：\(settingsURL.path).apet.bak

                \(installPreviewText)

                继续？
                """)
        }

        // ── Uninstall confirmation ────────────────────────────────────────
        .confirmationDialog(
            "卸载 Claude Code Hook",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("确认卸载", role: .destructive) { performUninstall() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从以下文件中移除 apet hook 条目：\n\(settingsURL.path)")
        }
    }

    // MARK: - Private helpers

    private func refreshStatus() {
        let installer = HookInstaller()
        errorText = nil
        do {
            isInstalled = try installer.isInstalled(settingsURL: settingsURL, marker: hookMarker)
        } catch HookInstallError.malformedSettings {
            isInstalled = false
            errorText = "settings.json 解析失败"
        } catch {
            isInstalled = false
            errorText = error.localizedDescription
        }
    }

    /// ⛔ Only called after explicit user confirmation in the dialog above.
    private func performInstall() {
        errorText = nil
        let installer = HookInstaller()
        // Build the full env-prefixed command so the hook script receives
        // AGENTPET_OUT and AGENTPET_ROOT even when running in Claude's env.
        let command = HookInstaller.hookCommand(
            scriptPath: runnerPath,
            eventsPath: AppPaths.eventsFile,
            rootPath: root.path
        )
        do {
            try installer.install(into: settingsURL, runnerPath: command, marker: hookMarker)
            isInstalled = true
        } catch {
            errorText = "安装失败：\(error.localizedDescription)"
        }
    }

    /// ⛔ Only called after explicit user confirmation in the dialog above.
    private func performUninstall() {
        errorText = nil
        let installer = HookInstaller()
        do {
            try installer.uninstall(from: settingsURL, marker: hookMarker)
            isInstalled = false
        } catch {
            errorText = "卸载失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - PreferencesView

/// SwiftUI form for all user-configurable apet preferences.
///
/// The view holds a local copy of `AppConfig` as `@State`; the caller's `onSave` closure
/// is invoked only when the user presses 保存.
struct PreferencesView: View {

    @State private var config: AppConfig
    private let configStore: ConfigStore
    private let onSave: (AppConfig) -> Void

    /// apet-managed hook marker written into settings.json. Never change once shipped
    /// (it is the key used to identify and cleanly remove apet entries).
    private let hookMarker = "apet-1"

    /// Path to the hook runner script installed inside the app bundle.
    private var runnerPath: String {
        Bundle.main.resourceURL?
            .appendingPathComponent("apet-emit-event.sh").path
            ?? "/usr/local/bin/apet-emit-event"
    }

    @State private var newRootPath = ""
    @State private var saveError: String?

    // MARK: - Health panel state (Part B)
    @State private var notifStatusForHealth: NotificationStatus = .notDetermined
    @State private var hookStatusForHealth: HookStatus = .notInstalled
    @State private var jsonlStatusForHealth: JSONLSourceStatus = .pathMissing
    @State private var hasOtherProfiles: Bool = false
    /// Changing this UUID forces `.task(id:)` to re-run `refreshHealthStatus`.
    @State private var healthRefreshID = UUID()

    init(config: AppConfig, configStore: ConfigStore, onSave: @escaping (AppConfig) -> Void) {
        _config = State(initialValue: config)
        self.configStore = configStore
        self.onSave = onSave
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                configHealthSection        // Part B: health overview at top
                Divider()
                dataRootsSection
                Divider()
                displaySection
                Divider()
                thresholdsSection
                Divider()
                petSection
                Divider()
                saveSection
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 440)
        // Part B: load health status on appear; re-run whenever healthRefreshID changes.
        .task(id: healthRefreshID) {
            await refreshHealthStatus()
        }
    }

    // MARK: - Sections

    private var dataRootsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("数据根目录", systemImage: "folder.badge.gearshape")
                .font(.headline)

            Text("每个数据根对应一个 Claude Code 配置目录（通常是 ~/.claude）。\n点击「安装 Hook」后，apet 会在该目录的 settings.json 中写入 hook 条目，并提示确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(config.dataRoots) { root in
                HookRowView(
                    root: root,
                    hookMarker: hookMarker,
                    runnerPath: runnerPath,
                    onRemove: {
                        config.dataRoots.removeAll { $0.path == root.path }
                    }
                )
            }

            // Add new root
            HStack(spacing: 8) {
                TextField("新增路径（如 ~/.claude）", text: $newRootPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addNewRoot() }
                Button(action: addNewRoot) {
                    Image(systemName: "plus")
                }
                .disabled(newRootPath.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("添加新数据根")
            }
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("显示与通知", systemImage: "bell.badge")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("显示模式")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("显示模式", selection: $config.displayMode) {
                    Text("悬浮宠物").tag("pet")
                    Text("仅菜单栏").tag("menuBarOnly")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("通知模式")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("通知模式", selection: $config.notifyMode) {
                    Text("仅等待关注时提醒").tag("attentionOnly")
                    Text("每次会话完成都提醒").tag("everyStop")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var thresholdsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("会话状态阈值", systemImage: "timer")
                .font(.headline)

            thresholdRow(
                label: "失活超时（分钟）",
                tooltip: "会话停止响应后多久标记为「失活」",
                value: Binding(
                    get: { config.staleAfterSec / 60 },
                    set: { config.staleAfterSec = $0 * 60 }
                ),
                range: 1...120,
                unit: "分"
            )

            thresholdRow(
                label: "已结束会话保留（小时）",
                tooltip: "已停止会话在内存中保留多久后被清除",
                value: Binding(
                    get: { config.endedAfterSec / 3600 },
                    set: { config.endedAfterSec = $0 * 3600 }
                ),
                range: 1...48,
                unit: "时"
            )

            thresholdRow(
                label: "等待会话保留（小时）",
                tooltip: "持续等待用户输入的会话多久后被清除",
                value: Binding(
                    get: { config.waitingEndedAfterSec / 3600 },
                    set: { config.waitingEndedAfterSec = $0 * 3600 }
                ),
                range: 1...72,
                unit: "时"
            )
        }
    }

    private func thresholdRow(
        label: String,
        tooltip: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(minWidth: 160, alignment: .leading)
                .help(tooltip)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue)) \(unit)")
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private var petSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("宠物形象", systemImage: "pawprint")
                .font(.headline)

            Picker("选择宠物", selection: $config.selectedPet) {
                Text("🐕 柴犬（Shiba）").tag("shiba")
                Text("🐩 比熊（Bichon）").tag("bichon")
            }
            .pickerStyle(.radioGroup)
        }
    }

    // MARK: - Part B: Config health section

    /// Aggregated `ConfigHealth` built from the async-loaded `@State` health vars.
    private var computedHealth: ConfigHealth {
        ConfigHealth(
            notification: notifStatusForHealth,
            hook: hookStatusForHealth,
            jsonlSource: jsonlStatusForHealth,
            dataRoots: config.dataRoots.map(\.path)
        )
    }

    private var configHealthSection: some View {
        let health = computedHealth
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("配置健康", systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer()
                Button {
                    healthRefreshID = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("刷新健康状态")
            }

            // Overall status row
            overallStatusRow(for: health.overall)

            // Hook row (neutral, not red when not installed)
            hookStatusRow(for: health.hook)

            // JSONL source row
            jsonlStatusRow(for: health.jsonlSource)

            // Other-profile hint (M4 future scope note)
            if hasOtherProfiles {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("发现其他 profile 目录（~/.claude-profiles），本期仅扫描默认 ~/.claude。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func overallStatusRow(for overall: OverallHealth) -> some View {
        switch overall {
        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("已就绪，正在看你的会话（hook 不装也在正常工作）")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
        case .readyEnhanced:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("已就绪（精确跳转/通知已启用）")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
        case .degraded(let reason):
            // 两种 degraded 原因（jsonl 数据源不可用 / 通知被拒）都是真正的故障——
            // 用红色而非橙色，与"只有真失败才红❌"的产品决策一致（Task12 评审 Important，产品-m8）。
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("配置需要关注：\(reason)")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                if case .denied = notifStatusForHealth {
                    Button("打开系统通知设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func hookStatusRow(for hookStatus: HookStatus) -> some View {
        switch hookStatus {
        case .installed:
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("精确跳转/通知：已启用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .notInstalled:
            // Neutral — not a red error; hook is optional enhancement.
            Text("➕ 开启精确跳转/通知（可选，在「数据根目录」中安装 Hook）")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text("Hook 检测失败：\(reason)")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func jsonlStatusRow(for status: JSONLSourceStatus) -> some View {
        switch status {
        case .found(let count):
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                let label = count > 0 ? "找到 \(count) 个会话文件" : "数据目录已就绪（暂无会话）"
                Text("会话数据：\(label)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .pathMissing:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text("会话数据路径不存在（请确认数据根目录设置）")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        case .unreadable(let path):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text("会话数据路径不可读：\(path)")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Part B: async health loader

    private func refreshHealthStatus() async {
        // 1. Notification authorisation status (async, returns on caller actor = MainActor)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notifStatusForHealth = .authorized
        case .denied:
            notifStatusForHealth = .denied
        default:
            notifStatusForHealth = .notDetermined
        }

        // 2. Hook status — check each data root; first installed one wins.
        let installer = HookInstaller()
        let marker = hookMarker
        var hookInstalled = false
        for root in config.dataRoots {
            let url = URL(fileURLWithPath: root.path).appendingPathComponent("settings.json")
            if (try? installer.isInstalled(settingsURL: url, marker: marker)) == true {
                hookInstalled = true
                // Path is informational; pass empty string — overall only checks installed/not.
                hookStatusForHealth = .installed(path: url.path)
                break
            }
        }
        if !hookInstalled {
            hookStatusForHealth = .notInstalled
        }

        // 3. JSONL source status — inspect the primary data root's projects/ directory.
        let fm = FileManager.default
        let primaryRoot = config.dataRoots.first?.path
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let projectsPath = (primaryRoot as NSString).appendingPathComponent("projects")

        if !fm.fileExists(atPath: projectsPath) {
            jsonlStatusForHealth = .pathMissing
        } else if !fm.isReadableFile(atPath: projectsPath) {
            jsonlStatusForHealth = .unreadable(path: projectsPath)
        } else {
            let files = DefaultDirectoryScanner().jsonlFiles(under: projectsPath)
            jsonlStatusForHealth = .found(count: files.count)
        }

        // 4. Detect ~/.claude-profiles/* directories not currently in config.
        let home = fm.homeDirectoryForCurrentUser.path
        let profilesDir = (home as NSString).appendingPathComponent(".claude-profiles")
        if fm.fileExists(atPath: profilesDir) {
            let contents = (try? fm.contentsOfDirectory(atPath: profilesDir)) ?? []
            let knownPaths = Set(config.dataRoots.map(\.path))
            let unknownProfiles = contents.filter { name in
                guard !name.hasPrefix(".") else { return false }
                let full = (profilesDir as NSString).appendingPathComponent(name)
                return !knownPaths.contains(full)
            }
            hasOtherProfiles = !unknownProfiles.isEmpty
        } else {
            hasOtherProfiles = false
        }
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("保存") { performSave() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }

    // MARK: - Private actions

    private func addNewRoot() {
        let raw = newRootPath.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let expanded = (raw as NSString).expandingTildeInPath
        guard !config.dataRoots.contains(where: { $0.path == expanded }) else {
            newRootPath = ""
            return
        }
        config.dataRoots.append(DataRoot(path: expanded, agent: "claude-code"))
        newRootPath = ""
    }

    private func performSave() {
        saveError = nil
        do {
            try configStore.save(config)
            onSave(config)
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - PreferencesWindowController

/// Hosts ``PreferencesView`` in a standard titled NSWindow.
///
/// - Thread safety: all methods must be called on `@MainActor`.
/// - The window is not released when closed (`isReleasedWhenClosed = false`) so it can be
///   shown again without re-creating the controller.
@MainActor
final class PreferencesWindowController: NSWindowController {

    private var hostingController: NSHostingController<PreferencesView>?

    init(config: AppConfig, configStore: ConfigStore, onSave: @escaping (AppConfig) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentPet 首选项"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let view = PreferencesView(config: config, configStore: configStore, onSave: onSave)
        let hc = NSHostingController(rootView: view)
        hostingController = hc
        window.contentViewController = hc
    }

    required init?(coder: NSCoder) { nil }

    /// Bring the preferences window to front.
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
