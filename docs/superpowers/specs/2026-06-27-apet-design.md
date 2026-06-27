# AgentPet — 设计文档

> 工作代号 **AgentPet**（名字可改）。一个常驻 macOS 原生 App，用桌面悬浮宠物 / 菜单栏图标监控多个 AI 编码 Agent 的会话状态，完成或需要关注时弹原生通知，点击跳回对应终端窗口/tab。
>
> 日期：2026-06-27 ｜ 状态：设计待复审（v2，已纳入三路红队对抗评审的契约/安全修订）
>
> **修订记录**：v2 对 §3 插件契约做了字段级加固（事件唯一键/版本协商/字段抽取语法），新增 §3.1 安全与信任基线（默认拒绝），并修补了 §4 去重排序、§6 状态机、§7 终端、§9 鲁棒性；§11 分期把桌宠提前到 M1。

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

## §3 公开插件契约 v2（扩展性核心）

未来第三方 Agent 厂商可自助接入，无需改本 App 源码。契约公开、版本化、语言无关，并以 **JSON Schema 规范文档**交付（非示例片段）。下文为字段定义，权威以仓库内 `contracts/event.schema.json` 与 `contracts/manifest.schema.json` 为准。

### (a) 事件协议（每行一个 JSON 事件）

```json
{"v":1, "eventId":"01J8...ULID", "seq":42,
 "agent":"claude-code",              // 必填，必须 == manifest.id
 "event":"session_start|busy|stop|attention|session_end|plugin_error",
 "sessionId":"…",                    // 必填，仅 agent 内唯一、全生命周期稳定
 "root":"~/.claude",                 // 必填，归一与隔离键的一部分
 "cwd":"/path/proj",                 // 可空，字段级合并(非空才覆盖)
 "title":"proj — claude",            // 可空，UI 视为不可信数据
 "terminal":{"kind":"iterm2","ref":{"itermSessionId":"w0t1p0"},"bundleId":"com.googlecode.iterm2"},
 "notify":"alert|passive|none",      // 可选，覆盖默认通知分类
 "reason":"stop|attention",          // WAITING 类事件的子语义
 "message":"log dir not found",      // 仅 plugin_error 用
 "ts":"2026-06-27T10:00:00.123Z"}    // RFC3339 UTC 毫秒，仅展示，不参与排序/去重
```

**必填**：`v, eventId, agent, event, sessionId, root, ts`。`seq` 强烈建议；缺失时由 App 按文件 append 偏移赋单调序。
**唯一键 / 去重**：`eventId`（ULID/UUID）。**排序 / 状态推进**：`seq`（或 App 赋的 ingest offset），**绝不用 `ts`**。
**归一键**：`(agent, root, sessionId)`——见 §4、§6 统一口径。
**terminal**：`kind` 枚举 `iterm2|terminal|warp|other`，未知一律按 `bundleId` 降级"仅激活"；`ref` 按 kind 给类型化负载（iterm2→`itermSessionId`；terminal→`{tty|pid}`），**格式由各 Locator 正则校验**（防注入，见 §3.1）。

### (b) 插件 Manifest `plugins/<id>/manifest.json`

