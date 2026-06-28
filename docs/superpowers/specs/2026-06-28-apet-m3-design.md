# apet M3 设计：体验修复 + 外观 + 会话管理 + 多终端/多 Agent + AI 总结

> 状态：草案（用户授权自主推进；5 视角对抗评审替代用户审批门）。
> 上游权威：`2026-06-27-apet-design.md`（v2 总设计）、`2026-06-28-apet-onboarding-jsonl-menubar-design.md`（M1.5）、`2026-06-28-apet-m2-pets-multisource-design.md`（M2）。
> 本文是 **M3 伞形设计**：先把用户这批诉求 + 主动发现的问题全量编目，再分解为 4 个可独立交付的子批次（A/B/C/D），每批次单独出 plan → 实现 → 评审 → 交付。

---

## 1. 需求来源与全量编目

用户一次性给出的诉求（原话要点）+ 我主动排查发现的其它功能问题，统一编号。`[BUG]`=回归/缺陷，`[FEAT]`=新功能，`[+]`=我主动补充。

| 编号 | 来源 | 诉求 | 现状（已查证） |
|---|---|---|---|
| **B1** | 用户 `[BUG]` | 看完提示消息后状态没立即变化 | `NotificationService.didReceive`（点击通知）只 `focus(terminal)`，**从不调用 `acknowledge`** → 红不转黄 |
| **B2** | 用户 `[BUG]` | 鼠标点击宠物有时不弹窗 | `DragDetectorView` 阈值 8pt；`togglePopover` 先 `NSApp.activate`+`makeKeyAndOrderFront` 再 transient 弹窗，激活竞态/非 key 窗口偶发吞掉首击 |
| **B3** | 用户 `[BUG/FEAT]` | 去掉图片白色背景，要透明背景 | 内置 `shiba/bichon/idle.png` 是 **RGB 无 alpha（不透明方块）**；`PetView.clipShape(Circle)` 只对 custom 生效 → 内置宠物桌面显示为不透明方块 |
| **F1** | 用户 `[FEAT]` | 消息通知 + 声音，分别开关 | `NotifyMode={attentionOnly,everyStop}`；声音恒为 `.default`，**无独立开关** |
| **F2** | 用户 `[FEAT]` | 状态栏做"类似截图效果"的东西 | 状态栏仅 SF Symbol `pawprint`，无宠物头像 |
| **F3** | 用户 `[FEAT]` | 4 状态颜色支持自定义 | `Tint` 硬编码 systemGreen/Red/Orange/gray |
| **F4** | 用户 `[FEAT]` | 首选项分多菜单（外观/Agent/通知…） | 首选项当前单页 |
| **F5** | 用户 `[FEAT]` | 内置：01=作者 / 02=柴犬 / 03=比熊；上传宠物可命名 | `PetKind` 无显示名；`CustomPetStore` 按 UUID 存目录，**无名字**；仅 shiba/bichon 两内置，**无"作者"** |
| **F6** | 用户 `[FEAT]` | 授权调用本地 ClaudeCode/Qoder 对活跃会话总结并展示 | 无；最复杂，需拉起外部 CLI |
| **F7** | 用户 `[FEAT]` | 会话重命名 + 收藏 | `Session` 无 displayName/favorite |
| **F8** | 用户 `[FEAT]` | 会话列表分页 + 分类 + 按日期类别查询/浏览 | 面板平铺全部会话，无分组/分页 |
| **F9** | 用户 `[FEAT]` | 默认快捷键改 ⌥⌘S | 当前默认 ⌥⌘P（keyCode 35） |
| **F10** | 用户 `[FEAT]` | 会话列表展示创建时间 + 最后修改时间 | `Session.lastActiveAt`（=最后修改）有；**无 createdAt** |
| **F11** | 用户 `[FEAT]` | 复制 sessionID 按钮，用于跨 Agent 恢复（走插件协议） | 无复制；resume 命令各 Agent 不同 |
| **F12** | 用户 `[FEAT]` | 多终端支持 | 仅 iTerm2 定位器 |
| **F13** | 用户 `[FEAT]` | 所有跨 Agent 交互走之前设计的插件协议 | 插件契约见总设计 §3，尚无多 Agent 适配 |
| **A1** | 我 `[+BUG]` | 桌宠 popover 缺"退出"入口 → 状态栏图标被刘海藏时**无法退出 App** | 刚加了"首选项"，仍缺"退出" |
| **A2** | 我 `[+]` | read-state/收藏/重命名 **无持久化**，重启全丢 | `acknowledged` 仅在内存 `SessionStore` |
| **A3** | 我 `[+]` | 会话源仅 `~/.claude/projects` → Qoder 等其它 Agent 会话**未接入**（F6/F11/F13 的前置） | 仅 Claude jsonl + hook |
| **A4** | 我 `[+]` | 无开机自启选项 | 无 login item |
| **A5** | 我 `[+]` | 仅中文，无英文本地化 | — |
| **A6** | 我 `[+]` | 无 VoiceOver/无障碍标签 | — |

