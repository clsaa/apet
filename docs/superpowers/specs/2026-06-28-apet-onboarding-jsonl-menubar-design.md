# apet M1.5 设计：开箱即用 + 常规 App 体验

> 状态：草案（待 5 视角面板评审）
> 日期：2026-06-28
> 前序权威设计：`2026-06-27-apet-design.md`（本文档是其 M2「jsonl 兜底」提前 + 新增「常规 App 体验/引导」的细化，不冲突，只细化）

## 1. 背景与问题

M1 交付后实测发现三个挡在"能用"前面的问题：

1. **零会话**：唯一数据源是 Claude Code hook → `events.ndjson`。未安装 hook 时一个会话都看不到；而 hook 安装是门控的（绝不擅自改用户 `~/.claude/settings.json`），且即便装了，**也只能采集装好之后新开的会话**——当前正在跑的会话永远不显示。
2. **菜单找不到**：菜单栏图标是灰色 template 字形，淹没在一排图标里；且 `statusItem.menu = nil`，**右键无任何反应**，"首选项"被埋在左键 popover 底部按钮里，不符合常规 macOS App 习惯。
3. **无引导/无状态反馈**：首次启动没有任何引导，用户不知道"要不要授权、会不会改我的文件、配置成没成功"。

## 2. 目标 / 非目标

**目标**：
- **零配置开箱即用**：不装 hook 也能看到所有 Claude Code 会话（含启动前已在跑的），靠只读扫描 `~/.claude/projects/**.jsonl`。
- **常规 App 体验**：菜单栏图标可发现；**右键弹标准菜单**（首选项 / 关于 / 退出）；左键保持会话面板。
- **透明可控的首启引导**：明确告知"默认只读扫描、不改任何文件"；hook 为**可选增强**，安装前明确告知"会改 `~/.claude/settings.json`、自动备份、可一键卸载"，并请求通知授权。
- **配置健康可见**：首选项展示每项配置 ✅/❌ 状态，失败可重配。

**非目标（本期不做）**：
- 图片生成 / 上传照片宠物（另起 brainstorm，已搁置）。
- Qoder / QoderWork 等其他 Agent 的 jsonl 兜底（架构留口，本期只接 Claude Code；多 Agent 走 M4 公开契约）。
- 进程探测 Plan B、sidecar。
- 精确 tab 跳转的 jsonl 路径（jsonl 拿不到 terminal ref，点击降级为"激活终端"，与 spec logscan 档定义一致）。

## 3. 关键决策溯源

| 决策 | 选择 | 理由 |
|------|------|------|
| jsonl 是否落 `events.ndjson` | **否，纯内存活投影** | jsonl 每次启动可重新派生；写入 append 日志会双计数、污染 hook 的事实源。hook 事件仍持久化。 |
| jsonl 与 hook 如何融合 | **同归一键 `(claude, ~/.claude, sessionId)` + 走同一 `apply()`** | 复用状态机/去重/字段级合并/终态保护，零新分支逻辑。 |
| 冲突时谁赢 | **hook 精确值优先**：terminal 字段非空不被 jsonl 空值降级；hook 的 `ended` 终态不被 jsonl mtime-fresh 复活 | 复用现有"字段级 last-non-nil-wins""ended 不可回退"硬约束。 |
| 状态如何从 jsonl 派生 | **mtime + 末尾窗口**：新鲜→进行中(绿)，安静近期→停下等你(红)，很旧→STALE(灰/丢) | 与 spec §3 评估窗口规则一致；避免启动重评历史误触发通知。 |
| 菜单交互 | **左键 popover 面板 + 右键 NSMenu** | 兼顾好用列表 + 常规可发现入口。 |
| 引导触发 | 无配置文件即首启；可从首选项"重跑向导" | 失败可恢复。 |

## 4. 架构总览

```
┌───────────────────────── 数据源（两路，融合进一个 Store）─────────────────────────┐
│  hook 实时（已有）        emit-event.sh ──append──▶ events.ndjson ──EventTailReader──┐ │
│  jsonl 兜底（本期新增）   ~/.claude/projects/**.jsonl ──JSONLDirectoryWatcher──┐    │ │
└──────────────────────────────────────────────────────────────────────────────┼────┼─┘
                                                                                 ▼    ▼
                                                  合成 AgentEvent ──▶ SessionStore.apply()（唯一状态机）
                                                                                 │
                                            ┌────────────────────────────────────┼─────────────────────┐
                                            ▼                                     ▼                     ▼
                                    PetState/通知                          会话面板(左键)          配置健康(首选项)
                                            │                                     │
                                  菜单栏图标(可发现) ──右键──▶ NSMenu(首选项/关于/退出)
```