```json
{"v":1, "id":"qoder", "name":"Qoder",
 "version":"1.3.0", "author":"…", "homepage":"…",
 "publisher":"…", "signature":"…",              // §3.1 信任校验
 "compat":{"manifestSchema":1,"eventSchema":1,"minAppVersion":"1.0.0"},
 "icon":{"panel":"icon@2x.png","menubarTemplate":"icon-template.pdf","size":[44,44]},
 "roots":["~/.qoder","~/.qoder-profiles/*"],    // 必须锚定 ~/.<id>* 白名单，禁绝对/**逃逸
 "discovery":{"state":"logscan|hook|sidecar", "terminal":"none|hook|from-event"},

 "logscan":{                                     // state=logscan 时
   "format":"jsonl-append|json-array|jsonl-last-line",
   "fields":{"sessionId":"$.session_id","cwd":"$.cwd","title":"$.summary","ts":"$.timestamp"},
   "stateRules":[                                // 有序，首个命中为准，对"最新行"求值
     {"when":"$.type=='user'","event":"busy"},
     {"when":"$.type=='result'","event":"stop"},
     {"when":"$.subtype=='end'","event":"session_end"}],
   "pollMs":1000, "staleAfterSec":300},

 "hookInstall":{                                 // state/terminal=hook 时
   "dialect":"claude-code",                      // 声明目标配置方言，不假设
   "events":["SessionStart","Stop","Notification"],
   "runner":"builtin:emit-event",               // 只能引用 App 自带可信脚本(参数化)，禁任意 shell
   "marker":"agentpet"},                          // 标记包裹，便于干净卸载

 "sidecar":{"exec":"./bridge","arch":["arm64"],"restartPolicy":"on-crash",
   "protocol":"ndjson-stdout","enabledByDefault":false}}  // 默认禁用，需用户显式授权
```

### 三档接入能力（`discovery.state` 与 `discovery.terminal` 可组合）
1. `logscan`：纯声明、无代码 → 状态 + 绿红点 + 通知（默认跳转 `terminal:none` 仅激活）。
2. `hook`：装 App 自带的参数化 runner → 实时 + 精确 + 带终端 ref（**Claude Code 走这档**）。
3. `sidecar`：挂程序吐事件 → 完全自定义（默认禁用，需授权）。
> 组合示例：`{"state":"logscan","terminal":"hook"}` = 状态扫日志、但挂个轻 hook 拿终端 ref 做精确跳转（回应"logscan 也想精确跳"的诉求）。

### 输出落盘
每插件写自己的 `plugins/<id>/out/events.ndjson`（UTF-8 / LF / 单次 `write()` 整行 / 限长）；或 sidecar 走 stdout 由 App 落盘。**App 独占合并 + 排序 + 监听**，第三方不碰共享文件。文件权限 0600 + owner 校验。

### dogfood 铁律
**Claude Code 支持就是内置插件 `plugins/claude-code/`**，用 `hook` 档实现——逼契约第一天就被真实使用。**但内置能跑 ≠ 对外可用**：M4 交付前必须用一个真实第三方样例（Qoder `logscan`）端到端跑通，才算契约达标。

---

## §3.1 安全与信任基线（默认拒绝）

红队三路一致判定：契约把 sidecar / hookInstall / AppleScript 三条本地代码执行通道 + 无认证事件文件 + 无约束盘扫一起敞开，**当前形态直接对第三方开放不安全**。以下为发布前必须达成的默认拒绝基线：

