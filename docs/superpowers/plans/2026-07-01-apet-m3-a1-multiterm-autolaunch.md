# M3-A1 多终端 + 常驻 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 两件用户强调、低风险的常规体验：① F12 多终端——iTerm2 之外也能定位（Terminal.app 窗口级、Warp/Ghostty/VSCode 激活应用），能力分级对用户透明；② A4 开机自启——`SMAppService` 常驻，首选项可开关，失败有提示。

**Architecture:** 沿用三层：可决策逻辑下沉 `AgentPetCore`（能力分级、定位器脚本渲染、自启决策，全纯函数可单测）；系统副作用（osascript 执行、SMAppService 注册）留 `AppShellKit`/`apet` 并抽协议缝 + Mock；GUI 只做薄胶水。**单一事实源**：终端能力分级由一个纯函数产出，planner 与 SessionRowModel 都消费它（消除现有二者对 `.terminal` 的判定分歧）。

**Tech Stack:** Swift 5.9 语言模式 / Swift 6.x 工具链；SwiftPM 三 target；XCTest；零第三方依赖（`SMAppService` 属 ServiceManagement 系统框架，不算第三方）。

## Global Constraints

- 零外部依赖，只用 Foundation/AppKit/SwiftUI/ServiceManagement 标准框架。
- core 纯逻辑：`AgentPetCore` 无 GUI、无系统副作用、不调 `Date()`；当前时间一律 `now: Double` 注入。
- **AppleScript 一律参数化 + 白名单**（设计 §3.1 / §6 安全红线）：终端标识（tty / session id）先经正则白名单校验，再作为 `osascript` 的 argv 传入，**严禁字符串内插**。
- 新 IO 缝（`LoginItemService`）必须协议化 + Mock 单测；core 仍纯。
- 向后兼容：`TerminalKind` 新增 case 走 `decodeIfPresent` + 未知值回退 `.other`（不破坏旧 wire 数据）。
- 测试是规范：测试失败改实现、不改测试；断言精确，覆盖正常/边界/异常。
- 文件路径镜像测试：`Sources/X/Foo.swift` → `Tests/XTests/FooTest.swift`。
- 提交粒度：一个可独立测试的交付物一个 commit；中文 commit message。
- `swift test` 提交前必须全绿（基线由 M3-A0 合并后的全绿数为准）。
- 分支：`feature/m3-a1-multiterm-autolaunch`（已创建），勿在 main。

## 现状核对（实现前已查证）

- `TerminalKind`（`Sources/AgentPetCore/Model/AgentEvent.swift:21`）= `iterm2, terminal, warp, other`；`TerminalRef` 已有 `tty/bundleId`。
- `TerminalFocusPlanner`（`Sources/AppShellKit/TerminalFocusPlanner.swift`）：iTerm2 精确、`.terminal`/`.warp`/`.other` 全走 `.activateBundle`——**Terminal.app 仅激活应用，未做窗口级**。
- `SessionRowModel.activateOnly`（`Sources/AppShellKit/SessionRowModel.swift:92`）：只把 `.warp`/`.other` 判为 activateOnly，**`.terminal` 被判为「精确」——与 planner 实际行为矛盾（BUG）**。
- hook（`Resources/apet-emit-event.sh`）：按 `ITERM_SESSION_ID` / `TERM_PROGRAM`(`Apple_Terminal`/`WarpTerminal`) 填 terminal，**不采集 tty，不识别 Ghostty/VSCode**。
- 无任何开机自启代码（全仓 grep `SMAppService` 无命中）。

---

### Task 1: F12 — 终端能力分级单一事实源（修 SessionRowModel/planner 判定分歧）

把「某终端能做到多精确」收口成一个纯函数，planner 与 row model 都消费它，消除现有 `.terminal` 判定矛盾。

**Files:**
- Create: `Sources/AgentPetCore/Terminal/TerminalCapability.swift`
- Modify: `Sources/AppShellKit/SessionRowModel.swift`（`activateOnly` 改由能力分级推导）
- Test: `Tests/AgentPetCoreTests/TerminalCapabilityTests.swift`
- Modify test: `Tests/AppShellKitTests/SessionRowModelTests.swift`（补 `.terminal` 用例）

