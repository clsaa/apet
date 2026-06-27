# AgentPet M1 — App 壳实现计划（Plan B）

> **For agentic workers:** 用 subagent-driven-development 逐任务执行。GUI 胶水以 `swift build` 通过 + 手动冒烟为验收；纯逻辑（offset 读取、节流、settings.json 合并、osascript 执行构造）走 TDD。

**Goal:** 把纯逻辑库 `AgentPetCore` 装进一个可运行的 macOS 背景 App（`apet`）：FSEvents 监听 events.ndjson → 喂 store → 菜单栏图标 + 悬浮宠物表达聚合态 → 通知 + 点击跳回 iTerm2 → 会话面板。产出一个本地可启动的 `.app`。

**Architecture:** SwiftPM 新增 ① 库 target `AppShellKit`（可单测的纯逻辑：文件增量读取、通知节流、settings.json 合并、checkpoint）② 可执行 target `apet`（@MainActor GUI 胶水 + 系统集成）。`apet` 依赖 `AgentPetCore` + `AppShellKit`。用打包脚本把 SPM 二进制包成 `.app` bundle（Info.plist: LSUIElement、bundle id、通知用途串），无需 Xcode 工程文件。

**Tech Stack:** Swift 5.9、SwiftPM、AppKit/SwiftUI/UserNotifications（系统框架，零三方依赖）、XCTest。

## Global Constraints
- 零外部依赖（仅系统框架）。Swift 5.9，.macOS(.v13)。
- `SessionStore` 由 `@MainActor` 的 AppCoordinator 独占持有；所有后台回调（FSEvents/Timer/Process）先 hop 到 MainActor 再触碰 store（满足引擎线程契约）。
- 不用 `Date.now` 的地方继续注入；GUI 实时层允许用 `Date()`（仅 UI/通知时间戳，非状态推进）。
- ⛔ **不擅自修改用户真实 `~/.claude/settings.json`**：HookInstaller 默认 dry-run + 需显式确认；测试只针对临时目录。
- ⛔ 不做代码签名/公证（需用户 Apple ID）——产出 unsigned `.app`，本地可运行，上线步骤写文档。
- osascript 一律参数化（沿用 AgentPetCore 的 ScriptInvocation：脚本走 stdin、id 走 argv）。
- 通知点击/终端跳转：iTerm2 精确，其它终端 activate-only。

---

## Phase B1 — 可运行核心 + 打包

### Task B1.1: AppShellKit — events.ndjson 增量读取 + checkpoint（TDD）
**Files:** Create `Sources/AppShellKit/EventTailReader.swift`, Test `Tests/AppShellKitTests/EventTailReaderTests.swift`; Modify `Package.swift`（加 AppShellKit 库 + 测试 target）。
**Interfaces:** Produces `struct Checkpoint: Codable, Equatable { var fileId: String; var offset: UInt64 }`; `struct EventTailReader { func readNewLines(path:from:) -> (lines: [String], next: Checkpoint) }`（基于文件 size/inode 检测轮换；轮换则从 0 读）。
- [ ] 写失败测试：临时文件追加 2 行 → readNewLines(from: .zero) 返回 2 行 + offset 到末尾；再追加 1 行 → 从上次 offset 只返回新行；文件被 truncate/换 inode → 从 0 重读。
- [ ] `swift test` 失败 → 实现 → 通过 → commit。

### Task B1.2: AppShellKit — HookInstaller settings.json 合并/卸载（TDD，仅操作传入路径）
**Files:** Create `Sources/AppShellKit/HookInstaller.swift`, Test `.../HookInstallerTests.swift`.
**Interfaces:** `struct HookInstaller { func install(into settingsURL:, runnerPath:, marker:) throws; func uninstall(from settingsURL:, marker:) throws; func isInstalled(settingsURL:, marker:) -> Bool }`。用 marker 包裹注入的 hooks（SessionStart/Stop/Notification/PreToolUse/PostToolUse/SubagentStop → 调 runnerPath 追加事件），写前备份 `settings.json.apet.bak`。snippet 只引用 runnerPath（参数化），不含任意 shell。
- [ ] 测试（临时目录）：空 settings.json → install → 含 marker 包裹的 6 个 hook + 备份存在；已有用户 hooks → install 不破坏、只追加；uninstall → 还原到无 marker 状态；isInstalled 正确。
- [ ] TDD → commit。