| 面 | 威胁 | 默认策略 |
|---|---|---|
| **插件来源** | 任何能写 `plugins/` 的本地进程即可投放 manifest 获 RCE | **显式安装**（用户主动导入 + 确认指纹），禁"目录里有就自动加载"；`signature`/`publisher` 经内置可信公钥校验；pin 已信任 hash，变更即重新确认；目录仅用户可写 + owner/权限校验 |
| **sidecar.exec** | 任意二进制以用户身份 RCE | **默认禁用**，逐插件弹窗授权（展示绝对路径 + 哈希 + 来源）；`exec` 限 manifest 同目录相对路径，禁 `..`/绝对/shell 元字符；最小权限子进程，不继承用户 env/keychain，默认禁网或域名白名单；展示进程清单可随时 kill |
| **hookInstall** | snippet 注入 settings.json = 每次事件 RCE | snippet **不接受任意 shell**，只能声明事件类型 + 引用 App 自带参数化 runner；结构校验拒绝 `; \| $() 反引号 curl\|sh`；安装前全文 diff + 用户确认；marker 包裹便于卸载 |
| **events.ndjson** | 本地进程伪造事件钓鱼/DoS | 文件 0600 + owner 校验；可选 per-plugin 签名 token，丢弃无法归属到已信任插件的事件；按 agent 限频 |
| **AppleScript 跳转** | title/terminal.ref 拼进脚本 → 注入 | `ref` 按 kind 严格正则校验；osascript **参数化(argv `on run argv`)**，绝不字符串内插；title 仅展示并转义；写注入用例断言不可逃逸 |
| **roots 盘扫** | glob 路径穿越 / 符号链接逃逸 / 读隐私 | root 必须锚定声明且用户确认的 `~/.<id>*` 基目录；展开后 realpath 校验拒绝逃出基目录；`O_NOFOLLOW`；禁 `**` 跨基目录与绝对路径；只抽 `fields` 声明的最小字段，不落原文 |
| **隐私落盘** | cwd/title 明文长期留存 | 最小字段；归档有保留上限 + 定期删除；提供"清空历史"入口；评估 cwd 展示哈希/截断；首选项告知存了什么/存哪/存多久 |
| **卸载** | 备份还原文件，撤不掉已执行危害 + sidecar 残留 | **安装账本**记录插件触达的所有副作用（写的文件 / 装的 hook / 起的进程），卸载按账本逆向清理并报残留；强调"安装前阻止"才是真正控制，备份不是安全机制 |
| **失败处理** | "坏插件标红不阻断"把安全失败降级成可用性问题 | 区分"格式错误"(可跳过) 与"完整性/签名失败"(**必须拒绝加载**，阻断该插件全部高危能力 exec/hookInstall) |

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

**幂等 / 去重 / 排序（v2 修订，回应红队 B1/B2/M1）**：
- **去重**：按 `eventId`。**归一**：按 `(agent, root, sessionId)`（含 `root`，避免多 profile 撞车）。
- **排序与状态推进**：一律按 `seq`，**不用墙钟 `ts`**。ingestor 对**所有来源所有行**赋**单一全局单调 seq**（= 合并后 append 顺序），故"等值 seq"不会发生 → 规则简化为 `incoming.seq <= session.lastSeq → 忽略`（**取消** v2 里的来源 tiebreak，面板报告 2026-06-28 确认）。**终态 `ENDED` 不可被非终态事件回退。** 注意：**面板展示排序**另用状态优先级 + `lastActiveAt`（见 §6 B4），seq 仅用于状态推进/去重。
- **宽容解码（B5）**：`reason`/`notify` 等枚举字段遇未知值降级为 `nil`（与 `event`/`terminal.kind` 一致），**不得**因未知枚举值丢弃整条合法事件。
- **字段级合并**（last-non-null-wins）：`cwd/title/terminal` 等空值不覆盖已有值；`terminal` 一旦拿到精确 ref，后续空值或"猜测"值**不得降级覆盖**。
- **回放**：App 启动从持久化的 `(eventsFileId, lastConsumedOffset)` checkpoint 续读；回放产生的事件打 `replay` 标志，**NotifyCenter 静默不补发历史通知**。
- **短路**：状态无变化的 `busy` 自环只刷新 `lastActiveAt`（喂 STALE 计时），不广播订阅，避免高频刷新。

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

**单会话状态机 — 全量 (态 × 事件) 转移表**（在 SessionStore，归一键 `(agent, root, sessionId)`）。`WAITING` 带 `reason`，区分"干完待命"与"等你授权"（回应红队 M2）：

| 当前态 \ 事件 | session_start | busy | stop | attention | session_end | 超时无事件 |
|---|---|---|---|---|---|---|
| (无) | → RUNNING | → RUNNING | → WAITING(stop) | → WAITING(attention) | **(忽略，不建会话)** | — |
| RUNNING | (刷新) | RUNNING(刷 lastActiveAt) | → WAITING(stop) | → WAITING(attention) | → ENDED | **→ STALE** |
| WAITING | → RUNNING | → RUNNING | → WAITING(更新 reason) | → WAITING(attention) | → ENDED | **(保持 WAITING，不降级)** |
| ENDED | (终态，忽略) | (忽略) | (忽略) | (忽略) | (忽略) | (忽略) |
| STALE | → RUNNING | → RUNNING | → WAITING | → WAITING | → ENDED | (保持) |