---

## 2. 分解为 4 个子批次（交付顺序）

每个子批次都是**可独立编译、测试、交付**的工作单元，单独出 plan。顺序按"价值 × 低风险优先 + 前置依赖"排：

| 批次 | 主题 | 含编号 | 风险 | 依赖 |
|---|---|---|---|---|
| **M3-A** | 体验修复 + 外观自定义 | B1 B2 B3 A1 F1 F2 F3 F4 F5 F9 + A2(持久化地基) | 低 | 无 |
| **M3-B** | 会话管理增强 | F7 F8 F10 F11(复制部分) | 中 | A2 |
| **M3-C** | 多终端 + 多 Agent 接入 | F12 A3 F13 F11(跨 Agent resume) | 中 | 插件契约 |
| **M3-D** | AI 会话总结 | F6 | 高 | A3、C 的 Agent 适配 |

**Defer（记入 backlog，本期不做，YAGNI）**：A4 开机自启（除非 A 末尾低成本顺手）、A5 英文本地化、A6 无障碍。理由：均非当前阻塞痛点，且会显著拉大每批次面。

> 用户特别强调"同时支持多终端支持" → **M3-C 必须落地**，不得因排在后面被丢。

---

## 3. M3-A 设计：体验修复 + 外观自定义

### 3.1 持久化地基（A2）—— 其它一切的底座

**新增** `SessionMetaStore`（AppShellKit，IO 缝）+ 纯逻辑 `SessionMeta`（AgentPetCore）。

- 落盘：`~/Library/Application Support/AgentPet/session-meta.json`，JSON。
- 键：`metaKey = "\(agent)::\(sessionId)"`（**不含 root**——同一会话换 cwd 不应丢元数据；与 SessionStore 的归一键 `(agent,root,sessionId)` 区分，root 仅用于运行时去重，元数据按会话身份持久）。
- 值 `SessionMeta`：`{ acknowledged: Bool, favorite: Bool, customName: String?, firstSeenAt: Double?, cachedSummary: String?, summaryAt: Double? }`。
- 纯逻辑：`SessionMeta` 的合并规则放 core，可单测。`SessionMetaStore` 仅负责 load/save（注入 `FileOps`，MockFileOps 单测）。
- 接线：`AppCoordinator` 在会话 upsert 后，用 metaKey 读 meta 注入 `Session`（acknowledged/displayName/favorite）；在 `acknowledge`/重命名/收藏变更后 `save`。**SessionStore 保持纯内存**，不直接碰磁盘（架构红线：core 无副作用）。

> 决策：`acknowledged` 现在挂在 `Session`（core），M3-A 起其"真值"来自 SessionMetaStore，运行时镜像进 Session。启动 replay 时按 meta 恢复，解决"重启已读态丢失"。

### 3.2 B1 通知点击 → 标记已读

`NotificationService.didReceive` 在 `focus(terminal)` 同时，调用注入的 `onAcknowledge(SessionKey)`（= `store.acknowledge` + `metaStore.save`）。红→黄即时生效。新增单测：点击回调触发 acknowledge。

### 3.3 B2 宠物点击可靠性

