# AgentPet — 设计文档

> 工作代号 **AgentPet**（名字可改）。一个常驻 macOS 原生 App，用桌面悬浮宠物 / 菜单栏图标监控多个 AI 编码 Agent 的会话状态，完成或需要关注时弹原生通知，点击跳回对应终端窗口/tab。
>
> 日期：2026-06-27 ｜ 状态：设计待复审

---

## §1 目标 / 非目标

**做什么**：常驻 macOS 原生 App（Swift/SwiftUI，`LSUIElement` 背景型，无 Dock 图标）。监控本机多个 AI 编码 Agent 的会话，用一只**桌面悬浮宠物**或**菜单栏图标**表达聚合状态；会话「需要你关注 / 完成」时弹原生通知；点通知或点会话列表项，**跳回对应终端窗口/tab**。

**MVP 必达**：
- 单只聚合宠物（忙碌 / 喊你 / 待机三态）+ 隐藏模式（仅菜单栏图标）
- 点宠物 / 图标 → 弹会话列表面板（每行：项目名·cwd / 绿点进行中·红点停下等你 / 点击跳转）
- 原生通知，默认「需要关注」才响、可选「每轮结束都响」
- 内置柴犬（公）/ 比熊（母）满血精灵动画 + 上传照片降级模式
- 多「数据根目录」配置（`~/.claude`、`~/.claude-profiles/*` …）
- iTerm2 精确跳转跑通
- **公开的插件契约**，Claude Code 自身作为「第一个内置插件」实现

**非目标（MVP 不做）**：AI 生成精灵帧；Warp / 其他终端的精确 tab 跳转（先降级为激活窗口）；iCloud 同步；宠物商店；Windows / Linux。

**关键决策溯源**：原生 macOS（Q1·A）；仅 Claude Code 但架构可插拔（Q2·A+扩展）；点宠物弹面板（Q3·A）；通知默认「需关注」、可配「每轮结束」（Q4·C）；三终端都要+诚实分级（Q5）；宠物混合 B1（内置精灵+上传降级）；单只聚合三态+隐藏模式（Q7·A+隐藏）；hook+jsonl 融合、App 自动托管 hook（Q8·C）；多数据根配置；插件机制公开契约（C）。

---

## §2 整体架构

```
        ┌──────────────────────── AgentPet.app (LSUIElement) ────────────────────────┐
        │                                                                            │
 各 Agent│   ┌─────────────┐   events.ndjson   ┌──────────────┐                       │
 ───────┼─▶│ PluginHost   │──(FSEvents 监听)─▶│ EventIngestor │──┐                    │
 (插件)  │   │ ·加载manifest│                   └──────────────┘  │                    │
        │   │ ·跑sidecar   │   扫 jsonl(兜底)                     ▼                    │
        │   │ ·装/卸hook   │◀───────────────────────────┐  ┌──────────────┐           │
        │   └─────────────┘                            └──│ SessionStore │(单一事实源) │
        │                                                  └──────┬───────┘           │
        │            订阅 SessionStore ─────────────┬──────────────┼───────────────┐  │
        │                                          ▼              ▼               ▼  │
        │                                  ┌────────────┐ ┌──────────────┐ ┌────────────┐
        │                                  │ PetPresenter│ │ NotifyCenter │ │ SessionPanel│
        │                                  │(悬浮窗/菜单栏│ │(UNUserNotif) │ │ + Prefs UI │
        │                                  │ +PetRenderer)│ └──────┬───────┘ └─────┬──────┘
        │                                  └────────────┘        点通知/点列表项 ──┤      │
        │                                                              ▼          ▼      │
        │                                                       ┌─────────────────────┐  │
        │                                                       │  TerminalLocator    │  │
        │                                                       │ iTerm2/Terminal/Warp│  │
        │                                                       └─────────────────────┘  │
        └────────────────────────────────────────────────────────────────────────────┘
```

一句话：**所有 Agent 的信号（hook 实时 + jsonl 兜底）统一汇成 `events.ndjson` → `SessionStore` 单一事实源 → 宠物 / 通知 / 面板都订阅它；用户动作经 `TerminalLocator` 落到终端。**

设计原则：
- **追加文件 + FSEvents**（而非 socket）：进程解耦、App 未开时事件不丢、重启可回放。
- **原生 `UNUserNotificationCenter`**（而非 terminal-notifier）：点击回调进 App 内、由 App 决定聚焦哪个 tab。
- **三个可插拔接口**承载扩展性：`AgentAdapter`（插件）/ `TerminalLocator` / `PetRenderer`。

---

## §3 公开插件契约（扩展性核心）

未来第三方 Agent 厂商可自助接入，无需改本 App 源码。契约两部分，均公开、版本化、语言无关。

### (a) 事件协议 `events.ndjson`
任何 Agent（厂商插件 / 我们的 Claude hook）往此文件追加一行 JSON：
```json
{"v":1,"agent":"claude-code","event":"session_start|busy|stop|attention|session_end",
 "sessionId":"…","root":"~/.claude","cwd":"/path/proj","title":"proj — claude",
 "terminal":{"kind":"iterm2","sessionId":"w0t1p0"},"ts":"2026-06-27T…Z"}
```
App 只认这个 schema，不关心谁写的。`terminal` 字段可空（拿不到则降级跳转）。