### Task B1.3: AppShellKit — 通知节流 NotificationThrottle（TDD）
**Files:** Create `Sources/AppShellKit/NotificationThrottle.swift`, Test。
**Interfaces:** `struct NotificationThrottle { mutating func allow(key: SessionKey, kind: String, now: Double, cooldown: Double) -> Bool }`（同 session+kind 在 cooldown 内只放行一次）。注入 now。
- [ ] 测试：首次 allow=true；cooldown 内同 key+kind allow=false；超出后 true；不同 key 互不影响。TDD → commit。

### Task B1.4: emit-event hook 脚本（被 Claude hook 调用，追加事件到 events.ndjson）
**Files:** Create `Resources/apet-emit-event.sh`（或 swift），Test `.../EmitEventScriptTests.swift`（用 bash 跑脚本断言输出行）。
**Interfaces:** 脚本读 hook 传入的 JSON（stdin/env：session_id、cwd、hook 事件名、`$ITERM_SESSION_ID`、`$TERM_PROGRAM`），映射成本仓事件 schema（eventId=uuid、agent="claude-code"、event 按 hook 名映射、terminal.kind 按 TERM_PROGRAM、terminal.itermSessionId=$ITERM_SESSION_ID），`flock` 追加一行到 events.ndjson。
- [ ] 测试：模拟一次 Stop hook 调用 → events.ndjson 末尾出现合法 JSON 行（含必填字段 + terminal）。→ commit。

### Task B1.5: apet 可执行 target + AppCoordinator + .app 打包（构建验收）
**Files:** Create `Sources/apet/main.swift`、`Sources/apet/AppCoordinator.swift`、`Sources/apet/AppDelegate.swift`、`scripts/package-app.sh`；Modify `Package.swift`（加 executable `apet`）。
- `AppDelegate`：`LSUIElement` 背景 App，启动 AppCoordinator。
- `AppCoordinator`（@MainActor）：持有 SessionStore + NDJSONIngestor；用 DispatchSource 监听 events.ndjson（变化→EventTailReader 读新行→主线程 ingest，live=replay:false）；启动时先回放已有内容（replay:true）；起 ReapTimer（周期 markStale + reap，阈值从配置）；注册 store changeHandler 打日志（B2 接 UI）。
- `package-app.sh`：`swift build -c release` → 组装 `AgentPet.app/Contents/{MacOS/apet, Info.plist, Resources/}`，Info.plist 含 `LSUIElement=YES`、`CFBundleIdentifier=com.clsaa.apet`、`NSUserNotificationsUsageDescription`。
- [ ] `swift build` 通过；运行 `scripts/package-app.sh` 产出 `AgentPet.app`；`open AgentPet.app` 后进程常驻（`pgrep apet`），手动往 events.ndjson 追加一行 → 日志显示 store 收到。→ commit。
- 验收=构建+手动冒烟（无单测，逻辑已在 Kit 层测过）。

---

## Phase B2 — 菜单栏 + 通知 + 跳转

### Task B2.1: TerminalFocusService（执行 ScriptInvocation + activate-only 兜底）
**Filesः** Create `Sources/apet/TerminalFocusService.swift`。
- iTerm2/terminal：跑 `/usr/bin/osascript -`（脚本走 stdin，argv 传 id）；捕获非零退出（未命中→"窗口已不存在"回调）。
- warp/other/无 ref：`NSWorkspace.shared` 按 bundleId 激活（activate-only）。
- [ ] 构建验收 + 手动：对一个真实 iTerm2 session id 跳转成功；伪造 id 跳转报"窗口已不存在"。commit。

### Task B2.2: NotificationService（UNUserNotificationCenter + 节流 + 点击跳转）
**Files:** Create `Sources/apet/NotificationService.swift`。
- AppCoordinator 在每次 ingest 后（拿到 event + 结果 session）调 `consider(event:session:replay:mode:)`：replay 跳过；过 NotificationThrottle；过 `NotificationDecider.decide`；deliver UNNotification（title/body/带 sessionKey）。
- 点击通知 → 取 sessionKey → 查 store.sessions[key].terminal → TerminalFocusService.focus。
- 请求通知授权。
- [ ] 构建验收 + 手动：追加一条 attention 事件 → 弹通知；点击 → 跳 iTerm2。commit。

