# apet 会话面板 UX 升级设计——悬停收藏 / Tab 分流 / 自定义分组 / 终端图标 / 视觉打磨

日期:2026-07-03 · 状态:待评审 · 里程碑:M3-D(面板体验)

## 0. 背景与决策

用户在真机使用中提出四项面板改进(2026-07-03),brainstorm 决策:

1. ~~内联本地摘要~~ **已砍**(2026-07-03 实测决策):面板标题**本就用 Claude Code 的 `ai-title`**(`JSONLParse.swift:162`,`customTitle > aiTitle > lastPrompt`),已是「这会话在干嘛」的好摘要;启发式再造一个只会更差(实测三例两垃圾)。内联启发式摘要移入非目标;真·丰富摘要留给「模型摘要按需」(遗留)。
2. **悬停收藏按钮**——行上悬停才淡出现 ☆,已收藏常驻 ⭐,点击 toggle(替代只能右键收藏)。
3. **Tab 取代分区**——顶部标签页:全部 / 收藏 / 进行中 / 已读 + 每个自定义分组一个 tab;选中 tab 只显该类,列表平铺不再有分区标题。
4. **自定义分组**——用户建命名分组,右键把会话加入/移出,**可多属**(标签语义),持久化。

三块按交付独立性从轻到重排序,**可分里程碑独立上线**:A 悬停收藏 → B Tab 分流 → C 自定义分组(C 依赖 B 的 tab 栏)。

## 1. 现状事实(已核对)

- `SessionMeta`(`Sources/AgentPetCore/Store/SessionMeta.swift`)已有 `favorite / customName / firstSeenAt / cachedSummary / summaryAnchor` 字段——后两者(cachedSummary/summaryAnchor)预留、全仓未用,本设计**不再启用**(见 §4:内联摘要已砍),留待模型摘要按需。
- `SessionMetaStore`(AppShellKit)`load()/save()` 持久化 `[String: SessionMeta]`(key=`agent|root|sessionId`)。
- `SessionListOrganizer.organize(sessions:dimension:filter:now:tzOffset:) -> OrganizedList(pinned, groups)`:搜索过滤 + 未读 waiting 置顶 + 收藏优先 + 按 `GroupDimension`(status/date/agent)分组。
- `SessionRowMapper.make` 纯映射 `Session → SessionRowModel`;`SessionRowModel` 已有 `favorite / agent / noJumpHint / ...`。
- `SessionPanel.swift` 渲染:搜索框 + 列表(pinned + 分组 section)+ 页脚(已读/隐藏/首选项/退出)。右键菜单:收藏/重命名/本地摘要(门控)/复制 ID/复制恢复命令。
- 本地摘要链:`SessionTranscriptLocator.find` → `TailLineReader.lastLines` → `ConversationTailParser.turns` → `LocalSummarizer.summarize`。无 jsonl 转录的源(OpenCode/QoderWork)无摘要。

## 2. 硬约束落位(对照 CLAUDE.md)

- 约束 1(零依赖)/ 2(禁 Date):摘要选取、tab 过滤、分组过滤为**纯函数**入 AgentPetCore/AppShellKit,`now: Double` 注入;摘要 I/O 走既有 IO 缝(可 mock)。
- 约束 7(测试是规范):纯逻辑全单测;GUI 胶水(SwiftUI 行/tab 栏)按仓库惯例不单测,但其消费的数据模型(过滤结果/摘要缓存决策)单测。
- 现有「收藏置顶」「未读 waiting 置顶」语义在「全部」tab 内保留。

## 3. 组件 A:悬停收藏按钮

**目标**:行悬停 → 尾部淡出 ☆ 按钮;已收藏 → 常驻 ⭐;点击 toggle 收藏(复用既有 `onToggleFavorite`)。

