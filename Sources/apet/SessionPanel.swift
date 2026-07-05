import SwiftUI
import AgentPetCore
import AppShellKit

/// AI 摘要异步结果(跨面板层传递)。
enum SummaryResult { case text(String), error(String) }

// MARK: - SessionPanel

/// SwiftUI 会话面板：顶部搜索框 + 「等你」置顶高亮区 + 按状态分组。
///
/// 组织逻辑（搜索/置顶/分组/相对时间）全在纯函数 ``SessionListOrganizer``；本视图只渲染 +
/// 冒泡行为回调。菜单栏 popover 与悬浮宠物 popover 共用。
struct SessionPanel: View {
    /// 已注入 meta（favorite/customName）的会话列表。
    let sessions: [Session]
    /// 当前时间（Unix 秒），用于相对时间与日期分组。
    let now: Double
    /// UI 触发状态:控制器持有,跨 rootView 替换存活(菜单闭包写 @State 会落进废弃存储,见 PanelUIState)。
    @ObservedObject var ui: PanelUIState
    /// 点击某行（跳转终端）。参数为行的稳定 id。
    let onTap: (String) -> Void
    /// 收藏/取消收藏。
    var onToggleFavorite: (String) -> Void = { _ in }
    /// 重命名（控制器弹输入框）。
    var onRename: (String) -> Void = { _ in }
    /// 复制 sessionId。
    var onCopyId: (String) -> Void = { _ in }
    /// 复制恢复命令（claude --resume <id>）。
    var onCopyResume: (String) -> Void = { _ in }
    /// M3-D①：免费本地摘要（一句话概括最近进展）。
    /// 摘要:useAI=false 走本地即时快速摘要(开场任务);true 走 claude -p 深度短标题。
    var onSummarize: (String, Bool) async -> SummaryResult = { _, _ in .error("未接入") }
    /// 面板顶部快捷键提示，如 "⌥⌘P 打开/关闭"。为 nil 不显示。
    var hotkeyHint: String? = nil
    /// 状态圆点配色（F3）。默认系统色。
    var palette: DotPalette = .system
    /// M3-D-B:当前选中 tab(权威值来自 config,onSelectTab 回写)。
    /// 是否显示 tab 栏(桌宠 popover 未接 tab/分组回调,传 false 隐藏,避免死控件)。
    var showsTabBar: Bool = true
    var selectedTab: SessionTab = .all
    var onSelectTab: (SessionTab) -> Void = { _ in }
    /// M3-D-C:自定义分组名单(tab 栏动态追加分组 tab)。
    var groups: [String] = []
    /// M3-D-C:会话加入/移出分组(sessionId, groupName)。
    var onToggleGroup: (String, String) -> Void = { _, _ in }
    /// M3-D-C:提交新建分组(name, 可选加入的会话 id)/删除分组/提交重命名(id, 新名)。
    /// UI 重设计:面板内内联输入,回调只收「已确认的值」,不再触发 NSAlert。
    var onCommitNewGroup: (String, String?) -> Void = { _, _ in }
    var onDeleteGroup: (String) -> Void = { _ in }
    var onCommitRename: (String, String) -> Void = { _, _ in }

    @State private var filter: String = ""
    @FocusState private var inlineFieldFocused: Bool

    private var organizedFlat: OrganizedFlat {
        SessionListOrganizer.organizeFlat(sessions: sessions, tab: selectedTab, filter: filter, now: now,
                                          tzOffset: Double(TimeZone.current.secondsFromGMT()))
    }

    /// U2:tab 计数。搜索激活时按过滤后集合算,与可见行一致(评审 Minor)。
    private func count(_ tab: SessionTab) -> Int {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let base = needle.isEmpty ? sessions
            : sessions.filter { SessionListOrganizer.matchesPublic($0, needle) }
        return SessionTabFilter.filter(base, tab: tab).count
    }

