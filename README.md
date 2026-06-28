# apet 🐕

> 一只悬浮在桌面（或藏进菜单栏）的小宠物，帮你盯着所有 AI 编码 Agent 的会话。会话需要你关注或干完活时弹 macOS 通知，点一下就跳回对应的终端窗口/tab。

macOS 原生 App（Swift / SwiftUI / AppKit，背景常驻 `LSUIElement`，无 Dock 图标）。代号 **AgentPet**。

![桌宠](docs/demo-pet.png)

## 它做什么

- 🐕 **桌宠 / 菜单栏两种形态**：内置柴犬（公）/ 比熊（母）；一只宠物表达聚合状态——忙碌 / 喊你 / 待机，叠加"N 个等你"角标与气泡。
- 🔔 **完成即通知**：会话「需要你输入」或「本轮完成」时弹原生通知（默认只在需要关注时响，可配每轮都响），带项目名、节流防轰炸。
- 🎯 **点通知/点列表跳回终端**：iTerm2 精确跳到对应 window+tab；其它终端降级为激活应用。
- 🟢🔴 **多会话一览**：点宠物 / 菜单栏弹面板，每会话绿点（进行中）/ 红点（停下等你，attention 橙·stop 红）/ 灰点（结束/停滞），多 profile 用标签区分。
- ⚙️ **多 Agent 数据根**：首选项里配置多个 profile 路径（如 `~/.claude`、`~/.claude-profiles/*`）。
- 🔌 **公开插件契约**：Claude Code 是第一个内置插件，跑在公开事件契约上；未来 Qoder 等可自助接入。

## 状态

✅ **M1 + M1.5 完成并可本地运行**：**309 个单元测试全绿**，多轮 5 视角面板评审 + 硬化。桌宠已验证在桌面（CGWindowList onscreen=true）。

✨ **M1.5 开箱即用**：**不装 hook**，靠只读扫描 `~/.claude/projects/**.jsonl` 就能看到所有 Claude Code 会话——**包括当前正在跑的会话**（E2E 实测：当前会话显示绿点）。叠加常规 macOS 体验：菜单栏**右键标准菜单** + 左键面板（底部齿轮）、精简首启引导 + 隐私承诺、配置健康面板、hook/通知授权 **just-in-time**（用到时才问）。

剩余为**上线人工门**（见下）。

## 架构

```
AgentPetCore (纯逻辑库, 零依赖, 全单测)
  Model: AgentEvent / SessionKey / SessionState
  Store: SessionStore(状态机/聚合 summary/STALE/reap) / PetState
  Ingest: NDJSONIngestor      Notify: NotificationDecider     Terminal: ITerm2Locator(防注入)
AppShellKit (可测胶水逻辑)
  EventTailReader(增量读+checkpoint) / HookInstaller / NotificationThrottle&Gate
  TerminalFocusPlanner / MenuBarPresenter / SessionRowMapper / PetPresenter / AppConfig
apet (可执行, @MainActor GUI)
  AppCoordinator(FSEvents 监听→摄取→reap→通知) / PetWindowController+PetView
  MenuBarController / SessionPanel / NotificationService / TerminalFocusService / PreferencesWindow
Resources/apet-emit-event.sh  ← Claude hook 调用，把事件写进 events.ndjson
```

数据流（两路融合，同一 SessionStore）：
- **hook 实时**：Claude hook → `apet-emit-event.sh` 追加 `events.ndjson` → AppCoordinator(FSEvents) → SessionStore（精确终端跳转 + OS 通知）。
- **jsonl 兜底**（M1.5，零配置）：`JSONLDirectoryWatcher` 扫 `~/.claude/projects/**.jsonl` →（内容信号 stop_reason/away_summary 派生状态、`SessionSource.jsonl` 标记、replay=false 不发通知）→ 同一 NDJSONIngestor（唯一 seq 源）→ SessionStore → 面板/桌宠。
- 点击 → TerminalFocusService 跳终端（jsonl 会话无终端引用时降级"激活"并提示）。

## 构建 / 运行

```bash
# 单元测试
swift test                       # 309 tests

# 打包成 .app（unsigned，本地可运行）
bash scripts/package-app.sh      # 产出 ./AgentPet.app
open AgentPet.app                # 启动：菜单栏图标 + 桌面右下角宠物 + 首次启动弹精简引导

# 零配置即用：无需任何设置，App 自动只读扫描 ~/.claude/projects 显示所有会话（含当前在跑的）。
#   菜单栏图标【右键】= 标准菜单（首选项/关于/退出）；【左键】= 会话面板（底部齿轮进首选项）。

# 可选增强（精确跳回终端 tab + OS 通知）——用到时 App 会提示，或主动去：
#   首选项 →「Hook 安装」对某个数据根点「安装」(先展示将写入 settings.json 的条目预览 + 自动备份，确认后才写)
#   之后该 profile 下跑 Claude Code，hook 事件驱动精确跳转与通知
```

需要 Xcode（XCTest + SwiftUI）。Swift 6.x 工具链；包固定 `swift-tools-version:5.9`。

## 上线人工门（需用户处理）

1. **代码签名 / 公证**：需 Apple Developer 账号（$99/yr）。当前是 unsigned `.app`，首次打开需右键→打开绕过 Gatekeeper。
2. **宠物美术终稿**：内置图为 AI 生成占位（近白底非透明，悬浮带淡白框）——需去背/精修，或上传自己的去背 PNG。
3. **`attention` hook 触发验证**（面板头号风险）：Claude Code 的工具授权走终端 readline、不一定走 hook——接真实 hook 后需验证「需要授权」时 attention 事件能否触发；若不能，走 logscan/进程探测补（M2/M3）。
4. **真机多终端 E2E**：iTerm2 精确跳转、Terminal/Warp 降级、多 profile 区分的实跑验证。

## 文档

| 文档 | 路径 |
|---|---|
| 设计 v2（含红队对抗评审加固） | `docs/superpowers/specs/2026-06-27-apet-design.md` |
| M1.5 设计（jsonl兜底+常规体验，§13 二轮面板评审） | `docs/superpowers/specs/2026-06-28-apet-onboarding-jsonl-menubar-design.md` |
| 各里程碑实现计划 | `docs/superpowers/plans/` |
| 5 视角面板评审报告 | `docs/superpowers/specs/2026-06-28-panel*-review-*.md` |

## 路线图

- **M1**（完成）：核心引擎 + 可运行 App 壳 + iTerm2 跳转 + 通知 + 内置宠物 + 多数据根 + 门控 hook 安装。
- **M1.5**（本期，完成）：jsonl 兜底（零配置看到会话含当前在跑的）+ 右键菜单 + 首启引导 + 配置健康 + just-in-time 授权。
- **M2**：上传照片+一键抠图、通知免打扰/会话静音、Terminal/Warp 精确跳转、内存驱逐落地、PostToolUse busy 心跳。
- **M3**：进程探活合成 session_end、subagent 折叠、STALE 视觉强化、签名公证。
- **M4**：公开契约 JSON Schema + 校验器 + 第三方样例（Qoder）。

## License

待定。