根因假设（待实现期复现确认）：transient popover 锚在刚 `makeKeyAndOrderFront` 的非 key 窗口上，激活竞态偶发吞首击。**改造**：
- 点击与拖动判定下沉为纯逻辑可测：`ClickDragClassifier`（输入 down/move/up 坐标序列 + 阈值，输出 `.click | .drag`），`DragDetectorView` 只做事件采集。
- 弹窗时序：先确保窗口 key（同步），popover `.show` 放到下一 runloop（`DispatchQueue.main.async`）避免与 activate 竞争；若 `popover.isShown==false` 但应显示，做一次重试兜底。
- 验收：连续点击 20 次必弹（实现期手测 + 分类器单测覆盖抖动/微移/长拖）。

### 3.4 B3 + 透明背景

- **内置宠物**：用 Vision cutter 离线把 `shiba/bichon/idle.png` 处理成透明 PNG，替换 Resources（构建期一次性，产物入仓）。无 alpha 的方块根因消除。
- **PetView 统一裁剪**：透明 PNG 后，圆形裁剪对内置/自定义**一致**（去掉"仅 custom 才 clipShape"的分支，改为所有宠物统一圆形 + 透明）。
- 上传宠物：M2 已有 Vision cutout，沿用；首选项预览展示透明效果。

### 3.5 A1 桌宠 popover 加"退出"

`PetPanelRootView` 页脚在"首选项…"下增"退出 apet"，调 `NSApp.terminate`。解决状态栏被藏时无法退出的死锁。

### 3.6 F1 通知 / 声音 分别开关

`AppConfig` 增 `notifyBannerEnabled: Bool=true`、`notifySoundEnabled: Bool=true`（`decodeIfPresent` 向后兼容）。`NotificationService`：banner 关→不 `center.add`；sound 关→`content.sound=nil`。`NotifyMode` 不变（决定**哪些事件**），两开关决定**横幅/声音通道**。首选项"通知"页两个独立开关。

### 3.7 F2 状态栏宠物头像

`AppConfig.menuBarIconStyle: String ∈ {"symbol","petAvatar"}`（默认 `"symbol"`，保持现状不惊扰）。
- `petAvatar`：取当前选中宠物的透明 PNG，缩放至 ~18px 作 `statusItem.button.image`（`isTemplate=false`），状态用**右下角小圆点**（当前态色）叠加，而非整体 tint。
- 渲染纯逻辑可测部分：`MenuBarIconPlan`（输入 style+state+petImageAvailable → 输出 symbol 名 or avatar+dot 计划）；位图合成在 apet 层。
- "类似截图效果"取意为：把宠物头像**像小快照一样**显示在状态栏（而非桌面截图——后者涉隐私 + 高复杂度，YAGNI 拒绝；已记录该取舍）。

### 3.8 F3 自定义状态颜色

`AppConfig.stateColors: { running, attention, read, idle: String(hex) }`，默认 = 现值（#34C759/#FF3B30/#FFCC00/#8E8E93 量级）。
- 纯逻辑：`Tint` 枚举不变（presenter 仍输出语义态）；**颜色解析在视图层**，apet 用 `HexColor.parse(config.stateColors[tint])`，非法 hex 回退默认（`HexColor` 纯函数单测：#RGB/#RRGGBB/带#/非法）。
- 首选项"外观"页 4 个取色器 + 重置默认。

### 3.9 F4 首选项分类

`PreferencesWindow` 改 TabView/NSToolbar 分页：
1. **外观**：宠物选择/命名/上传、状态颜色、状态栏样式、快捷键。
2. **通知**：模式、横幅开关、声音开关、免打扰（M2 已有）。
3. **会话**：数据源/多 profile（M2 已有）、（M3-D）总结授权。
4. **终端 & Agent**：终端偏好（M3-C）、已接入 Agent（M3-C）。
5. **关于**：版本、作者、开机自启（若做 A4）。
> M3-A 先把"外观/通知"两页做实，其余页占位，随 B/C/D 填充。

### 3.10 F5 宠物命名

