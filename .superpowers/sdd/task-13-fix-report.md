# Task 13 — 合并前 8 项修复报告

分支：`feature/m1.5-onboarding-jsonl-menubar`
基线：309 测试全绿 → 修复后 **315 测试全绿**（新增 6 个测试），`swift build` 通过。

---

## FIX 1 — 懒授权通知（NotificationService.swift）
- `start()` 移除 `requestAuthorization`，仅保留 delegate + category 注册。
- 新增私有 `deliver(_:)`：投递前先 `getNotificationSettings`：
  - `.denied` → 直接跳过投递；
  - `.notDetermined` → 先 `requestAuthorization`，授权通过才投递；
  - 其它（authorized/provisional/ephemeral）→ 直接投递。
- 系统回调队列上的投递统一 hop 回 `@MainActor`（`Task { @MainActor in center.add(...) }`）后再调 `add`。
- 效果：不再在启动时弹授权框，首条真实通知才触发授权。

## FIX 2 — 来源判定（MenuBarController.swift，约 L278）
- `handleSessionTap` 中 `let isJsonlSession = (terminal == nil)` → `(session.source == .jsonl)`。
- 对齐硬约束 #9：用进程内 `source` 标记判定来源，不用 `terminal == nil` 当代理。

## FIX 3 — Watcher 幽灵会话对账（真实 bug，JSONLDirectoryWatcher.swift）
- `scanOnce()` 内新增 `observedKeys` 记录本轮 `.observe` 的 key。
- 循环结束后，对 `lastEmitted` 中状态为 `.running/.waitingStop` 但本轮未被 observe 的 key（文件变 `.ignore` 或消失），补发 `.observe(state:.stale, key, cwd:nil, title:nil)` 并清出 `lastEmitted` + `quietStreak`（同源消失只打一次灰）。
- 新增测试 `test_running_then_gone_emits_stale`：round1 running → round2 `.ignore(tooOld)` → emit 序列 `[.running, .stale]`，且第三轮不重复补 stale。

## FIX 4 — applyScanResult 可测化 + hook 不被 jsonl 打灰（SessionStore.swift / AppCoordinator.swift）
- SessionStore 新增 `@discardableResult func markStaleSessionIfJSONL(_ key:SessionKey, now:Double) -> [StoreChange]`：`guard sessions[key]?.source == .jsonl else { return [] }` 再委派 `markStaleSession`。
- AppCoordinator `applyScanResult` 的 `.stale` 分支改用该方法（守卫逻辑收敛、便于单测）。
- 新增 3 个测试：hook 来源返回 `[]` 且保持 running；jsonl 来源变 stale 且刷新 lastActiveAt；不存在 key 返回 `[]`。

## FIX 5 — 健康面板装/卸后刷新（PreferencesWindow.swift）
- `HookRowView` 新增 `let onChanged: () -> Void`，在 `performInstall` / `performUninstall` 成功分支调用。
- `PreferencesView` 传入 `onChanged: { healthRefreshID = UUID() }`，触发 `.task(id:)` 重跑 `refreshHealthStatus`。

## FIX 6 — 面板感知 hook 是否已装（MenuBarController.swift / AppCoordinator.swift）
- `PanelRootView` 新增 `let hookInstalled: Bool`：为 true 时把"开启精确跳转/通知…"按钮替换为绿色"精确跳转/通知：已启用"静态标签。
- `MenuBarController` 新增注入点 `var hookInstalledProvider: (() -> Bool)?`，`makePanelRootView()` 调用它取值（含降级 fallback 构造同步更新）。
- AppCoordinator 注入 provider：遍历 `config.dataRoots` 用 `HookInstaller.isInstalled` 判定（marker 提为静态常量 `AppCoordinator.hookMarker = "apet-1"`，与 PreferencesView 一致）。

## FIX 7 — recentQueueOp 优先于 end_turn（真实 bug，JSONLSessionScanner.swift）
- 状态派生顺序调整为：`recentQueueOp` → `awayIsLatest(stale)` → `end_turn/stop_sequence(waitingStop)` → `tool_use` → 默认（均按 runningWindow 区分）。
- 修复"用户刚入队新指令、但末条 assistant 是 end_turn 时被误判 waitingStop"。
- 新增测试 `test_recentQueueOp_overrides_end_turn_isRunning`（end_turn + lastQueueOpTs=now-50 → running）；新增对照 `test_end_turn_without_queueOp_stays_waitingStop`（end_turn 无 queueOp → waitingStop）。

## FIX 8 — away 测试钉死（JSONLParseTests.swift）
- `test_parse_away_ts_vs_assistant_ts` 末尾新增 `XCTAssertEqual(f.lastConversationTs!, f.lastAwayTs!)`，断言 away_summary（带 timestamp 的末行）也更新了 `lastConversationTs`。

---

## 测试结果
- `swift test`：**Executed 315 tests, with 0 failures**（309 基线 + 6 新增）。
- `swift build`：**Build complete!**（仅 UserNotifications 的 Sendable 非阻断 warning，Swift 5 语言模式下不影响）。

## 不变量校验
- 终态 ended 不复活：`markStaleSessionIfJSONL` 复用 `markStaleSession`，ended 直接返回 []。
- 唯一 seq 源：未触碰 NDJSONIngestor 取号路径。
- markStale 跳过 jsonl：FIX 4 仅新增定向方法，定时 `markStale` 行为不变（既有测试仍绿）。
- jsonl 不触发通知：FIX 1/3 均不在 jsonl 路径调用 NotificationService。

## 关注点
- FIX 1 在 `Task { @MainActor in center.add(request) }` 处有 `UNNotificationRequest` 非 Sendable 捕获 warning（编译告警，非错误）。Swift 5 语言模式下不阻断；如后续升 Swift 6 严格并发需用 `@preconcurrency` 或本地 sendable 包装处理。
