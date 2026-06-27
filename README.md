# apet

> 一只悬浮在桌面（或藏进菜单栏）的小宠物，帮你盯着所有 AI 编码 Agent 的会话。会话需要你关注或干完活时弹 macOS 通知，点一下就跳回对应的终端窗口/tab。

macOS 原生 App（Swift / SwiftUI，背景常驻、无 Dock 图标）。代号 **AgentPet**。

## 它做什么

- 🐕 **桌宠 / 菜单栏两种形态**：内置柴犬（公）/ 比熊（母），可上传自己的宠物照片。一只宠物表达聚合状态——忙碌 / 喊你 / 待机。
- 🔔 **完成即通知**：会话「需要你输入」或「本轮完成」时弹原生通知（默认只在需要关注时响，可配每轮都响）。
- 🎯 **点通知/点列表跳回终端**：iTerm2 精确跳到对应 window+tab；Terminal.app 次之；Warp 降级为激活应用。
- 🟢🔴 **多会话一览**：点宠物弹面板，每个会话绿点（进行中）/ 红点（停下等你）。
- 🧩 **可插拔插件机制**：Claude Code 是第一个内置插件，跑在公开契约上；未来 Qoder / QoderWork 等可由各厂商自助接入（声明式 logscan / hook / sidecar 三档）。
- ⚙️ **多 Agent 数据根**：支持配置多个 profile 路径（如 `~/.claude`、`~/.claude-profiles/*`）。

## 状态

🚧 设计 + M1 实现计划已就绪，编码未开始。

| 文档 | 路径 |
|---|---|
| 设计（v2，含红队对抗评审加固） | [`docs/superpowers/specs/2026-06-27-apet-design.md`](docs/superpowers/specs/2026-06-27-apet-design.md) |
| M1 核心引擎实现计划（Plan A，10 个 TDD 任务） | [`docs/superpowers/plans/2026-06-27-apet-m1-core.md`](docs/superpowers/plans/2026-06-27-apet-m1-core.md) |

## 路线图

- **M1 地基 + 桌宠**：事件协议 + SessionStore 状态机 + Claude Code hook 插件 + iTerm2 精确跳转 + 悬浮宠物（柴犬/比熊三态）+ 菜单栏 + 会话面板 + 通知。
- **M2 宠物扩展 + 多源**：上传照片（一键抠图）+ 多根首选项 + jsonl 兜底 + 通知模式可配 + hook 一键装卸。
- **M3 终端 + 加固**：Terminal.app / Warp 定位器 + 安全基线（签名校验 / sidecar 默认禁用 / glob 锚定 / 防注入）+ 隐私归档。
- **M4 生态**：公开契约 JSON Schema + 校验器 + 第三方样例（Qoder）+ 打包签名公证。

## 技术栈

Swift 5.9+ · SwiftPM · XCTest · 零外部依赖。核心逻辑（`AgentPetCore`）纯函数 + 注入时钟，完全单测覆盖。

## License

待定。