- 内置三只：`builtin("author")→"01 作者"`、`builtin("shiba")→"02 柴犬"`、`builtin("bichon")→"03 比熊"`。`PetSelection.parse` 增 author。
  - **"01 作者"资产缺失** → 决策：M3-A 用占位（app 图标/简笔头像）落 `Resources/pets/author/idle.png`（透明），并在 spec 标注"作者头像待用户替换"；不阻塞。
- 自定义宠物命名：`CustomPetStore` 增 `pets.json` manifest（`id → {name, createdAt}`）；`importPhoto(srcPath:name:)` 落名；list 返回 `(id,name,imagePath)`。首选项上传后可编辑名字。
- 显示名贯穿：宠物选择器、状态栏 tooltip、缩略图标签。

### 3.11 F9 默认快捷键 ⌥⌘S

`HotKeyConfig.defaultPanel` keyCode 35→**1（S）**，modifiers 保持 2304（⌥⌘）。已存配置者不受影响（只改默认）；首选项可改。面板顶部提示同步显示 ⌥⌘S。

### 3.12 M3-A 测试要点

ClickDragClassifier（抖动/微移/拖动边界）、HexColor.parse、SessionMeta 合并、SessionMetaStore load/save（MockFileOps）、通知点击→acknowledge、notify 双开关门控、MenuBarIconPlan、PetSelection.parse(author)、builtin 透明 PNG 存在性 + 圆裁统一。

---

## 4. M3-B 设计：会话管理增强

### 4.1 F7 重命名 + 收藏（依赖 A2）
- `Session` 增运行时镜像 `displayName: String?`、`favorite: Bool`（真值在 SessionMeta）。
- 面板行：右键/悬浮菜单"重命名""收藏/取消收藏"；重命名走 sheet 输入，写 SessionMetaStore。
- 收藏分组置顶。

### 4.2 F10 创建 + 最后修改时间
- `Session` 增 `createdAt: Double?`：首次 upsert 时 `min(已有, firstSeenAt, 事件 ts)`；jsonl 源用文件创建时间兜底，写入 SessionMeta.firstSeenAt 持久。
- `lastActiveAt` 即最后修改。行展示两时间（相对："3 分钟前 / 创建于昨天"）。

### 4.3 F8 分页 + 分类 + 日期浏览
- 面板列表重构为分组：**按状态**（在跑/未读/已读/闲置/收藏）+ **按日期**（今天/昨天/本周/更早）+ **按 Agent**，分组维度可切。
- 分页：会话数 > 阈值（默认 50）时懒加载"加载更多"，避免长列表卡顿（大列表用 List 复用）。
- 纯逻辑：`SessionListOrganizer`（输入 sessions + 分组维度 + 页大小 → 输出分组分页结构），完全可单测。

### 4.4 F11 复制 sessionID（复制部分；resume 兼容入 M3-C）
- 行内"复制 ID"按钮 → `NSPasteboard` 写 sessionId。
- 旁注 resume 提示（命令来自 Agent 适配描述，M3-C 提供；M3-B 先复制 ID + 显示 Claude 默认 `claude --resume <id>`）。

---

## 5. M3-C 设计：多终端 + 多 Agent（走插件协议）

### 5.1 F12 多终端定位器
- `TerminalLocator` 重构为协议 + 能力分级：
  | 终端 | 能力 | 实现 |
  |---|---|---|
  | iTerm2 | 精确 tab（现状） | 现有 AppleScript |
  | Terminal.app | window 级激活 | AppleScript（bundleId `com.apple.Terminal`） |
  | Warp | 仅 bundleId 激活到前台 | `NSWorkspace` 激活 `dev.warp.Warp-Stable` |
- `TerminalRef` 增 `app` 类型 + 能力位。AppleScript **一律参数化 + 白名单**（安全红线，沿用 §6）。
- 纯逻辑：定位器选择 + 能力分级可测；AppleScript 执行在 IO 缝。

### 5.2 A3 + F13 多 Agent 接入（插件协议）
- 抽象 **Agent 适配描述** `AgentAdapter`（落插件契约扩展）：`{ agentCode, projectsRootGlob, sessionIdExtractor, resumeCommandTemplate, stateRules? }`。
  - Claude：内置（`~/.claude/projects/**`，resume `claude --resume {id}`）。
  - Qoder/QoderWork：经 manifest 注册（rootGlob、resume 模板按 Qoder 实际填；**未知则标注"待核实"，绝不臆造命令**——遵守 no-fabricated-urls-commands 记忆）。
