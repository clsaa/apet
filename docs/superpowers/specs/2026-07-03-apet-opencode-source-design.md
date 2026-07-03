# apet OpenCode 接入设计(零配置层)

日期:2026-07-03 · 状态:v2,七视角对抗评审(架构/交互/产品/AI/用户/测试/开源)修订后 · 里程碑:M3-C 追加(多 Agent)

## 0. 背景与决策

- 用户决策(2026-07-03):Qoder 产品线可能与其他产品合并,**Qoder IDE 追加接入搁置**;转而接入 **OpenCode**(sst/opencode,opencode.ai)。
- 范围决策:先做**零配置层**(只读 SQLite 轮询);**插件增强**(opencode 插件订阅事件 → events.ndjson → 精确通知 + tty 采集)为**下一个 OpenCode 里程碑(P1)**,触发条件:零配置层真机验证通过。它才是通知价值的兑现点,零配置层是引子与地基。
- 评审修订(v2,2026-07-03):七视角对抗评审共 4 Blocker + 12 Major,全部吸收,详见各节「评审」标注。

## 1. 目标与用户故事

**用户故事**:同时开着 3 个 Claude Code 和 2 个 OpenCode TUI 的工程师,打开 apet 面板即可总览全部会话:OpenCode 会话显示标题、目录、状态(内容信号优先的完成态 + 活动窗口兜底)、相对时间;跑完的会话变橙(已读黄点,不冒充「等你」);想回去时右键复制**带目录的**恢复命令 `opencode <dir> --session <id>` 粘贴即用。首分钟观感:「我的 OpenCode 会话都在这了」。

边界(必须向用户传达,不能只写在 spec 里):

- **无 OS 通知**(约束 10:非 hook 级信号不打扰)——面板 agent 徽标 tooltip 明示「OpenCode:仅面板可见,无通知(插件增强规划中)」。
- **无点击跳转**(TUI 宿主终端未知)——行内显示「无跳转」降级提示;点击弹定制弹窗:「OpenCode 在终端中运行,apet 无法定位具体窗口」+ **「复制恢复命令」按钮**(评审 B3:把死路变恢复路径;「复制恢复命令」是 OpenCode 会话的主操作出口)。

非目标(明确不做):

- OpenCode 插件增强(P1 后续里程碑,见 §7)。
- 旧版 OpenCode 的 JSON 文件存储(官方已迁 SQLite);但 ConfigHealth 需识别「有 `storage/session/**` 旧结构而无 db」→ 提示用户升级 OpenCode(评审:区分「未安装」与「版本太旧」)。
- OpenCode 子 agent 会话(`parent_id IS NOT NULL`;fork 不设 parent_id,不会误伤)与已归档会话。

## 2. 数据源事实(verified as of v1.17.13 / commit 04d236c / 2026-07-03)

依据:sst/opencode 源码。上游对该 DB **无公开 stability 承诺**(blessed 接入面是 plugin/SDK),本接入是只读逆向,风险自担、防御为先。

| 事实 | 值 | 依据 |
|---|---|---|
| DB 路径 | `$XDG_DATA_HOME/opencode/`(默认 `~/.local/share/opencode/`)下,文件名**默认** `opencode.db`;`OPENCODE_DB` 环境变量可整体覆盖;非 latest/beta/prod 渠道为 `opencode-<channel>.db` | `core/src/database/database.ts:43-55`、`core/src/global.ts:11` |
| 引擎 | SQLite,WAL;同用户只读打开安全(写方自带 busy_timeout 5000) | `database.ts:27`、`sqlite.node.ts:159` |
| session 表关键列 | `id, project_id, parent_id, directory, title, time_created, time_updated, time_archived` | `core/src/session/sql.ts` |
| **⚠️ time_updated 语义** | **只在用户提交 prompt 时 touch**;流式/工具执行/完成均不刷新(评审 B1,全设计最关键事实) | `opencode/src/session/prompt.ts:1058`、`core/src/session/projector.ts:96-110` |
| 实时活动信号 | `part` 表流式期间持续 upsert(`time_created=事件时间`);`session_message` 有 `(session_id, time_created)` 索引 | `projector.ts:312-330`、`session/sql.ts` |
| 完成信号 | 最后一条 `type='assistant'` 的 `session_message.data` JSON 内 `$.time.completed` | `schema/src/session-message.ts:77,135` |
| 时间方言 | epoch **毫秒**(time_created/time_updated/time_archived/part.time_created 全部) | `schema.sql.ts:4-9` |
| sessionId | `ses_` + **26 位**(前缀外;全长 30):前 12 位为**取反时间戳小写 hex**(降序用),后 14 位 base62。上游 schema 校验只查 `startsWith("ses")`,SDK 可自带异形 id 入库 → 我们的白名单比上游严,异形 id 仅失去恢复命令、不影响面板展示 | `schema/src/identifier.ts:14-30`、`session-id.ts:5`、`core/src/session.ts:209` |
| 恢复命令 | `opencode [project] --session <id>`:**目录是位置参数**;TUI 按 cwd 解析 project 并 chdir,跨目录裸跑会以错误项目上下文打开(评审:resume 必须带目录) | `opencode/src/cli/cmd/tui.ts:66-79,198-208` |
| title | NOT NULL,新会话为占位串 `New session - <ISO>`。**决策:原样展示**(模式匹配上游文案脆弱);空串→nil | `core/src/session.ts:228` |
| directory | legacy 会话**可为空串** → 空串→nil(约束 5) | `core/src/database/path.ts:43-44` |
| 版本探测 | `migration` 表(`id TEXT PRIMARY KEY` 时间戳前缀,天然可排序) | `core/src/database/migration.ts` |
| 演进速度 | **5 个月 38 个迁移**(2026-01~06,~8/月),含 `reset_v2_session_state` 整表清空式迁移 → 防御不可省 | `migration/` 目录 |

