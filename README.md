# apet 🐕

> 一只悬浮在桌面（或藏进菜单栏）的小宠物，帮你盯着所有 AI 编码 Agent 的会话。会话需要你关注或干完活时弹 macOS 通知，点一下就跳回对应的终端窗口/tab。

macOS 原生 App（Swift / SwiftUI / AppKit，背景常驻 `LSUIElement`，无 Dock 图标）。代号 **AgentPet**。

![桌宠](docs/demo-pet.png)

## 它做什么

- 🐕 **桌宠 / 菜单栏两种形态**：内置柴犬/比熊 + **上传照片一键抠图**做成自己的宠物；每只都可命名（01=你自己、02/03=家人…）。
- 📊 **状态栏彩色计数**：菜单栏直接显示 `🟢2 🟠1 ⚪3`（进行中/等你/超时），不用点开就一目了然；可切回 🐾 图标模式。
- 🔔 **完成即通知**：会话「需要你输入」或「本轮完成」时弹原生通知（横幅/声音独立开关 + 免打扰时段），带项目名、节流防轰炸。
- 🎯 **点通知/点列表跳回终端**：iTerm2 精确到 window+tab；Terminal.app 窗口级（tty）；Warp/Ghostty 激活应用；VSCode/Cursor 激活+提示手动切标签；OpenCode 无跳转（TUI 宿主终端未知），点击弹窗内一键复制恢复命令。精确跳转未命中自动兜底激活 App。
- 🗂 **会话管理**：**Tab 分流**（全部/收藏/进行中/已读 + 自定义分组，「⏳等你」跨 tab 常驻置顶）、**可多属自定义分组**（右键加入/建组/删组）、面板搜索（名字/目录/ID/agent）、**悬停收藏**、**终端真 app 图标**（一眼分 iTerm2/Warp…）、**可缩放面板窗口**、重命名、相对时间、复制 sessionID/恢复命令、右键 **AI 摘要**(调本机 claude 出真总结)。
- 🎨 **自定义**：5 种状态圆点颜色取色器、首选项四分页（外观/通知/会话/通用）、**改动即时生效**、开机自启。
- 🤖 **多 Agent**：Claude Code（hook 实时 + jsonl 兜底）、**Qoder CLI**（`~/.qoder`，实测接入）、**QoderWork**（SQLite agents.db，实测接入）、**OpenCode**（opencode.db 只读轮询，内容信号优先状态；面板可见/复制恢复命令，无通知无跳转——插件增强规划中；**已真机实测**,v1.17.13）；面板 agent 徽标区分来源。
- 🔌 **公开插件契约**：`AgentManifest`（roots/时间方言/resume argv 模板/状态规则），第三方可自助接入（JSON Schema 在 M4 交付）。

## 状态

✅ **M1 / M1.5 / M2 / M3 完成**：**752 个单元测试全绿**，多轮多视角（架构/产品/AI/用户/测试/开源）对抗评审 + 修复。零配置开箱即用：不装 hook 也能靠只读扫描 `~/.claude/projects/**.jsonl` 看到所有会话（含当前在跑的）；hook 为可选增强（精确跳转 + 通知），安装前预览确认、自动备份、一键卸载。

## 架构

```
AgentPetCore (纯逻辑库, 零第三方依赖, 全单测)
  Model: AgentEvent / SessionKey / SessionState / PetKind
  Store: SessionStore(状态机/聚合/STALE/reap) / PetState / SessionMeta(收藏/命名)
  Ingest: NDJSONIngestor / JSONLSessionScanner    Summarize: LocalSummarizer
  Notify: NotificationDecider / NotifyChannelDecider
  Terminal: ITerm2Locator / TerminalAppLocator(防注入) / TerminalCapability / ResumeCommand
AppShellKit (可测胶水逻辑, 可用 Apple 系统框架)
  EventTailReader / JSONLDirectoryWatcher / QoderWorkSource(SQLite只读) / AgentManifest
  HookInstaller / NotificationThrottle&Gate / SessionListOrganizer(搜索/分组/置顶)
  TerminalFocusPlanner / MenuBar&Pet Presenter / SessionMetaStore / ProcessRunner(缝)
apet (可执行, @MainActor GUI 薄胶水)
  AppCoordinator(多源汇聚→摄取→reap→通知) / PetWindowController / MenuBarController
  SessionPanel / NotificationService / TerminalFocusService / PreferencesWindow(四分页)
Resources/apet-emit-event.sh  ← Claude hook 调用，把事件写进 events.ndjson
```

