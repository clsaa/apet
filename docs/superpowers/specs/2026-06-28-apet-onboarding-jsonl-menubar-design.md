# apet M1.5 设计：开箱即用 + 常规 App 体验（v2，已纳入 5 视角面板评审）

> 状态：v2（架构/产品/AI/用户/测试 五视角面板评审已整合）
> 日期：2026-06-28
> 前序权威设计：`2026-06-27-apet-design.md`（本文档是其 M2「jsonl 兜底」提前 + 新增「常规 App 体验/引导」的细化）
> 评审纪要：见 §12（每条 blocker/major 的处置）

## 1. 背景与问题

M1 交付后实测发现三个挡在"能用"前面的问题：

1. **零会话**：唯一数据源是 Claude Code hook → `events.ndjson`。未装 hook 时一个会话都看不到；即便装了也只能采集装好之后**新开**的会话——当前正在跑的会话永远不显示。
2. **菜单找不到**：菜单栏图标灰色 template 字形淹没在一排图标里；`statusItem.menu = nil` 右键无反应；"首选项"被埋在左键 popover 底部，不符合常规 macOS App 习惯。
3. **无引导/无反馈**：首次启动无引导，用户不知道"要不要授权、会不会改我文件、配置成没成功"。

## 2. 目标 / 非目标

**目标**：
- **零配置开箱即用**：不装 hook 也能在面板看到所有 Claude Code 会话（含启动前已在跑的），靠只读扫描 `~/.claude/projects/**.jsonl`。
- **常规 App 体验**：图标可发现；**右键弹标准菜单** + **左键面板内常驻设置入口**；左键保持会话面板。
- **透明可控的引导**：明确"默认只读、不改任何文件、全程本地不上传"；hook 与通知授权改为**用到时再请求（just-in-time）**，不在冷启动堆弹窗。
- **配置健康可见**：首选项展示各项状态；"可选增强"与"故障"视觉分离。

**非目标 / 明确降级（本期不做或做不到，诚实声明）**：
- 图片生成 / 上传照片宠物（另起 brainstorm，已搁置）。
- **「进行中·等你授权工具」无法由 jsonl 可靠识别**（AI 抽样：pending 模式 401 文件仅命中 2，且与"正在执行工具"完全同形）。此状态的**秒级精确识别只能由 hook 提供**；jsonl 档降级为"近期活跃 → 转停下"。
- 其他 Agent（Qoder/QoderWork）的 jsonl 兜底：架构留口，本期只接 Claude Code；多 Agent 走 M4 公开契约。
- 多 root 扫描：本期只扫默认 `~/.claude`；但**检测到 `~/.claude-profiles/*` 存在却未纳入时，面板给一条提示**，避免静默空面板。
- 精确 tab 跳转的 jsonl 路径：jsonl 无 terminal ref，点击降级为"激活终端"，且**终端已关时给明确反馈**（§7）。

## 3. 关键决策溯源（v2）