**改动**(纯 GUI,`SessionPanel.swift` 的 `SessionRowCell`):
- 加 `@State private var hovering = false` + `.onHover { hovering = $0 }`。
- 行尾(相对时间列旁)放一个星按钮:`favorite ? "star.fill"(黄) : "star"(灰)`;`opacity(favorite || hovering ? 1 : 0)`;`.onTapGesture { onToggleFavorite(row.id) }`,`.buttonStyle(.plain)`。
- 既有「已收藏时标题前的 ⭐」保留还是移除?**决策:移除标题前的星**,收藏视觉统一到行尾按钮(避免两处星)。
- 点击星**不触发**行的 `onTap`(跳转)——按钮吞掉点击。

**测试**:GUI,不单测;`SessionRowModel.favorite` 既有测试覆盖。

## 4. 组件 B(已砍):内联本地摘要 → 移入非目标

实测决策(2026-07-03):面板标题已由 `JSONLParse.title = customTitle ?? aiTitle ?? lastPrompt` 提供
Claude Code 的 AI 标题(如「创建 AI Coding Agent 的 GitHub 项目模板」),已是会话意图的好摘要。
再叠一行启发式摘要(「指令:X · 最近:Y」)冗余且质量差(实测:tool_use 窗口无真实指令时回退到
注入消息、skill 前缀被当指令)。故**不做内联自动摘要**;`SessionMeta.cachedSummary/summaryAnchor`
预留字段留待「模型摘要按需」(遗留 §9)。既有右键「本地摘要」保留不动(本轮已加注入过滤)。

## 5. 组件 B:Tab 分流(取代分区)

**目标**:顶部 tab 栏,选中只显该类,平铺无分区标题。

**模型**(AgentPetCore 纯):
```swift
public enum SessionTab: Equatable {
    case all            // 全部:保留未读置顶 + 收藏优先排序,平铺
    case favorites      // 收藏:favorite == true
    case running        // 进行中:state == .running
    case read           // 已读:acknowledged 的 waiting(现「已读」组语义)
    case group(String)  // 自定义分组(组件 C)
}
```
- **新纯函数** `SessionTabFilter.filter(sessions:tab:metas:) -> [Session]`(单测):按 tab 谓词过滤。`.all` 不过滤。
- `SessionListOrganizer` 增**平铺出口** `organizeFlat(sessions:tab:metas:filter:now:tzOffset:) -> OrganizedFlat`,`OrganizedFlat { pinned: [SessionRowModel]; rest: [SessionRowModel] }`(无 `groups`/无 section 标题):内部先 `SessionTabFilter.filter` → 搜索过滤 → 未读 waiting 置顶(`pinned`)+ 其余按收藏优先稳定排序(`rest`),复用现有 `isUnreadWaiting`/收藏排序私有逻辑。现有 `organize`(带 `groups`)保留不动,面板改调 `organizeFlat`。
- **UI**:搜索框下方横向 tab 栏(Segmented 风格,自定义分组多时可横向滚动)。选中态 `config.selectedTab` 持久化(String 编码;`group(name)` 编码为 `group:name`)。
- **U1(交互评审 P0-1,核心任务不可牺牲)**:「⏳等你」(未读 waiting)pinned **无论选中哪个 tab 都常驻置顶**——`organizeFlat` 的 tab 过滤**只作用于 rest,不过滤 pinned**;否则停在「收藏/分组」tab 重开面板会藏掉刚变等你的会话(菜单栏显🟠却点不到)。
- **U2(交互评审 P1-5)**:tab 标签**带计数角标**(「进行中 3」「收藏 5」「⏳2」),接住平铺后消失的分区计数信息;pinned 区保留「⏳ N 个等你」小头。
- 空 tab → **可操作引导文案**(U4/P1-7):自定义空组显「右键任意会话 →『加入分组』把它归到这里」,而非干巴巴「暂无会话」。
- 搜索与 tab 正交:tab 过滤后再套搜索(或反之,等价)。
- 页脚现有「已读」快捷键行为与「已读」tab 语义对齐(点已读页脚 = 切已读 tab 或保留标记已读?**决策:页脚「已读」保持原义(标记全部已读),不动**)。

