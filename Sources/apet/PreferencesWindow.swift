import AppKit
import SwiftUI
import AppShellKit

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
                    Button("安装 Hook") { showInstallConfirm = true }
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
            // swiftlint:disable:next line_length
            Text("将在以下文件中写入 apet hook 条目，并自动备份原文件：\n\(settingsURL.path)\n→ 备份路径：\(settingsURL.path).apet.bak\n\n继续？")
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
        isInstalled = (try? installer.isInstalled(settingsURL: settingsURL, marker: hookMarker)) ?? false
        errorText = nil
    }

    /// ⛔ Only called after explicit user confirmation in the dialog above.
    private func performInstall() {
        errorText = nil
        let installer = HookInstaller()
        do {
            try installer.install(into: settingsURL, runnerPath: runnerPath, marker: hookMarker)
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

    init(config: AppConfig, configStore: ConfigStore, onSave: @escaping (AppConfig) -> Void) {
        _config = State(initialValue: config)
        self.configStore = configStore
        self.onSave = onSave
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
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