| 决策 | 选择 | 理由 / 评审来源 |
|------|------|------|
| 状态如何派生 | **内容信号优先、mtime 兜底**：读末条 assistant `stop_reason`、`away_summary`、`queue-operation`、尾部元数据记录；mtime 仅作 running↔刚停的兜底 | AI 抽样证明 mtime 会被带外元数据写入刷晚 187s，单靠 mtime 会把已停会话误判绿点（AI-B2/M1） |
| jsonl「安静/已停」映射 | **away_summary 或活动陈旧 → 灰 `stale`（可复活）**；**末条 `end_turn` 且近期 → `waiting(.stop)` 但标注"推断"、视觉柔和** | 架构-M6 + 产品-B1 + 用户-Blocker：红"等你"是强信号，不能被一堆"已死/晾着"会话稀释 |
| jsonl 是否触发通知 | **seed 扫描静默（replay）**；**仅"运行中→end_turn"的实时翻转**按 notifyMode 触发，body 标"（推断）"；**精确"需关注/授权"通知只来自 hook** | 产品-B2 防启动通知风暴 + 防 cry-wolf；复用既有 replay/NotificationGate |
| seq 如何分配 | **全局共享单调 `SeqAllocator`，hook 与 jsonl 两路都取号** | 架构-B2 + 测试-B1：`apply` 内 `seq<=lastSeq` 跨源比较，各用各计数器会互相压制，违反硬约束#3 |
| 合成事件去重 | **弃"按 derivedState 散列去重"**；每次发射 eventId 唯一，watcher **对每会话 last-emitted 快照做差分，仅状态/关键字段变化才发射**；靠 `applyInner` 末尾 `stateChanged` 收敛广播 | 架构-B1 + 测试-B2：状态散列 + `seenEventIds` 永不清 → 回流 running 被吞 → 永卡红 |
| jsonl 会话生命周期/STALE | **由 scanner 内容+mtime 驱动（跨 idleWindow 或 away_summary → 发 stale 转换）**，不靠 store 的 `lastActiveAt` 计时器 | 架构-M4/M5：去重冻结 lastActiveAt 会误 STALE；两源 replay 策略冲突 |
| 读取方式 | **新增 `TailLineReader.lastLines(n,maxBytes)` 反向读尾 + seek0 读首行**；不复用 EventTailReader | 架构-M1/M2 + 测试-B3：EventTailReader 从 checkpoint 前向读到 EOF，冷启动读全量（实测最大 49.6MB）；entrypoint 在文件头、对话尾在文件尾 |
| 标题/cwd 来源 | **优先复用尾部元数据记录**：`custom-title`/`ai-title`→标题、`last-prompt`→最后输入；cwd 从带 cwd 的对话行取（尾 50–200 行才稳） | AI-B1：~95% 文件尾是无 timestamp/无 cwd 的元数据块，硬扫"user text"会落空 |
| 是否给 AgentEvent 加 source | **不加到 wire 模型**；用 `Session.terminal == nil` 判"能否精确跳转" | 架构-m1 + 测试-M5：动 wire 模型=动第三方契约且到不了 Session |
| subagent 排除 | **路径排除（3 层 `<uuid>/subagents/`）+ `isSidechain==true` 内容兜底** | AI-m1：实测 30/30 subagent 行 isSidechain=true，比路径鲁棒 |
| 合成会话过滤 | **主力 `entrypoint=="sdk-cli"`**；cwd 黑名单作冗余；**删除 `^Use the .* skill` 正则** | AI-M3：该正则已被 entrypoint 覆盖（86%）且有误杀风险 |
| 菜单交互 | **左键 popover 面板（底部常驻齿轮入口）+ 右键 NSMenu** | 用户-M3：用户想不到右键，设置不能只塞右键 |
| hook / 通知授权 | **just-in-time**：首次想跳转却只能"激活终端"时提示装 hook；首次真要通知时请求通知授权 | 产品-M3 + 用户：默认不勾的 opt-in 采纳率极低；冷启动连弹劝退 |
| 改 settings.json | **写入前展示将新增条目的预览/diff，确认后再写** | 用户-Major：开发者最在意这个文件，看得见才敢点 |

## 4. 架构总览

```
┌───────────────── 数据源（两路，融合进一个 Store）─────────────────┐
│  hook 实时        emit-event.sh ─append─▶ events.ndjson ─EventTailReader─┐ │
│  jsonl 兜底       ~/.claude/projects/**.jsonl ─JSONLDirectoryWatcher─┐  │ │
└──────────────────────────────────────────────────────────────────┼──┼─┘
                       两路都向 SeqAllocator.next() 取单调 seq ──────┘  │
                                                                        ▼  ▼
                        合成/真实 AgentEvent ──▶ SessionStore.apply()（唯一状态机）
                                                          │
              ┌───────────────────────────────────────────┼───────────────────┐
              ▼                          ▼                  ▼                   ▼
       PetState/通知(仅hook+实时翻转)  会话面板(左键,带齿轮)  菜单栏(右键NSMenu)  配置健康(首选项)
```

**一句话**：新增 jsonl 只读扫描，用**内容信号**派生状态、经**共享 seq**融进**已有** SessionStore；菜单栏补右键标准菜单 + 左键常驻设置；引导/授权全 just-in-time。