**测试**:`SessionTabFilter.filter` 每 tab(含空、含多属分组);`.all` 与现有 organize 置顶序一致的回归。

## 6. 组件 C:自定义分组

**目标**:建命名分组,右键会话加入/移出,可多属,每组一个 tab。

**存储**:
- `SessionMeta` 加 `groups: [String]`(默认 `[]`,该会话所属分组名)。
- 分组注册表(有序名单,决定 tab 顺序 + 允许空组存在)存 `AppConfig.sessionGroups: [String]`(config.json 持久化)。
- 纯逻辑 `GroupMembership`(AgentPetCore):`add/remove(group:to meta:)`、`isValidGroupName`(非空、去重、限长、滤控制字符——防注入/UI 破坏)。

**交互**:
- 右键会话 →「加入分组 ▸」子菜单:列出 `config.sessionGroups`,勾选态 = 该会话是否在组;点击 toggle 成员(写 `SessionMeta.groups`,持久化);末尾「新建分组…」弹输入框(`promptRename` 同款)建组并加入。
- Tab 栏末尾「+」也可建空组。
- 删组:tab 栏分组 tab 右键「删除分组」(从 `config.sessionGroups` 移除 + 清各 meta 的该组名);确认弹窗。
- 分组 tab = `SessionTab.group(name)`,`SessionTabFilter` 谓词 `meta.groups.contains(name)`。

**约束**:分组名经 `isValidGroupName` 校验(纯函数,防注入/重名);持久化失败不崩(与现有 meta save 一致容错)。

**测试**:`GroupMembership.add/remove`(幂等、多属、去重);`isValidGroupName`(空/重复/超长/控制字符/正常);`SessionTabFilter.filter(.group)`(命中/不含/空组);config 编解码 `selectedTab` 的 `group:name` 往返。

## 6.5 组件 D:终端图标(真 app 图标)

**目标**:每行显示会话所在终端软件的**真实 app 图标**(iTerm2/Warp/Ghostty/VSCode/Terminal 的 logo),一眼区分;终端未知(纯 jsonl 无 hook,`terminal == nil`)不显图标(decision 2026-07-04)。

**事实**:`TerminalKind { iterm2, terminal, warp, ghostty, vscode, other }`(`AgentEvent.swift:21`);kind→bundleId 映射已存在于 `TerminalFocusService.fallbackBundleId`(private)。DB 源(qoder-work/qoder-ide)在 `applyScanResult` 注入 `TerminalRef(.other, bundleId:)`。

**设计**:
- 抽公共纯映射 `TerminalKind.bundleId: String?`(入 AgentPetCore,单测):iterm2→`com.googlecode.iterm2`、terminal→`com.apple.Terminal`、warp→`dev.warp.Warp-Stable`、ghostty→`com.mitchellh.ghostty`、vscode→`com.microsoft.VSCode`、other→nil。`TerminalFocusService.fallbackBundleId` 改为复用它(消除双份)。
- `SessionRowModel` 加 `terminalBundleId: String?`:`session.terminal?.bundleId ?? session.terminal?.kind.bundleId`;`terminal == nil` → nil。
- **图标获取**(GUI,AppKit):`AppIconCache`(apet 层)按 bundleId → `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` → `.icon(forFile:)`,`[String: NSImage]` 缓存(app 图标不变,进程内缓存即可)。取不到(未安装)→ SF Symbol `terminal` 灰色兜底。
- **位置**:行首状态圆点**右侧**、标题**左侧**,14pt;`terminalBundleId == nil` 不占位(不显)。

**测试**:`TerminalKind.bundleId` 全 case;`SessionRowModel.terminalBundleId`(有 kind/有 ref.bundleId/nil 三态)。图标 fetch 为 GUI 不单测。