**一句话**：新增 jsonl 只读扫描，派生为合成事件喂进**已有的** SessionStore，与 hook 同键融合；菜单栏补右键标准菜单；首启加透明引导 + 首选项加健康面板。

## 5. 组件设计

### 5.1 JSONLSessionScanner（纯逻辑，AgentPetCore，全单测）

**职责**：把"一批会话文件的观测"翻译成"该不该产生哪些合成事件"。**不做任何 IO**。

```
输入：[ScannedFile]  // 由 IO 壳提供
  struct ScannedFile {
    sessionId: String
    root: String           // "~/.claude" 展开后的绝对路径
    cwd: String?           // 从末尾行解析
    mtime: Double          // 文件修改时间（Unix 秒）
    lastUserText: String?  // 末尾近 N 行里最后一条非 isMeta 的 user text（合成会话判定 + 标题）
    entrypoint: String?    // sdk-cli → 合成会话
    promptSource: String?  // sdk → 合成会话
    isSubagentPath: Bool   // 路径含 /subagents/
  }

输出：[ScanIntent]
  enum ScanIntent { case observeRunning(SessionKey, cwd, title) ; case observeStopped(...) ; case ignore(reason) }
  // 由 IO 壳的 adapter 翻译为 AgentEvent 喂 SessionStore.apply()
```

**过滤（基于已验证 jsonl 数据模型事实）**：
- 排除 `isSubagentPath`（subagent transcript 共享父 sessionId，会污染）。
- 排除合成/评测：`entrypoint=="sdk-cli"` 或 `promptSource=="sdk"`；cwd 命中黑名单 `-iteration-`/`/eval-`/`/private/tmp/claude-`/`/private/var/folders`；`lastUserText` 匹配 `^Use the .* skill to handle the following request:`。
- `isMeta==true` 的 user 行不计入用户信号（解析末尾行时跳过）。

**状态派生**（参数注入 `now`，不用 `Date()`）：
- `now - mtime < runningWindow`（默认 45s）→ **running（绿）**
- `runningWindow ≤ now - mtime < idleWindow`（默认 4h）→ **stopped/waiting（红，停下等你）**
- `now - mtime ≥ idleWindow` → **ignore**（很旧，不再展示；交给 Store 的 STALE/reap）

### 5.2 JSONLDirectoryWatcher（IO 壳，AppShellKit）

**职责**：扫 `<root>/projects/`，对每个 `*.jsonl`（排除 `/subagents/`）读 mtime + **末尾近 N 行**（复用 `EventTailReader` 的末尾增量读思路，避免读 24MB 全量），构造 `ScannedFile`，交给 `JSONLSessionScanner`，把 `ScanIntent` 经 adapter 转 `AgentEvent`，回调给 `AppCoordinator`。

- **触发**：启动时扫一次（seed）；之后定时（默认 8s）+ 对 `projects/` 的 FSEvents 变更触发增量重扫。
- **合成 AgentEvent**：`eventId` 取确定性散列 `hash(source=jsonl, sessionId, derivedState)`，使**同一状态重复扫描天然去重**；状态翻转（running↔stopped）产生新 `eventId` → 一条新事件。`agent="claude"`、`root`、`cwd`、`terminal=nil`（jsonl 无终端 ref）。
- **不写 events.ndjson**：直接 `apply()`，活投影。
- **降级**：`projects/` 不存在 → 上报 `ConfigHealth.jsonlSource = .pathMissing`，不崩。

### 5.3 SessionStore 融合（复用，最小改动）

- jsonl 合成事件与 hook 事件走**同一 `apply()`**；归一键含 `root`，天然同会话合并。
- **复用现有硬约束**：`ended` 终态不被 jsonl running 复活；`terminal` 精确值不被 nil 降级；字段级 last-non-nil-wins。
- 新增（若缺）：合成事件需带 `source` 标记（`hook`/`jsonl`），仅用于 ConfigHealth 计数与"精确跳转是否可用"判断；**不参与排序**（排序唯一事实仍是 `seq`）。

### 5.4 菜单栏常规化（apet + AppShellKit）