### (b) 插件 Manifest `plugins/<agent>/manifest.json`
```json
{"v":1,"id":"qoder","name":"Qoder","icon":"icon.png",
 "roots":["~/.qoder","~/.qoder-profiles/*"],
 "discovery":{"mode":"hook|logscan|sidecar"},
 "logscan":{"glob":"**/sessions/*.jsonl","stateRules":{ "字段→状态映射" : "…" }},
 "hookInstall":{"target":"settings.json","snippet":{ "写啥 hook" : "…" }},
 "sidecar":{"exec":"./bridge","protocol":"ndjson-stdout"},
 "terminal":{"strategy":"from-event|guess-by-title"}}
```

### 三档接入能力（厂商按自身条件选）
1. `logscan`：纯声明、无代码 → 状态 + 绿红点 + 通知（跳转靠标题猜）
2. `hook`：装个 hook 片段 → 实时 + 精确 + 带终端 ID（**Claude Code 走这档**）
3. `sidecar`：挂个小程序吐事件 → 完全自定义

### dogfood 铁律
我们的 **Claude Code 支持就是内置插件 `plugins/claude-code/`**，用 `hook` 档实现 —— 逼这份契约第一天就被真实使用、够格给第三方。

---

## §4 数据流（端到端）

**采集（写入侧）**
```
Claude Code 触发 hook ──▶ 内置 hook 脚本(swift/sh) ──追加─▶ events.ndjson
其他 Agent(插件) ────────▶ logscan 轮询 / sidecar ───追加─▶ events.ndjson
                                                          │
EventIngestor(FSEvents 监听) ──增量解析每行──▶ SessionStore.apply(event)
jsonl 兜底扫描(定时/启动时) ──补全缺失会话──▶ SessionStore.upsert(session)
```

**渲染与交互（读取侧）**
```
SessionStore 变更 ──发布──▶ PetPresenter(算聚合态→选动画)  ┐
                          ▶ NotifyCenter(按通知模式决定弹不弹) ├ 都订阅同一事实源
                          ▶ SessionPanel(刷新列表+绿红点)    ┘

用户点通知 / 点列表项 ──▶ resolve(session) ──▶ TerminalLocator.focus(terminal)
                                                  ├ iterm2: AppleScript 选中 window+tab(精确)
                                                  ├ terminal: 按 tty 匹配 tab
                                                  └ warp/未知: 激活 App(降级,行内标"仅激活")
```

**幂等 / 去重**：每行事件带 `(agent, sessionId, ts)`；`SessionStore` 按 `agent+sessionId` 归一；**hook 事件优先级 > jsonl 推断**（hook 有就以 hook 为准，避免两路打架）。

---

## §5 组件分解（单元职责单一、可独立测试）

| 组件 | 职责 | 依赖 | 可独立测什么 |
|---|---|---|---|
| **PluginHost** | 扫 `plugins/`、校验 manifest、按 `discovery.mode` 拉起 logscan/sidecar、装/卸 hook | 文件系统 | 喂假 manifest→是否正确派生采集器 |
| **EventIngestor** | FSEvents 监听 `events.ndjson`、增量逐行解析、丢坏行不崩 | events.ndjson | 喂 ndjson 流→产出标准事件 |
| **SessionStore** | 单一事实源：会话集合 + 状态机 + 聚合态；发布变更 | 无（纯内存+持久快照） | 纯函数式 apply(event)→断言状态 |
| **AgentRegistry** | 内置 + 第三方插件的统一注册表（名/图标/能力档） | PluginHost | 注册/注销/能力查询 |
| **TerminalLocator**(协议) | `focus(TerminalRef)`；三实现 iTerm2/Terminal/Warp | AppleScript/AX | 各实现 mock 注入、断言生成的脚本 |
| **PetRenderer**(协议) | 画宠物；`SpriteRenderer`(内置帧) / `PhotoRenderer`(上传降级) | 资源/AppKit | 给状态→选对帧/动作 |
| **PetPresenter** | 订阅 store→算聚合三态→驱动 renderer；管悬浮窗 vs 菜单栏两模式 | SessionStore,PetRenderer | 状态→动画意图映射 |
| **NotifyCenter** | 按通知模式过滤事件→发原生通知→路由点击回调 | UNUserNotificationCenter | 模式×事件→是否发 |
| **SessionPanel / PrefsUI** | 会话列表面板 + 首选项窗口 | SessionStore,AgentRegistry | SwiftUI 预览/快照 |

---

## §6 状态模型

**单会话状态机**（在 SessionStore）：
```
(无) ─session_start→ RUNNING ─busy→ RUNNING
        RUNNING ─stop/attention→ WAITING(等你)     // 你说的"完成/停下"
        WAITING ─(用户在该会话又发指令/busy)→ RUNNING
        任意 ─session_end / jsonl 判定结束→ ENDED(从活跃列表移除/灰显)
        超时无事件 → STALE(灰显, 兜底防泄漏)
```
- 面板：绿点 = `RUNNING`，红点 = `WAITING`，灰 = `ENDED/STALE`

