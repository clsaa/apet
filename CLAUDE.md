# CLAUDE.md

本文件指导在本仓库工作的 Claude Code / AI 协作者。提交前请遵循这里的约定。

## 项目是什么

**apet**（代号 AgentPet）——一个常驻 macOS 原生 App（Swift / SwiftUI，`LSUIElement` 背景型）。用一只桌面悬浮宠物或菜单栏图标，监控多个 AI 编码 Agent（Claude Code 等）的会话状态：会话「需要你关注」或「完成」时弹原生通知，点击跳回对应终端窗口/tab；点宠物弹面板看所有会话（绿点=进行中 / 红点=停下等你）。宠物可扩展（内置柴犬/比熊，支持上传照片）。Agent 接入走**公开插件契约**，第三方厂商可自助接入。

## 仓库结构

```
apet/
├── README.md                    项目门面
├── CLAUDE.md                    本文件
├── Package.swift                SwiftPM（三 target）
├── Sources/AgentPetCore/        纯逻辑核心库（无 GUI、无系统副作用，完全单测覆盖）
│   ├── Model/                   AgentEvent / SessionKey / SessionState / SessionSource
│   ├── Store/                   SessionStore（单一事实源，状态机）/ PetState
│   ├── Ingest/                  NDJSONIngestor / JSONLSessionScanner（jsonl 内容信号→状态，纯函数）
│   ├── Notify/                  NotificationDecider
│   └── Terminal/                TerminalLocator（iTerm2…）
├── Sources/AppShellKit/         可测胶水层（含系统副作用但抽了协议缝）
│   ├── EventTailReader / TailLineReader        （增量读 / 反向读尾+读首行）
│   ├── JSONLParse / JSONLDirectoryWatcher      （真实 jsonl 解析 / 扫目录+滞回+差分，queue:.main）
│   ├── HookInstaller / HookHintThrottle        （门控装 hook + previewLines / just-in-time 提示节流）
│   ├── ConfigHealth / OnboardingGate           （配置健康决策表 / 首启谓词）
│   └── MenuBarMenuModel / SessionRowModel / …  （UI 纯数据模型）
├── Sources/apet/                可执行 GUI（@MainActor）：AppCoordinator / MenuBarController /
│                                PetWindowController / OnboardingWindow / PreferencesWindow / …
├── Tests/AgentPetCoreTests/ + Tests/AppShellKitTests/   XCTest（含 fixtures/jsonl 真实语料）
└── docs/superpowers/
    ├── specs/2026-06-27-apet-design.md                       原始权威设计（v2，红队加固）
    ├── specs/2026-06-28-apet-onboarding-jsonl-menubar-design.md  M1.5 设计（jsonl兜底+常规体验，§13 含二轮面板评审）
    └── plans/…                                               各里程碑 TDD 实现计划
```