> **§6 面板修订（2026-06-28，见 `2026-06-28-panel-review-core-engine.md`）**：

- **终态**：`ENDED` 不可复活；`STALE` **可复活**（收到任何事件回到对应态）。
- **STALE 只作用于 RUNNING**（B2）：`WAITING` 是"轮到用户"，本就无活动事件，**不因超时降级**——否则"等你授权"的红点会变灰被静默。`session_end` 作为**首事件**不建会话（B3）。
- **STALE 阈值**：可配，默认建议提到 20–30 分钟（B/AI：长任务 hook 心跳稀疏，10 分钟过短）；Plan B 内置 hook 在 PostToolUse 发 busy 心跳缓解误判。
- **未知事件 / 未知 `v`**：不改状态，仅刷新 `lastActiveAt` 续命，不当坏行丢弃。
- 面板：绿点 = `RUNNING`，红点 = `WAITING`（`attention`=橙/紧急、`stop`=红/完成待命，颜色区分紧急度），灰 = `ENDED`，橙 `?` = `STALE`(疑似停滞，区别于 ENDED)。

**宠物聚合 — 富聚合 `summary()`（B1，取代单一枚举）**：
```
PetSummary {
  state: busy | calling | idle    // busy=有 running；calling=无 running 但有 waiting；idle=否
  hasWaiting / attentionCount / staleCount / runningCount
}
```
- **关键修正**：即便 `state==busy`（有会话在跑），只要 `hasWaiting`，PetPresenter 也必须在宠物/菜单栏图标**叠加"喊你"角标/计数**——绝不能让"忙碌"吞掉"有 N 个等你"。`attentionCount>0` 用更强提示（橙色感叹号）。
- 菜单栏模式同一套：图标着色 + 角标数字。

**面板会话排序（B4）**：按状态优先级 `waiting(attention) > waiting(stop) > running > stale`，同级再按 `lastActiveAt` 倒序（**不用 lastSeq**——跨插件 seq 命名空间独立，比较无意义）。让"最需要你的"自动置顶。

---

## §7 终端跳转能力分级（诚实预期）

| 终端 | 档位 | 机制 | 跳转精度 |
|---|---|---|---|
| iTerm2 | 🟢 精确 | hook 抓 `ITERM_SESSION_ID` → AppleScript 选中 window+tab | 到 tab |
| Terminal.app | 🟡 可做 | 按 tty/PID 匹配 → AppleScript 选 tab | 多数到 tab |
| Warp | 🔴 降级 | 自动化弱 → 仅激活 Warp App | 到应用，**行内标「仅激活」** |
| 未知/无终端字段 | 🔴 降级 | 按窗口标题猜 / 仅激活 | 尽力而为 |

`TerminalLocator` 每实现声明自己的 `capability`（`precise` / `activate-only`），UI 据此给用户正确预期，不假装精确。未知 `kind` 用事件里的 `terminal.bundleId` 激活对应 App（activate-only）。

**安全（回应红队 M4）**：跳转脚本一律 **osascript 参数化（argv）**，`terminal.ref` 先按 kind 正则校验（iTerm2 形如 `w\d+t\d+p\d+`，否则拒绝），`title` 仅展示并转义——**严禁把事件字段字符串拼进 AppleScript**。§10 须含注入用例（恶意 title/ref → 断言不可逃逸）。

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

