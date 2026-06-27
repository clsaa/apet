# B2 Review Fix Report

## Status
All three issues fixed. Build clean. Tests 176/176 pass. Smoke exit 0.

## Changes

### I-1 (Important) — focus() 离开主线程
- `NotificationService.didReceive`: 在 `@MainActor` Task 内解析 `terminal` 引用，随即 `Task.detached { fs.focus(terminal) }` 卸载阻塞调用。`completionHandler()` 仍在主线程立即返回。
- `MenuBarController.sessionItemClicked`: 同样模式——@MainActor 内取 `box.terminal` + `self.focusService` 引用，然后 `Task.detached` 执行 `focus()`。
- `TerminalFocusService` 本身无 `@MainActor` 标注，`Process`/`NSWorkspace` 调用线程安全，无需修改。

### M-3 (Minor) — 共享 TerminalFocusService
- `MenuBarController.init` 改为接受 `focusService: TerminalFocusService` 注入参数（移除内联 `= TerminalFocusService()`）。
- `NotificationService.init` 移除 `focusService` 默认值，改为必传。
- `AppCoordinator.start()` 创建单一 `let focusService = TerminalFocusService()` 并注入两者。

### M-1 (Minor) — ingest(event:) 避免双重解码
- `NDJSONIngestor` 新增 `public func ingest(event: AgentEvent, now: Double, replay: Bool) -> [StoreChange]`，直接分配 seq 并写 store；原 `ingest(line:)` 内部调用它（解码一次）。
- `AppCoordinator` 的 live-watch handler 与 eager-drain 路径均改为：`AgentEvent.decode(line:)` 一次 → `ingestor.ingest(event:)` → `ns.consider(event:)`，消除热路径上的二次 JSON 解码。
- 新增单测 `test_ingest_event_assigns_monotonic_seq` + `test_ingest_event_and_line_share_seq_counter`。

## Build / Test / Smoke
- `swift build`: Build complete, 0 warnings.
- `swift test`: 176 tests, 0 failures (174 original + 2 new).
- `swift run apet --smoke`: exit 0, no crash.

## Concerns
None. `TerminalRef` is a value type (struct) — safe to pass across concurrency boundaries. `TerminalFocusService` is a `final class` with no shared mutable state and no `@MainActor` isolation, so `Task.detached` capture is safe.