**Interfaces:**
- Produces:
  - `public enum TerminalCapability: Equatable { case preciseTab; case preciseWindow; case activateOnly; case activateOnlyManualTab }`
    - `preciseTab` = 能选中具体 tab（iTerm2）；`preciseWindow` = 能选中窗口但不到 tab（Terminal.app）；`activateOnly` = 仅激活应用（Warp/Ghostty）；`activateOnlyManualTab` = 仅激活应用且需用户手动找 tab（VSCode/Cursor 内置终端）。
  - `public enum TerminalCapabilities { static func capability(for kind: TerminalKind) -> TerminalCapability }`
  - 便利派生：`var isActivateOnly: Bool`（`preciseTab`/`preciseWindow` → false，其余 true）；`var needsManualTabHint: Bool`（仅 `activateOnlyManualTab`）。
- Consumes: `TerminalKind`。

- [ ] **Step 1: 写失败测试（能力分级）** —— `TerminalCapabilityTests`：
  - `capability(.iterm2) == .preciseTab`
  - `capability(.terminal) == .preciseWindow`
  - `capability(.warp) == .activateOnly`
  - `capability(.ghostty) == .activateOnly`（Task 3 加 case 后生效——本步先按当前 enum 写，Task 3 补齐）
  - `capability(.vscode) == .activateOnlyManualTab`（同上）
  - `capability(.other) == .activateOnly`
  - `TerminalCapability.preciseWindow.isActivateOnly == false`；`.activateOnly.isActivateOnly == true`
  - `TerminalCapability.activateOnlyManualTab.needsManualTabHint == true`；`.activateOnly.needsManualTabHint == false`
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现 `TerminalCapability.swift`**（先只覆盖当前 4 个 kind，ghostty/vscode 留 Task 3）
- [ ] **Step 4: 跑测试确认通过**
- [ ] **Step 5: 改 `SessionRowModel`** —— `activateOnly = TerminalCapabilities.capability(for: kind).isActivateOnly`（kind 缺省时 activateOnly=false，保持无终端信息不显降级提示）；补 `.terminal` 现在应为 `activateOnly=false`（preciseWindow 不算 activateOnly），并在既有 `SessionRowModelTests` 加一条 `.terminal` 断言。
- [ ] **Step 6: 全量 `swift test` 绿；commit** `feat(m3a1): 终端能力分级单一事实源 + 修 rowmodel .terminal 判定`

---

### Task 2: F12 — Terminal.app 窗口级 AppleScript 定位器

`.terminal` 从「仅激活应用」升级为「窗口级」：用 tty 在 Terminal.app 里选中对应窗口/tab。tty 由 hook 采集（Task 3 补 hook 侧），本任务先把定位器 + planner 接线做好，无 tty 时优雅降级为激活应用。

**Files:**
- Modify: `Sources/AgentPetCore/Terminal/TerminalLocator.swift`（加 `TerminalAppLocator` + `TTYPath` 白名单）
- Modify: `Sources/AppShellKit/TerminalFocusPlanner.swift`（`.terminal` 有合法 tty → osascript，否则 activateBundle）
- Test: `Tests/AgentPetCoreTests/TerminalAppLocatorTests.swift`
- Modify test: `Tests/AppShellKitTests/TerminalFocusPlannerTests.swift`

**Interfaces:**
- Produces:
  - `public enum TTYPath { static func isValid(_ s: String) -> Bool }` —— 只允许 `/dev/tty` + `[A-Za-z0-9]`（如 `/dev/ttys001`），杜绝空格/引号/`;`/`$()`/反引号注入。
  - `public struct TerminalAppLocator: TerminalLocator`：`kind == .terminal`，`capability == .activateOnly`（脚本层不区分，能力分级另由 Task 1 出）；`focusInvocation(for:)` 用 `ref.tty`，缺失 → `LocatorError.missingRef`，非法 → `.invalidRef`。
- Consumes: `TerminalRef.tty`、`ScriptInvocation`。