## 6.6 组件 E:视觉打磨(UI review P0)

2026-07-04 专业 UI review 的 P0 项,并入本设计:

- **E1 路径折叠**(纯函数 `PathAbbreviator.abbreviate(_ path:home:) -> String`,单测):home 前缀 → `~`;仍超 ~32 字符 → `…/<父>/<叶>`。副标题改用它(消除满屏重复 `/Users/nathan/workspace/`)。
- **E2 状态指示器加形状**(无障碍,色盲 8% 男性):圆点从**纯色**改为**形状+色**——每状态一个 SF Symbol(running=`circle.fill`、attention=`exclamationmark.circle.fill`、doneWaiting=`stop.circle.fill`、read=`checkmark.circle.fill`、stale=`minus.circle`),保留状态色。菜单栏彩色计数同题记入遗留(本轮只改面板)。
- **E3 元数据视觉统一**:次要状态标签(仅激活 / 推断 / 无跳转)**统一为灰色小字**(size 10 tertiary,无 chip 背景);**只有 agent 来源保留彩色 chip**(它才是需区分维度)。
- **E4 整行 hover 背景**:行悬停淡色背景(与组件 A 的悬停☆共用 `hovering` 状态),给点击目标反馈。
- **E5 字号收敛到 3 级**:标题 13 / 副标题 11 / 徽标+时间 10,灰度对应三档(primary/secondary/tertiary)。
- **E6(U3/P1-6)页脚「已读」常驻置灰**:不再「有未读才显」(点完塌成 3 个按钮抖动),改为**常驻**,无未读时**禁用置灰**;所有页脚图标加 tooltip(已读/隐藏/首选项/退出)。
- **E7(U5/P2-8)可靠性标记收敛**:「推断/仅激活/无跳转」三个语义重叠词不再并列——收敛为**单一弱化标记**(点击前预期告知保留:这是难得的错误预防,别删),细节进 tooltip。
- **E8(U6/P2-14)悬停☆用 overlay 淡入**:不参与布局(`.overlay` 叠加,非 HStack 成员),保证 hover 出现/消失时时间列**零位移**(否则每次划过抖动)。
- **E9(U7/P2-12)profileTag 灰化**:只有 agent 来源保留彩色 chip;profileTag 随 E3 灰化(否则两个彩 chip 同行最花)。
- **E10(U8/P2-13)悬停溢出入口**:悬停时 ☆ 旁露一个 `⋯` 按钮 = 右键菜单同款,让**一个可发现的悬停入口**同时通往收藏与全部行内操作(统一交互平面)。
- **E11 词汇决策**(D2/D3,自主拍板):`仅激活` → **「仅切到 App」**(「激活」是 jargon);`已读` 保留但**加 tooltip**「你看过,但会话可能仍在等你」(改名风险大、surface 广,先用 tooltip 消歧义)。

**测试**:`PathAbbreviator.abbreviate`(home 折叠 / 超长 `…/父/叶` / 短路径原样 / 非 home 路径);其余为 GUI 调整不单测。

## 6.7 组件 F:可缩放面板窗口(D1=A)

**目标**:面板可拖拽改大小,尺寸持久化(用户 2026-07-04 选 A:真拖拽,放弃 popover 手感)。

**现状**:面板 SwiftUI 写死 `.frame(width: 320)`/`maxHeight: 420`;用 `NSPopover`(菜单栏 + 桌宠都是),NSPopover **不支持拖拽 resize**。