- `JSONLDirectoryWatcher` 泛化为多 root/多 agent；`SessionKey.agent` 已存在，天然支持。
- F11 resume：每行按 `session.key.agent` 取 `resumeCommandTemplate` 渲染（argv 化，无注入），复制完整命令。

### 5.3 跨 Agent 兼容
- 所有跨 Agent 字段经插件协议 DTO，不在 UI 层硬编码各 Agent 差异（F13）。
- sessionId 语义差异（Claude UUID vs Qoder ?）由 adapter 的 `sessionIdExtractor` 归一。

---

## 6. M3-D 设计：AI 会话总结（最高风险，最后做）

### 6.1 目标
授权后，apet 拉起本地 Agent CLI 对**指定活跃会话**做只读总结，面板展示，便于用户定位某会话。

### 6.2 安全 / 授权 / 成本红线
- **绝不自动跑**：每次总结需用户显式触发（行内"总结"按钮）或显式开启"自动总结活跃会话"开关（默认关）。
- **白名单 CLI**：仅 `claude` / `qoder` 等已注册 Agent 的可执行；路径来自 adapter，argv 化执行，无 shell 拼接（注入红线）。
- **超时 + 取消**：默认 30s 超时，可取消；并发上限。
- **成本提示**：总结调用消耗模型额度，UI 明示；结果缓存进 `SessionMeta.cachedSummary`+`summaryAt`，避免重复烧。
- **只读**：总结调用不得改会话/不得写用户工程。

### 6.3 实现
- `SummarizerService`（AppShellKit）：输入 `(adapter, sessionId, jsonlPath)`，渲染 adapter 的"总结命令模板"（如 `claude -p "用三句话总结这个会话在做什么" --resume {id}` 或读 jsonl 末段 pipe 给 `claude -p`），`Process` 执行，捕获 stdout。
- 纯逻辑：命令模板渲染 + 输出裁剪可测；`Process` 执行在 IO 缝（协议 + Mock）。
- 面板：会话行可展开显示总结 + "重新总结"。

### 6.4 决策记录
- **方式取舍**：优先 `claude -p --resume {id}`（复用会话上下文）；若 Qoder 无等价能力 → 退化为"读 jsonl 末 N 条 → 喂 `claude -p`"。具体命令**待 Qoder 能力核实**，不臆造。
- 该批次单独再过一轮 5 视角评审（安全/成本面大）。

---

## 7. 全局约束（继承 + 新增）

继承总设计 §3/§4/§6（零依赖、不用 `Date()`、seq 排序、AppleScript 参数化、测试是规范）。新增：
- **持久化新增 IO 缝**（SessionMetaStore/pets.json/SummarizerService）必须协议化 + MockFileOps/MockProcess 单测；core 仍纯。
- **AppConfig 所有新字段 `decodeIfPresent` + 默认值**（向后兼容铁律，沿用 M2 教训）。
- **外部进程（M3-D）argv 化、白名单、超时**，零 shell 注入。
- **跨 Agent 一律走插件协议 DTO**（F13），UI 不硬编码 Agent 差异。
- **不臆造 Qoder 的 resume/总结命令**（遵守 no-fabricated-urls-commands）。

---

## 8. 测试策略

每批次纯逻辑新增类全部进 XCTest 矩阵（正常/边界/异常）；IO 缝用 Mock；GUI 行为（点击/弹窗/状态栏）实现期 headless smoke + 手测验收。维持"测试是规范"。

---

## 9. 未决/假设（已用默认拍板，醒后可推翻）

1. 状态栏"截图效果" = 宠物头像入状态栏（非桌面截图）。
2. "01 作者"宠物用占位资产，待替换。
3. Qoder 的 jsonl 路径 / resume / 总结命令待核实，先内置 Claude，Qoder 留 manifest 接口。
4. 分页阈值 50、总结超时 30s 为默认，可配。
5. Defer：开机自启、英文本地化、无障碍。