### Task B2.3: MenuBarController（NSStatusItem 反映 summary()）
**Files:** Create `Sources/apet/MenuBarController.swift`。
- NSStatusItem 图标：idle/busy/calling 着色；`summary().badgeCount>0` 显示角标数字，`attentionCount>0` 橙色。
- 点击 → NSPopover 显示 SessionPanel（B3）。
- 订阅 store.changeHandler（主线程刷新）。
- [ ] 构建验收 + 手动：多事件下菜单栏图标随聚合态变化、角标显示等你数量。commit。

---

## Phase B3 — 悬浮宠物 + 会话面板 + 占位素材

### Task B3.1: 占位宠物素材
**Files:** Create `Resources/pets/shiba/*.png`、`Resources/pets/bichon/*.png`、状态徽标/气泡。
- 用图像生成工具产柴犬(公)/比熊(母) 去背静态图 + idle/busy/calling 三态徽标。精修留用户。
- [ ] 资源就位，README 标注占位。commit。

### Task B3.2: SessionPanel（SwiftUI 列表）
**Files:** Create `Sources/apet/SessionPanel.swift`。
- 列 `store.activeSessions()`：绿点 RUNNING / 红点 WAITING(attention 橙、stop 红) / 橙? STALE；显示 title + cwd + `profileLabel`（多 profile 区分）；warp/other 行标"仅激活"。
- 点行 → TerminalFocusService.focus。
- [ ] 构建验收 + 手动：面板列出会话、点击跳转、profile 标签可见。commit。

### Task B3.3: PetWindowController + PetView + 显示模式
**Files:** Create `Sources/apet/PetWindowController.swift`、`Sources/apet/PetView.swift`。
- 无边框透明悬浮 NSWindow（floating level、可拖、不抢焦点）；PetView 渲染选中宠物图 + 聚合态徽标 + 气泡（"N 个等你"）；点宠物 → 弹 SessionPanel。
- 显示模式：悬浮宠物 / 仅菜单栏（PreferencesB4 切换）。
- [ ] 构建验收 + 手动：宠物悬浮桌面、可拖、状态徽标随聚合态变化、点击弹面板。commit。

---

## Phase B4 — 首选项 + Hook 安装（门控）

### Task B4.1: 配置持久化 + PreferencesWindow
**Files:** Create `Sources/apet/Preferences.swift`、`Sources/apet/PreferencesWindow.swift`。
- 持久化（`~/Library/Application Support/AgentPet/config.json`）：数据根列表、显示模式、通知模式（attentionOnly/everyStop）、STALE/reap 阈值、选中宠物。
- PreferencesWindow：增删数据根、切显示/通知模式、传宠物照片（可选一键抠图 VNGenerateForegroundInstanceMaskRequest）、选内置宠物。
- [ ] 构建验收 + 手动。commit。

### Task B4.2: Hook 安装 UI（门控，安全）
**Files:** Create `Sources/apet/HookInstallUI.swift`。
- 首选项里"安装 Claude hook"按钮 → 展示将写入的 settings.json diff + 备份说明 → 用户确认后调 AppShellKit.HookInstaller.install（针对所选数据根的 settings.json）。卸载同理。
- ⛔ 绝不在无确认下改用户 settings.json。
- [ ] 构建验收 + 手动（在临时 settings.json 上验证；真实安装由用户点）。commit。

---

## 验收与上线（人工门）
- **本地可运行**：`scripts/package-app.sh` → `AgentPet.app`，双击启动，菜单栏/宠物出现，配 hook 后真实跑通"会话完成→通知→点击跳 iTerm2"。
- **人工门（用户醒后）**：① Apple Developer 签名/公证（需用户凭证）② 宠物美术终稿 ③ 真机多终端 E2E ④ 验证 attention hook 真实触发源（面板头号风险）。
- **遗留并入 M2/M3**：Terminal.app/Warp 精确跳转、process 探活合成 session_end、subagent 折叠、checkpoint 性能、第三方插件契约。