    var body: some View {
        VStack(spacing: 0) {
            if let hint = hotkeyHint { hotkeyHeader(hint) }
            searchField
            Divider()
            if showsTabBar {
                tabBar
                Divider()
            }
            if sessions.isEmpty {
                emptyState
            } else {
                content
            }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("搜索 标题 / 目录 / ID / agent", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Content

    private var content: some View {
        let o = organizedFlat
        return ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                // U1:等你 pinned 跨 tab 常驻 + 保留「⏳N个等你」头(U2)。
                if !o.pinned.isEmpty {
                    sectionHeader("⏳ \(o.pinned.count) 个等你 · 始终置顶", emphasized: true)
                    ForEach(o.pinned) { row in rowCell(row) }
                }
                ForEach(o.rest) { row in rowCell(row) }
                if o.pinned.isEmpty && o.rest.isEmpty {
                    emptyTabHint
                }
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }

    // 空 tab 引导(U4/P1-7):自定义空组给可操作引导,而非干巴巴「暂无」。
    private var emptyTabHint: some View {
        Group {
            if case .group = selectedTab {
                Text("该分组暂无会话\n右键任意会话 →「加入分组」把它归到这里")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else if !filter.isEmpty {
                Text("没有匹配的会话").foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                Text("该分类暂无会话").foregroundStyle(.secondary).padding(.vertical, 16)
            }
        }
    }

    // MARK: - Tab bar(M3-D-B,取代分区)

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tabChip(.all, "全部")
                tabChip(.favorites, "收藏")
                tabChip(.running, "进行中")
                tabChip(.read, "已读")
                ForEach(groups, id: \.self) { g in
                    if ui.confirmDeleteGroup == g {
                        deleteConfirmChip(g)
                    } else {
                        tabChip(.group(g), "#\(g)")
                            .contextMenu {
                                Button("删除分组「\(g)」", role: .destructive) {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { ui.confirmDeleteGroup = g }
                                }
                            }
                    }
                }
                if ui.isCreatingGroup {
                    newGroupInputChip
                } else {
                    Button { startCreateGroup(attach: nil) } label: {
                        Image(systemName: "plus").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("新建分组")
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // 建组内联输入 chip(就地把 + 展成输入框;回车确认/Esc 取消/失焦取消)。
    private var newGroupInputChip: some View {
        let trimmed = ui.newGroupText.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = GroupMembership.isValidName(ui.newGroupText) && !groups.contains(trimmed)
        let dupe = !trimmed.isEmpty && groups.contains(trimmed)
        return HStack(spacing: 4) {
            TextField("分组名", text: $ui.newGroupText)
                .textFieldStyle(.plain).font(.system(size: 11))
                .frame(width: 110)
                .focused($inlineFieldFocused)
                .onSubmit { commitNewGroup(valid: valid) }
                .onExitCommand { cancelCreateGroup() }
            if !ui.newGroupText.isEmpty {
                Text(dupe ? "已存在" : "\(ui.newGroupText.count)/30")
                    .font(.system(size: 9))
                    .foregroundStyle(valid ? Color.secondary : Color.red)
            }
            Button { commitNewGroup(valid: valid) } label: {
                Image(systemName: "return").font(.system(size: 9))
            }.buttonStyle(.plain).foregroundStyle(valid ? Color.accentColor : Color.secondary).disabled(!valid)
            Button { cancelCreateGroup() } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((dupe ? Color.red : Color.accentColor).opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
            (dupe ? Color.red : Color.accentColor).opacity(inlineFieldFocused ? 1 : 0.5),
            lineWidth: inlineFieldFocused ? 1.5 : 1))
        .cornerRadius(6)
        .onAppear { inlineFieldFocused = true }
    }

    // 删组二段式内联确认 chip。
    private func deleteConfirmChip(_ g: String) -> some View {
        HStack(spacing: 4) {
            Text("删「\(g)」?").font(.system(size: 11)).foregroundStyle(.red)
            Button { onDeleteGroup(g); ui.confirmDeleteGroup = nil } label: {
                Image(systemName: "checkmark").font(.system(size: 9))
            }.buttonStyle(.plain).foregroundStyle(.red).help("确认删除,不可撤销")
            Button { ui.confirmDeleteGroup = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.red.opacity(0.12)).cornerRadius(6)
    }

    private func startCreateGroup(attach id: String?) {
        ui.newGroupText = ""; ui.creatingGroupAttachId = id
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { ui.isCreatingGroup = true }
    }
    private func commitNewGroup(valid: Bool) {
        guard valid else { return }
        let name = ui.newGroupText.trimmingCharacters(in: .whitespacesAndNewlines)
        onCommitNewGroup(name, ui.creatingGroupAttachId)
        ui.isCreatingGroup = false; ui.newGroupText = ""; ui.creatingGroupAttachId = nil
    }
    private func cancelCreateGroup() {
        ui.isCreatingGroup = false; ui.newGroupText = ""; ui.creatingGroupAttachId = nil
    }

    @ViewBuilder
    private func tabChip(_ tab: SessionTab, _ label: String) -> some View {
        let selected = (tab == selectedTab)
        let c = count(tab)
        Button { onSelectTab(tab) } label: {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 11, weight: selected ? .semibold : .regular))
                if c > 0 {
                    Text("\(c)").font(.system(size: 9))
                        .foregroundStyle(selected ? .white : .secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12))
            .foregroundStyle(selected ? .white : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain).fixedSize()
        .help(tabHelp(tab))
    }

    private func tabHelp(_ tab: SessionTab) -> String {
        switch tab {
        case .read: return "你看过,但会话可能仍在等你(E11 消歧)"
        case .all: return "全部会话"
        case .favorites: return "已收藏"
        case .running: return "进行中"
        case .group(let n): return "分组:\(n)"
        }
    }

    private func sectionHeader(_ title: String, emphasized: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(emphasized ? Color.orange : Color.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .background(emphasized ? Color.orange.opacity(0.06) : Color.clear)
    }

    // E10:行操作菜单抽成共享,右键 contextMenu 与悬停 ⋯ 复用同一份。
    @ViewBuilder
    private func rowMenuItems(_ row: SessionRowModel) -> some View {
        Button(row.favorite ? "取消收藏" : "收藏") { onToggleFavorite(row.id) }
        Button("重命名…") {
            ui.renameText = row.title; ui.renamingId = row.id
        }
        Menu("加入分组") {
            ForEach(groups, id: \.self) { g in
                Button { onToggleGroup(row.id, g) } label: {
                    Label(g, systemImage: row.groups.contains(g) ? "checkmark.circle.fill" : "circle")
                }
            }
            if !groups.isEmpty { Divider() }
            Button("新建分组…") { startCreateGroup(attach: row.id) }
        }
        if !AgentManifest.dbBackedAgents.contains(row.agent) {
            Divider()
            Button("快速摘要") {
                SessionRowActions.summaryDebug("[ui] menu quick clicked row=\(row.id)")
                ui.summaryUseAI = false; ui.summaryNonce += 1
                ui.summaryOutcome = .loading; ui.summaryRowId = row.id
            }
            Button("AI 摘要") {
                SessionRowActions.summaryDebug("[ui] menu ai clicked row=\(row.id)")
                ui.summaryUseAI = true; ui.summaryNonce += 1
                ui.summaryOutcome = .loading; ui.summaryRowId = row.id
            }
        }
        Divider()
        Button("复制 sessionID") { onCopyId(row.id) }
        if SessionRowActions.hasResumeCommand(agent: row.agent, sessionId: row.sessionId) {
            Button("复制恢复命令") { onCopyResume(row.id) }
        }
    }

    @ViewBuilder
    private func rowCell(_ row: SessionRowModel) -> some View {
        VStack(spacing: 0) {
            rowCellCore(row)
            if ui.summaryRowId == row.id, let outcome = ui.summaryOutcome {
                summaryBanner(outcome, row: row)
            }
        }
        .task(id: ui.summaryRowId == row.id ? "\(row.id)#\(ui.summaryNonce)" : nil) {
            guard ui.summaryRowId == row.id, case .loading? = ui.summaryOutcome else { return }
            SessionRowActions.summaryDebug("[ui] task fired row=\(row.id) useAI=\(ui.summaryUseAI)")
            let useAI = ui.summaryUseAI
            let result = await onSummarize(row.id, useAI)
            guard ui.summaryRowId == row.id else { return }   // 期间用户切走则丢弃
            switch result {
            case .text(let t): ui.summaryOutcome = .text(t)
            case .error(let e): ui.summaryOutcome = .error(e)
            }
        }
    }

    private func rowCellCore(_ row: SessionRowModel) -> some View {
        SessionRowCell(
            row: row, palette: palette,
            onFavorite: { onToggleFavorite(row.id) },
            overflowMenu: AnyView(
                Menu { rowMenuItems(row) } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 18)
            ),
            renaming: ui.renamingId == row.id,
            renameText: ui.renamingId == row.id ? $ui.renameText : nil,
            onRenameCommit: {
                onCommitRename(row.id, ui.renameText.trimmingCharacters(in: .whitespacesAndNewlines))
                ui.renamingId = nil
            },
            onRenameCancel: { ui.renamingId = nil }
        )
            .contentShape(Rectangle())
            .onTapGesture { if ui.renamingId != row.id { onTap(row.id) } }   // 编辑中不跳转
            .contextMenu { rowMenuItems(row) }
    }


    @ViewBuilder
    private func summaryBanner(_ outcome: SummaryOutcome, row: SessionRowModel) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(.secondary)
            switch outcome {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(ui.summaryUseAI ? "AI 生成中…" : "生成中…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .text(let t):
                Text(t).font(.system(size: 11)).foregroundStyle(.primary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            case .error(let e):
                Text(e).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if case .text(let t) = outcome {
                Button {
                    // 一键把摘要设为会话名称(≤40 字,与重命名同上限)。
                    onCommitRename(row.id, String(t.prefix(40)))
                    ui.summaryRowId = nil; ui.summaryOutcome = nil
                } label: { Image(systemName: "square.and.pencil").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("设为会话名称")
                Button { copyText(t) } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("复制摘要")
            }
            Button { ui.summaryRowId = nil; ui.summaryOutcome = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06))
    }

    private func copyText(_ t: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    // MARK: - Header / empty

    private func hotkeyHeader(_ hint: String) -> some View {
        HStack {
            Spacer()
            Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
    }

    private var emptyState: some View {
        Text("没有活跃会话")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }
}

// MARK: - SessionRowCell

private struct SessionRowCell: View {
    let row: SessionRowModel
    let palette: DotPalette
    var onFavorite: () -> Void = {}
    var overflowMenu: AnyView? = nil    // E10:悬停 ⋯ 溢出入口(= 右键菜单同款)
    var renaming: Bool = false
    var renameText: Binding<String>? = nil
    var onRenameCommit: () -> Void = {}
    var onRenameCancel: () -> Void = {}
    @State private var hovering = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            // E2:状态指示器形状+色(色盲无障碍);isInferred 降透明保留。
            Image(systemName: dotSymbol)
                .font(.system(size: 11))
                .foregroundStyle(dotColor)
                .frame(width: 12)

            // D3:终端真 app 图标(未知→不显)。
            if let bid = row.terminalBundleId {
                if let icon = AppIconCache.icon(bundleId: bid) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                } else {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if renaming, let rt = renameText {
                        TextField("留空恢复默认名", text: rt)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .focused($renameFocused)
                            .onSubmit { onRenameCommit() }
                            .onExitCommand { onRenameCancel() }
                            .onAppear { DispatchQueue.main.async { renameFocused = true } }
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5))
                            .cornerRadius(4)
                    } else {
                        Text(row.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    // E9:profileTag 随 E3 灰化(只 agent 保留彩 chip)。
                    if let tag = row.profileTag {
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    // 唯一彩色 chip:agent 来源(需区分维度)。
                    if row.agent != "claude" && row.agent != "claude-code" && !row.agent.isEmpty {
                        Text(row.agent)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .cornerRadius(4).lineLimit(1).fixedSize()
                            .help(row.agent == "opencode"
                                  ? "来自 opencode:仅面板可见,无通知(插件增强规划中);状态按内容信号+活动时间推断;长时间无活动会灰显(会话仍在,活动后恢复),数小时后自动清理"
                                  : "来自 \(row.agent)（状态按活动时间粗略推断）")
                    }
                    // E3/E7:可靠性标记统一为灰字(无 chip);点击前预期告知保留(错误预防)。
                    if let hint = reliabilityHint {
                        Text(hint.text)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1).fixedSize()
                            .help(hint.help)
                    }
                    Spacer(minLength: 4)
                    if !row.relativeText.isEmpty {
                        Text(row.relativeText)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(width: 58, alignment: .trailing)
                    }
                }

                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // E10:悬停 ⋯ 溢出入口(固定 18pt 常驻位,悬停才现,不抖动)。
            if let overflow = overflowMenu {
                overflow
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
            }
            // A/E8:收藏☆固定 18pt 尾列(空间常驻→无位移抖动);悬停或已收藏才显。
            Image(systemName: row.favorite ? "star.fill" : "star")
                .font(.system(size: 11))
                .foregroundStyle(row.favorite ? .yellow : .secondary)
                .opacity(row.favorite || hovering ? 1 : 0)
                .frame(width: 18)
                .contentShape(Rectangle())
                .onTapGesture { onFavorite() }
                .help(row.favorite ? "取消收藏" : "收藏")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)   // E4:整行 hover 背景
        .onHover { hovering = $0 }
    }

    // E2:每状态一个 SF Symbol(形状+色可区分)。
    private var dotSymbol: String {
        switch row.dot {
        case .running:     return "circle.fill"
        case .attention:   return "exclamationmark.circle.fill"
        case .doneWaiting: return "stop.circle.fill"
        case .read:        return "checkmark.circle.fill"
        case .stale:       return "minus.circle"
        }
    }

    private var dotColor: Color {
        let base = palette.color(for: row.dot)
        return row.isInferred ? base.opacity(0.45) : base
    }

    // E7:三个可靠性词收敛为单一标记(优先级:无跳转 > 仅切到App > 推断)。
    private var reliabilityHint: (text: String, help: String)? {
        if row.noJumpHint {
            return ("无跳转", "该会话在外部终端中运行,apet 无法定位窗口;点击查看恢复方式")
        }
        if row.activateOnly {
            return (row.needsManualTabHint ? "仅切到 App·手动切标签" : "仅切到 App",
                    "该终端不支持精确跳 tab,点击只把 App 切到最前")
        }
        if row.isInferred {
            return ("推断", "状态由文件扫描推得,非实时 hook,可能已过时")
        }
        return nil
    }
}