- **MenuBarMenuModel**（纯逻辑，AppShellKit，可测）：产出菜单项列表 `[{title, action, enabled, shortcut}]`：会话概览（disabled 标题）、分隔、首选项…(⌘,)、关于 apet、分隔、退出(⌘Q)。
- **MenuBarController**（UI）：
  - `button.sendAction(on: [.leftMouseUp, .rightMouseUp])`；action 内判 `NSApp.currentEvent?.type`：左键 → 现有 popover；右键 → 用 `MenuBarMenuModel` 构建 `NSMenu`，`menu.popUp(positioning:at:in:)`（**不**长期 set `statusItem.menu`，避免吃掉左键）。
  - 图标：保持 HIG template 单色，换明确的 `pawprint.fill` / `dog` 字形；忙时仍按 tint 上色。

### 5.5 引导 + 配置健康（apet + AppShellKit）

- **ConfigHealth**（纯逻辑，AppShellKit，可测）：聚合四项状态枚举 + 整体就绪度：
  - `notification: .authorized/.denied/.notDetermined`
  - `hook: .installed(path)/.notInstalled/.failed(reason)`
  - `jsonlSource: .found(count)/.pathMissing`
  - `dataRoots: [root]`
  - `overall`：派生——只要 jsonlSource.found 即"可用（零配置）"；hook 装好则"增强可用（精确跳转+实时）"。
- **OnboardingFlow**（UI，apet）：检测无配置文件 → 弹引导窗：
  1. 欢迎 + 箭头/图示指向菜单栏图标位置（教用户"它在这”）。
  2. "默认只**只读扫描** `~/.claude/projects` 看会话状态——零配置、**不改你任何文件**。"
  3. 可选增强（默认不勾）："开启精确跳回终端 tab + 实时秒级响应？需安装 hook，**会修改 `~/.claude/settings.json`**（自动备份 `.apet.bak`、可在首选项一键卸载）。" → 勾选并确认才走现有门控 HookInstaller。
  4. 请求通知授权（UNUserNotificationCenter）。
- **首选项**：新增「配置健康」面板，渲染 ConfigHealth 四项 ✅/❌；每项可操作（装/卸 hook、重开向导、打开系统通知设置）。向导可"重跑"。

## 6. 数据流：当前会话如何立刻变绿点

1. 启动 → `JSONLDirectoryWatcher` 扫 `~/.claude/projects/-Users-renguijie-workspace/323baaab-….jsonl`，mtime=刚刚。
2. `JSONLSessionScanner`：非 subagent、非合成、`now-mtime<45s` → `observeRunning`。
3. adapter → 合成 `AgentEvent(agent=claude, root=~/.claude, sessionId=323…, cwd=…/apet, terminal=nil)` → `apply()`。
4. Store 新增 running 会话 → 面板**绿点**、菜单栏 tint 变绿。
5. 你在终端按回车后会话继续写 jsonl，mtime 持续刷新 → 保持绿；停手 4h 内 → 转红"停下等你"。

## 7. 错误处理与边界

- `projects/` 或某 jsonl 不可读 → 跳过该文件 + ConfigHealth 标注，不崩、不影响 hook 路径。
- 超大 jsonl（实测最大 24MB）→ 只读末尾 N 行 + mtime，O(1)-ish。
- jsonl running 与 hook ended 冲突 → ended 终态保护胜出（不复活）。
- 同 sessionId 跨文件（resume/拷贝）→ 同键合并，按内容/mtime 取最新，不重复计数。
- 时钟：全程 `now: Double` 注入，便于测试窗口边界。

## 8. 测试策略

- **纯逻辑 TDD**（大头）：`JSONLSessionScanner`（过滤矩阵：subagent/合成/isMeta/各 mtime 窗口边界）、`MenuBarMenuModel`、`ConfigHealth`（四项状态组合 → overall）。
- **融合测试**：构造 jsonl 合成事件 + hook 事件序列喂 SessionStore，断言 terminal 不降级、ended 不复活、不双计数。
- **IO 壳**：`JSONLDirectoryWatcher` 末尾读 + 增量用临时目录夹具测；FSEvents/定时器与 UI（NSMenu/向导）走手动验证 + 协议 mock 隔离。
- 既有 205 测试保持全绿。

## 9. 里程碑切分（实现顺序）

1. **菜单栏常规化**（小，先让首选项可达）。
2. **jsonl 兜底**（核心，零配置看到会话含当前）。
3. **引导 + 配置健康**（依赖前两者的状态）。

每步：纯逻辑 TDD → `swift test` 全绿 → 5 视角子 Agent 评审 → 修订 → 小步提交。