## 5. 组件设计

### 5.0 SeqAllocator（纯逻辑，AgentPetCore，可注入）

单调递增 seq 的唯一来源。`NDJSONIngestor`（hook 路径）与 `JSONLDirectoryWatcher`（jsonl 路径）**共用同一实例**。测试可注入受控实例断言"无论 wall-time 交错，ended 恒胜"。

```
final class SeqAllocator { func next() -> Int }   // 进程内单调，owner 串行化
```

### 5.1 JSONLSessionScanner（纯逻辑，AgentPetCore，全单测）

**职责**：把"一个会话文件的观测"翻译成"该产生哪个状态"。**不做 IO、不分配 seq、不发射事件**——纯函数，便于真值表断言。

```
输入：ScannedFile（由 IO 壳提供，含头尾已读字段）
  struct ScannedFile {
    sessionId: String
    root: String
    cwd: String?                 // 取自带 cwd 的对话行
    title: String?               // 优先 custom-title/ai-title 元数据记录
    lastPrompt: String?          // last-prompt 元数据记录（最后用户输入，标题兜底）
    mtime: Double                // 文件 mtime（Unix 秒，墙钟，与 now 同域）
    lastAssistantStopReason: String?  // 末条 assistant 的 message.stop_reason
    hasAwaySummary: Bool         // 尾部出现 system subtype==away_summary
    hasRecentQueueOp: Bool       // 尾部出现 queue-operation / 未应答 trailing user
    lastConversationTs: Double?  // 末条带 timestamp 对话行的时间（mtime 漂移校正用）
    entrypoint: String?          // 取自文件首行
    promptSource: String?        // 取自文件首行
    isSidechain: Bool            // 任一读到的行 isSidechain==true
    isSubagentPath: Bool         // 路径匹配 <uuid>/subagents/
  }

输出：ScanResult
  enum ScanResult: Equatable {
    case observe(state: ScanState, key: SessionKey, cwd: String?, title: String?)
    case ignore(IgnoreReason)
  }
  enum ScanState: Equatable { case running, waitingStop, stale }   // 映射 SessionState
  enum IgnoreReason: Equatable { case subagent, synthetic(SyntheticKind), blacklistedCwd, tooOld }
  enum SyntheticKind: Equatable { case sdkCli, sdkPromptSource }
```

**过滤优先级（高→低，命中即返回，保证真值表确定）**：
1. `isSubagentPath || isSidechain` → `.ignore(.subagent)`
2. `entrypoint=="sdk-cli"` → `.ignore(.synthetic(.sdkCli))`；`promptSource=="sdk"` → `.ignore(.synthetic(.sdkPromptSource))`
3. `cwd` 命中黑名单子串（`-iteration-`/`/eval-`/`/private/tmp/claude-`/`/private/var/folders`，大小写敏感）→ `.ignore(.blacklistedCwd)`
4. 活动时间 `effectiveTs = min(mtime, lastConversationTs ?? mtime)`；`now - effectiveTs ≥ idleWindow` → `.ignore(.tooOld)`（很旧，交给面板不再展示）

**状态派生（内容优先，mtime 兜底；窗口作入参注入）**：
- `hasAwaySummary` → **`.stale`**（用户离开，灰，可复活）
- 末条 assistant `stop_reason == end_turn`（或 `stop_sequence`）且未离开 →
  - `now - effectiveTs < idleWindow` → **`.waitingStop`**（轮到你，但 terminal==nil 时面板标"推断"、柔和色）
  - 否则 → `.stale`
- 末条 assistant `stop_reason == tool_use` 或 `hasRecentQueueOp` →
  - `now - effectiveTs < runningWindow` → **`.running`**（绿）
  - `runningWindow ≤ now - effectiveTs < idleWindow` → **`.waitingStop`**（刚停）
  - 否则 → `.stale`
- 无法判定（无 stop_reason、无元数据）→ 退回 mtime 兜底：`< runningWindow`→running；`< idleWindow`→waitingStop；否则 stale

