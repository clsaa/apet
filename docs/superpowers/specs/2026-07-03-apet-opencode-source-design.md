# apet OpenCode 接入设计(零配置层)

日期:2026-07-03 · 状态:已评审待实现 · 里程碑:M3-C 追加(多 Agent)

## 0. 背景与决策

- 用户决策(2026-07-03):Qoder 产品线可能与其他产品合并,**Qoder IDE 追加接入搁置**;转而接入 **OpenCode**(sst/opencode,opencode.ai)。
- 范围决策:先做**零配置层**(只读 SQLite 轮询,同 QoderWork 模式);**插件增强**(opencode 插件订阅 `session.idle`/`permission.ask` → events.ndjson → 精确通知)为后续里程碑,本轮不做。

## 1. 目标

apet 面板/菜单栏计数/桌宠能看到本机 OpenCode 的会话:标题、目录、粗略状态、相对时间;右键可复制 `opencode --session <id>` 恢复命令;点击激活终端(无精确 tab 跳转)。**静默不发 OS 通知**(对齐约束 10 精神:非 hook 级信号不打扰)。

非目标(明确不做):

- OpenCode 插件增强(高保真通知 + tty 采集)——记入路线图遗留。
- 旧版 OpenCode 的 JSON 文件存储(`storage/session/**` 已被官方迁移进 SQLite)。
- OpenCode 子 agent 会话、已归档会话的展示。

## 2. 数据源事实(源码钉死,v1.17.13,2026-07-03)

依据:sst/opencode 仓库 `packages/core/src/database/*`、`packages/core/src/session/sql.ts`、`packages/schema/src/session-id.ts`、`packages/opencode/src/cli/cmd/tui.ts`。

| 事实 | 值 |
|---|---|
| DB 路径 | `$XDG_DATA_HOME/opencode/opencode.db`,默认 `~/.local/share/opencode/opencode.db`(xdg-basedir) |
| 引擎 | SQLite(drizzle,WAL);只读打开安全 |
| session 表关键列 | `id, project_id, parent_id, directory, title, time_created, time_updated, time_archived` |
| 时间方言 | **epoch 毫秒**(`Date.now()`) |
| sessionId 格式 | `ses_` + 26 位 `[0-9A-Za-z]`(首 12 位 hex 时间 + base62 随机),**非 UUID** |
| 实时状态 | **不落库**(进程内存 + 事件总线 `session.status`/`session.idle`)→ 零配置只能派生粗略态 |
| 恢复命令 | `opencode --session <id>`(TUI 官方 flag;`--continue` 恢复最近一场) |
| 过滤 | `parent_id IS NOT NULL` = 子 agent 会话,不展示;`time_archived IS NOT NULL` = 已归档,不展示 |
| DDL 参考 | `packages/core/src/database/migration/20260127222353_*.ts`(fixture 用真实 CREATE TABLE) |

风险:上游 schema 演进(该迁移目录 2026-01 起 10+ 个迁移)。缓解:读取失败/列缺失按「本轮读取失败」跳过(同 QoderWork 半读语义),不崩不空刷;真机实测门合并前验证。

## 3. 组件设计(全部沿既有缝,QoderWork 同构)

### 3.1 AppShellKit:`OpenCodeSource.swift`(新文件)

仿 `QoderWorkSource.swift` 三件套:

- **`OpenCodeSessionRow`**(纯数据):`sessionId, directory, title, updatedAt(秒), createdAt(秒)`。读取层负责毫秒→秒换算,Row 内统一 Unix 秒。
- **`OpenCodeScanner`**(纯函数):`scan(rows:root:now:runningWindow:idleWindow:) -> [ScanResult]`
  - `age = now - updatedAt`;`age < runningWindow(120)` → `.running`;`< idleWindow(1800)` → `.waitingStop`;更老 → 不进面板。
  - `SessionKey(agent: "opencode", root: <展开后的 DB 绝对路径>, sessionId: row.sessionId)`(同 QoderWork 先例:root=数据文件路径,保证多 XDG 环境不撞车);`cwd = directory`,`title = title`。
- **`OpenCodeDBReader`**(IO 缝,只读 SQLite):
  - `defaultDBPath`:尊重 `XDG_DATA_HOME` 环境变量,默认 `~/.local/share/opencode/opencode.db`。
  - 失败 ≠ 空(同 QoderWork 评审语义):文件不存在 → `[]`;打不开/prepare 失败/step 非 DONE 收尾 → `nil`(整轮跳过)。
  - `sqlite3_open_v2(READONLY)` + `busy_timeout(200ms)`。
  - SQL:`SELECT id, directory, title, time_updated, time_created FROM session WHERE parent_id IS NULL AND time_archived IS NULL`。