风险与缓解:上游 schema 演进 → ① 读失败按半读语义整轮跳过;② `SELECT MAX(id) FROM migration` 与代码内「已验证迁移 id」比较,高于已验证且读失败 → ConfigHealth 给出**用户可见**的「OpenCode 版本过新,暂不支持」(区别于「未安装」的静默空);③ 辅助表(part/session_message)缺失/被清空 → 探测降级为 session-only(活动=time_updated,语义变「距上次提问」,状态标注更粗);④ 上游升级后 spec 事实表须按新版本重核(见 §6 实测门)。

## 3. 组件设计

### 3.1 AppShellKit:`OpenCodeSource.swift`(新文件)

- **`OpenCodeSessionRow`**(纯数据):`sessionId, directory(空串→nil), title(空串→nil), lastActivity(秒), lastAssistantCompleted(秒?), createdAt(秒)`。Reader 层毫秒→秒换算,Row 内统一 Unix 秒。
- **`OpenCodeScanner`**(纯函数):`scan(rows:root:now:runningWindow:idleWindow:staleHorizon:) -> [ScanResult]`,状态派生**内容信号优先、活动窗口兜底**(约束 11):
  1. `age = now - lastActivity`;`age >= staleHorizon(86400,注入)` → 不进面板;`age >= idleWindow(1800)` → **stale**(灰显,**不移除**——评审:常开 TUI 挂机 30 分钟就蒸发违背用户直觉;QoderWork 的「消失」语义不适用于桌面上实打实开着的终端)。**年龄降档先于内容信号**,否则一周前完成的会话会以 waitingStop 永悬面板。
  2. 活跃窗口内(`age < idleWindow`):`lastAssistantCompleted != nil && lastAssistantCompleted >= lastActivity - ε`(ε=1 秒,容纳毫秒截断误差)→ **waitingStop**(本轮真实完成,不等 120 秒窗口;完成后用户再提问会 touch `time_updated` 推高 lastActivity,自然回到 running 分支)。
  3. 否则 `age < runningWindow(120)` → **running**。
  4. 否则 → **waitingStop**(窗口兜底)。
  - `SessionKey(agent: "opencode", root: <DB 所在目录>, sessionId:)`;窗口边界语义与 QoderWork 对齐(`<` 进档)。