数据流（多路融合，同一 SessionStore、唯一 seq 源）：
- **hook 实时**：Claude hook → `apet-emit-event.sh` → `events.ndjson` → kqueue → SessionStore（精确终端跳转 + OS 通知）。
- **jsonl 兜底**（零配置）：扫 `~/.claude/projects/**.jsonl` + `~/.qoder/projects/**.jsonl`（Qoder CLI），内容信号派生状态，静默不发通知。
- **QoderWork**：只读轮询 `agents.db`（SQLite），粗略状态（活动时间窗口），点击激活 QoderWork.app。
- **OpenCode**：只读轮询 `opencode.db`（SQLite），part/消息表活动信号 + assistant in-flight/完成信号派生状态，静默不通知。

## 构建 / 运行

```bash
swift test                       # 752 tests 全绿
bash scripts/package-app.sh      # 产出 ./AgentPet.app（unsigned，本地可运行）
open AgentPet.app                # 菜单栏彩色计数 + 桌面宠物 + 首启精简引导
```

需要 Xcode（XCTest + SwiftUI）。Swift 6.x 工具链；包固定 `swift-tools-version:5.9`。零第三方包依赖（SQLite3/Vision 为 Apple 系统框架）。

## 上线人工门（需用户处理）

1. **代码签名 / 公证**：需 Apple Developer 账号。当前 unsigned，首次打开需右键→打开（或 `xattr -dr com.apple.quarantine`）。
2. **开机自启在签名构建上的稳定性**：`SMAppService` 对未签名开发构建可能注册失败（UI 已有失败提示与回滚）。

## 文档

| 文档 | 路径 |
|---|---|
| 设计 v2（含红队对抗评审加固） | `docs/superpowers/specs/2026-06-27-apet-design.md` |
| M1.5 / M2 / M3 设计 | `docs/superpowers/specs/` |
| 各里程碑实现计划 | `docs/superpowers/plans/` |
| 实现/评审报告 | `.superpowers/sdd/` |

## 路线图

- **M1 / M1.5 / M2** ✅：核心引擎 + App 壳 + jsonl 兜底 + 照片宠物抠图 + 多 profile + 免打扰。
- **M3** ✅：多终端能力分级 + 开机自启 + 会话管理（搜索/置顶/收藏/重命名/复制）+ 外观自定义（彩色计数/取色/分页/即时生效）+ 多 Agent（Qoder CLI/QoderWork/OpenCode/**Codex** 实测接入）+ AI 摘要（本地免费档已上线；模型档核心已备、UI 待接）+ 六视角对抗评审修复。
- **M3-D 面板 UX** ✅：Tab 分流取代分区（含计数、等你跨 tab 常驻）+ 可多属自定义分组 + 终端真 app 图标 + 悬停收藏 + 视觉打磨（路径折叠/色盲状态形状/元数据统一/整行 hover）+ 可缩放面板窗口 + 现存 bug 修复（跳转失败不误标已读等）+ **8 视角对抗评审修复**。
- **M3-C+** ✅：**OpenCode 实测接入**（零配置层，2026-07-03 spec，七视角评审×3 轮 + 真机实测门七项过门）。
- **遗留**：Qoder IDE 追加接入（**搁置**：产品线合并未定）、OpenCode 插件增强（P1：精确通知+tty 跳转）、模型摘要 UI、F10 createdAt 注入、签名公证。
- **M4**：公开契约 JSON Schema + 校验器 + 第三方接入样例。

## 上游版本适配（OpenCode）

apet 以**只读**方式（`SQLITE_OPEN_READONLY`，绝不写入）读取 OpenCode 的本地数据库
（`~/.local/share/opencode/opencode*.db`）。该数据库是 OpenCode 的内部实现，上游无兼容性承诺：

- 已验证版本：**v1.17.13**（migration ≤ `20260622202450_simplify_session_input`；源码级核对 + **真机端到端实测**,2026-07-03）。
- OpenCode 升级导致 schema 变化时，apet 可能暂时看不到其会话——「首选项 → 会话 → 配置健康」会提示
  「schema 新于已验证版本」；请升级 apet 或提 [issue](https://github.com/clsaa/apet/issues)。
- 旧版 OpenCode（JSON 文件存储，未迁 SQLite）不支持，请升级 OpenCode。
- 状态边界：仅面板可见（无通知/无跳转，插件增强规划中）；30 分钟无活动灰显（会话仍在），24 小时移出面板。

## License

MIT（见 [LICENSE](LICENSE)）。