- [ ] **Step 1: 写失败测试** —— `TerminalAppLocatorTests`：
  - `TTYPath.isValid("/dev/ttys001") == true`；`isValid("") == false`；`isValid("/dev/ttys0 01") == false`；`isValid("`whoami`") == false`；`isValid("/dev/ttys001; rm -rf /") == false`。
  - `ref(.terminal, tty: "/dev/ttys001")` → `focusInvocation` 返回 `executable == "/usr/bin/osascript"`，`arguments[0]` 含参数化脚本、`arguments[1] == "/dev/ttys001"`（**断言脚本体不含内插的 tty 串**）。
  - `ref(.terminal, tty: nil)` → throws `.missingRef`；`ref(.terminal, tty: "bad; x")` → throws `.invalidRef`。
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现 `TerminalAppLocator`** —— 参数化脚本（`on run argv` 取 `item 1 of argv` 作 targetTty；`repeat with w in windows / repeat with t in tabs of w / if tty of t is targetTty then set selected of t to true; set frontmost of w to true; activate; return`；未命中 `error … number -1`）。
- [ ] **Step 4: 跑测试确认通过**
- [ ] **Step 5: 改 planner** —— `.terminal`：`if let tty = ref.tty, TTYPath.isValid(tty) { .osascript(TerminalAppLocator().focusInvocation…) } else { .activateBundle(ref.bundleId ?? "com.apple.Terminal") }`；补 `TerminalFocusPlannerTests`：`.terminal`+合法 tty → `.osascript`；`.terminal`+nil tty → `.activateBundle("com.apple.Terminal")`；`.terminal`+非法 tty → `.activateBundle`（**不抛异常**）。
- [ ] **Step 6: 全量 `swift test` 绿；commit** `feat(m3a1): Terminal.app 窗口级定位（tty 白名单参数化）+ planner 接线`

---

### Task 3: F12 — 扩展 Ghostty/VSCode 终端类型 + hook 检测 + tty 采集 + UI 提示

**Files:**
- Modify: `Sources/AgentPetCore/Model/AgentEvent.swift`（`TerminalKind` 增 `ghostty, vscode`）
- Modify: `Sources/AgentPetCore/Terminal/TerminalCapability.swift`（补 ghostty/vscode 分支——Task 1 已预留测试）
- Modify: `Sources/AppShellKit/TerminalFocusPlanner.swift`（`.ghostty`/`.vscode` → activateBundle，带默认 bundleId）
- Modify: `Resources/apet-emit-event.sh`（`TERM_PROGRAM` 识别 ghostty/vscode；`ps -o tty= -p $PPID` 采集 tty 填入 terminal）
- Modify: `Sources/apet/SessionPanel.swift`（消费 `needsManualTabHint` 展示「仅激活应用 / 需手动找 tab」）
- Test: 扩 `Tests/AgentPetCoreTests/TerminalCapabilityTests.swift`、`Tests/AgentPetCoreTests/AgentEventTests.swift`（terminal decode ghostty/vscode + 未知 kind 回退 other + tty 字段 decode）

**Interfaces:**
- `TerminalKind` = `iterm2, terminal, warp, ghostty, vscode, other`（rawValue 小写；未知回退 `.other` 逻辑已存在于 `init(from:)`）。
- 能力映射：`ghostty → .activateOnly`（bundleId `com.mitchellh.ghostty`）；`vscode → .activateOnlyManualTab`（bundleId `com.microsoft.VSCode`，Cursor 同 `TERM_PROGRAM=vscode`，激活 VSCode/Cursor 前台应用即可）。

- [ ] **Step 1: 写失败测试** —— decode `{"kind":"ghostty"}`→`.ghostty`、`{"kind":"vscode"}`→`.vscode`、`{"kind":"zellij"}`→`.other`（回退）、`{"kind":"terminal","tty":"/dev/ttys003"}` tty 正确 decode；能力分级 ghostty/vscode 断言（Task 1 已写、此处确认转绿）。
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现** —— enum 加 case；capability 加分支；planner 加 `.ghostty`/`.vscode` → `.activateBundle`。
- [ ] **Step 4: 跑测试确认通过**
- [ ] **Step 5: 改 hook `apet-emit-event.sh`** —— python 段：`term_prog` 增 `"ghostty"→ghostty(com.mitchellh.ghostty)`、`"vscode"→vscode(com.microsoft.VSCode)`；采集 tty：shell 段 `_APET_TTY="$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')"`，非空且非 `??` 时拼 `/dev/$tty` 注入 `_APET_TTY`，python 把合法 tty 写进 `terminal.tty`（Apple_Terminal 尤其需要）。**注意 hook 无单测**，改动最小化并在计划记「手测项」。
- [ ] **Step 6: 改 SessionPanel** —— activateOnly 行显「仅激活应用」；`needsManualTabHint` 行额外显「需手动切到对应标签页」（用户 MN-7：降级终端明示）。
- [ ] **Step 7: 全量 `swift test` 绿；commit** `feat(m3a1): 识别 Ghostty/VSCode + hook 采集 tty + 降级终端 UI 提示`
- [ ] **手测项（记入报告）**：真实 Terminal.app 会话点击应选中对应窗口；Ghostty/VSCode 会话点击激活应用且面板显提示。

---

### Task 4: A4 — 开机自启（LoginItemDecider 纯决策 + SMAppService 缝）