**宠物聚合三态**（PetPresenter 从所有会话推导）：
```
有任一 RUNNING            → 忙碌动画(打字/忙)
无 RUNNING 但有 WAITING   → 喊你动画(叫/红色感叹号气泡)   ← 最高优先级提示
全 ENDED/无活跃           → 待机动画(睡觉/发呆)
```
菜单栏模式下同一套语义：图标着色 / 角标表达三态。

---

## §7 终端跳转能力分级（诚实预期）

| 终端 | 档位 | 机制 | 跳转精度 |
|---|---|---|---|
| iTerm2 | 🟢 精确 | hook 抓 `ITERM_SESSION_ID` → AppleScript 选中 window+tab | 到 tab |
| Terminal.app | 🟡 可做 | 按 tty/PID 匹配 → AppleScript 选 tab | 多数到 tab |
| Warp | 🔴 降级 | 自动化弱 → 仅激活 Warp App | 到应用，**行内标「仅激活」** |
| 未知/无终端字段 | 🔴 降级 | 按窗口标题猜 / 仅激活 | 尽力而为 |

`TerminalLocator` 每实现声明自己的 `capability`（`precise` / `activate-only`），UI 据此给用户正确预期，不假装精确。

---

## §8 首选项（Preferences）

- **数据根目录**：增删多个根（`~/.claude`、`~/.claude-profiles/*` 等），每根绑定一个 Agent 插件、独立扫描与 hook 安装
- **显示模式**：悬浮宠物 / 仅菜单栏；悬浮位置记忆、贴边
- **通知模式**：默认「需要关注才响」/ 可开「每轮结束都响」（Q4·C）；免打扰时段（可选）
- **宠物**：选内置柴犬/比熊；上传照片（可选一键抠图 `VNGenerateForegroundInstanceMaskRequest`）；「想要满血动画→按模板传精灵帧」提示
- **Hooks 管理**：一键安装/卸载、改 settings.json 前自动备份、显示当前安装状态
- 持久化目录：`~/Library/Application Support/AgentPet/`（settings.json + 宠物资源 + events.ndjson + 状态快照）

---

## §9 错误处理与鲁棒性

- **events.ndjson 坏行**：跳过该行、记日志，不崩；文件过大时滚动归档
- **App 未开时的事件**：hook 照常追加文件，**App 启动回放**未消费部分（追加文件而非 socket 的价值）
- **hook 没装/被删**：自动降级到 jsonl 扫描，面板顶部提示「精确跳转不可用，去首选项安装 hook」
- **跳转失败**（终端关了/tab 没了）：通知用户「目标窗口已不存在」，不静默失败
- **抠图/插件加载失败**：隔离到单个 Agent/宠物，不影响整体；坏插件标红但不阻断 App
- **权限**：首次用到 AppleScript / 通知时引导授权（自动化权限、通知权限）

---

## §10 测试策略

- **SessionStore**（核心，覆盖最全）：纯函数 `apply(event)`，事件序列→状态断言（状态机各转移、聚合三态、hook/jsonl 优先级、幂等去重）
- **EventIngestor**：喂 ndjson 流（含坏行/乱序）→断言产出
- **TerminalLocator**：mock 注入，断言**生成的 AppleScript 文本**正确（不真弹终端）；精度能力声明
- **PluginHost**：假 manifest（合法/非法/三种 mode）→派生正确采集器；坏插件隔离
- **NotifyCenter**：通知模式 × 事件类型矩阵 → 是否触发
- **UI**：SwiftUI 快照/预览（面板、宠物三态、菜单栏）
- 原则：优先**纯逻辑层 TDD**；AppleScript/通知/抠图等系统副作用用协议 + mock 隔离

---

## §11 分期

| 里程碑 | 内容 |
|---|---|
| **M1 地基** | 事件协议 + SessionStore + EventIngestor + Claude Code 内置插件(hook) + iTerm2 精确跳转 + 菜单栏图标 + 会话面板 + 通知(默认模式) |
| **M2 宠物** | 悬浮窗 + SpriteRenderer(内置两宠物) + PhotoRenderer(上传降级) + 显示模式切换 + 聚合三态动画 |
| **M3 完善** | 多根首选项 + Terminal.app/Warp 定位器(分级) + 通知模式可配 + hooks 一键装卸 + 抠图 |
| **M4 生态** | 第三方插件文档 + 校验器 + 示例(Qoder logscan/sidecar 样板) + 打包/签名/公证 |

---

## 参考（同类开源，思路借鉴）

- iTerm2 点击跳 tab：stevemeisner/claude-iterm-notify、wonjun3991/iterm-notification
- 多会话状态：gmr/claude-status、farouqaldori/vibe-notch、JasperSui/claude-code-iterm2-tab-status
- 桌宠形态：rullerzhou-afk/clawd-on-desk
- 跨平台通知：777genius/claude-notifications-go