> 窗口默认：`runningWindow = 120s`（放宽，避免读代码/思考期抖动）、`idleWindow = 30min`（砍掉原 4h，对齐 STALE 语义）。**绿↔停加滞回**：刚判 running 的会话需连续两次扫描落入"停"区间才翻 waitingStop（hysteresis，防闪烁）——滞回状态由 watcher 持有，scanner 收 `priorState` 入参保持纯函数。

### 5.2 JSONLDirectoryWatcher（IO 壳，AppShellKit；系统副作用经协议隔离）

**职责**：扫 `<root>/projects/`，对每个候选 `*.jsonl` 读头尾构造 `ScannedFile` → 喂 `JSONLSessionScanner` → 对每会话 **last-emitted 快照差分**，仅变化时经 `SeqAllocator.next()` 合成一条 `AgentEvent` 回调 `AppCoordinator`。

- **协议缝（可测）**：`protocol DirectoryScanning`（列目录，可喂临时目录）、`protocol Scheduler`（注入假调度器确定性触发 seed/周期）、`now: () -> Double`。
- **读取**：`TailLineReader.lastLines(path, n, maxBytes)`（反向 seek 至多 maxBytes、丢首个残行、UTF-8 截断防御）+ seek0 读首行取 entrypoint/promptSource。`n/maxBytes` 双上限取较大者（实测尾 50–200 行才稳拿 cwd/title）。
- **合成 AgentEvent**：`eventId = "jsonl:" + sessionId + ":" + seq`（每次发射唯一）；`terminal=nil`。kind 映射：`running→.busy`、`waitingStop→.stop`。**`stale` 不映射 `.sessionEnd`**（stale ≠ 终态 ended，必须可复活）——`stale` 走 §5.3 约定的"令会话进入 stale"的内部语义，不经 ended 路径。
- **生命周期**：watcher 是 jsonl 会话生命周期的权威——状态变化才发事件；跨 idleWindow/away_summary 时发 stale 转换。**不写 events.ndjson**（活投影）。
- **降级**：`projects/` 不存在 → 上报 `ConfigHealth.jsonlSource = .pathMissing`；单文件 `EACCES` → `TailLineReader` 返回 `.unreadable(path)`（不吞成空），watcher 跳过 + 计入健康，不崩、不影响 hook 路径。
- **防御式解析 + 固定夹具语料**：未知 type 跳过、缺字段不崩；锁一份覆盖 end_turn/away_summary/尾元数据块/subagent/sdk-cli/queue-operation 各形态的 jsonl 夹具进单测，CC 版本漂移时回归。

### 5.3 SessionStore 融合（复用，最小改动）

- jsonl 合成事件与 hook 事件走**同一 `apply()`**，共享 SeqAllocator 的单调 seq；归一键含 `root` 天然同会话合并。
- **复用硬约束**：`ended` 终态不被 jsonl 复活；`terminal` 精确值不被 nil 降级；字段级 last-non-nil-wins；排序唯一事实 = seq。
- **最小扩展**：需要一条"令会话进入 `.stale`"的合成事件语义。优先复用既有 `markStale` 不够（它按 lastActiveAt 计时）。方案：watcher 对 `.stale` 发 `.busy/.stop` 之外的事件——具体在实现计划里二选一定稿：(a) 给 apply 增加显式 `case staleHint`（仅内部源用，不进 wire decode）；(b) watcher 直接调 `store.markStaleSession(key)`。**契约不变量**：任何选择都不得让 jsonl 复活 hook 的 ended、不得绕过 seq 单调。
- **不加 wire `source`**；消费端用 `Session.terminal == nil` 判"是否可精确跳转"。

### 5.4 菜单栏常规化（apet + AppShellKit）

