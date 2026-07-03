import SwiftUI
import AgentPetCore
import AppShellKit

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
    var onLocalSummary: (String) -> Void = { _ in }
    /// 面板顶部快捷键提示，如 "⌥⌘P 打开/关闭"。为 nil 不显示。
    var hotkeyHint: String? = nil
    /// 状态圆点配色（F3）。默认系统色。
    var palette: DotPalette = .system

    @State private var filter: String = ""

    private var organized: OrganizedList {
        SessionListOrganizer.organize(sessions: sessions, dimension: .status, filter: filter, now: now,
                                      tzOffset: Double(TimeZone.current.secondsFromGMT()))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let hint = hotkeyHint { hotkeyHeader(hint) }
            searchField
            Divider()
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
        let o = organized
        return ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                if !o.pinned.isEmpty {
                    sectionHeader("⏳ \(o.pinned.count) 个等你", emphasized: true)
                    ForEach(o.pinned) { row in rowCell(row) }
                }
                ForEach(o.groups, id: \.title) { group in
                    sectionHeader(group.title, emphasized: false)
                    ForEach(group.rows) { row in rowCell(row) }
                }
                if o.pinned.isEmpty && o.groups.isEmpty {
                    Text("没有匹配的会话")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
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

    private func rowCell(_ row: SessionRowModel) -> some View {
        SessionRowCell(row: row, palette: palette, onFavorite: { onToggleFavorite(row.id) })
            .contentShape(Rectangle())
            .onTapGesture { onTap(row.id) }
            .contextMenu {
                Button(row.favorite ? "取消收藏" : "收藏") { onToggleFavorite(row.id) }
                Button("重命名…") { onRename(row.id) }
                // 本地摘要:DB 型 agent 无 jsonl 转录,必弹「找不到记录文件」死弹窗 → 隐藏
                //(M3-C+ 评审;Divider 随项内移,免得留双分隔线)。
                if !AgentManifest.dbBackedAgents.contains(row.agent) {
                    Divider()
                    Button("本地摘要") { onLocalSummary(row.id) }
                }
                Divider()
                Button("复制 sessionID") { onCopyId(row.id) }
                // 仅对有已核实恢复命令的 agent 显示（产品评审 M3：不静默复制假命令）。
                if SessionRowActions.hasResumeCommand(agent: row.agent, sessionId: row.sessionId) {
                    Button("复制恢复命令") { onCopyResume(row.id) }
                }
            }
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
            .frame(width: 320)
            .padding(.vertical, 20)
    }
}

// MARK: - SessionRowCell

private struct SessionRowCell: View {
    let row: SessionRowModel
    let palette: DotPalette
    var onFavorite: () -> Void = {}
    @State private var hovering = false

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
                    Text(row.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

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