**Files:**
- Create: `Sources/AgentPetCore/Startup/LoginItemDecider.swift`（纯决策）
- Create: `Sources/AppShellKit/LoginItemService.swift`（`LoginItemControlling` 协议 + `MockLoginItemControl`；真实 `SMAppServiceLoginItem` 实现放 apet 或此处 `#if canImport(ServiceManagement)`）
- Modify: `Sources/apet/PreferencesWindow.swift`（「通用/关于」区加开关 + 失败提示）
- Test: `Tests/AgentPetCoreTests/LoginItemDeciderTests.swift`、`Tests/AppShellKitTests/LoginItemServiceTests.swift`

**Interfaces:**
- Produces:
  - `public enum LoginItemAction: Equatable { case register; case unregister; case noop }`
  - `public enum LoginItemDecider { static func plan(desiredEnabled: Bool, currentlyRegistered: Bool) -> LoginItemAction }`（desired && !current→register；!desired && current→unregister；else→noop）。
  - `public protocol LoginItemControlling { var isRegistered: Bool { get }; func register() throws; func unregister() throws }`
  - `public struct LoginItemCoordinator`（注入 `LoginItemControlling`）：`apply(desiredEnabled:) -> Result<Bool, Error>`——先 `plan` 再据结果 register/unregister，返回最终 registered 态；错误透传供 UI 提示。
- Consumes: 无 core 外依赖；真实实现用 `SMAppService.mainApp.register()/unregister()`（macOS 13+）。

- [ ] **Step 1: 写失败测试（decider）** —— 4 组合矩阵：`plan(true,false)==.register`、`plan(false,true)==.unregister`、`plan(true,true)==.noop`、`plan(false,false)==.noop`。
- [ ] **Step 2: 写失败测试（coordinator + Mock）** —— `MockLoginItemControl`（可设 isRegistered、可令 register/unregister throw）：
  - desired=true & 未注册 → 调 register 一次、结果 `.success(true)`；
  - desired=true & register throw → `.failure`，且 UI 可取错误；
  - desired=false & 已注册 → 调 unregister、结果 `.success(false)`；
  - noop 分支不调用任何注册 API。
- [ ] **Step 3: 跑测试确认失败**
- [ ] **Step 4: 实现 decider + coordinator + 协议 + Mock**
- [ ] **Step 5: 跑测试确认通过**
- [ ] **Step 6: 真实 `SMAppServiceLoginItem: LoginItemControlling`** —— `#if canImport(ServiceManagement)`；`isRegistered` 读 `SMAppService.mainApp.status == .enabled`；register/unregister 调对应 API 并把非 `.enabled` 结果转错误。
- [ ] **Step 7: 首选项接线** —— 「通用」页 Toggle「开机自启动 apet」；`onChange` 调 coordinator，`.failure` 弹提示「无法设置开机自启（需在系统设置 › 通用 › 登录项里手动开启）」；状态从 `isRegistered` 反读。
- [ ] **Step 8: 全量 `swift test` 绿；commit** `feat(m3a1): 开机自启（LoginItemDecider + SMAppService 缝 + 首选项开关）`
- [ ] **手测项**：勾选后重启登录应自动拉起；取消勾选后不再自启；注册失败弹提示。

---

## 交付顺序与依赖

`Task 1 → Task 2 → Task 3`（能力分级是底座；Terminal.app 定位器依赖 tty；Ghostty/VSCode/hook/UI 依赖前两者）。`Task 4` 与 F12 独立，可并行或最后做。每 Task 一 commit，最后 `swift test` 全绿后合并回主线（走 `feature/` → PR/merge，SSH push）。

## 验收

- 全量 `swift test` 绿（新增用例覆盖能力分级 4×kind、tty 白名单红队、planner 降级、decoder 向后兼容、自启决策矩阵 + Mock 四态）。
- `swift build` 无新增警告。
- 手测：Terminal.app 窗口级跳转、Ghostty/VSCode 激活 + 提示、开机自启开关往返 + 失败提示。
- 安全红线复核：所有终端标识（tty/session id）经白名单校验后以 argv 传入 osascript，脚本体零内插（红队用例断言）。

## 记入报告（`.superpowers/sdd/`）

完成后写 `task-m3a1-report.md`：实现取舍（tty 采集用 `ps -o tty= -p $PPID` 的原因与局限——hook stdin 非终端）、hook 无单测的手测覆盖、SMAppService 在未签名/开发构建下的行为观察、遗留项（VSCode 内置终端无法精确到 tab 的产品取舍）。