- **`OpenCodeDBReader`**(IO 缝):
  - **路径解析**(评审:GUI 进程不继承 shell env,XDG 承诺必须可测):`static func defaultDBPath(env: [String: String]) -> String`——优先 `OPENCODE_DB`(绝对路径);其次 `XDG_DATA_HOME`(空串/相对路径视为未设);默认 `~/.local/share`。目录内 glob `opencode*.db`(排除 `-wal/-shm`)取 mtime 最新,覆盖 channel 后缀。
  - 失败 ≠ 空:文件不存在 → `[]`;打不开/prepare 失败/step 非 DONE → `nil`(整轮跳过)。**空库无 session 表 → `[]`**(评审:「装了没跑过」是常态,不是失败;先探 `sqlite_master`)。
  - `READONLY` + `busy_timeout(注入,默认 200ms,测试可 0)`。
  - 读取(代表性 SQL;先探表存在性,part/session_message 缺 → session-only 降级):

    ```sql
    SELECT s.id, s.directory, s.title, s.time_created,
      COALESCE(
        (SELECT MAX(p.time_created) FROM part p WHERE p.session_id = s.id),
        (SELECT MAX(m.time_created) FROM session_message m WHERE m.session_id = s.id),
        s.time_updated) AS last_activity,
      (SELECT json_extract(m.data, '$.time.completed') FROM session_message m
        WHERE m.session_id = s.id AND m.type = 'assistant'
        ORDER BY m.seq DESC LIMIT 1) AS last_assistant_completed
    FROM session s
    WHERE s.parent_id IS NULL AND s.time_archived IS NULL
    ```

    窗口过滤在 Swift 层做(**不能按 `time_updated` 下推**——正是 B1 的错误列);列皆有索引,数千行量级 5s 轮询可接受,实测慢再优化。`json_extract` 失败/NULL → 完成信号缺席,窗口兜底。
  - 版本探测:`SELECT MAX(id) FROM migration`,连同 rows 返回;高于代码内已验证 id 且本轮读失败 → 上报「版本过新」信号(供 ConfigHealth)。
- **轮询器 `DBPollWatcher`**(泛化自 QoderWorkWatcher):`scan: (now) -> [ScanResult]?` 闭包注入;**契约随迁移保持:timer `queue: .main`、start 幂等(stop-first)、读 nil 整轮跳过、差分 emit、幽灵对账**。`QoderWorkWatcher` 保持公开签名、内部委托。**动刀前先补回归网**(评审 B4,见 §5)。

### 3.2 契约扩展(SessionIdRule 入 AgentPetCore;AgentManifest 留 AppShellKit)

- **`SessionIdRule`**(AgentPetCore,纯枚举仅 Foundation):`case uuid; case prefixedBase62(prefix: String, length: Int)` + `validate(_:) -> Bool`。**`length` 指前缀外位数**(opencode=26,全长 30——评审:防 off-by-4,测试加全长反例)。字符集严格 ASCII `[0-9A-Za-z]`,逐字符白名单(防组合字符字素)。既有两份 `isValidUUID`(ResumeCommand/AgentManifest)收敛为对 `.uuid` 的委托。
- **M4 前瞻**(评审:防单案例锁死公开契约):JSON Schema 化时按 `{prefix, charset(封闭枚举), minLength/maxLength}` 建模;防注入红线是**字符集白名单**,精确长度是当前实现细节。本轮 Swift 枚举照旧,语义写清即可。
- **`ResumeCommand`**:改为**先按 agent 选规则再校验**;新增:

  ```
  case "opencode": ["opencode", <directory>, "--session", id]   // directory 非 nil 时作位置参数
                   ["opencode", "--session", id]                // directory 缺席时降级
  ```

  `display()` 对含空格/特殊字符的 argv 元素做**单引号 shell 引用**(`'` → `'\''`),不再裸空格 join(评审:含空格目录产出坏命令;argv 本身单元素传递无注入面,引号只为 display)。
- **`AgentManifest`**:加 `sessionIdRule`(默认 `.uuid`,既有 manifest 行为不变)+ 新增 openCode manifest:

  ```swift
  public static let openCode = AgentManifest(
      id: "opencode",
      rootsGlobs: ["~/.local/share/opencode/opencode*.db"],
      tsDialect: .epochMillis,
      resumeArgvTemplate: ["opencode", "{dir}", "--session", "{id}"],
      hasStateRules: true,   // 内容信号完成态(§3.1),非纯 mtime
      sessionIdRule: .prefixedBase62(prefix: "ses_", length: 26)
  )
  ```

  `renderResumeArgv` 支持 `{dir}` 占位(与 `{id}` 同「独立元素」规则;directory nil → 该元素整体省略)。加入 builtins。
- **双源一致性**(评审):新增遍历测试——对 builtins 全体断言 `ResumeCommand.argv(agent:id:) == manifest.renderResumeArgv(...)`,opencode 行覆盖合法 `ses_` 与 UUID 交叉拒绝。

### 3.3 apet(GUI 薄胶水)

