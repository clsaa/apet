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

✅ **M1 完成并可本地运行**：核心引擎 + App 壳全部实现，**201 个单元测试全绿**，经两轮 5 视角面板评审 + 三轮硬化。桌宠已验证可显示在桌面（CGWindowList onscreen=true）。

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

数据流：Claude hook → `apet-emit-event.sh` 追加 `events.ndjson` → AppCoordinator(FSEvents) → SessionStore → 宠物/菜单栏/通知；点击 → TerminalFocusService 跳终端。

## 构建 / 运行

```bash
# 单元测试
swift test                       # 201 tests

# 打包成 .app（unsigned，本地可运行）
bash scripts/package-app.sh      # 产出 ./AgentPet.app
open AgentPet.app                # 启动：菜单栏出现图标 + 桌面右下角出现宠物

# 接入 Claude Code（让宠物收到事件）
# 在 App 首选项 →「Hook 安装」对某个数据根点「安装」(会先展示 settings.json diff + 备份说明，确认后才写入)
# 之后在该 profile 下跑 Claude Code，事件就会驱动宠物
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
| 核心引擎实现计划 | `docs/superpowers/plans/2026-06-27-apet-m1-core.md` |
| App 壳实现计划 | `docs/superpowers/plans/2026-06-28-apet-m1-app-shell.md` |
| 5 视角面板评审报告 ×2 | `docs/superpowers/specs/2026-06-28-panel*-review-*.md` |

## 路线图

- **M1**（本期，完成）：核心引擎 + 可运行 App 壳 + iTerm2 跳转 + 通知 + 内置宠物 + 多数据根 + 门控 hook 安装。
- **M2**：上传照片+一键抠图、通知免打扰/会话静音、Terminal/Warp 精确跳转、内存驱逐落地、PostToolUse busy 心跳。
- **M3**：进程探活合成 session_end、subagent 折叠、STALE 视觉强化、签名公证。
- **M4**：公开契约 JSON Schema + 校验器 + 第三方样例（Qoder）。

## License

待定。