- **`OpenCodeWatcher`**:直接复用 `QoderWorkWatcher` 的轮询/差分/幽灵对账逻辑。**实现取向:把 `QoderWorkWatcher` 泛化改名为通用 `DBPollWatcher`(read/scan 注入)或直接以闭包复用**——不复制粘贴第二份轮询器;若泛化侵入过大,允许薄别名。

### 3.2 AgentPetCore:契约扩展(唯一动核心的点)

`AgentManifest` 增加 **`sessionIdPattern`**(id 白名单策略),`renderResumeArgv` 用它替代硬编码 UUID:

- 表达:枚举 `SessionIdRule { case uuid; case prefixedBase62(prefix: String, length: Int) }`(不用正则字符串,避免 ReDoS/转义面;M4 JSON Schema 化时再映射)。
- 默认 `.uuid` —— 既有 manifest(claude/qoderCli)行为不变,已有测试必须全绿。
- opencode:`.prefixedBase62(prefix: "ses_", length: 26)`,严格 ASCII `[0-9A-Za-z]`。
- 校验失败 → `renderResumeArgv` 返回 nil(既有语义)。占位符「独立元素」规则不变。

新增内置 manifest:

```swift
public static let openCode = AgentManifest(
    id: "opencode",
    rootsGlobs: ["~/.local/share/opencode/opencode.db"],
    tsDialect: .epochMillis,
    resumeArgvTemplate: ["opencode", "--session", "{id}"],
    hasStateRules: false,
    sessionIdRule: .prefixedBase62(prefix: "ses_", length: 26)
)
```

加入 `builtins`。(`rootsGlobs` 描述默认位置,供 UI 展示;实际读取路径由 `OpenCodeDBReader.defaultDBPath` 计算含 XDG 覆盖。)

### 3.3 apet(GUI 薄胶水)

- `AppCoordinator`:注册 `OpenCodeWatcher`(与 QoderWork 同一轮询节奏),emit 经**同一 NDJSONIngestor** 入 store。
- 面板:agent 徽标显示 OpenCode(沿 `SessionRowModel` 既有 agent 徽标机制);右键「复制恢复命令」走 manifest 渲染。
- 点击跳转:无 tty 信息 → 兜底激活策略。OpenCode 是 TUI,不知宿主终端 → 采用「激活用户默认/最前终端 App」的既有兜底(`TerminalCapability` 最低档);不臆造精确跳转。

## 4. 硬约束落位(对照 CLAUDE.md)

| 约束 | 落位 |
|---|---|
| 1 零第三方依赖 | SQLite3 系统库,已有先例 |
| 2 禁 `Date()` | `now: Double` 注入;毫秒→秒在 Reader 层换算 |
| 3 seq 唯一源/归一键 | 合成事件经同一 `NDJSONIngestor`;key=`("opencode", root, sessionId)` |
| 6 防注入 | resume 渲染先过 `sessionIdRule` 白名单;argv 单元素替换,无字符串内插 |
| 8 严禁自带 seq | 同 QoderWork,watcher 只 emit `ScanResult`,不触 seq |
| 10 jsonl/轮询源不发通知 | `OpenCodeSource` 静默;markStale 跳过(生命周期由 watcher 幽灵对账驱动) |
| 11 内容信号优先 | 本层无内容信号(状态不落库),粗略态 = 活动窗口,窗口参数注入 |

## 5. 测试策略(TDD,测试是规范)

- **fixture**:用上游迁移文件的真实 DDL 在测试临时目录造 `opencode.db`(sqlite3 直建),语料覆盖:正常会话 / 归档 / 子 agent / 毫秒时间戳 / 空 title / 目录带空格与中文。
- `OpenCodeDBReaderTests`:正常读、文件不存在 → `[]`、坏文件/半读 → `nil`、过滤(parent/archived)、毫秒→秒换算精度。
- `OpenCodeScannerTests`:窗口边界(=120/=1800)、排序无关性、key 归一。
- `AgentManifestTests` 扩展:`sessionIdRule` 各分支(uuid 回归全绿、`ses_` 合法/长度错/非法字符/全角字符——沿既有全角修复语料)、opencode manifest 渲染 argv。
- watcher 复用:若泛化 `DBPollWatcher`,QoderWork 既有测试作为回归网必须全绿。
- **真机实测门(合并前人工/半自动)**:本机安装 OpenCode 跑真实会话,验证 DB 路径、schema、时间方言、resume 命令端到端。装机方式待用户确认(用户装或授权我装)。

## 6. 路线图更新

- M3-C 追加:OpenCode 零配置接入(本 spec)。
- 遗留新增:OpenCode 插件增强(`~/.config/opencode/plugin/*.js` 订阅 `session.idle`/`permission.ask` → events.ndjson,门控安装同 HookInstaller;可顺带采集 tty 实现精确跳转)。
- Qoder IDE 追加接入:**搁置**(产品线合并未定)。