- **注册**:`AppCoordinator` **无条件**注册 OpenCode 的 `DBPollWatcher`(评审:`fileExists` 才挂会被安装顺序击穿零配置;reader 对不存在返回 `[]`,常驻成本趋零)。**QoderWork 同题顺手回填**(同 PR 改为无条件注册)。
- **粗略态预置已读**(评审 B2,架构 m6 同构):opencode 的 `.stop` 合成后一律 `store.acknowledge(key:)`(黄点、不进「⏳等你」置顶、不污染 🟠 计数)。**判定收敛**:把 AppCoordinator 里 `key.agent == "qoder-work"` 的字符串硬编码改为集合判定(如 `coarseAttentionAgents: Set<String> = ["qoder-work", "opencode"]` 或由 manifest 查表),不再每接一源加一个 if。
- **点击**:不注入 `TerminalRef`(无 bundleId 可注入);行内显示「无跳转」提示(`SessionRowModel` 增加对 `terminal == nil` 粗略源的降级标记);点击 → 定制弹窗(文案见 §1)+「复制恢复命令」按钮。**hook 提示门控**:「安装 Hook 可精确跳转」提示限定 `agent ∈ {claude, claude-code}`(评审:对 opencode 弹 Claude 的 settings.json 提示完全错误且耗节流配额)。
- **本地摘要**:右键「本地摘要」对无 jsonl 转录的 agent(qoder-work、opencode)**隐藏**(评审:必然弹「找不到记录文件」死弹窗;qoder-work 同病顺手治)。
- **ConfigHealth**:新增两条决策——① db 读失败 + migration id 高于已验证 → 「OpenCode 版本过新」;② 无 db 但存在 `storage/session/**` 旧结构 → 「OpenCode 版本过旧,请升级」。
- 面板徽标:`row.agent` 既有机制自动显示「opencode」;tooltip 补「仅面板可见,无通知」。

## 4. 硬约束落位(对照 CLAUDE.md)

| 约束 | 落位 |
|---|---|
| 1 零第三方依赖 | SQLite3 系统库(json_extract 为 SQLite 内建 JSON1) |
| 2 禁 `Date()` | `now: Double` 注入;毫秒→秒在 Reader 层换算 |
| 3 seq 唯一源/归一键 | 合成事件经同一 `NDJSONIngestor`;key=`("opencode", root=DB所在目录, sessionId)` |
| 5 字段级合并 | `directory`/`title` 空串→nil,不污染 last-non-nil-wins |
| 6 防注入 | resume 渲染先过 `SessionIdRule` 白名单;argv 单元素传递;display 层 shell 引用 |
| 8 严禁自带 seq | watcher 只 emit `ScanResult` |
| 10 轮询源不发通知 | 静默;waitingStop 预置已读;markStale 跳过(生命周期由幽灵对账驱动) |
| 11 内容信号优先 | `time.completed` 完成态优先,活动窗口兜底;降级链条明确(§3.1) |

## 5. 测试策略(TDD;评审后语料清单)

**次序要求(评审 B4)**:先在 `QoderWorkWatcher` 名下补 4 条行为测试并全绿,再泛化 `DBPollWatcher`:① running→消失(stale)→复活 → 断言重新 emit(3 条精确序列);② 读失败轮(nil)夹在中间 → stale 恰好 1 条且发生在恢复轮;③ 双 key 交错(一转态一消失)→ emit 集合精确断言;④ start 两次 + stop → 不再 emit(timer 缝注入)。泛化后 DBPollWatcher 本体再直测幂等/幽灵/读失败三条。

**fixture**:测试临时目录 `sqlite3` 直建;DDL 以上游 `schema.gen.ts`(fresh-install 基线)为蓝本,真机实测后以 `.schema` 快照校正(文件头注明来源 sst/opencode MIT + commit);**`PRAGMA journal_mode=WAL`**,插行后不 checkpoint 保留 `-wal/-shm`(评审:真实 db 恒为 WAL,默认 journal 测不到目标形态);外键涉及 project 表则补建或 `PRAGMA foreign_keys=OFF`。

**`OpenCodeDBReaderTests`** 语料:

- 正常读(session+part+session_message 全量,`time.completed` 解析);
- WAL 未 checkpoint 行可见;WAL + 另一连接持写事务 → 读成功;
- 文件不存在 → `[]`;空库无 session 表 → `[]`;垃圾字节文件 → `nil`;**缺列**(只有 id,title 的 session 表)→ `nil`;真 BUSY(非 WAL + `BEGIN EXCLUSIVE`,busyTimeout=0)→ `nil`;
- 辅助表缺失 → session-only 降级(活动=time_updated,completed=nil);
- 过滤:`parent_id` 非 NULL 排除、空串 `parent_id` 行为钉死;`time_archived` 非 NULL 排除、`=0` 行为钉死(注释注明上游自身 truthy/isNull 不一致,我们随 list 语义);
- 毫秒→秒:整千 `1782554400000 → 1782554400.0` 精确相等;带尾数 `...123 → accuracy: 0.0005`;**方言一致性 tripwire**:`TimestampDialect.epochMillis.parse(...) == reader 读出值`(防 /1000 两次的静默失败);
- `directory=''` → `cwd == nil`(≠ `""`);`title=''` → nil;占位标题原样保留;内嵌 NUL 的 id/title 行为钉死(不崩、不与他行归并);
- `defaultDBPath(env:)`:未设/设绝对路径/空串/相对路径/`OPENCODE_DB` 覆盖/channel 后缀 glob 取最新,共 6 条。