- **events.ndjson 坏行**：跳过该行、记日志，不崩。但**完整性/签名校验失败 ≠ 格式坏行** → 必须拒绝加载该插件并阻断其高危能力（回应红队 M-minor）
- **归档（单写者协议，回应红队 M5/B8）**：归档只由 App 自身做，做前暂停 ingest；checkpoint 存 `(eventsFileId, offset)`，归档时 fileId 翻新、offset 归零；归档后 ingestor 重挂监听、从新文件 offset 0 续读；写入侧统一 `O_APPEND`；归档有保留上限并定期删除（隐私）
- **App 未开时的事件**：hook 照常追加文件，**App 启动从 checkpoint `(eventsFileId, lastConsumedOffset)` 续读回放**（追加文件而非 socket 的价值）；回放事件打 `replay` 标志、不补发通知
- **hook 没装/被删**：自动降级到 jsonl 扫描，面板顶部提示「精确跳转不可用，去首选项安装 hook」
- **跳转失败**（终端关了/tab 没了）：通知用户「目标窗口已不存在」，不静默失败
- **抠图/插件加载失败**：隔离到单个 Agent/宠物，不影响整体；坏插件标红但不阻断 App
- **权限**：首次用到 AppleScript / 通知时引导授权（自动化权限、通知权限）

---

## §10 测试策略

- **SessionStore**（核心，覆盖最全）：纯函数 `apply(event)`，事件序列→状态断言（全量状态机各转移、聚合三态、WAITING reason、ENDED 不可复活/STALE 可复活）；**乱序/同 seq/时钟回拨/eventId 重复 → 去重排序正确**；字段级合并(terminal 不被空值降级)；回放 replay 不发通知
- **EventIngestor**：喂 ndjson 流（含坏行/交错半行/乱序）→断言产出；归档轮换后 checkpoint 续读正确
- **TerminalLocator**：mock 注入，断言生成的脚本正确（不真弹终端）；精度能力声明；**注入用例：恶意 `title`/`terminal.ref` → 断言参数化、不可逃逸**
- **PluginHost / 安全**：假 manifest（合法/非法/三档 discovery 组合）→派生正确采集器；**签名/完整性失败 → 拒绝加载并阻断 exec/hookInstall**；snippet 含 shell 元字符 → 拒绝；roots glob 含 `..`/`**`/绝对路径/符号链接 → 拒绝逃逸；伪造（无归属）事件 → 丢弃
- **NotifyCenter**：通知模式 × 事件类型矩阵 → 是否触发
- **UI**：SwiftUI 快照/预览（面板、宠物三态、菜单栏）
- 原则：优先**纯逻辑层 TDD**；AppleScript/通知/抠图等系统副作用用协议 + mock 隔离

---

## §11 分期

> **调整（用户诉求）**：桌宠是做这个东西的初衷，提前到 M1 一起出现，不等到第二期。

| 里程碑 | 内容 |
|---|---|
| **M1 地基 + 桌宠** | 事件协议(含 eventId/seq/root) + SessionStore(全量状态机) + EventIngestor + Claude Code 内置插件(hook) + iTerm2 精确跳转(参数化 AppleScript) + **悬浮宠物窗 + SpriteRenderer(内置柴犬/比熊三态动画)** + 菜单栏图标 + 显示模式切换 + 会话面板 + 通知(默认模式) |
| **M2 宠物扩展 + 多源** | PhotoRenderer(上传照片降级 + 一键抠图) + 多根首选项 + jsonl 兜底扫描 + 通知模式可配(每轮结束) + hooks 一键装卸(含安装账本) |
| **M3 终端 + 加固** | Terminal.app/Warp 定位器(能力分级 + bundleId 激活) + §3.1 安全基线(签名校验/sidecar 默认禁用/snippet 白名单/glob 锚定/events 0600+限频) + 归档与隐私(保留上限/清空历史) |
| **M4 生态** | 公开契约 JSON Schema + 校验器 + 第三方插件文档 + **真实第三方样例(Qoder logscan)端到端跑通**(契约达标门槛) + sidecar 信任执行模型 + 打包/签名/公证 |

---

## 参考（同类开源，思路借鉴）

- iTerm2 点击跳 tab：stevemeisner/claude-iterm-notify、wonjun3991/iterm-notification
- 多会话状态：gmr/claude-status、farouqaldori/vibe-notch、JasperSui/claude-code-iterm2-tab-status
- 桌宠形态：rullerzhou-afk/clawd-on-desk
- 跨平台通知：777genius/claude-notifications-go
