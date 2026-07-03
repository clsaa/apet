# apet 会话面板 UX 升级设计——内联摘要 / 悬停收藏 / Tab 分流 / 自定义分组

日期:2026-07-03 · 状态:待评审 · 里程碑:M3-D(面板体验)

## 0. 背景与决策

用户在真机使用中提出四项面板改进(2026-07-03),brainstorm 决策:

1. **内联本地摘要**——会话目录下方常驻显示本地启发式摘要(非右键弹窗);**本地摘要**档(零网络零成本),不用模型档。
2. **悬停收藏按钮**——行上悬停才淡出现 ☆,已收藏常驻 ⭐,点击 toggle(替代只能右键收藏)。
3. **Tab 取代分区**——顶部标签页:全部 / 收藏 / 进行中 / 已读 + 每个自定义分组一个 tab;选中 tab 只显该类,列表平铺不再有分区标题。
4. **自定义分组**——用户建命名分组,右键把会话加入/移出,**可多属**(标签语义),持久化。

四块按交付独立性从轻到重排序,**可分里程碑独立上线**:A 悬停收藏 → B 内联摘要 → C Tab 分流 → D 自定义分组(D 依赖 C 的 tab 栏)。

## 1. 现状事实(已核对)

- `SessionMeta`(`Sources/AgentPetCore/Store/SessionMeta.swift`)已有 `favorite / customName / firstSeenAt / cachedSummary / summaryAnchor` 字段——后两者是**预留、全仓未用**,组件 B 直接接上。
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

## 4. 组件 B:内联本地摘要

**目标**:目录下方常驻一行本地摘要(`指令:X · 最近:Y`);无转录会话不显此行。

**架构**(复用 SessionMeta 预留字段 + 后台缓存):
- `SessionRowModel` 加 `summary: String?`(nil = 不显该行)。
- `SessionMeta.cachedSummary`(文案)+ `summaryAnchor`(计算时的 `lastSeq`)接上:摘要**按 seq 失效**——`meta.summaryAnchor == session.lastSeq` 则缓存有效,直接用 `cachedSummary`;否则需重算。
- **新 `SummaryRefresher`**(AppShellKit,IO 缝可注入):
  - 输入:当前 sessions + metas + `locate/read` 闭包。
  - 纯决策函数 `SummaryPlanner.needsRefresh(session:meta:) -> Bool`(AgentPetCore 纯函数,单测):`session.source` 有转录能力(claude/claude-code/qoder-cli/qoder-ide,即非 `dbBackedAgents`)且 `meta.summaryAnchor != session.lastSeq`。
  - IO 部分:对 needsRefresh 的会话,后台队列跑 locate→read→parse→summarize,写回 `meta.cachedSummary/summaryAnchor`,持久化,触发面板刷新(经既有 changeHandler/applyMetas 路径)。
  - 节流:每次 store 变更后合并计算,单会话同 seq 不重复算。
- `SessionRowMapper.make` 增参 `summary: String?`(默认 nil),从 meta 注入(有效缓存才给)。
- OpenCode/QoderWork(`dbBackedAgents`):`SummaryPlanner.needsRefresh` 恒 false → 无 summary → 不显摘要行(与「本地摘要右键隐藏」一致)。**遗留**:从 DB message 表做摘要(AI 评审提过),后续里程碑。

**约束**:摘要 I/O 绝不在 main/映射同步做(约束隐含性能);`now` 无关(摘要不含时间派生)。

**测试**:`SummaryPlanner.needsRefresh` 各分支(有/无转录源、anchor 命中/失效);`LocalSummarizer` 既有 + 注入过滤(本轮已修);SummaryRefresher 用 mock locate/read 验证「同 seq 不重算 / seq 变则重算 / 无转录源跳过」。

## 5. 组件 C:Tab 分流(取代分区)

**目标**:顶部 tab 栏,选中只显该类,平铺无分区标题。

**模型**(AgentPetCore 纯):
```swift
public enum SessionTab: Equatable {
    case all            // 全部:保留未读置顶 + 收藏优先排序,平铺
    case favorites      // 收藏:favorite == true
    case running        // 进行中:state == .running
    case read           // 已读:acknowledged 的 waiting(现「已读」组语义)
    case group(String)  // 自定义分组(组件 D)
}
```
- **新纯函数** `SessionTabFilter.filter(sessions:tab:metas:) -> [Session]`(单测):按 tab 谓词过滤。`.all` 不过滤。
- `SessionListOrganizer` 增**平铺出口** `organizeFlat(sessions:tab:metas:filter:now:tzOffset:) -> OrganizedFlat`,`OrganizedFlat { pinned: [SessionRowModel]; rest: [SessionRowModel] }`(无 `groups`/无 section 标题):内部先 `SessionTabFilter.filter` → 搜索过滤 → 未读 waiting 置顶(`pinned`)+ 其余按收藏优先稳定排序(`rest`),复用现有 `isUnreadWaiting`/收藏排序私有逻辑。现有 `organize`(带 `groups`)保留不动,面板改调 `organizeFlat`。
- **UI**:搜索框下方横向 tab 栏(Segmented 风格,自定义分组多时可横向滚动)。选中态 `config.selectedTab` 持久化(String 编码;`group(name)` 编码为 `group:name`)。
- 空 tab → 「该分组暂无会话」。
- 搜索与 tab 正交:tab 过滤后再套搜索(或反之,等价)。
- 页脚现有「已读」快捷键行为与「已读」tab 语义对齐(点已读页脚 = 切已读 tab 或保留标记已读?**决策:页脚「已读」保持原义(标记全部已读),不动**)。

**测试**:`SessionTabFilter.filter` 每 tab(含空、含多属分组);`.all` 与现有 organize 置顶序一致的回归。

## 6. 组件 D:自定义分组

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

## 7. 数据流

```
SessionStore 变更 → changeHandler
  → SummaryRefresher.plan(needsRefresh) → 后台算 → 写 meta.cachedSummary/anchor → 持久化
  → applyMetas(注入 favorite/customName/groups/summary)
  → SessionTabFilter.filter(by: config.selectedTab)
  → organize(平铺:未读置顶 + 收藏优先)
  → SessionRowMapper.make(summary:) → 面板渲染(3 行高:标题/目录/摘要 + 悬停☆)
```

## 8. 交付里程碑(建议一块一 PR/一评审批次)

- **M3-D-A**:悬停收藏按钮(§3)。最小,先落地验证行布局。
- **M3-D-B**:内联本地摘要(§4)。接上预留字段 + 后台缓存。
- **M3-D-C**:Tab 分流(§5)。取代分区。
- **M3-D-D**:自定义分组(§6)。依赖 C。

每块独立可测、可 ship;D 前需 C 的 tab 栏在位。

## 9. 非目标 / 遗留

- 模型摘要档 UI(仍遗留;本设计只接本地档,但缓存字段复用后模型档接入更顺)。
- OpenCode/QoderWork 的 DB 摘要(从 message 表)——B 之后的独立里程碑。
- 拖拽加入分组(本轮右键足够;拖拽 YAGNI)。
- 分组嵌套 / 分组图标颜色(YAGNI)。
