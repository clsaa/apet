# CLAUDE.md

本文件指导在本仓库工作的 Claude Code / AI 协作者。提交前请遵循这里的约定。

## 项目是什么

**apet**（代号 AgentPet）——一个常驻 macOS 原生 App（Swift / SwiftUI，`LSUIElement` 背景型）。用一只桌面悬浮宠物或菜单栏图标，监控多个 AI 编码 Agent（Claude Code 等）的会话状态：会话「需要你关注」或「完成」时弹原生通知，点击跳回对应终端窗口/tab；点宠物弹面板看所有会话（绿点=进行中 / 红点=停下等你）。宠物可扩展（内置柴犬/比熊，支持上传照片）。Agent 接入走**公开插件契约**，第三方厂商可自助接入。

## 仓库结构

```
apet/
├── README.md                    项目门面
├── CLAUDE.md                    本文件
├── Package.swift                SwiftPM（建后存在）
├── Sources/AgentPetCore/        纯逻辑核心库（无 GUI、无系统副作用，完全单测覆盖）
│   ├── Model/                   AgentEvent / SessionKey / SessionState
│   ├── Store/                   SessionStore（单一事实源，状态机）/ PetState
│   ├── Ingest/                  NDJSONIngestor
│   ├── Notify/                  NotificationDecider
│   └── Terminal/                TerminalLocator（iTerm2…）
├── Tests/AgentPetCoreTests/     XCTest
└── docs/superpowers/
    ├── specs/2026-06-27-apet-design.md        权威设计（v2，含红队加固）
    └── plans/2026-06-27-apet-m1-core.md       M1 核心引擎实现计划（10 TDD 任务）
```

> **App 壳**（NSWindow 宠物窗、菜单栏、SwiftUI 面板、真实 osascript、hook 安装器、UNUserNotificationCenter）尚未规划成代码——属于后续 Plan B。当前仓库只有 `AgentPetCore` 纯逻辑引擎。

## 构建 / 测试

```bash
swift build          # 编译
swift test           # 跑全部单测（提交前必须全绿）
swift test --filter SessionStoreOrderingTests   # 跑单个测试类
```

无第三方依赖，`swift test` 直接可用。Swift 6.x 工具链；包固定 `swift-tools-version:5.9`（Swift 5 语言模式）。

## 硬约束（改代码前必读）

源自设计文档 §3/§4/§6/§7 与红队对抗评审，**违反即是 bug**：

1. **零外部依赖** —— 只用 Foundation 标准库。
2. **不用 `Date()` / `Date.now`** —— 需要「当前时间」一律通过参数 `now: Double`（Unix 秒）注入，便于测试 STALE。
3. **排序唯一事实是 `seq`**（由 `NDJSONIngestor` 按 append 顺序赋的单调序），**绝不用墙钟 `ts` 排序**。去重唯一键是 `eventId`。归一键是 `(agent, root, sessionId)`（必须含 `root`，否则多 profile 会撞车）。
4. **终态 `ended` 不可回退**；`stale` 可复活。`busy` 落在 `running` 上只刷新计时、**不广播**。
5. **字段级合并**（last-non-nil-wins）：`cwd/title/terminal` 空值不覆盖已有值；`terminal` 一旦拿到精确值不被空值降级。
6. **AppleScript 一律参数化** —— 终端跳转脚本**严禁字符串内插**事件字段；id 先经正则白名单校验，再作为 `osascript` 的 argv 传入。这是防注入红线。
7. **测试是规范** —— 测试失败时改实现、不改测试迁就实现。断言精确，覆盖正常/边界/异常。

## 设计权威性

`docs/superpowers/specs/2026-06-27-apet-design.md` 是唯一权威设计。改行为先改 spec，再改实现与测试，保持一致。事件协议 / 插件 Manifest 字段是第三方对接的契约，改动需谨慎（见 spec §3 / §3.1 安全基线）。

## 协作约定

- **分支**：不在 `main` 上直接开发，用 `feature/` 前缀分支（当前：`feature/m1-core-engine`）。push 用 SSH（本机 git 全局把 github https 改写到被拦截的代理，**https 推不动、SSH 可以**：`git@github.com:clsaa/apet.git`）。
- **提交身份**：本仓库已配 `clsaa <812022339@qq.com>`，直接 `git commit` 即可，勿覆盖。
- **提交粒度**：小步提交，一个可独立测试的交付物一个 commit；中文 commit message。
- **执行计划**：M1 按 `docs/superpowers/plans/2026-06-27-apet-m1-core.md` 逐任务 TDD 推进（写失败测试→跑→实现→跑过→提交）。

## 路线图

M1 地基+桌宠 → M2 宠物扩展+多源 → M3 终端+安全加固 → M4 生态（公开契约+第三方样例）。详见 README 与 spec §11。