- **MenuBarMenuModel**（纯逻辑，AppShellKit，可测）：产出 `[MenuRow]`，`MenuRow: Equatable { title, command: MenuCommand, enabled, shortcut }`，`enum MenuCommand: Equatable { case sessionSummary, preferences, about, quit }`。测试断言期望数组全等。
- **MenuBarController**（UI）：
  - `button.sendAction(on: [.leftMouseUp, .rightMouseUp])`；按 `NSApp.currentEvent?.type` **early-return 分流**：左键→popover；右键→用 MenuBarMenuModel 构 `NSMenu`，`menu.popUp(...)` 临时弹（**不**长期 set `statusItem.menu`，避免吃掉左键）；popUp 前后手动设/清 button highlight。
  - 图标：保持 HIG template 单色，换明确的 `pawprint.fill`；忙时按 tint 上色。
- **面板底部常驻入口**：左键 popover 底部保留齿轮/⋯（首选项、退出），不把设置唯一塞右键（用户-M3）。

### 5.5 引导 + 配置健康（apet + AppShellKit）

- **ConfigHealth**（纯逻辑，AppShellKit，可测）：四项枚举 + **完整决策表**映射 overall（实现计划附全组合真值表）：
  - `notification: .authorized/.denied/.notDetermined`
  - `hook: .installed(path)/.notInstalled/.failed(reason)`
  - `jsonlSource: .found(count)/.pathMissing/.unreadable(path)`（count = **过滤后保留的会话数**，与面板一致）
  - `dataRoots: [root]`
  - `overall`：**只要 `jsonlSource==.found(>0)` 即 `.ready`（"已就绪，正在看你的会话"）**；hook 装好则 `.readyEnhanced`；仅 `jsonlSource==.pathMissing/.unreadable` 或 `notification==.denied`（且用户想要通知）才算降级。**hook 未装绝不算故障**。
- **OnboardingFlow**（UI，apet）：检测无配置文件 → 弹**1–2 屏**精简引导：
  1. "它在这 ↑"（箭头指菜单栏图标）+ 一句隐私硬承诺："**全程本地、零网络请求**；只读 mtime 与每个会话头尾几行判断状态，**不留存、不上传**你的对话内容。"
  2. （可选第 2 屏）一句"完成/需关注想收**通知**、想**精确跳回终端 tab**？用到时我再问你授权。" → 关闭即进入零配置可用态，面板已有真实会话作"活教材"。
  - **通知授权**：延后到第一次真要发通知那刻，带上下文请求。
  - **hook**：延后到第一次点会话只能"激活终端"那刻，就地提示 + **展示将新增的 settings.json 条目预览** → 确认才走门控 HookInstaller。
- **首选项·配置健康面板**：渲染 ConfigHealth；**"可选增强"（hook）显示为中性"可增强 ➕"而非红 ❌**；jsonl 就绪顶部一句"已就绪"；失败项（路径不可读/通知被拒）才用 ❌ 并给修复入口；可"重跑向导"；检测到 `~/.claude-profiles/*` 未纳入 → 提示。

## 6. 数据流：当前会话如何立刻、且正确地变绿

1. 启动 → watcher 扫到本会话 jsonl，读尾部：末条 assistant=`tool_use` 或近期 `queue-operation`，`now - effectiveTs < 120s`。
2. scanner → `.observe(.running, …)`；非 subagent/非合成。
3. watcher 取 `SeqAllocator.next()` → 合成 `AgentEvent(kind=.busy, agent=claude, root=~/.claude, sessionId, cwd, terminal=nil, eventId="jsonl:…:seq")` → `apply(replay=true)`（seed 静默）。
4. Store 新增 running 会话 → 面板**绿点**、菜单栏 tint 变绿。**seed 不发通知**。
5. 你回车继续 → jsonl 刷新、watcher 下次扫描状态不变 → 差分无变化、不重复发事件（避免 seenEventIds 膨胀）。
6. Claude 答完 `end_turn` → 实时翻转 `.waitingStop` → 发事件（replay=false）→ 面板转"轮到你"（terminal==nil 标"推断"、柔和）；若 notifyMode=每轮结束 → 一条"（推断）已完成"通知。
7. 你离开、CC 写 `away_summary`，或 30min 无活动 → `.stale` → 灰点、不再喊你。

## 7. 错误处理与边界