**`OpenCodeScannerTests`**:窗口边界(`=120`/`=1800`/`=staleHorizon` 三界,`<` 语义写进断言消息)、完成信号优先于窗口(120 秒内 completed → waitingStop)、完成信号缺席回退、未来时间戳 → running 不崩(QoderWork test_futureUpdatedAt 语料带过来)、`time=0`/负值/近 int64 极大值 → 不崩不进面板、排序无关、key root 精确值断言。

**`SessionIdRuleTests`** 对抗清单(每条独立断言):前缀大小写 `SES_`/`Ses_`;长度 25/27/全长 30 当 26 传;`-`/`_` 混入 26 位;内嵌 NUL;全角前缀与全角字母凑位;组合字符字素(`é`=e+U+0301,字素数够、标量不 ASCII);注入串 `ses_$(id)...` 凑 26;空串/仅 `ses_`;正例:12 hex+14 base62 混大小写;`.uuid` 委托后既有全部 UUID 语料(含全角修复语料)全绿。

**一致性/回归**:`test_resumeCommand_manifest_consistency` 加 opencode 行 + 交叉拒绝(opencode×UUID → nil,claude×`ses_` → nil);`{dir}` 渲染:有/无 directory、含空格目录的 display 引用。

**live 门控测试(评审:真机门可重跑留痕)**:`APET_OPENCODE_LIVE=1` 才跑(否则 `XCTSkip`)——读真机 `defaultDBPath`,断言 `read() != nil`、每行 id 过 SessionIdRule、每行时间 ∈ [2020, now+1d] 秒量级(抓漏换算+方言漂移)。

## 6. 真机实测门(合并前;评审补全)

安装 latest opencode(方式待用户确认:用户装或授权我装);**若版本 ≠ v1.17.13,先重跑 §2 事实核对再继续**。清单:

1. DB 路径/文件名(含 channel);GUI 启动(`open AgentPet.app`,非终端启动)下路径解析;自定义 `XDG_DATA_HOME` 场景。
2. **长任务观察:流式期间 part/session_message 的实际刷新节奏**(B1 修复的直接验证);`time.completed` 完成态翻转及时性。
3. OpenCode 正在写库(WAL 活跃)时轮询无半读/无空转。
4. resume:会话目录内、**非会话目录 + 位置参数**两种执行;含空格目录的 display 命令粘贴可用。
5. 面板观感:挂机 TUI 黄点不置顶;stale 灰显不消失;首分钟观感;误报观感。
6. 抽查最老一条会话 id(旧 JSON 迁移来的)长度/字符集,越界则确认「无恢复命令但正常展示」。
7. `sqlite3 opencode.db ".schema session"` 快照存入 fixtures(校正 DDL 蓝本);live 测试输出贴 PR 作过门证据。

## 7. 交付物与路线图

**文档交付物**(评审:任务化,合并验收项):

- README:多 Agent 清单加 OpenCode(注明「面板可见/无通知/无跳转,插件增强规划中」);跳转能力矩阵如实标注 OpenCode=复制恢复命令;数据流图加 opencode.db 轮询;「上游版本适配」声明(只读打开、非官方接口无兼容承诺、已验证版本、升级后可能暂时看不到会话);Qoder IDE 遗留改「搁置」。
- CLAUDE.md:路线图 M3-C 追加 OpenCode;Qoder IDE 标搁置;遗留加「OpenCode 插件增强(P1)」。

**路线图**:

- 本 spec:OpenCode 零配置接入。
- **下一个 OpenCode 里程碑(P1,零配置真机验证通过后启动)**:插件增强——`~/.config/opencode/{plugin,plugins}/*.{ts,js}`(评审:glob 修正),`event` hook 订阅 `session.idle`、`permission.ask` hook 拦截权限请求(注意 v1 hook 与 v2 事件 `permission.asked` 之别)→ events.ndjson → 精确通知 + tty 采集(精确跳转);门控安装同 HookInstaller;届时面板加 just-in-time「装插件可获通知」提示。
- 维护义务(遗留):watch 上游 releases 与 `packages/core/src/database/` 变更;版本漂移时重跑 §2 核对 + live 测试。
- Qoder IDE 追加接入:**搁置**(产品线合并未定)。