**设计**:
- 菜单栏面板从 `NSPopover` 换为**可缩放浮动 NSWindow**(`.titled`/`.resizable`/`.fullSizeContentView` 或复用现有 `ApeFloatingWindow` 加 `.resizable`);行为:点菜单栏图标 toggle 显隐,失焦不强制关(或保留「点别处关」可配)。
- SwiftUI 内容去掉写死 `width`,改 `minWidth: 300`/`idealWidth: 360`/`maxWidth: .infinity` + `minHeight`;行随宽自适应(标题占更多、时间列固定)。
- 尺寸持久化:`AppConfig.panelWidth: Double`/`panelHeight: Double`(默认 360/480);窗口 resize 回调写 config(去抖)。
- 桌宠侧 popover 可暂保留(桌宠本就是浮窗),或同步换;本组件**先做菜单栏面板**,桌宠 popover 记遗留。

**约束**:窗口 level/behavior 不抢焦点(`.nonactivatingPanel` 惯例);去掉写死宽度后所有行内元素靠既有 `fixedSize`/`layoutPriority` 撑住(本轮竖排教训)。

**测试**:`AppConfig.panelWidth/Height` 默认 + 往返编解码(单测);窗口/resize 为 GUI 不单测。

## 7. 数据流

```
SessionStore 变更 → changeHandler
  → applyMetas(注入 favorite/customName/groups)
  → SessionTabFilter.filter(by: config.selectedTab)
  → organizeFlat(未读置顶 + 收藏优先,无分区)
  → SessionRowMapper.make → 面板渲染(标题/目录 + 悬停☆)
```

## 8. 交付里程碑(建议一块一 PR/一评审批次)

- **M3-D-A**:悬停收藏按钮(§3)。最小,先落地验证行布局。
- **M3-D-B**:Tab 分流(§5)。取代分区。
- **M3-D-C**:自定义分组(§6)。依赖 B 的 tab 栏。
- **M3-D-D**:终端图标(§6.5)。独立。
- **M3-D-E**:视觉打磨(§6.6,UI review P0 + 交互评审 U3/U5/U6/U7/U8 + 词汇)。独立;E4/E8 hover 与 A 合流最省。
- **M3-D-F**:可缩放面板窗口(§6.7)。独立;改动面板呈现方式,建议最后做(前面组件先在现窗口验证)。

每块独立可测、可 ship;C 前需 B 的 tab 栏在位。建议顺序 A→E→D→B→C(A/E/D 是行内视觉,先把行做对再上 tab/分组)。

## 8.5 已修现存 bug(本轮先行,非组件)

交互评审揪出的现存 bug 已在组件前修复(feature/panel-ux):B1 跳转失败不再误标已读(丢等你会话)、B2 Claude/iTerm2 失败弹窗给复制恢复命令、B3 复制瞬时 HUD 反馈、B4 搜索匹配 agent 名、B5 推断 chip tooltip。

## 9. 非目标 / 遗留

- **内联启发式摘要**(本设计原组件 B,实测后砍):标题已是 ai-title 好摘要,启发式冗余且差。
- 模型摘要按需 UI(遗留):右键 → LLM 出丰富摘要,是唯一比标题多给价值的路径;`SessionMeta.cachedSummary/summaryAnchor` 预留字段为它备着。
- OpenCode/QoderWork 的 DB 摘要(从 message 表)——独立里程碑。
- 拖拽加入分组(本轮右键足够;拖拽 YAGNI)。
- 分组嵌套 / 分组图标颜色(YAGNI)。
- **E10 悬停 ⋯ 溢出入口**:本轮**未做**(8 视角评审后如实回写)——行内操作仍靠右键 contextMenu,悬停仅 ☆。后续可补:悬停 ☆ 旁露 `⋯` = 右键菜单同款。
- **可缩放窗口 hidesOnDeactivate 取舍**:当前失焦自隐(近 popover transient)。用户评审希望「常驻并存」——留待用户定夺(加 pin 开关 vs 保持自隐)。
- **桌宠侧面板**:tab/分组已接通,但仍是固定 NSPopover(不可缩放);可缩放留菜单栏侧。
- 菜单栏彩色计数的色盲无障碍(E2 只改面板圆点;菜单栏计数同题留遗留)。
