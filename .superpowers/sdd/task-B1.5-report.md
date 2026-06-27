# Task B1.5 Report — apet 可执行 + AppCoordinator + .app 打包

## 日期
2026-06-28

## 实现清单

| 文件 | 说明 |
|------|------|
| `Package.swift` | 新增 `.executableTarget(name: "apet", dependencies: ["AgentPetCore", "AppShellKit"])` |
| `Sources/apet/AppCoordinator.swift` | `@MainActor final class`；回放 + 增量监听 + reap 定时器 |
| `Sources/apet/AppDelegate.swift` | `NSApplicationDelegate`；用 `MainActor.assumeIsolated` 启停 coordinator |
| `Sources/apet/main.swift` | `--smoke` 无头模式 + 正常 `NSApplication` 背景 App 模式 |
| `scripts/package-app.sh` | `swift build -c release` → 组装 `AgentPet.app`，Info.plist 含 `LSUIElement=YES` |

## 关键 API 确认

- `EventTailReader().readNewLines(path:from:) throws -> (lines: [String], next: Checkpoint)` —— 增量读取，支持旋转检测
- `NDJSONIngestor.ingest(line: Substring, now: Double, replay: Bool) -> [StoreChange]`
- `SessionStore.addChangeHandler(_ handler: @escaping ([StoreChange], Bool) -> Void)` —— Bool = isReplay

## `@MainActor` 解法

`AppCoordinator` 标注 `@MainActor`，`main.swift` 是 nonisolated 同步上下文。解决方式：

1. `main.swift` 所有 AppKit/AppCoordinator 调用包入 `MainActor.assumeIsolated { ... }`（合法：main.swift 始终在主线程执行）。
2. `AppDelegate` 不加 `@MainActor`（ObjC delegate 回调本就在主线程）；在 `applicationDidFinishLaunching` 内用 `MainActor.assumeIsolated` 调用 `AppCoordinator`。

## 构建结果

```
swift build       → Build complete!
swift test        → 151 tests passed, 0 failures
package-app.sh    → Done: AgentPet.app
                   Contents/MacOS/apet ✓  |  LSUIElement=YES ✓
```

## 冒烟测试记录

```
# 启动方式
AGENTPET_EVENTS=/tmp/apet_smoke/events.ndjson \
AGENTPET_LOG=/tmp/apet_smoke/apet.log \
.build/release/apet --smoke &

# 写入事件（正确 schema：event="session_start", ts=字符串）
{"eventId":"smoke-001","agent":"claude-code","event":"session_start",
 "sessionId":"sess-smoke-123","root":"/tmp/smoke","ts":"2026-06-28T00:00:00Z"}

# 日志输出
[start] replay done, lines=0, offset=0
[change] [AgentPetCore.StoreChange.upserted(AgentPetCore.SessionKey(
  agent: "claude-code", root: "/tmp/smoke", sessionId: "sess-smoke-123"))]
  replay=false summary=PetSummary(state: AgentPetCore.PetState.busy,
  runningCount: 1, waitingCount: 0, attentionCount: 0, staleCount: 0)

INGESTION CONFIRMED ✓
```

## 注意事项

- 计划中的冒烟 JSON 使用 `"event":"session_started"`（不在协议枚举中）和 `"ts":1751000000`（数字），均会导致 `AgentEvent.decode` 返回 nil 导致静默忽略。实际测试修正为 `"event":"session_start"` + `"ts":"2026-06-28T00:00:00Z"`（字符串）。
- `DispatchSource` 监听的文件删除/改名事件触发时会取消旧 source、关闭 fd，0.5 s 后重新打开（轮转支持）。