> **两路数据源融合**：`hook 实时`（emit-event.sh→events.ndjson→EventTailReader）+ `jsonl 兜底`（~/.claude/projects/**.jsonl→JSONLDirectoryWatcher）都经**同一个 NDJSONIngestor**（唯一 seq 源）喂进**同一个 SessionStore**。jsonl 用 `SessionSource.jsonl` 进程内标记与 hook 隔离。

## 构建 / 测试

```bash
swift build          # 编译
swift test           # 跑全部单测（提交前必须全绿）
swift test --filter SessionStoreOrderingTests   # 跑单个测试类
```

无第三方依赖，`swift test` 直接可用。Swift 6.x 工具链；包固定 `swift-tools-version:5.9`（Swift 5 语言模式）。

## 硬约束（改代码前必读）

源自设计文档 §3/§4/§6/§7 与红队对抗评审，**违反即是 bug**：

1. **零第三方包依赖** —— SwiftPM 依赖恒为零。分层细则：**AgentPetCore 只用 Foundation**；AppShellKit/apet 可用 Apple 系统框架（AppKit/SwiftUI/Vision/SQLite3/ServiceManagement 等），新增系统框架须在 commit message 说明理由。
2. **不用 `Date()` / `Date.now`** —— 需要「当前时间」一律通过参数 `now: Double`（Unix 秒）注入，便于测试 STALE。
3. **排序唯一事实是 `seq`**（由 `NDJSONIngestor` 按 append 顺序赋的单调序），**绝不用墙钟 `ts` 排序**。去重唯一键是 `eventId`。归一键是 `(agent, root, sessionId)`（必须含 `root`，否则多 profile 会撞车）。
4. **终态 `ended` 不可回退**；`stale` 可复活。`busy` 落在 `running` 上只刷新计时、**不广播**。
5. **字段级合并**（last-non-nil-wins）：`cwd/title/terminal` 空值不覆盖已有值；`terminal` 一旦拿到精确值不被空值降级。
6. **AppleScript 一律参数化** —— 终端跳转脚本**严禁字符串内插**事件字段；id 先经正则白名单校验，再作为 `osascript` 的 argv 传入。这是防注入红线。
7. **测试是规范** —— 测试失败时改实现、不改测试迁就实现。断言精确，覆盖正常/边界/异常。

### M1.5 jsonl 兜底专属约束（见 `2026-06-28-…design.md` §13）

8. **唯一 seq 源是 NDJSONIngestor 实例** —— jsonl 合成事件必须经**同一个** ingestor `ingest(event:)` 取号，**严禁自带 seq 计数器**（否则跨源 `seq<=lastSeq` 比较错乱）。
9. **`SessionSource` 是进程内标记**（`AgentEvent`/`Session` 默认 `.hook`，**不进 wire `decode`**）。来源判定/面板柔和渲染/markStale 跳过一律用 `session.source == .jsonl`，**不用 `terminal == nil` 当来源代理**。hook 一旦标记不被 jsonl 降级。
10. **jsonl 永不发 OS 通知** —— jsonl 路径只驱动面板/桌宠视觉，**不调用 NotificationService**；可靠的完成/需关注通知是 hook 专属（just-in-time）。`markStale` 定时器跳过 `source==.jsonl`（其生命周期由 watcher 驱动）。
11. **jsonl 状态派生「内容信号优先、mtime 兜底」** —— 读末条 assistant `message.stop_reason`、`away_summary`（时间感知）、`queue-operation`、`entrypoint`（从**对话行**非首行取）；mtime 仅兜底，且用 `effectiveTs=min(mtime,lastConversationTs)` 校正带外写入漂移。窗口 `runningWindow=120/idleWindow=1800` 作入参注入。
12. **hook 安装永远门控** —— 绝不自动写用户 `~/.claude/settings.json`；安装前展示 `previewLines` 条目预览，用户确认才写（自动备份 `.apet.bak`、可一键卸载）。

## 设计权威性

`docs/superpowers/specs/2026-06-27-apet-design.md` 是唯一权威设计。改行为先改 spec，再改实现与测试，保持一致。事件协议 / 插件 Manifest 字段是第三方对接的契约，改动需谨慎（见 spec §3 / §3.1 安全基线）。

## 协作约定

- **分支**：不在 `main` 上直接开发，用 `feature/` 前缀分支。push 用 SSH（本机 git 全局把 github https 改写到被拦截的代理，**https 推不动、SSH 可以**：`git@github.com:clsaa/apet.git`）。
- **提交身份**：本仓库已配 `clsaa <812022339@qq.com>`，直接 `git commit` 即可，勿覆盖。
- **提交粒度**：小步提交，一个可独立测试的交付物一个 commit；中文 commit message。
- **执行计划**：按 `docs/superpowers/plans/` 下对应里程碑计划逐任务 TDD 推进（写失败测试→跑→实现→跑过→提交）。
- **子 Agent 编排（避免慢任务）**：实测教训——某次「逐项修复 9 个问题」耗时 24 分钟，拆解发现 **22.3 分钟全卡在一个空档**，根因不是编译（fresh worktree 冷编译实测仅 build 10s / test 11s），而是：① 派出去的修复 Agent **自己又转手嵌套派了一个后台 Agent**，外层纯空等其完成；② 同段时间**并行跑了太多 Agent**抢 API 吞吐，生成被排队拖慢（有效仅 ~37 token/s）。**约定**：(a) 「逐项修复 / 单层明确」的活让 Agent **直接动手，禁止再嵌套转包**（一层够用别套娃）；(b) 带 `swift build/test` 的重活**适当串行**，别一窝蜂并发抢吞吐；(c) 任务异常慢时先按「总耗时 vs 单点最大空档」拆时间戳定位，**别先猜编译慢**——本仓冷编译也只要 ~20s。

## 路线图

- **M1 地基+桌宠** ✅ 事件协议 + SessionStore 状态机 + hook 内置插件 + 悬浮宠物窗 + 菜单栏 + iTerm2 精确跳转。
- **M1.5 开箱即用+常规体验** ✅ jsonl 兜底（零配置看到会话含当前在跑的）+ 右键菜单 + 首启引导 + 配置健康 + just-in-time 授权。
- **M2 宠物扩展+多源** ✅ 上传照片宠物（本地 Vision 抠图，零网络）+ 多 profile 并行发现（带授权）+ 通知模式可配 + 免打扰。
- **M3**（大体完成）：
  - **M3-A0 体验热修** ✅（B1/B2/B3/A1）
  - **M3-A1 多终端+常驻** ✅（Terminal.app 窗口级/Warp/Ghostty/VSCode 能力分级 + hook 采集 tty；SMAppService 开机自启；精确跳转未命中兜底激活 App）
  - **M3-B 会话管理** ✅（搜索/等你置顶/收藏+重命名 F7/相对时间 F10/复制 ID+恢复命令 F11；SessionMeta 持久化）
  - **M3-A2 外观/体验** ✅（首选项即时生效、状态圆点自定义色 F3、通知横幅/声音分开 F1、首选项四分页 F4、内置宠物名 F5、面板页脚瘦身）。F9 主动不改 ⌥⌘S（footgun）。
  - **M3-C 多 Agent** ✅（AgentManifest 契约 + **QoderWork 实测接入**：SQLite agents.db 只读轮询/粗略态/点击激活 App + **Qoder CLI 实测接入**：~/.qoder jsonl 与 Claude 同构/resume=`qodercli --resume`）。
  - **M3-D AI 总结** ✅（**模型摘要已接**：右键「AI 摘要」→ ExecutableLocator 定位本机 claude(-lic 补 nvm PATH)→ SummarizerService 后台跑 `claude -p` 读会话日志出一句中文总结,行内展开显示。启发式 LocalSummarizer 保留但不再进 UI）。F5 宠物命名持久化 ✅（pet-names.json，01=用户本人语义）。
  - **M3-D 面板 UX** ✅（2026-07-04，见 `docs/superpowers/specs/2026-07-03-apet-panel-ux-tabs-summary-groups-design.md`）：Tab 分流取代分区（全部/收藏/进行中/已读 + 自定义分组，带计数，「等你」跨 tab 常驻）+ 可多属自定义分组（右键加入/建组/删组，删组二次确认）+ 终端真 app 图标（hook 读 `__CFBundleIdentifier`，Cursor/Warp-Preview 正确）+ 悬停收藏 + 视觉打磨（路径折叠/色盲状态形状/元数据统一/整行 hover/字号三级）+ 可缩放面板窗口（菜单栏侧，桌宠仍 popover）。现存 bug 修复：跳转失败不误标已读（FocusResult.missedButActivated 区分兜底激活）、Claude 失败弹窗给复制恢复命令、复制 HUD 反馈、搜索匹配 agent。经 **8 视角对抗评审 + 修复**（架构/交互/UI/产品/AI/用户/测试/开源）。后续热修：轻量内联弹层取代 5 处 NSAlert（建组=tab栏+就地输入chip/重命名=行内编辑/删组=二段式确认/无效名=内联红字）、AI摘要反馈回路（AGENTPET_INTERNAL 标记内部子进程,hook 早退）、hook 不发 title（防覆盖 jsonl 真标题致面板全目录名）、replay 用事件 ts（EventTsParser,防旧会话每次重启复活永不老化）、**会话存活三态**（TtyLiveness.classify:hook 采集 claude 进程 pid($PPID)——`alive`(pid活+tty在)保护不老化 / `dead`(pid已死=claude确定退出)**30分钟快清**(程序化批量测试会话/退出的claude不再占位8h,幂等清理) / `unknown`(无pid旧事件)正常窗口。单靠tty被macOS编号复用真机实锤误判**）。遗留：桌宠侧不可缩放。767 测试全绿。
  - **六视角对抗评审** ✅（架构/产品/AI/用户/测试/开源 2026-07-03，Blocker/Major 已修复：applyMetas 绕过、ProcessRunner cwd/PATH/argv0、SQLite busy 半读、时区日界、幽灵01、围栏逃逸等，见 `.superpowers/sdd/`）。
  - **M3-C++ Codex 接入**（2026-07-05，见 `docs/superpowers/specs/2026-07-05-apet-codex-source-design.md`）：`~/.codex/sessions/**/rollout-*.jsonl`（首行 session_meta）+ `session_index.jsonl` thread_name 白送标题；task_started/complete 轮次信号经 `CodexRolloutParse` 映射 end_turn，**全复用** JSONLDirectoryWatcher/Scanner；合成新鲜会话真机门验证 upsert。**resume 已核实提供**（codex-cli 0.142.5 实跑：`codex resume <UUID>`）；rollout schema 非 Claude 同构→摘要菜单隐藏（`claudeStyleTranscriptAgents` 门控）；三视角评审修复（turn_aborted/长轮次截断兜底/noJumpAgents 诚实降级/DisplaySanitizer 标题消毒）；**Desktop/CLI 分流**（首条 meta source 分 codex-desktop/codex，desktop 点击激活 Codex.app，身份取首条防混用漂移，真机门验证）；**CLI 精确跳转**（apet-codex-notify.sh 链式包装 config.toml notify——原程序保留转发+采集 tty/pid/iTerm id 发 stop 事件+真通知；CodexNotifyInstaller 门控安装：预览确认/备份/卸载/多行 TOML 诚实拒绝；首选项入口；45 测试）。
  - **M3-C+ OpenCode 接入**（2026-07-03）：opencode.db 只读轮询/内容信号优先（in-flight/completed）/无条件注册/诚实无跳转降级+复制恢复命令/OpenCodeHealth 用户可见，见 `docs/superpowers/specs/2026-07-03-apet-opencode-source-design.md`（七视角评审×3 轮 + 真机实测门七项过门,含 v1 message 表漂移发现与修复,见 `.superpowers/sdd/task-opencode-live-gate-report.md`）。
  - 真实遗留：Qoder IDE 追加接入（**搁置**：产品线合并未定）、OpenCode 插件增强（P1：`~/.config/opencode/{plugin,plugins}/*.{ts,js}` 订阅 session.idle → 精确通知+tty 跳转）、模型摘要 UI、F10 createdAt 注入、**OpenCode 上游维护义务**（watch sst/opencode releases 与 `packages/core/src/database/` 变更；版本漂移按 `OpenCodeDBReader.verifiedMaxMigrationId` doc 注释的四步流程更新——上游 ~8 迁移/月，无流程必然烂掉）。
- **M4 生态**（公开契约 + 第三方样例）。详见 README 与 spec。