- `projects/` 或某 jsonl 不可读 → 显式 `.unreadable`，跳过 + 健康标注，不崩、不影响 hook。
- 超大 jsonl（实测 49.6MB）→ 只读头一行 + 尾 maxBytes，O(1)-ish；窗口注释不写死绝对 MB 值。
- **mtime 漂移**：带外元数据写入会把 mtime 顶到对话结束之后；用 `effectiveTs = min(mtime, lastConversationTs)` 校正，避免已停会话误判绿点（AI-B2）。
- jsonl running 与 hook ended 冲突 → ended 终态保护胜出。
- **终端已关的会话**：jsonl 仍可能显示 waitingStop；点击"激活终端"失败时给明确反馈"会话窗口可能已关闭"，并视觉弱化此类点（用户-Major）。
- 同 sessionId 跨文件（resume/拷贝）→ 同键合并，按 effectiveTs 取最新，不重复计数。
- 时钟：全程 `now: Double`（墙钟 Unix 秒，与 fs mtime 同域）注入，便于测试窗口边界。

## 8. 测试策略

- **纯逻辑 TDD（大头）**：
  - `JSONLSessionScanner`：过滤优先级真值表（subagent/sidechain/sdk-cli/黑名单/tooOld 各命中且多命中按优先级）、状态派生矩阵（away_summary / end_turn×窗口 / tool_use×窗口 / queue-op / 兜底）、边界值（`now-effectiveTs` 正好 = runningWindow/idleWindow 的归属，运算符方向钉死：running `<120`、waitingStop `[120,30min)`、ignore `≥30min`）、滞回（priorState 入参）、mtime 漂移校正（effectiveTs=min）。窗口作入参注入小值精确打边界。
  - `MenuBarMenuModel`：期望 `[MenuRow]` 全等断言。
  - `ConfigHealth`：四枚举全组合 → overall 唯一值。
  - `TailLineReader`：临时目录夹具断言"只读尾 K 字节/丢残行/UTF-8 截断/EACCES→.unreadable"。
- **融合测试**：注入受控 SeqAllocator，构造"jsonl running(.busy) + hook ended(.sessionEnd)"任意交错，断言 ended 恒胜不复活、不双计数、回流 running→stop→running 能正确翻转（验证已弃状态散列去重）。
- **固定 jsonl 夹具语料**：覆盖各真实形态，锁单测防 CC 版本漂移。
- **IO/UI 副作用**：`DirectoryScanning`/`Scheduler`/`now` 注入 mock；FSEvents/NSMenu/向导/UNUserNotification 手动验证。
- **回归基线**：改动前先跑既有 205 测试取基线；`source` 不入 wire，AgentEvent 合成 Equatable/decode 不受影响。

## 9. 里程碑切分（实现顺序）

1. **菜单栏常规化 + 面板齿轮入口**（小，先让设置可达）。
2. **TailLineReader + SeqAllocator + JSONLSessionScanner**（纯逻辑地基，全 TDD）。
3. **JSONLDirectoryWatcher + 融合 SessionStore**（IO 壳 + 集成）。
4. **引导（精简 + just-in-time 授权 + settings.json 预览）+ 配置健康面板**。

每步：纯逻辑 TDD → `swift test` 全绿 → 5 视角子 Agent 评审 → 修订 → 小步提交。

## 10. 接口契约小结（第三方/下游不变量）

- 事件 wire 协议**不变**（不加 source）；jsonl 是**进程内合成事件**，不写 events.ndjson、不进 decode。
- `SessionStore.apply` 既有不变量全保留；新增的"令 stale"语义仅供内部源，不暴露给 wire。
- seq 单调性由共享 SeqAllocator 保证——任何新事件源必须取号，不得自带计数器。

## 11. 与上位设计的关系

本文档把上位 `2026-06-27-apet-design.md` 的 M2「jsonl 兜底扫描」提前实现，并细化「常规 App 体验/引导」。上位 §3 的 logscan 档定义（terminal:none 仅激活、状态扫日志）在此具体化为"内容信号优先"的派生规则；§3 评估窗口规则（末尾近 N 行 + mtime 过滤）被 AI 抽样修正为"内容信号优先、mtime 漂移校正、读头尾而非纯尾窗"。

## 12. 五视角面板评审处置纪要

| 来源 | 级别 | 问题 | 处置 |
|------|------|------|------|
| 架构-B1/测试-B2 | Blocker | 状态散列去重致会话永卡红 | §3/§5.2：弃状态散列，eventId 每发射唯一 + watcher 差分 + stateChanged 收敛 |
| 架构-B2/测试-B1 | Blocker | 合成事件 seq 来源未定义破坏融合 | §5.0：共享 SeqAllocator 两路取号 |
| AI-B1 | Blocker | "末行=attachment"假设错，尾是无 cwd 元数据块 | §3/§5.1：复用 last-prompt/ai-title 元数据；读头尾；cwd 取自对话行 |
| AI-B2 | Blocker | mtime 被带外写入刷晚→已停误判绿 | §5.1/§7：effectiveTs=min(mtime,lastConversationTs) |
| 用户-Blocker/产品-B1/架构-M6 | Blocker/Major | 红"等你"被一堆已死/晾着会话稀释 | §3：away/旧→灰 stale；end_turn 近期→waitingStop 标"推断"柔和；红留 hook |
| 产品-B2 | Blocker | 零配置通知失灵/启动风暴 | §3/§6：seed 静默 replay；仅实时翻转通知标"推断"；精确通知靠 hook |
| AI-M1 | Major | 漏用 stop_reason/away_summary 确定性信号 | §5.1：内容信号优先派生 |
| AI-M2/产品-B2 | Major | "等你授权"jsonl 不可识别 | §2 非目标：明确只 hook 能给，jsonl 降级 |
| 架构-M1/M2、测试-B3 | Major | EventTailReader 不能读尾；entrypoint 在头 | §3/§5.2：TailLineReader + seek0 读首行 |
| 架构-M3 | Major | adapter 落在不单测的 IO 壳 | §5.1：scanner 纯逻辑输出可断言 ScanResult；eventId/kind 映射进单测 |
| 架构-M4/M5 | Major | 去重冻结 lastActiveAt 误 STALE；replay 冲突 | §3/§5.3：jsonl 生命周期由 scanner 驱动；seed replay 仅静默通知 |
| 产品-M3/用户 | Major | hook 默认不勾→核心功能不可达 | §3/§5.5：just-in-time，首次跳转时提示 |
| 用户-Major | Major | 改 settings.json 要可见 | §5.5：写入前展示新增条目预览 |
| 用户-M3 | Major | 设置只塞右键找不到 | §5.4：左键面板底部常驻齿轮 + 右键菜单 |
| 产品-M5 | Major | 隐私只说不改文件、没说读对话 | §5.5：本地/零网络/不上传 硬承诺；标题截断 |
| 产品-M4/用户 | Major | 开箱被向导前置；多 profile 静默空 | §5.5：精简引导、真实会话当活教材；profile 提示 |
| 用户-Major | Major | 终端已关红点点击默默失败 | §7：明确反馈"窗口可能已关闭"+视觉弱化 |
| 测试-M1/M2/M3/M4 | Major | 类型未定型不可精确断言；缺协议缝 | §5.1/§5.4/§5.5/§5.2：IgnoreReason/MenuCommand/overall 决策表/协议缝 + .unreadable |
| AI-M3/m1 | Major/Minor | skill 正则死规则；isSidechain 更鲁棒 | §3/§5.1：删正则；isSidechain + 3 层路径 |
| AI-M4 | Major | 格式跨版本漂移 | §5.2：防御式解析 + 固定夹具语料 |
| 用户-m7/产品-m7 | Minor | 45s 太敏感抖动 | §5.1：runningWindow=120s + 滞回 |
| 产品-m8/用户-m8 | Minor | 健康面板 hook❌ 像故障 | §5.5：hook 未装=中性"可增强➕" |
| AI-m3 | Minor | queue-operation 是正向活跃信号 | §5.1：hasRecentQueueOp→倾向 running |
| 测试-m1/m2 | Minor | 窗口须入参；边界运算符/标题 trim | §5.1/§8：窗口注入；运算符方向钉死；标题截断 |
