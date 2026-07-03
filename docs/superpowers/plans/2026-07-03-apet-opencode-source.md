# OpenCode 零配置接入 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** apet 面板/菜单栏/桌宠可见本机 OpenCode(sst/opencode)会话:内容信号优先的状态、带目录的恢复命令、诚实的无跳转降级;静默不通知。

**Architecture:** 只读轮询 `opencode.db`(SQLite,WAL):`OpenCodeDBReader`(IO 缝)→ `OpenCodeScanner`(纯函数,内容信号优先/活动窗口兜底/三档 stale)→ 泛化的 `DBPollWatcher`(差分+幽灵对账)→ 同一 `NDJSONIngestor` 入 `SessionStore`。契约层新增 `SessionIdRule` 收敛两处 UUID 校验并放行 `ses_` 前缀 id。

**Tech Stack:** Swift 5.9(SwiftPM 三 target)、XCTest、SQLite3(Apple 系统库)。

**权威 spec:** `docs/superpowers/specs/2026-07-03-apet-opencode-source-design.md`(v2,七视角评审后)。行为与本计划冲突时以 spec 为准并回报。

## Global Constraints(每个任务隐含)

- 零第三方包依赖;AgentPetCore 只用 Foundation;AppShellKit 可用 SQLite3。
- 禁 `Date()`/`Date.now`——「当前时间」一律 `now: Double` 参数注入(GUI 胶水层 `Date().timeIntervalSince1970` 的既有用法除外)。
- 排序唯一事实是 `seq`(唯一 seq 源 = 同一 NDJSONIngestor 实例);归一键 `(agent, root, sessionId)`。
- OpenCode 轮询源**永不发 OS 通知**;`markStale` 定时器跳过 `source == .jsonl`。
- 防注入:恢复命令 sessionId 先过白名单;argv 单元素传递,严禁字符串内插。
- 测试是规范:测试失败改实现不改测试;提交前 `swift test` 全绿(当前基线 610 个)。
- 提交:中文 message,小步一交付物一 commit;不动 `main`,分支 `feature/opencode-source`。
- 时间戳:opencode DB 全部 epoch **毫秒**,Reader 层换算成 Unix 秒,Row 之后的世界只有秒。

---

### Task 1: QoderWorkWatcher 回归网补齐(评审 B4,泛化前置)

**Files:**
- Modify: `Tests/AppShellKitTests/QoderWorkDBReaderTests.swift`(追加 4 个测试)

**Interfaces:**
- Consumes: `QoderWorkWatcher`(现有,`Sources/AppShellKit/QoderWorkSource.swift:116`)
- Produces: 无新接口——为 Task 2 泛化重构提供行为回归网

- [ ] **Step 1: 写 4 个失败/通过的行为测试**(现有实现应直接通过——这是钉死现状,不是驱动新行为)

在 `QoderWorkDBReaderTests.swift` 文件末尾(class 内)追加:

```swift
    // ── 评审 B4:DBPollWatcher 泛化前的行为回归网 ──

    /// 复活语义:running → 消失(stale)→ 复活,必须重新 emit running(3 条精确序列)。
    /// 依赖 lastEmitted.removeValue 这一行为——泛化时最易丢。
    func test_watcher_reappearAfterGhost_reEmitsRunning() {
        var rows: [QoderWorkChatRow] = [
            QoderWorkChatRow(chatId: "c1", name: "任务", projectPath: "/w",
                             sessionId: "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34", updatedAt: 1000)
        ]
        var emitted: [ScanResult] = []
        let watcher = QoderWorkWatcher(
            read: { rows }, root: "/root", now: { 1010 },
            emit: { emitted.append($0) })
        watcher.scanOnce()                                   // running
        rows = []
        watcher.scanOnce()                                   // ghost → stale
        rows = [QoderWorkChatRow(chatId: "c1", name: "任务", projectPath: "/w",
                                 sessionId: "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34", updatedAt: 1005)]
        watcher.scanOnce()                                   // 复活 → 必须重新 emit
        let key = SessionKey(agent: "qoder-work", root: "/root",
                             sessionId: "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34")
        XCTAssertEqual(emitted, [
            .observe(state: .running, key: key, cwd: "/w", title: "任务"),
            .observe(state: .stale, key: key, cwd: nil, title: nil),
            .observe(state: .running, key: key, cwd: "/w", title: "任务"),
        ], "消失后复活必须重新 emit(lastEmitted 须被 stale 清除)")
    }

    /// 读失败轮(nil)夹在中间:失败轮绝不发幽灵 stale;行真正消失的 stale 恰好 1 条、发生在恢复轮。
    func test_watcher_readFailureRound_thenEmptyRows_staleExactlyOnceOnRecovery() {
        var phase = 0
        var emitted: [ScanResult] = []
        let watcher = QoderWorkWatcher(
            read: {
                switch phase {
                case 0: return [QoderWorkChatRow(chatId: "c1", name: nil, projectPath: nil,
                                                 sessionId: nil, updatedAt: 1000)]
                case 1: return nil          // 锁抖动半读
                default: return []          // 恢复,行确实没了
                }
            },
            root: "/r", now: { 1010 }, emit: { emitted.append($0) })
        watcher.scanOnce(); phase = 1
        watcher.scanOnce(); phase = 2       // nil 轮:整轮跳过,不 emit
        watcher.scanOnce()
        let staleCount = emitted.filter {
            if case .observe(state: .stale, _, _, _) = $0 { return true }; return false
        }.count
        XCTAssertEqual(emitted.count, 2, "running + stale,失败轮零 emit")
        XCTAssertEqual(staleCount, 1, "stale 恰好 1 条且在恢复轮")
    }

    /// 双 key 交错:一个转态 + 一个消失,同轮 emit 集合精确。
    func test_watcher_twoKeys_transitionAndGhost_sameRound() {
        let idA = "aaaaaaaa-0000-0000-0000-000000000001"
        let idB = "bbbbbbbb-0000-0000-0000-000000000002"
        var rows: [QoderWorkChatRow] = [
            QoderWorkChatRow(chatId: "a", name: "A", projectPath: "/a", sessionId: idA, updatedAt: 1000),
            QoderWorkChatRow(chatId: "b", name: "B", projectPath: "/b", sessionId: idB, updatedAt: 1000),
        ]
        var emitted: [ScanResult] = []
        let watcher = QoderWorkWatcher(
            read: { rows }, root: "/r", now: { 1010 },
            emit: { emitted.append($0) })
        watcher.scanOnce()
        XCTAssertEqual(emitted.count, 2, "首轮两条 running")
        emitted.removeAll()
        // A 转 waitingStop(age 进入 120..1800),B 消失。
        rows = [QoderWorkChatRow(chatId: "a", name: "A", projectPath: "/a", sessionId: idA, updatedAt: 700)]
        watcher.scanOnce()
        let keyA = SessionKey(agent: "qoder-work", root: "/r", sessionId: idA)
        let keyB = SessionKey(agent: "qoder-work", root: "/r", sessionId: idB)
        XCTAssertTrue(emitted.contains(.observe(state: .waitingStop, key: keyA, cwd: "/a", title: "A")))
        XCTAssertTrue(emitted.contains(.observe(state: .stale, key: keyB, cwd: nil, title: nil)))
        XCTAssertEqual(emitted.count, 2)
    }

    /// start 幂等(源码注释宣称"测试评审 M6"但测试缺席——补上)+ stop 后不再 emit。
    func test_watcher_startIdempotent_stopSilences() {
        var emitted = 0
        let watcher = QoderWorkWatcher(
            read: { [QoderWorkChatRow(chatId: "c", name: nil, projectPath: nil,
                                      sessionId: nil, updatedAt: 1000)] },
            root: "/r", now: { 1001 }, emit: { _ in emitted += 1 })
        watcher.start(every: 0.05)
        watcher.start(every: 0.05)   // 幂等:不得产生双 timer
        let exp = expectation(description: "first tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        watcher.stop()
        let after = emitted
        let exp2 = expectation(description: "silence after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { exp2.fulfill() }
        wait(for: [exp2], timeout: 2)
        // 同 key 同态差分不重复 emit,所以只断言 stop 后无新增(双 timer 会因竞态多次进 scanOnce
        // ——首轮 emit 1 次后差分抑制,无法用计数抓双 timer;用 stop 后静默 + 不崩来钉行为)。
        XCTAssertEqual(emitted, after, "stop 后不得再 emit")
        XCTAssertGreaterThanOrEqual(emitted, 1)
    }
```

- [ ] **Step 2: 跑测试确认全绿**(现状钉死型测试,应直接通过;若红,先按「测试是规范」判断是测试写错还是现实现有 bug,有 bug 即修)

Run: `swift test --filter QoderWorkDBReaderTests 2>&1 | tail -5`
Expected: 全部 PASS(原有 4-5 个 + 新增 4 个)

- [ ] **Step 3: 提交**

```bash
git add Tests/AppShellKitTests/QoderWorkDBReaderTests.swift
git commit -m "test(m3c+): QoderWorkWatcher 回归网补齐——复活重emit/失败轮零幽灵/双key交错/start幂等(评审B4,泛化前置)"
```

---

### Task 2: DBPollWatcher 泛化,QoderWorkWatcher 委托

**Files:**
- Create: `Sources/AppShellKit/DBPollWatcher.swift`
- Modify: `Sources/AppShellKit/QoderWorkSource.swift`(QoderWorkWatcher 改委托,删除其内部 timer/差分实现)
- Test: `Tests/AppShellKitTests/DBPollWatcherTests.swift`(新)

**Interfaces:**
- Consumes: `ScanResult`/`ScanState`/`SessionKey`(AgentPetCore)
- Produces: `DBPollWatcher.init(scan: @escaping (Double) -> [ScanResult]?, now: @escaping () -> Double, emit: @escaping (ScanResult) -> Void)`、`scanOnce()`、`start(every: Double)`、`stop()`。Task 8 的 OpenCode 接线直接用它。

- [ ] **Step 1: 写失败测试**(新文件,3 条直测泛化本体)

```swift
import XCTest
@testable import AppShellKit
import AgentPetCore

/// DBPollWatcher(泛化自 QoderWorkWatcher):轮询/差分/幽灵对账的通用件。
/// 契约:timer queue=.main、start 幂等、scan 返回 nil 整轮跳过。
final class DBPollWatcherTests: XCTestCase {

    private func key(_ id: String) -> SessionKey {
        SessionKey(agent: "x", root: "/r", sessionId: id)
    }

    func test_diffSuppression_and_ghost() {
        var results: [ScanResult] = [.observe(state: .running, key: key("s1"), cwd: nil, title: nil)]
        var emitted: [ScanResult] = []
        let w = DBPollWatcher(scan: { _ in results }, now: { 0 }, emit: { emitted.append($0) })
        w.scanOnce()
        w.scanOnce()   // 同态:差分抑制
        XCTAssertEqual(emitted.count, 1)
        results = []
        w.scanOnce()   // 幽灵 → stale
        XCTAssertEqual(emitted.last, .observe(state: .stale, key: key("s1"), cwd: nil, title: nil))
        XCTAssertEqual(emitted.count, 2)
    }

    func test_scanNil_skipsRound_noGhost() {
        var results: [ScanResult]? = [.observe(state: .running, key: key("s1"), cwd: nil, title: nil)]
        var emitted: [ScanResult] = []
        let w = DBPollWatcher(scan: { _ in results }, now: { 0 }, emit: { emitted.append($0) })
        w.scanOnce()
        results = nil
        w.scanOnce()   // 整轮跳过
        XCTAssertEqual(emitted.count, 1, "nil 轮不 emit、不发幽灵 stale")
    }

    func test_nowIsPassedToScan() {
        var seenNow: Double = -1
        let w = DBPollWatcher(scan: { now in seenNow = now; return [] }, now: { 42 }, emit: { _ in })
        w.scanOnce()
        XCTAssertEqual(seenNow, 42)
    }

    /// 幂等直测(spec §5:泛化本体三条之一;评审:只靠委托层回归网,QoderWorkWatcher 被删即失防线)。
    func test_start_idempotent_stopSilences() {
        var emitted = 0
        let w = DBPollWatcher(
            scan: { [self] _ in [.observe(state: .running, key: key("s1"), cwd: nil, title: nil)] },
            now: { 0 }, emit: { _ in emitted += 1 })
        w.start(every: 0.05)
        w.start(every: 0.05)   // 幂等:不得产生双 timer
        let exp = expectation(description: "first tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        w.stop()
        let after = emitted
        let exp2 = expectation(description: "silence after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { exp2.fulfill() }
        wait(for: [exp2], timeout: 2)
        XCTAssertEqual(emitted, after, "stop 后不得再 emit")
        XCTAssertGreaterThanOrEqual(emitted, 1)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter DBPollWatcherTests 2>&1 | tail -5`
Expected: 编译失败 `cannot find 'DBPollWatcher'`

- [ ] **Step 3: 实现 DBPollWatcher + QoderWorkWatcher 委托**

`Sources/AppShellKit/DBPollWatcher.swift`(新):

```swift
import Foundation
import AgentPetCore

/// 通用 DB 轮询器(泛化自 QoderWorkWatcher,评审 B4 回归网先行后重构):
/// 定时轮询 → scan 闭包(读+纯扫描)→ 差分 emit + 幽灵对账。
/// 契约(随泛化保持,架构评审):timer `queue: .main`;`start` 幂等(stop-first);
/// scan 返回 nil(如写锁竞争半读)→ 整轮跳过,不差分、不发幽灵 stale。
public final class DBPollWatcher {
    private let scan: (Double) -> [ScanResult]?
    private let now: () -> Double
    private let emit: (ScanResult) -> Void

    private var lastEmitted: [SessionKey: ScanState] = [:]
    private var timer: DispatchSourceTimer?

    public init(
        scan: @escaping (Double) -> [ScanResult]?,
        now: @escaping () -> Double,
        emit: @escaping (ScanResult) -> Void
    ) {
        self.scan = scan; self.now = now; self.emit = emit
    }

    public func scanOnce() {
        guard let results = scan(now()) else { return }
        var observed: Set<SessionKey> = []
        for result in results {
            guard case .observe(let state, let key, _, _) = result else { continue }
            observed.insert(key)
            if lastEmitted[key] != state {
                emit(result)
                lastEmitted[key] = state
            }
        }
        let ghosts = lastEmitted.keys.filter { !observed.contains($0) }
        for key in ghosts {
            emit(.observe(state: .stale, key: key, cwd: nil, title: nil))
            lastEmitted.removeValue(forKey: key)
        }
    }

    public func start(every interval: Double) {
        stop()  // 幂等:重复 start 不产生双 timer
        let src = DispatchSource.makeTimerSource(queue: .main)
        src.schedule(deadline: .now() + interval, repeating: interval)
        src.setEventHandler { [weak self] in self?.scanOnce() }
        src.resume()
        timer = src
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }
}
```

`QoderWorkSource.swift` 中 `QoderWorkWatcher` 整体替换为委托(公开签名不变,Task 1 回归网必须全绿):

```swift
/// 定时轮询 agents.db → 纯扫描 → 差分 emit。实现已泛化为 DBPollWatcher,此处保持公开签名委托。
public final class QoderWorkWatcher {
    private let inner: DBPollWatcher

    public init(
        read: @escaping () -> [QoderWorkChatRow]?,
        root: String,
        now: @escaping () -> Double,
        emit: @escaping (ScanResult) -> Void,
        runningWindow: Double = 120,
        idleWindow: Double = 1800
    ) {
        inner = DBPollWatcher(
            scan: { now in
                read().map {
                    QoderWorkScanner.scan(rows: $0, root: root, now: now,
                                          runningWindow: runningWindow, idleWindow: idleWindow)
                }
            },
            now: now, emit: emit)
    }

    public func scanOnce() { inner.scanOnce() }
    public func start(every interval: Double) { inner.start(every: interval) }
    public func stop() { inner.stop() }
}
```

- [ ] **Step 4: 跑测试**

Run: `swift test --filter "DBPollWatcherTests|QoderWorkDBReaderTests" 2>&1 | tail -5`
Expected: 全 PASS(含 Task 1 的 4 条回归)

- [ ] **Step 5: 全量测试 + 提交**

Run: `swift test 2>&1 | tail -3` → 全绿

```bash
git add Sources/AppShellKit/DBPollWatcher.swift Sources/AppShellKit/QoderWorkSource.swift Tests/AppShellKitTests/DBPollWatcherTests.swift
git commit -m "refactor(m3c+): 轮询/差分/幽灵对账泛化为 DBPollWatcher,QoderWorkWatcher 委托(公开签名不变,回归网全绿)"
```

---

### Task 3: SessionIdRule(AgentPetCore)+ 两处 UUID 校验收敛

**Files:**
- Create: `Sources/AgentPetCore/Terminal/SessionIdRule.swift`
- Modify: `Sources/AgentPetCore/Terminal/ResumeCommand.swift`(isValidUUID 委托)
- Modify: `Sources/AppShellKit/AgentManifest.swift`(isValidUUID 委托)
- Test: `Tests/AgentPetCoreTests/SessionIdRuleTests.swift`(新)

**Interfaces:**
- Produces: `public enum SessionIdRule: Equatable { case uuid; case prefixedBase62(prefix: String, length: Int) }`,`public func validate(_ s: String) -> Bool`。**`length` 指前缀外位数**(opencode:26,全长 30)。Task 4/5 依赖。

- [ ] **Step 1: 写失败测试**(新文件,对抗语料按 spec §5 清单逐条)

```swift
import XCTest
@testable import AgentPetCore

/// SessionIdRule:恢复命令 id 白名单(防注入红线)。字符集白名单逐 Unicode 标量,
/// 不用字素计数(组合字符欺骗)、不用正则(ReDoS/转义面)。
final class SessionIdRuleTests: XCTestCase {

    private let ses = SessionIdRule.prefixedBase62(prefix: "ses_", length: 26)
    /// 12 hex + 14 base62 = 26 位(上游真实生成形态,混大小写)。
    private let valid26 = "0189f3ab2c4dXyZ01234abcDEF"

    // ── 正例 ──
    func test_valid_sesId() { XCTAssertTrue(ses.validate("ses_" + valid26)) }
    func test_valid_allDigits() { XCTAssertTrue(ses.validate("ses_" + String(repeating: "9", count: 26))) }

    // ── 前缀 ──
    func test_prefixCaseSensitive() {
        XCTAssertFalse(ses.validate("SES_" + valid26))
        XCTAssertFalse(ses.validate("Ses_" + valid26))
    }
    func test_prefixOnly_andEmpty() {
        XCTAssertFalse(ses.validate("ses_"))
        XCTAssertFalse(ses.validate(""))
    }
    func test_fullwidthPrefix_rejected() { XCTAssertFalse(ses.validate("ｓｅｓ_" + valid26)) }

    // ── 长度(length=前缀外;全长 30 当 26 传是 off-by-4,显式钉死)──
    func test_length25_rejected() { XCTAssertFalse(ses.validate("ses_" + String(valid26.dropLast()))) }
    func test_length27_rejected() { XCTAssertFalse(ses.validate("ses_" + valid26 + "a")) }
    func test_fullLength30AsBody_rejected() {
        XCTAssertFalse(ses.validate("ses_" + "ses_" + valid26))  // 有人把全长 30 串再拼前缀
    }

    // ── 字符集 ──
    func test_hyphen_rejected() { XCTAssertFalse(ses.validate("ses_-" + String(valid26.dropLast()))) }
    func test_underscoreInBody_rejected() { XCTAssertFalse(ses.validate("ses_" + String(valid26.dropLast()) + "_")) }
    func test_embeddedNUL_rejected() {
        XCTAssertFalse(ses.validate("ses_ab\u{0}" + String(repeating: "c", count: 23)))
    }
    func test_fullwidthLetterInBody_rejected() {
        XCTAssertFalse(ses.validate("ses_" + String(valid26.dropLast()) + "Ｆ"))
    }
    /// é = e + U+0301:字素数 26 但标量 27——钉死实现必须逐标量,不得用字素计数。
    func test_combiningCharacter_rejected() {
        XCTAssertFalse(ses.validate("ses_" + String(valid26.dropLast()) + "e\u{0301}"))
    }
    func test_shellInjection_rejected() {
        // "$(id)" 5 位 + 21 个 a = 26 位:长度合法、字符集非法——确保拒绝理由是字符集。
        XCTAssertFalse(ses.validate("ses_$(id)" + String(repeating: "a", count: 21)))
    }

    // ── .uuid 委托回归(既有语料在 ResumeCommand/AgentManifest 测试中,此处钉枚举本体)──
    func test_uuid_valid() { XCTAssertTrue(SessionIdRule.uuid.validate("8dd7ca5f-e655-47b7-8a5f-ad28336c1d34")) }
    func test_uuid_fullwidthHex_rejected() {
        XCTAssertFalse(SessionIdRule.uuid.validate("８dd7ca5f-e655-47b7-8a5f-ad28336c1d34"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter SessionIdRuleTests 2>&1 | tail -3`
Expected: 编译失败 `cannot find 'SessionIdRule'`

- [ ] **Step 3: 实现**

`Sources/AgentPetCore/Terminal/SessionIdRule.swift`(新):

```swift
import Foundation

/// 会话 ID 白名单规则(防注入红线的共享表达;ResumeCommand 与 AgentManifest 共用)。
/// 校验失败 → 恢复命令渲染返回 nil。M4 JSON Schema 化预定按
/// {prefix, charset(封闭枚举), minLength/maxLength} 建模(开源评审:防单案例锁死),
/// 本枚举是其 Swift 先行形态。不用正则:避免 ReDoS 与转义面。
public enum SessionIdRule: Equatable {
    /// 严格 UUID(8-4-4-4-12,仅 ASCII hex——全角十六进制必须被拒,评审 m9 语料)。
    case uuid
    /// 前缀 + 定长 ASCII base62。`length` 指**前缀外**位数(opencode:"ses_"+26,全长 30)。
    /// 逐 Unicode 标量白名单:字素计数会被组合字符欺骗(é = e+U+0301)。
    case prefixedBase62(prefix: String, length: Int)

    public func validate(_ s: String) -> Bool {
        switch self {
        case .uuid:
            let groups = [8, 4, 4, 4, 12]
            let parts = s.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == groups.count else { return false }
            for (part, expected) in zip(parts, groups) {
                guard part.count == expected, part.allSatisfy({ c in
                    (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
                }) else { return false }
            }
            return true
        case .prefixedBase62(let prefix, let length):
            guard s.hasPrefix(prefix) else { return false }
            let body = s.dropFirst(prefix.count).unicodeScalars
            guard body.count == length else { return false }
            return body.allSatisfy { c in
                (c >= "0" && c <= "9") || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
            }
        }
    }
}
```

`ResumeCommand.swift`:`isValidUUID` 函数体替换为委托(签名与调用点不动):

```swift
    /// 严格 UUID 校验(收敛至 SessionIdRule.uuid,评审:消除双份实现)。
    private static func isValidUUID(_ s: String) -> Bool {
        SessionIdRule.uuid.validate(s)
    }
```

`AgentManifest.swift`:同样委托(保留 `static func isValidUUID` 供既有测试直呼):

```swift
    /// 严格 UUID(收敛至 AgentPetCore.SessionIdRule.uuid)。
    static func isValidUUID(_ s: String) -> Bool {
        SessionIdRule.uuid.validate(s)
    }
```

(删除两处原手写 hex 循环体。⚠️ `AgentManifest.swift` 顶部目前**只有** `import Foundation`——需**新增** `import AgentPetCore`(评审:计划初稿误称"已有";AppShellKit target 本就依赖 AgentPetCore,分层合法):

```swift
import Foundation
import AgentPetCore   // SessionIdRule 收敛委托所需
```
)

- [ ] **Step 4: 跑测试**

Run: `swift test --filter "SessionIdRuleTests|AgentManifestTests|ResumeCommand" 2>&1 | tail -3`
Expected: 全 PASS(含既有全角 UUID 拒绝语料——委托后必须原样全绿)

- [ ] **Step 5: 全量 + 提交**

Run: `swift test 2>&1 | tail -3` → 全绿

```bash
git add Sources/AgentPetCore/Terminal/SessionIdRule.swift Sources/AgentPetCore/Terminal/ResumeCommand.swift Sources/AppShellKit/AgentManifest.swift Tests/AgentPetCoreTests/SessionIdRuleTests.swift
git commit -m "feat(m3c+): SessionIdRule 白名单枚举入核心,ResumeCommand/AgentManifest 双份 UUID 校验收敛委托"
```

---

### Task 4: ResumeCommand 支持 opencode(带目录位置参数 + display shell 引用)

**Files:**
- Modify: `Sources/AgentPetCore/Terminal/ResumeCommand.swift`
- Test: `Tests/AgentPetCoreTests/`(找到现有 ResumeCommand 测试文件追加;若无则新建 `ResumeCommandTests.swift`,先 `grep -rln "ResumeCommand" Tests/` 确认)

**Interfaces:**
- Consumes: `SessionIdRule`(Task 3)
- Produces: `ResumeCommand.argv(agent: String, sessionId: String, directory: String? = nil) -> [String]?`、`display(agent:sessionId:directory:) -> String?`(默认参数保证既有调用点零改动编译通过)。Task 5 一致性测试、Task 8 GUI 依赖。

- [ ] **Step 1: 写失败测试**(追加)

```swift
    // ── opencode(M3-C+):id 规则 ses_+26;目录敏感 → 位置参数;display 引号 ──

    func test_opencode_argv_withDirectory() {
        XCTAssertEqual(
            ResumeCommand.argv(agent: "opencode",
                               sessionId: "ses_0189f3ab2c4dXyZ01234abcDEF",
                               directory: "/Users/x/proj"),
            ["opencode", "/Users/x/proj", "--session", "ses_0189f3ab2c4dXyZ01234abcDEF"])
    }

    func test_opencode_argv_withoutDirectory_degrades() {
        XCTAssertEqual(
            ResumeCommand.argv(agent: "opencode", sessionId: "ses_0189f3ab2c4dXyZ01234abcDEF"),
            ["opencode", "--session", "ses_0189f3ab2c4dXyZ01234abcDEF"])
    }

    /// 交叉拒绝(测试评审:防"先选规则"重构后规则窜线)。
    func test_crossRules_rejected() {
        XCTAssertNil(ResumeCommand.argv(agent: "opencode",
                                        sessionId: "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34"))
        XCTAssertNil(ResumeCommand.argv(agent: "claude-code",
                                        sessionId: "ses_0189f3ab2c4dXyZ01234abcDEF"))
        XCTAssertNil(ResumeCommand.argv(agent: "qoder-cli",
                                        sessionId: "ses_0189f3ab2c4dXyZ01234abcDEF"))
    }

    /// display:含空格目录必须单引号引用,不得裸空格 join 产出坏命令(评审)。
    func test_opencode_display_quotesSpacedDirectory() {
        XCTAssertEqual(
            ResumeCommand.display(agent: "opencode",
                                  sessionId: "ses_0189f3ab2c4dXyZ01234abcDEF",
                                  directory: "/Users/x/My Proj"),
            "opencode '/Users/x/My Proj' --session ses_0189f3ab2c4dXyZ01234abcDEF")
    }

    func test_opencode_display_quotesSingleQuoteInDirectory() {
        XCTAssertEqual(
            ResumeCommand.display(agent: "opencode",
                                  sessionId: "ses_0189f3ab2c4dXyZ01234abcDEF",
                                  directory: "/Users/x/it's"),
            "opencode '/Users/x/it'\\''s' --session ses_0189f3ab2c4dXyZ01234abcDEF")
    }

    /// 既有 agent 的 display 不受引用逻辑影响(无 shell 元字符 → 原样)。
    func test_claude_display_unchanged() {
        XCTAssertEqual(
            ResumeCommand.display(agent: "claude", sessionId: "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34"),
            "claude --resume 8dd7ca5f-e655-47b7-8a5f-ad28336c1d34")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ResumeCommand 2>&1 | tail -5`
Expected: FAIL/编译错(argv 无 directory 参数、无 opencode case)

- [ ] **Step 3: 实现**(`ResumeCommand.swift` 整体重构为「先选规则再校验」)

```swift
import Foundation

public enum ResumeCommand {

    /// agent → id 白名单规则。未知 agent → nil(无恢复命令,不臆造)。
    private static func idRule(agent: String) -> SessionIdRule? {
        switch agent {
        case "claude", "claude-code", "qoder-cli": return .uuid
        case "opencode": return .prefixedBase62(prefix: "ses_", length: 26)
        default: return nil
        }
    }

    /// 恢复命令 argv 数组。非法 sessionId 或未知 agent → nil。
    /// opencode 目录敏感(TUI 按 cwd 解析 project 并 chdir,实测源码 tui.ts:66-79):
    /// directory 非空时作位置参数;缺席时降级为裸 --session(评审:best effort)。
    public static func argv(agent: String, sessionId: String, directory: String? = nil) -> [String]? {
        guard let rule = idRule(agent: agent), rule.validate(sessionId) else { return nil }
        switch agent {
        case "claude", "claude-code":
            return ["claude", "--resume", sessionId]
        case "qoder-cli":
            // 实测确认(qodercli v1.0.36 --help):`-r, --resume [id]`。
            return ["qodercli", "--resume", sessionId]
        case "opencode":
            if let dir = directory, !dir.isEmpty {
                return ["opencode", dir, "--session", sessionId]
            }
            return ["opencode", "--session", sessionId]
        default:
            return nil
        }
    }

    /// 展示用命令行字符串(供「复制恢复命令」)。
    /// 评审:argv 元素含空格/引号等时单引号引用('→'\''),不再裸空格 join。
    public static func display(agent: String, sessionId: String, directory: String? = nil) -> String? {
        guard let parts = argv(agent: agent, sessionId: sessionId, directory: directory) else { return nil }
        return parts.map(shellQuote).joined(separator: " ")
    }

    /// 单引号 shell 引用;纯安全字符原样(命令名/flag/合法 id 均不受影响)。
    static func shellQuote(_ s: String) -> String {
        let safeExtra: Set<Character> = ["-", "_", ".", "/", "=", ":", "@", "%", "+", ","]
        let isSafe = !s.isEmpty && s.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || safeExtra.contains(c))
        }
        if isSafe { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 严格 UUID 校验(收敛至 SessionIdRule.uuid,评审:消除双份实现)。
    private static func isValidUUID(_ s: String) -> Bool {
        SessionIdRule.uuid.validate(s)
    }
}
```

(注:`isValidUUID` 若重构后无调用点则删除,保持无警告。)

- [ ] **Step 4: 跑测试**

Run: `swift test --filter ResumeCommand 2>&1 | tail -3` → 全 PASS(既有 UUID/未知 agent 语料原样绿)

- [ ] **Step 5: 全量 + 提交**

```bash
git add Sources/AgentPetCore/Terminal/ResumeCommand.swift Tests/AgentPetCoreTests/
git commit -m "feat(m3c+): ResumeCommand 支持 opencode——ses_ 规则/目录位置参数/display 单引号引用(评审:含空格目录不产坏命令)"
```

---

### Task 5: AgentManifest——sessionIdRule 字段、{dir} 占位、openCode manifest、双源一致性测试

**Files:**
- Modify: `Sources/AppShellKit/AgentManifest.swift`
- Test: `Tests/AppShellKitTests/AgentManifestTests.swift`(追加)

**Interfaces:**
- Consumes: `SessionIdRule`(Task 3)、`ResumeCommand`(Task 4)
- Produces: `AgentManifest.sessionIdRule: SessionIdRule`(init 默认 `.uuid`);`renderResumeArgv(sessionId: String, directory: String? = nil) -> [String]?`(支持 `{dir}` 占位,nil/空目录整体省略);`AgentManifest.openCode`;builtins 含之。Task 8 依赖 `AgentManifest.dbBackedAgents`。

- [ ] **Step 1: 写失败测试**(追加到 AgentManifestTests)

```swift
    // ── M3-C+:openCode manifest 与 sessionIdRule/{dir} ──

    func test_openCode_manifest_rendersArgvWithDir() {
        XCTAssertEqual(
            AgentManifest.openCode.renderResumeArgv(sessionId: "ses_0189f3ab2c4dXyZ01234abcDEF",
                                                    directory: "/w"),
            ["opencode", "/w", "--session", "ses_0189f3ab2c4dXyZ01234abcDEF"])
    }

    func test_openCode_manifest_nilDir_omitsElement() {
        XCTAssertEqual(
            AgentManifest.openCode.renderResumeArgv(sessionId: "ses_0189f3ab2c4dXyZ01234abcDEF"),
            ["opencode", "--session", "ses_0189f3ab2c4dXyZ01234abcDEF"])
    }

    func test_openCode_manifest_rejectsUUID() {
        XCTAssertNil(AgentManifest.openCode.renderResumeArgv(
            sessionId: "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34"))
    }

    /// {dir} 占位与 {id} 同规则:只允许独立元素(评审 AI m8⑤ 同构)。
    func test_partialDirPlaceholder_rejected() {
        let m = AgentManifest(id: "x", rootsGlobs: [], tsDialect: .iso,
                              resumeArgvTemplate: ["run", "--dir={dir}", "{id}"],
                              hasStateRules: false)
        XCTAssertNil(m.renderResumeArgv(sessionId: "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34",
                                        directory: "/w"))
    }

    /// 既有 manifest 默认 .uuid,行为不变(默认参数回归)。
    func test_existingManifests_defaultUUIDRule() {
        XCTAssertEqual(AgentManifest.claude.sessionIdRule, .uuid)
        XCTAssertEqual(AgentManifest.qoderCli.sessionIdRule, .uuid)
    }

    func test_builtins_containOpenCode() {
        // glob 不重叠由既有 test_builtins_noGlobOverlap 自动扩展覆盖(评审:测试名别撒谎)。
        XCTAssertTrue(AgentManifest.builtins.contains(where: { $0.id == "opencode" }))
    }

    /// 双源一致性遍历(开源/架构评审:ResumeCommand 与 manifest 模板第三处复制的防漂移网)。
    func test_resumeCommand_manifest_consistency_allBuiltins() {
        let samples: [(agent: String, id: String, dir: String?)] = [
            ("claude-code", "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34", nil),
            ("qoder-cli", "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34", nil),
            ("opencode", "ses_0189f3ab2c4dXyZ01234abcDEF", "/w"),
            ("opencode", "ses_0189f3ab2c4dXyZ01234abcDEF", nil),
            ("qoder-work", "8dd7ca5f-e655-47b7-8a5f-ad28336c1d34", nil),  // 两边同为 nil
            ("qoder-ide", "task-abc", nil),                                // 两边同为 nil
        ]
        for s in samples {
            let manifest = AgentManifest.builtins.first { $0.id == s.agent }
            let fromCommand = ResumeCommand.argv(agent: s.agent, sessionId: s.id, directory: s.dir)
            let fromManifest = manifest?.renderResumeArgv(sessionId: s.id, directory: s.dir)
            // optional chaining 已扁平为 [String]?,直接比较(评审:?? nil 冗余)。
            XCTAssertEqual(fromCommand, fromManifest,
                           "双源漂移:\(s.agent) ResumeCommand=\(String(describing: fromCommand)) manifest=\(String(describing: fromManifest))")
        }
    }
```

(注:claude 的 ResumeCommand agent 名有 "claude"/"claude-code" 两个别名而 manifest id 是 "claude-code"——一致性样本用 "claude-code";若现有 consistency 测试已有别名处理,沿用其写法。)

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AgentManifestTests 2>&1 | tail -5`
Expected: 编译失败(无 sessionIdRule/openCode/directory 参数)

- [ ] **Step 3: 实现**(AgentManifest.swift 增改)

结构体增加字段与默认参数(放 init 末位,既有调用点零改动):

```swift
    /// 会话 id 白名单规则(默认 UUID;评审:防注入红线按 agent 可配)。
    public let sessionIdRule: SessionIdRule

    public init(id: String, rootsGlobs: [String], tsDialect: TimestampDialect,
                resumeArgvTemplate: [String]?, hasStateRules: Bool,
                sessionIdRule: SessionIdRule = .uuid) {
        self.id = id; self.rootsGlobs = rootsGlobs; self.tsDialect = tsDialect
        self.resumeArgvTemplate = resumeArgvTemplate; self.hasStateRules = hasStateRules
        self.sessionIdRule = sessionIdRule
    }
```

`renderResumeArgv` 替换:

```swift
    /// 渲染恢复命令 argv。模板缺失或 sessionId 非法 → nil。
    /// 占位符 {id}/{dir} 只允许作独立元素(部分含会静默渲染坏命令,评审 AI m8⑤)。
    /// {dir}:directory nil/空 → 该元素整体省略(opencode 目录缺席降级)。
    public func renderResumeArgv(sessionId: String, directory: String? = nil) -> [String]? {
        guard let template = resumeArgvTemplate, sessionIdRule.validate(sessionId) else { return nil }
        guard template.allSatisfy({ el in
            (!el.contains("{id}") || el == "{id}") && (!el.contains("{dir}") || el == "{dir}")
        }) else { return nil }
        var out: [String] = []
        for el in template {
            switch el {
            case "{id}": out.append(sessionId)
            case "{dir}":
                if let dir = directory, !dir.isEmpty { out.append(dir) }
            default: out.append(el)
            }
        }
        return out
    }
```

新增 manifest 与 builtins/dbBackedAgents:

```swift
    /// OpenCode(sst/opencode,**源码核实 v1.17.13 / commit 04d236c,2026-07-03**;真机实测门待过):
    /// SQLite `$XDG_DATA_HOME/opencode/opencode*.db`(默认 ~/.local/share;OPENCODE_DB 可覆盖;
    /// 非常规 channel 有后缀)。时间 epoch 毫秒;id `ses_`+26 位 base62(前缀外);
    /// 状态派生内容信号优先(part/session_message 活动 + assistant time.completed),
    /// 见 OpenCodeScanner——hasStateRules=true(非纯 mtime)。
    /// resume 目录敏感 → {dir} 位置参数(tui.ts:66-79)。读取走 OpenCodeDBReader + DBPollWatcher。
    /// ⚠️ rootsGlobs 是**文档性默认路径**(UI 展示用);实际解析含 OPENCODE_DB/XDG/launchctl
    /// 兜底,见 `OpenCodeDBReader.defaultDBPath`(开源评审:防第三方按 glob 语义消费漏发现)。
    public static let openCode = AgentManifest(
        id: "opencode",
        rootsGlobs: ["~/.local/share/opencode/opencode*.db"],
        tsDialect: .epochMillis,
        resumeArgvTemplate: ["opencode", "{dir}", "--session", "{id}"],
        hasStateRules: true,
        sessionIdRule: .prefixedBase62(prefix: "ses_", length: 26)
    )

    /// 内置注册表(无 glob 重叠)。
    public static let builtins: [AgentManifest] = [.claude, .qoderWork, .qoderCli, .qoderIDE, .openCode]

    /// DB 型 agent(会话在 SQLite 而非 jsonl 转录):
    /// 用于 ① 粗略/轮询源 waitingStop 预置已读(架构 m6 收敛,评审 B2:别再加 agent 字符串 if);
    /// ② 右键「本地摘要」隐藏(无 jsonl 转录必弹死弹窗,交互评审)。
    /// ⚠️ M4 公开契约前的**内部注册表**,非第三方接入面——M4 时应改为 manifest 字段
    ///(如 sourceKind),第三方 DB 型 agent 才能经契约声明获得同等语义(开源评审)。
    public static let dbBackedAgents: Set<String> = ["qoder-work", "opencode"]
```

- [ ] **Step 4: 跑测试**

Run: `swift test --filter AgentManifestTests 2>&1 | tail -3` → 全 PASS

- [ ] **Step 5: 全量 + 提交**

```bash
git add Sources/AppShellKit/AgentManifest.swift Tests/AppShellKitTests/AgentManifestTests.swift
git commit -m "feat(m3c+): AgentManifest 加 sessionIdRule/{dir} 占位/openCode manifest/dbBackedAgents;双源一致性遍历测试防漂移"
```

---

### Task 6: OpenCodeSessionRow + OpenCodeScanner(纯函数)

**Files:**
- Create: `Sources/AppShellKit/OpenCodeSource.swift`(本任务先放 Row+Scanner;Task 7 在同文件追加 Reader)
- Test: `Tests/AppShellKitTests/OpenCodeScannerTests.swift`(新)

**Interfaces:**
- Consumes: `ScanResult`/`ScanState`/`SessionKey`
- Produces:
  - `AssistantSignal: Equatable { case none; case inFlight; case completed }`(最后一条 assistant 消息的结构性信号,评审 v3:取代 ε 时间比较——part upsert 冻结 time_created,长操作期间时间链停摆,in-flight 布尔不受影响)
  - `OpenCodeSessionRow(sessionId: String, directory: String?, title: String?, lastActivity: Double, assistantSignal: AssistantSignal, createdAt: Double)`(时间全 Unix 秒;directory/title 空串已由 Reader 映射 nil)
  - `OpenCodeScanner.scan(rows: [OpenCodeSessionRow], root: String, now: Double, runningWindow: Double = 120, idleWindow: Double = 1800, staleHorizon: Double = 86400) -> [ScanResult]`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import AppShellKit
import AgentPetCore

/// OpenCodeScanner(spec §3.1 v3):年龄降档先于内容信号;活跃窗口内按最后 assistant 的
/// in-flight/completed 结构性信号(上游 getCurrentAssistant 同构),无信号才窗口兜底。
final class OpenCodeScannerTests: XCTestCase {

    private func row(id: String = "ses_0189f3ab2c4dXyZ01234abcDEF",
                     dir: String? = "/w", title: String? = "t",
                     activity: Double, signal: AssistantSignal = .none) -> OpenCodeSessionRow {
        OpenCodeSessionRow(sessionId: id, directory: dir, title: title,
                           lastActivity: activity, assistantSignal: signal,
                           createdAt: activity - 100)
    }

    private func scan(_ rows: [OpenCodeSessionRow], now: Double) -> [ScanResult] {
        OpenCodeScanner.scan(rows: rows, root: "/data/opencode", now: now)
    }

    private var key: SessionKey {
        SessionKey(agent: "opencode", root: "/data/opencode",
                   sessionId: "ses_0189f3ab2c4dXyZ01234abcDEF")
    }

    // ── 窗口分档(< 语义:=120 → waitingStop,=1800 → stale,=86400 → 排除;signal=.none)──
    func test_freshActivity_noSignal_running() {
        XCTAssertEqual(scan([row(activity: 1000)], now: 1050),
                       [.observe(state: .running, key: key, cwd: "/w", title: "t")])
    }
    func test_ageExactly120_noSignal_waitingStop() {
        XCTAssertEqual(scan([row(activity: 1000)], now: 1120).first,
                       .observe(state: .waitingStop, key: key, cwd: "/w", title: "t"),
                       "age == runningWindow 属 waitingStop(guard 用 <)")
    }
    func test_ageExactly1800_stale() {
        XCTAssertEqual(scan([row(activity: 1000)], now: 2800).first,
                       .observe(state: .stale, key: key, cwd: "/w", title: "t"),
                       "age == idleWindow 属 stale(常开 TUI 不蒸发,评审)")
    }
    func test_ageExactly86400_dropped() {
        XCTAssertTrue(scan([row(activity: 1000)], now: 87400).isEmpty,
                      "age == staleHorizon 排除")
    }

    // ── in-flight/completed 结构性信号(评审 B1+v3)──
    func test_inFlight_beatsWindowFallback_running() {
        // 长工具执行 500 秒无新行:时间链停摆,但 assistant 未 completed → 仍 running(评审 M1 核心)。
        XCTAssertEqual(scan([row(activity: 1000, signal: .inFlight)], now: 1500).first,
                       .observe(state: .running, key: key, cwd: "/w", title: "t"))
    }
    func test_completedWithin120s_waitingStop_notRunning() {
        // 活动 30 秒前但 assistant 已 completed → 真实完成,不等窗口。
        XCTAssertEqual(scan([row(activity: 1000, signal: .completed)], now: 1030).first,
                       .observe(state: .waitingStop, key: key, cwd: "/w", title: "t"))
    }
    func test_ageDegradationBeatsSignal() {
        // 信号存在但 age >= idleWindow → stale(年龄降档先行;in-flight 的 kill 兜底同理)。
        XCTAssertEqual(scan([row(activity: 1000, signal: .completed)], now: 3000).first,
                       .observe(state: .stale, key: key, cwd: "/w", title: "t"))
        XCTAssertEqual(scan([row(activity: 1000, signal: .inFlight)], now: 3000).first,
                       .observe(state: .stale, key: key, cwd: "/w", title: "t"),
                       "进程被 kill 后 completed 永为 NULL——in-flight 只在活跃窗口内可信")
    }

    // ── 时间边界鲁棒(QoderWork test_futureUpdatedAt 语料带过来,评审)──
    func test_futureActivity_running_noCrash() {
        XCTAssertEqual(scan([row(activity: 5000)], now: 1000).first,
                       .observe(state: .running, key: key, cwd: "/w", title: "t"))
    }
    func test_zeroAndNegativeActivity_dropped() {
        XCTAssertTrue(scan([row(activity: 0)], now: 100_000).isEmpty)
        XCTAssertTrue(scan([row(activity: -50)], now: 100_000).isEmpty)
    }
    func test_hugeActivity_noCrash() {
        _ = scan([row(activity: 9e18)], now: 1000)  // 不崩即可(future → running)
    }

    // ── key/字段 ──
    func test_nilDirAndTitle_passthrough() {
        XCTAssertEqual(scan([row(dir: nil, title: nil, activity: 1000)], now: 1010).first,
                       .observe(state: .running, key: key, cwd: nil, title: nil))
    }
    func test_orderIndependent() {
        let a = row(id: "ses_" + String(repeating: "a", count: 26), activity: 1000)
        let b = row(id: "ses_" + String(repeating: "b", count: 26), activity: 1000)
        XCTAssertEqual(scan([a, b], now: 1010).count, 2)
        XCTAssertEqual(scan([b, a], now: 1010).count, 2)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter OpenCodeScannerTests 2>&1 | tail -3`
Expected: 编译失败 `cannot find 'OpenCodeSessionRow'`

- [ ] **Step 3: 实现**(`Sources/AppShellKit/OpenCodeSource.swift` 新建)

```swift
import Foundation
import AgentPetCore

// MARK: - OpenCodeSessionRow

/// 最后一条 assistant 消息的结构性信号(上游 getCurrentAssistant 同款判据,projector.ts:134-151)。
/// 评审 v3:取代 ε 时间比较——part 的 upsert 只更新 data、time_created 冻结(projector.ts:319-324),
/// 长工具/长文本期间活动时间链停摆,任何窗口判据都会误降;in-flight 布尔不受影响。
public enum AssistantSignal: Equatable {
    case none        // 无 assistant 消息(会话刚建/降级读取)
    case inFlight    // $.time.completed IS NULL → 本轮进行中
    case completed   // 非 NULL(任意类型,ISO 串也算)→ 本轮真实完成
}

/// OpenCode(opencode.db,源码核实 v1.17.13)一条会话的轻量投影。
/// 时间为 **Unix 秒**(Reader 层已从 epoch 毫秒换算);directory/title 空串已映射 nil(约束 5)。
public struct OpenCodeSessionRow: Equatable {
    public let sessionId: String
    public let directory: String?
    public let title: String?
    /// 最近**行插入**时间:MAX(part.time_created) → session_message → session.time_updated 降级链。
    /// 仅用于年龄降档(stale/排除),不用于 running 判定(见 AssistantSignal)。
    public let lastActivity: Double
    public let assistantSignal: AssistantSignal
    public let createdAt: Double

    public init(sessionId: String, directory: String?, title: String?,
                lastActivity: Double, assistantSignal: AssistantSignal, createdAt: Double) {
        self.sessionId = sessionId; self.directory = directory; self.title = title
        self.lastActivity = lastActivity; self.assistantSignal = assistantSignal
        self.createdAt = createdAt
    }
}

// MARK: - OpenCodeScanner(纯函数)

/// 状态派生(spec §3.1 v3):
/// 1. 年龄降档先行:age>=staleHorizon 排除;age>=idleWindow → stale(灰显不蒸发;
///    亦是 in-flight 的 kill 兜底——进程死后 completed 永为 NULL,靠年龄出场)。
/// 2. 活跃窗口内:.inFlight → running;.completed → waitingStop(不等窗口);
///    .none → age<runningWindow ? running : waitingStop(窗口兜底,prompt-touch 保活)。
public enum OpenCodeScanner {
    public static func scan(
        rows: [OpenCodeSessionRow],
        root: String,
        now: Double,
        runningWindow: Double = 120,
        idleWindow: Double = 1800,
        staleHorizon: Double = 86400
    ) -> [ScanResult] {
        rows.compactMap { row in
            guard row.lastActivity > 0 else { return nil }   // 0/负值:坏数据,静默排除
            let age = now - row.lastActivity
            guard age < staleHorizon else { return nil }
            let key = SessionKey(agent: "opencode", root: root, sessionId: row.sessionId)
            let state: ScanState
            if age >= idleWindow {
                state = .stale
            } else {
                switch row.assistantSignal {
                case .inFlight:  state = .running
                case .completed: state = .waitingStop
                case .none:      state = age < runningWindow ? .running : .waitingStop
                }
            }
            return .observe(state: state, key: key, cwd: row.directory, title: row.title)
        }
    }
}
```

- [ ] **Step 4: 跑测试**

Run: `swift test --filter OpenCodeScannerTests 2>&1 | tail -3` → 全 PASS

- [ ] **Step 5: 提交**

```bash
git add Sources/AppShellKit/OpenCodeSource.swift Tests/AppShellKitTests/OpenCodeScannerTests.swift
git commit -m "feat(m3c+): OpenCodeScanner 纯函数——年龄降档先行/内容信号优先/三档stale(评审B1);时间边界鲁棒语料"
```

---

### Task 7: OpenCodeDBReader(路径解析 + WAL fixture + 读取/降级/版本探测)

**Files:**
- Modify: `Sources/AppShellKit/OpenCodeSource.swift`(追加 Reader)
- Test: `Tests/AppShellKitTests/OpenCodeDBReaderTests.swift`(新)

**Interfaces:**
- Consumes: `OpenCodeSessionRow`/`AssistantSignal`(Task 6)
- Produces:
  - `OpenCodeReadOutcome: Equatable { case ok(rows: [OpenCodeSessionRow], maxMigrationId: String?); case failed(maxMigrationId: String?) }` + 便捷访问器 `var rows: [OpenCodeSessionRow]?`、`var maxMigrationId: String?`(评审 Blocker:失败路径必须携带版本信号——migration 探测**先于**主查询,否则 schema 破坏性升级时「版本过新」永不可达)
  - `OpenCodeDBReader(dbPath: String, busyTimeoutMs: Int32 = 200)`,`read() -> OpenCodeReadOutcome`(不存在/空库 → `.ok(rows: [], ...)`;打不开/半读 → `.failed`)
  - `OpenCodeDBReader.defaultDBPath(env:launchctlGetenv:listDir:) -> String`(评审 Blocker:GUI 进程读不到 shell env,补 `launchctl getenv` 探测缝)
  - `OpenCodeDBReader.verifiedMaxMigrationId == "20260622202450_simplify_session_input"`(⚠️ **全名**——上游落库 id 是 `<14位时间戳>_<名字>`,`migration.ts:30-35`;裸时间戳比较在已验证版本上恒误报,评审 Blocker)+ `isNewerThanVerified(_ maxId: String) -> Bool`(取两侧前导数字前缀比较)
- Task 8/8b 接线依赖全部。

**`verifiedMaxMigrationId` 维护流程(写进该常量 doc 注释,评审:没有流程这个值必然烂掉——上游 ~8 迁移/月)**:上游出新迁移后 ① 重跑 spec §2 事实核对;② 常量改为新迁移**全名**;③ `APET_OPENCODE_LIVE=1 swift test --filter OpenCodeLiveTests` 重跑;④ 同步 README「已验证版本」行。

- [ ] **Step 1: 写失败测试**(新文件;fixture 用 WAL + 上游 schema.gen.ts 蓝本的最小充分列集)

```swift
import XCTest
import SQLite3
@testable import AppShellKit
import AgentPetCore

/// OpenCodeDBReader:对着按上游 schema 造的临时 WAL SQLite 读取。
/// fixture DDL 来源:https://github.com/sst/opencode(MIT,Copyright (c) 2025 opencode)
/// packages/core/src/database/schema.gen.ts @ 04d236c——与真表在 apet 触达列上同形
/// (含 NOT NULL 约束),其余列省略;真机实测门后以 `.schema` 快照校正。
final class OpenCodeDBReaderTests: XCTestCase {

    private var dbPath: String!

    private func exec(_ db: OpaquePointer?, _ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, file: file, line: line)
    }

    /// 建标准 fixture(WAL;session/part/session_message/migration 四表)。
    /// 注:关闭最后一个连接时 SQLite 自动 checkpoint 并删 -wal——journal_mode=WAL 持久化在库头;
    /// 「已提交未 checkpoint」形态由专项测试用常开写者连接构造(评审:勿声称此处保留 -wal)。
    private func makeFixture(populate: (OpaquePointer?) -> Void) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        exec(db, "PRAGMA journal_mode=WAL;")
        exec(db, """
        CREATE TABLE session (
          id text PRIMARY KEY, project_id text NOT NULL, parent_id text,
          directory text NOT NULL, title text NOT NULL, version text NOT NULL,
          time_created integer NOT NULL, time_updated integer NOT NULL,
          time_archived integer);
        CREATE TABLE part (
          id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL,
          time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
        CREATE TABLE session_message (
          id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL,
          seq integer NOT NULL, time_created integer NOT NULL,
          time_updated integer NOT NULL, data text NOT NULL);
        CREATE TABLE migration (id text PRIMARY KEY, time_completed integer NOT NULL);
        """)
        populate(db)
        sqlite3_close_v2(db)
    }

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("apet-oc-\(UUID().uuidString).db").path
    }
    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        super.tearDown()
    }

    // ── 正常读:活动降级链 + assistant 信号 + 毫秒→秒 + 全名 migration id ──
    func test_readsRow_activityFromPart_signalFromAssistantMessage() throws {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_a', 'p1', NULL, '/w', '修 bug', '1.17.13',
                                        1782554400000, 1782554400000, NULL);
            INSERT INTO part VALUES ('prt_1', 'msg_1', 'ses_a', 1782554460000, 1782554460000, '{}');
            INSERT INTO session_message VALUES
              ('msg_0', 'ses_a', 'user', 1, 1782554400000, 1782554400000, '{}'),
              ('msg_1', 'ses_a', 'assistant', 2, 1782554455000, 1782554455000,
               '{"time":{"created":1782554455000,"completed":1782554460123}}');
            INSERT INTO migration VALUES ('20260622202450_simplify_session_input', 1782554400000);
            """)
        }
        let outcome = OpenCodeDBReader(dbPath: dbPath).read()
        let rows = try XCTUnwrap(outcome.rows)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.sessionId, "ses_a")
        XCTAssertEqual(row.directory, "/w")
        XCTAssertEqual(row.title, "修 bug")
        // 整千毫秒可精确相等(评审:毫秒精度断言写法)。
        XCTAssertEqual(row.lastActivity, 1782554460.0)
        XCTAssertEqual(row.assistantSignal, .completed)
        XCTAssertEqual(row.createdAt, 1782554400.0)
        XCTAssertEqual(outcome.maxMigrationId, "20260622202450_simplify_session_input",
                       "⚠️ 上游 id 是全名,非裸时间戳(评审 Blocker)")
    }

    func test_assistantInFlight_completedNull() throws {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1782554400000,1782554400000,NULL);
            INSERT INTO session_message VALUES
              ('msg_1','ses_a','assistant',2,1782554455000,1782554455000,
               '{"time":{"created":1782554455000}}');
            """)
        }
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        XCTAssertEqual(row.assistantSignal, .inFlight, "completed IS NULL → 进行中(评审 M1)")
    }

    func test_noAssistantMessage_signalNone() throws {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1000000,2000000,NULL);
            INSERT INTO session_message VALUES ('msg_0','ses_a','user',1,2000000,2000000,'{}');
            """)
        }
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        XCTAssertEqual(row.assistantSignal, AssistantSignal.none)
        XCTAssertEqual(row.lastActivity, 2000, "user 消息行插入时间进活动链")
    }

    /// 方言一致性 tripwire(评审:防 /1000 两次的静默失败——那会让面板永远空)。
    func test_millisecondConversion_matchesTimestampDialect() throws {
        makeFixture { db in
            exec(db, "INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1782554400123,1782554400123,NULL);")
        }
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        let viaDialect = try XCTUnwrap(TimestampDialect.epochMillis.parse("1782554400123"))
        XCTAssertEqual(row.lastActivity, viaDialect, accuracy: 0.0005,
                       "Reader 换算与 manifest 方言(epochMillis)必须同一真相")
    }

    // ── WAL:已提交、未 checkpoint、只在 -wal 的行 → 读者可见(评审:真机常态形态)──
    func test_WAL_committedButUncheckpointedRow_visible() {
        makeFixture { _ in }                       // 只建表
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &writer), SQLITE_OK)
        defer { sqlite3_close_v2(writer) }         // 保持打开直到读取完成
        exec(writer, "PRAGMA wal_autocheckpoint=0;")
        exec(writer, "INSERT INTO session VALUES ('ses_w','p',NULL,'/w','t','v',1000000,1000000,NULL);")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath + "-wal"),
                      "行已 COMMIT 但只存在于 -wal")
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read().rows?.map(\.sessionId), ["ses_w"])
    }

    func test_WAL_concurrentWriteTransaction_readStillSucceeds() {
        makeFixture { db in
            exec(db, "INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1000000,1000000,NULL);")
        }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &writer), SQLITE_OK)
        exec(writer, "BEGIN IMMEDIATE;")
        exec(writer, "INSERT INTO session VALUES ('ses_b','p',NULL,'/w','t2','v',2000000,2000000,NULL);")
        defer { exec(writer, "ROLLBACK;"); sqlite3_close_v2(writer) }
        // WAL 下读者取快照,不被写事务阻塞(评审:opencode 正在跑时轮询不空转)。
        XCTAssertNotNil(OpenCodeDBReader(dbPath: dbPath).read().rows)
    }

    // ── 失败 ≠ 空:三态语义(评审:失败路径必须携带版本信号)──
    func test_missingFile_okEmptyRows() {
        XCTAssertEqual(OpenCodeDBReader(dbPath: "/nonexistent/oc.db").read(),
                       .ok(rows: [], maxMigrationId: nil))
    }
    func test_emptyDatabaseNoSessionTable_okEmptyRows() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)  // 建空库即关
        sqlite3_close_v2(db)
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read(),
                       .ok(rows: [], maxMigrationId: nil),
                       "空库=「装了没跑过」是常态,归 ok([]) 而非 failed(否则每轮永久跳过)")
    }
    func test_garbageFile_failed() {
        try! "not a sqlite db".write(toFile: dbPath, atomically: true, encoding: .utf8)
        guard case .failed = OpenCodeDBReader(dbPath: dbPath).read() else {
            return XCTFail("垃圾文件应 failed")
        }
    }
    /// 评审 Blocker 的规范化:缺列(schema 破坏性演进)→ failed,但 **migration 版本信号必须带出来**。
    func test_missingColumns_failedButCarriesMigrationId() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        exec(db, "CREATE TABLE session (id text PRIMARY KEY, title text);")
        exec(db, "CREATE TABLE migration (id text PRIMARY KEY, time_completed integer NOT NULL);")
        exec(db, "INSERT INTO migration VALUES ('20990101000000_future_break', 1);")
        sqlite3_close_v2(db)
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read(),
                       .failed(maxMigrationId: "20990101000000_future_break"),
                       "migration 探测先于主查询——「版本过新」提示的唯一数据来源")
    }
    func test_busyExclusiveLock_failed() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        exec(db, "CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, directory text NOT NULL, title text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer);")
        exec(db, "BEGIN EXCLUSIVE;")
        defer { exec(db, "ROLLBACK;"); sqlite3_close_v2(db) }
        guard case .failed = OpenCodeDBReader(dbPath: dbPath, busyTimeoutMs: 0).read() else {
            return XCTFail("非 WAL + EXCLUSIVE 应 failed(半读不可信)")
        }
    }

    // ── 辅助表缺失 → session-only 降级(评审:reset 型迁移防御)──
    func test_auxTablesMissing_degradesToSessionOnly() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        exec(db, "CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, directory text NOT NULL, title text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer);")
        exec(db, "INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1000000,2000000,NULL);")
        sqlite3_close_v2(db)
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        XCTAssertEqual(row.lastActivity, 2000, "降级:活动=time_updated")
        XCTAssertEqual(row.assistantSignal, AssistantSignal.none, "降级:无消息信号,回窗口兜底")
    }

    // ── 过滤 ──
    func test_filters_parentAndArchived() {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_a','p',NULL,'/w','t','v',1000000,1000000,NULL);
            INSERT INTO session VALUES ('ses_sub','p','ses_a','/w','子','v',1000000,1000000,NULL);
            INSERT INTO session VALUES ('ses_arc','p',NULL,'/w','归档','v',1000000,1000000,999);
            """)
        }
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read().rows?.map(\.sessionId), ["ses_a"])
    }
    func test_archivedZero_hidden_parentEmptyString_hidden() {
        // 上游自身 truthy/isNull 不一致;我们随 list 语义:非 NULL 即隐藏(含 0/空串)。钉死为决策。
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_z','p',NULL,'/w','t','v',1000000,1000000,0);
            INSERT INTO session VALUES ('ses_e','p','','/w','t','v',1000000,1000000,NULL);
            """)
        }
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read().rows, [])
    }

    // ── 空串映射(约束 5)+ 占位标题 + 内嵌 NUL ──
    func test_emptyDirectoryAndTitle_mapNil() throws {
        makeFixture { db in
            exec(db, "INSERT INTO session VALUES ('ses_a','p',NULL,'','',  'v',1000000,1000000,NULL);")
        }
        let row = try XCTUnwrap(OpenCodeDBReader(dbPath: dbPath).read().rows?.first)
        XCTAssertNil(row.directory, "legacy 空目录(上游 path.ts 注释)→ nil ≠ \"\"")
        XCTAssertNil(row.title)
    }
    func test_placeholderTitle_keptVerbatim() {
        makeFixture { db in
            exec(db, "INSERT INTO session VALUES ('ses_a','p',NULL,'/w','New session - 2026-07-03T10:00:00.000Z','v',1000000,1000000,NULL);")
        }
        XCTAssertEqual(OpenCodeDBReader(dbPath: dbPath).read().rows?.first?.title,
                       "New session - 2026-07-03T10:00:00.000Z",
                       "决策:不模式匹配上游占位文案,原样展示(spec §2)")
    }
    /// SQLite text 可含 \0;String(cString:) 截断。行为钉死:不崩、逐行原样、Reader 层不归并
    /// (截断 id 与真实行撞 key 的归并发生在 store 层,是既有归一语义)。
    func test_embeddedNUL_idAndTitle_truncate_noReaderMerge() {
        makeFixture { db in
            exec(db, """
            INSERT INTO session VALUES ('ses_ab' || char(0) || 'cd','p',NULL,'/w','t' || char(0) || 'x','v',1000000,1000000,NULL);
            INSERT INTO session VALUES ('ses_ab','p',NULL,'/other','真身','v',2000000,2000000,NULL);
            """)
        }
        let rows = OpenCodeDBReader(dbPath: dbPath).read().rows
        XCTAssertEqual(rows?.count, 2, "Reader 层不归并(评审:截断撞 key 是 store 层归一语义)")
        XCTAssertEqual(rows?.first(where: { $0.directory == "/w" })?.title, "t", "title NUL 截断为前缀")
        XCTAssertEqual(rows?.first(where: { $0.directory == "/w" })?.sessionId, "ses_ab",
                       "截断 id 过不了 SessionIdRule(26 位)→ 无恢复命令,fail-closed")
    }

    // ── isNewerThanVerified(评审 Blocker:全名前缀比较)──
    func test_isNewerThanVerified_numericPrefixComparison() {
        XCTAssertFalse(OpenCodeDBReader.isNewerThanVerified("20260622202450_simplify_session_input"),
                       "已验证版本自身不得误报(裸时间戳字符串比较会在这里恒 true)")
        XCTAssertFalse(OpenCodeDBReader.isNewerThanVerified("20260127222353_familiar_lady_ursula"))
        XCTAssertTrue(OpenCodeDBReader.isNewerThanVerified("20260701000000_new_migration"))
        XCTAssertFalse(OpenCodeDBReader.isNewerThanVerified("garbage_no_digits"),
                       "无数字前缀 → 不误报(保守)")
    }

    // ── defaultDBPath(env:launchctlGetenv:listDir:)(评审:GUI 不继承 shell env)──
    func test_defaultDBPath_envMatrix() {
        let noFiles: (String) -> [(name: String, mtime: Double)] = { _ in [] }
        let noLaunchctl: (String) -> String? = { _ in nil }
        let home = NSHomeDirectory()
        func path(_ env: [String: String]) -> String {
            OpenCodeDBReader.defaultDBPath(env: env, launchctlGetenv: noLaunchctl, listDir: noFiles)
        }
        XCTAssertEqual(path([:]), home + "/.local/share/opencode/opencode.db")
        XCTAssertEqual(path(["XDG_DATA_HOME": "/custom/data"]), "/custom/data/opencode/opencode.db")
        XCTAssertEqual(path(["XDG_DATA_HOME": ""]), home + "/.local/share/opencode/opencode.db",
                       "空串视为未设(xdg 规范)")
        XCTAssertEqual(path(["XDG_DATA_HOME": "rel/path"]), home + "/.local/share/opencode/opencode.db",
                       "相对路径忽略(xdg 规范)")
        XCTAssertEqual(path(["OPENCODE_DB": "/x/y.db"]), "/x/y.db", "OPENCODE_DB 绝对路径整体覆盖")
        XCTAssertEqual(path(["OPENCODE_DB": "custom.db"]),
                       home + "/.local/share/opencode/custom.db",
                       "OPENCODE_DB 相对路径 join 到数据目录(上游 database.ts:44-47 语义,评审 m1)")
    }
    func test_defaultDBPath_launchctlFallback_forGUIProcess() {
        // GUI 进程 env 无 XDG → launchctl getenv 补探(评审 Blocker:XDG 机器静默失明)。
        let path = OpenCodeDBReader.defaultDBPath(
            env: [:],
            launchctlGetenv: { name in name == "XDG_DATA_HOME" ? "/launchd/data" : nil },
            listDir: { _ in [] })
        XCTAssertEqual(path, "/launchd/data/opencode/opencode.db")
    }
    func test_defaultDBPath_channelGlob_newestWins_excludesWal() {
        let listDir: (String) -> [(name: String, mtime: Double)] = { _ in
            [("opencode.db", 100), ("opencode-dev.db", 200),
             ("opencode-dev.db-wal", 300), ("other.db", 400)]
        }
        let path = OpenCodeDBReader.defaultDBPath(env: [:], launchctlGetenv: { _ in nil },
                                                  listDir: listDir)
        XCTAssertTrue(path.hasSuffix("/opencode/opencode-dev.db"),
                      "opencode*.db 取 mtime 最新;-wal 与非 opencode 前缀排除,got \(path)")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter OpenCodeDBReaderTests 2>&1 | tail -3`
Expected: 编译失败 `cannot find 'OpenCodeDBReader'`

- [ ] **Step 3: 实现**(追加到 `OpenCodeSource.swift`)

```swift
// MARK: - OpenCodeDBReader(IO 缝,只读 SQLite)

/// 读取结果三态(评审 Blocker:失败路径必须携带版本信号):
/// ok(rows: [], ...) = 不存在/空库(「装了没跑过」是常态);failed = 打不开/prepare 失败/半读。
public enum OpenCodeReadOutcome: Equatable {
    case ok(rows: [OpenCodeSessionRow], maxMigrationId: String?)
    case failed(maxMigrationId: String?)

    public var rows: [OpenCodeSessionRow]? {
        if case .ok(let rows, _) = self { return rows }
        return nil
    }
    public var maxMigrationId: String? {
        switch self {
        case .ok(_, let id), .failed(let id): return id
        }
    }
}

/// 只读打开 opencode.db(READONLY,WAL 兼容)。上游对该 DB 无 stability 承诺,防御为先。
public struct OpenCodeDBReader {
    private let dbPath: String
    private let busyTimeoutMs: Int32

    public init(dbPath: String, busyTimeoutMs: Int32 = 200) {
        self.dbPath = dbPath; self.busyTimeoutMs = busyTimeoutMs
    }

    /// 已验证的上游迁移 id 上界(**全名**,v1.17.13 / commit 04d236c;上游落库 id 形如
    /// `<14位时间戳>_<名字>`,migration.ts:30-35——裸时间戳比较会在已验证版本上恒误报)。
    /// ⚠️ 维护流程(上游 ~8 迁移/月,此值常态过期):上游出新迁移后
    /// ① 重跑 spec §2 事实核对;② 本常量改为新迁移全名;
    /// ③ `APET_OPENCODE_LIVE=1 swift test --filter OpenCodeLiveTests` 重跑;
    /// ④ 同步 README「已验证版本」行。
    public static let verifiedMaxMigrationId = "20260622202450_simplify_session_input"

    /// maxId 是否新于已验证版本:取两侧**前导数字前缀**比较(等长 14 位时间戳,字典序=数值序);
    /// 无数字前缀 → false(保守不误报)。
    public static func isNewerThanVerified(_ maxId: String) -> Bool {
        let lhs = maxId.prefix(while: { $0.isASCII && $0.isNumber })
        let rhs = verifiedMaxMigrationId.prefix(while: { $0.isASCII && $0.isNumber })
        guard !lhs.isEmpty else { return false }
        return lhs > rhs
    }

    /// DB 路径解析(评审 Blocker:GUI 进程读不到 shell rc 的环境变量):
    /// 1. `OPENCODE_DB`(env → launchctl):绝对路径整体覆盖;**相对路径 join 到数据目录**
    ///    (上游 database.ts:44-47 语义,评审 m1:勿按"忽略相对"实现);
    /// 2. `XDG_DATA_HOME`(env → launchctl;绝对非空才算设了);默认 `~/.local/share`;
    /// 3. 目录内 glob `opencode*.db` 取 mtime 最新(channel 后缀;`.db` 后缀天然排除 -wal/-shm)。
    public static func defaultDBPath(
        env: [String: String],
        launchctlGetenv: (String) -> String? = Self.launchctlGetenv,
        listDir: ((String) -> [(name: String, mtime: Double)])? = nil
    ) -> String {
        func lookup(_ name: String) -> String? {
            if let v = env[name], !v.isEmpty { return v }
            return launchctlGetenv(name)
        }
        let dataHome: String
        if let xdg = lookup("XDG_DATA_HOME"), xdg.hasPrefix("/") {
            dataHome = xdg
        } else {
            dataHome = NSHomeDirectory() + "/.local/share"
        }
        let dir = dataHome + "/opencode"
        if let ov = lookup("OPENCODE_DB"), !ov.isEmpty {
            return ov.hasPrefix("/") ? ov : dir + "/" + ov
        }
        let list = listDir ?? Self.realListDir
        let candidates = list(dir).filter { $0.name.hasPrefix("opencode") && $0.name.hasSuffix(".db") }
        if let newest = candidates.max(by: { $0.mtime < $1.mtime }) {
            return dir + "/" + newest.name
        }
        return dir + "/opencode.db"
    }

    /// GUI 进程(launchd 拉起)env 兜底:`launchctl getenv`。只在启动路径解析时调用一次,非轮询热路径。
    static func launchctlGetenv(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["getenv", name]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty ?? true) ? nil : out
    }

    private static func realListDir(_ dir: String) -> [(name: String, mtime: Double)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.map { name in
            let attrs = try? fm.attributesOfItem(atPath: dir + "/" + name)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return (name, mtime)
        }
    }

    public func read() -> OpenCodeReadOutcome {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .ok(rows: [], maxMigrationId: nil)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return .failed(maxMigrationId: nil)
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, busyTimeoutMs)

        // 表存在性探测:session 缺 → 空库常态;part/session_message 缺 → 降级 session-only。
        guard let tables = tableNames(db) else { return .failed(maxMigrationId: nil) }
        // 版本探测**先于**主查询(评审 Blocker:排后面则 schema 破坏性升级时主查询先失败,
        // 版本信号永远带不出来——恰是唯一需要它的场景)。migration 表结构 5 个月未变,最稳。
        let maxMigration: String? = tables.contains("migration") ? maxMigrationId(db) : nil
        guard tables.contains("session") else {
            return .ok(rows: [], maxMigrationId: maxMigration)
        }
        let hasPart = tables.contains("part")
        let hasMsg = tables.contains("session_message")

        // 活动降级链(评审 B1/M1:time_updated 只在提问时刷新;part/message 只有**行插入**时间可靠,
        // upsert 更新不刷 time_created——running 判定不依赖这里,靠 assistantSignal)。
        var activityExprs = ["s.time_updated"]
        if hasMsg {
            activityExprs.insert("(SELECT MAX(m.time_created) FROM session_message m WHERE m.session_id = s.id)", at: 0)
        }
        if hasPart {
            activityExprs.insert("(SELECT MAX(p.time_created) FROM part p WHERE p.session_id = s.id)", at: 0)
        }
        // assistant 信号:NULL=无 assistant 行(none);0=completed IS NULL(inFlight);1=completed(completed)。
        // CASE 包裹使 ISO 串等未来编码也归 completed(非 NULL 即完成,评审 m3)。
        let signalExpr = hasMsg
            ? """
              (SELECT CASE WHEN json_extract(m.data, '$.time.completed') IS NULL THEN 0 ELSE 1 END
                 FROM session_message m
                WHERE m.session_id = s.id AND m.type = 'assistant'
                ORDER BY m.seq DESC LIMIT 1)
              """
            : "NULL"
        // 窗口过滤在 Swift 层(scanner)做:不能按 time_updated 下推(B1 同根)。
        // SQLite 的 COALESCE 至少 2 参——session-only 降级时单表达式不包裹(实现时发现,回写)。
        let activityExpr = activityExprs.count > 1
            ? "COALESCE(\(activityExprs.joined(separator: ", ")))"
            : activityExprs[0]
        let sql = """
        SELECT s.id, s.directory, s.title, s.time_created,
               \(activityExpr) AS last_activity,
               \(signalExpr) AS assistant_signal
        FROM session s
        WHERE s.parent_id IS NULL AND s.time_archived IS NULL
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .failed(maxMigrationId: maxMigration)
        }
        defer { sqlite3_finalize(stmt) }

        func text(_ col: Int32) -> String? {
            sqlite3_column_text(stmt, col).map { String(cString: $0) }
        }
        func emptyAsNil(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

        var rows: [OpenCodeSessionRow] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let id = text(0) {
                let signal: AssistantSignal
                if sqlite3_column_type(stmt, 5) == SQLITE_NULL {
                    signal = .none
                } else {
                    signal = sqlite3_column_int64(stmt, 5) == 0 ? .inFlight : .completed
                }
                rows.append(OpenCodeSessionRow(
                    sessionId: id,
                    directory: emptyAsNil(text(1)),
                    title: emptyAsNil(text(2)),
                    lastActivity: sqlite3_column_double(stmt, 4) / 1000.0,
                    assistantSignal: signal,
                    createdAt: sqlite3_column_double(stmt, 3) / 1000.0
                ))
            }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else {
            return .failed(maxMigrationId: maxMigration)   // 半读(BUSY/IOERR)不可信
        }
        return .ok(rows: rows, maxMigrationId: maxMigration)
    }

    /// `SELECT MAX(id) FROM migration`;查询失败 → nil(不拦整体读取)。
    private func maxMigrationId(_ db: OpaquePointer) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(id) FROM migration", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    /// sqlite_master 表名集合;查询失败(BUSY 等)→ nil。
    private func tableNames(_ db: OpaquePointer) -> Set<String>? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let n = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) { names.insert(n) }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { return nil }
        return names
    }
}
```

- [ ] **Step 4: 跑测试**

Run: `swift test --filter OpenCodeDBReaderTests 2>&1 | tail -3` → 全 PASS

- [ ] **Step 5: 全量 + 提交**

Run: `swift test 2>&1 | tail -3` → 全绿

```bash
git add Sources/AppShellKit/OpenCodeSource.swift Tests/AppShellKitTests/OpenCodeDBReaderTests.swift
git commit -m "feat(m3c+): OpenCodeDBReader——WAL fixture/活动降级链/完成信号 json_extract/版本探测/defaultDBPath(env:) 注入可测"
```

---

### Task 8: GUI 接线(AppCoordinator/面板/弹窗)

**Files:**
- Modify: `Sources/apet/AppCoordinator.swift`(约 46-47 行属性、175-205 行源注册、574-625 行 applyScanResult)
- Modify: `Sources/apet/MenuBarController.swift:390-425`(弹窗定制 + hook 提示门控)
- Modify: `Sources/apet/PetWindowController.swift`(同构弹窗,约 219 行起,先读再改)
- Modify: `Sources/apet/SessionPanel.swift:120-130`(本地摘要隐藏)
- Modify: `Sources/apet/SessionRowActions.swift`(copyResume 带目录)
- Modify: `Sources/AppShellKit/SessionRowModel.swift`(noJumpHint)
- Test: `Tests/AppShellKitTests/`(SessionRowModel 相关测试文件追加;GUI 胶水按仓库惯例不单测)

**Interfaces:**
- Consumes: Task 2/5/6/7 全部产出
- Produces: 无新公开接口;`SessionRowModel.noJumpHint: Bool`(面板渲染用)

- [ ] **Step 1: noJumpHint 失败测试**(追加到 `Tests/AppShellKitTests/SessionRowMapperTests.swift`,用其现成 `makeSession` helper;渲染模型入口是 `SessionRowMapper.make`)

```swift
    // MARK: - noJumpHint(M3-C+ 评审 B3:预期在点击前对齐,不是点完才弹错误)

    /// opencode:DB 轮询源、无 terminal 信息、无 hook 升级路径 → 行内「无跳转」提示。
    func test_noJumpHint_opencode_noTerminal() {
        let s = makeSession(agent: "opencode", state: .waiting(.stop))
        XCTAssertTrue(SessionRowMapper.make(s).noJumpHint)
    }

    func test_noJumpHint_false_forClaudeAndTerminalBackedAgents() {
        let claude = makeSession(agent: "claude-code")
        XCTAssertFalse(SessionRowMapper.make(claude).noJumpHint, "claude 有 hook 升级路径,不显")
        let qw = makeSession(agent: "qoder-work",
                             terminal: TerminalRef(kind: .other, bundleId: "com.qoder.work"))
        XCTAssertFalse(SessionRowMapper.make(qw).noJumpHint, "有 terminal 可激活 App,不显")
    }
```

- [ ] **Step 2: 实现 noJumpHint**(`SessionRowModel.swift`)

字段与 make 内逻辑(放在 `isInferred` 计算旁):

```swift
    /// 无跳转提示:DB 轮询源且无终端信息(点击只能复制恢复命令,评审 B3 预期前置)。
    public let noJumpHint: Bool
```

make 内:

```swift
        // opencode 等 DB 源无 terminal 且无 hook 升级路径 → 行内「无跳转」。
        let noJumpHint = session.terminal == nil
            && AgentManifest.dbBackedAgents.contains(key.agent)
```

⚠️ 别忘了两处收尾(评审:代码段"计算了没用上"会编译警告+测试红):
① `make` 末尾的 `return SessionRowModel(...)` 调用同步传 `noJumpHint: noJumpHint`;
② init 参数增加 `noJumpHint: Bool = false` 默认值(放 `relativeText` 之后),既有构造点零改动。

- [ ] **Step 2b: 单独提交 noJumpHint**(评审:可独立测试的交付物独立成 commit)

```bash
git add Sources/AppShellKit/SessionRowModel.swift Tests/AppShellKitTests/SessionRowMapperTests.swift
git commit -m "feat(m3c+): SessionRowModel.noJumpHint——DB 轮询源无终端信息的行内预期提示(评审B3前置)"
```

- [ ] **Step 3: 跑 SessionRowModel 测试** → PASS 后继续

- [ ] **Step 4: AppCoordinator 改造**(无条件双源注册 + ack 集合化 + 健康信号采集)

(a) 属性区(46-47 行旁):

```swift
    /// M3-C:QoderWork(agents.db)轮询源。评审:无条件注册(安装顺序不应击穿零配置)。
    private var qoderWorkWatcher: QoderWorkWatcher?
    /// M3-C+:OpenCode(opencode.db)轮询源。同上无条件注册。
    private var openCodeWatcher: DBPollWatcher?
    /// OpenCode 最近一轮读取结果的健康信号(Task 8b 决策表输入;主线程读写——timer queue=.main)。
    private var openCodeLastOutcome: OpenCodeReadOutcome?
    private var openCodeDBPath: String = ""
```

(b) 源注册块(替换原 `if FileManager.default.fileExists(atPath: qwDBPath)` 门控;OpenCode 紧随其后):

```swift
        // ─── 2a-2. QoderWork 源(M3-C):无条件注册——reader 对文件不存在返回 [],
        // 常驻成本趋零;后装 QoderWork 无需重启 apet(评审:安装顺序击穿零配置)。──
        let qwDBPath = QoderWorkDBReader.defaultDBPath
        let qwReader = QoderWorkDBReader(dbPath: qwDBPath)
        let qwRoot = (qwDBPath as NSString).deletingLastPathComponent
        qoderWorkWatcher = QoderWorkWatcher(
            read: { qwReader.read() },
            root: qwRoot,
            now: { Date().timeIntervalSince1970 },
            emit: { [weak self] result in self?.applyScanResult(result) }
        )
        appendToLog("[info] QoderWork 会话监控已挂载(粗略状态;DB 出现即生效)\n")

        // ─── 2a-3. OpenCode 源(M3-C+):只读轮询 opencode.db,静默通道。──
        // 路径解析含 launchctl getenv 兜底(评审 Blocker:GUI 进程读不到 shell rc 的 XDG)。
        let ocPath = OpenCodeDBReader.defaultDBPath(env: ProcessInfo.processInfo.environment)
        openCodeDBPath = ocPath
        let ocReader = OpenCodeDBReader(dbPath: ocPath)
        let ocRoot = (ocPath as NSString).deletingLastPathComponent
        openCodeWatcher = DBPollWatcher(
            scan: { [weak self] now in
                // 契约:DBPollWatcher timer queue=.main——openCodeLastOutcome 主线程独占
                // (评审:该假设只有注释保障,precondition 让漂移当场爆)。
                dispatchPrecondition(condition: .onQueue(.main))
                let outcome = ocReader.read()
                self?.openCodeLastOutcome = outcome
                self?.reportOpenCodeHealthIfChanged()   // Task 8b:去抖上报
                guard let rows = outcome.rows else { return nil }   // .failed → 整轮跳过
                return OpenCodeScanner.scan(rows: rows, root: ocRoot, now: now)
            },
            now: { Date().timeIntervalSince1970 },
            emit: { [weak self] result in self?.applyScanResult(result) }
        )
        appendToLog("[info] OpenCode 会话监控已挂载(路径:\(ocPath);内容信号优先)\n")
```

(c) 找到 QoderWork 的 `start(every:)`/`scanOnce()` 调用点(约 403 行 seed 与其附近的 start),为 `openCodeWatcher` 增加同款调用(同一轮询节奏);**并且** `stop()`(约 428-439 行)在 `qoderWorkWatcher?.stop()` 之后补一行(评审 Major:漏停则 teardown 后 timer 继续打事件):

```swift
        qoderWorkWatcher?.scanOnce()
        openCodeWatcher?.scanOnce()
```

```swift
        // stop() 内:
        qoderWorkWatcher?.stop()
        openCodeWatcher?.stop()
```

(start 处同构;interval 沿 QoderWork 现值。)

(d) applyScanResult(574-625 行)两处改动:

```swift
                // M3-C:QoderWork/Qoder IDE 点击 → 激活对应 App。
                // opencode 不注入 terminal:TUI 宿主终端未知,诚实降级(评审 B3)。
                if key.agent == "qoder-work" {
                    ev.terminal = TerminalRef(kind: .other, bundleId: "com.qoder.work")
                } else if key.agent == "qoder-ide" {
                    ev.terminal = TerminalRef(kind: .other, bundleId: "com.qoder.ide")
                }
```

```swift
                // 评审修复(架构 m6 → B2 收敛):DB 轮询源的 waitingStop 不代表真实「等你」
                // (无 hook 级信号),预置已读——不进「等你」置顶、不污染未读徽标。
                // 集合判定取代 agent 字符串 if(评审:别每接一源加一个分支)。
                if AgentManifest.dbBackedAgents.contains(key.agent), kind == .stop {
                    _ = store.acknowledge(key: key)
                }
```

(e) 版本/安装健康的**用户可见**出口在 **Task 8b**(评审 Blocker:spec 承诺 ConfigHealth,日志不是用户可见面;`reportOpenCodeHealthIfChanged()` 在 8b 实现,此处只需保证 scan 闭包已按 (b) 调用它)。

- [ ] **Step 5: 弹窗改造——共享 helper + 门控 + hook 提示限定**

评审 Major:MenuBar 与 Pet 两处弹窗**并不同构**(Pet 侧无 `isShowingTapAlert`/`hookHintThrottle`,MainActor.run 结构也不同)——"同改"必漏。改为把 opencode 弹窗抽成共享 helper,两控制器各自调用。

(a) `SessionRowActions.swift` 新增(与既有弹窗惯例一致:`NSApp.activate` 置前、"好"按钮):

```swift
    /// opencode 点击弹窗(评审 B3:诚实降级 + 把死路变恢复路径)。@MainActor 调用。
    /// 返回 true = 用户点了主按钮并已复制。
    /// 评审:复制按钮继承右键菜单的 hasResumeCommand 门控(产品 M3「不静默复制假命令」)——
    /// 异形 id(旧迁移/SDK 自带)拿不到恢复命令时按钮如实降级为「复制会话 ID」。
    @discardableResult
    static func showOpenCodeNoJumpAlert(_ s: Session) -> Bool {
        let hasCmd = ResumeCommand.display(agent: s.key.agent, sessionId: s.key.sessionId,
                                           directory: s.cwd) != nil
        let alert = NSAlert()
        alert.messageText = "OpenCode 在终端中运行"
        alert.informativeText = hasCmd
            ? "apet 无法定位它所在的终端窗口。若该会话的终端还开着,直接切换过去即可;终端已关时,可复制恢复命令粘贴到项目目录的终端里打开该会话。"
            : "apet 无法定位它所在的终端窗口,且该会话 ID 来自旧版本、无可用恢复命令(可复制会话 ID 自行处理)。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: hasCmd ? "复制恢复命令" : "复制会话 ID")
        let cancel = alert.addButton(withTitle: "好")
        cancel.keyEquivalent = "\u{1b}"   // Esc 可取消(HIG;NSAlert 不给"好"自动绑 Esc)
        NSApp.activate(ignoringOtherApps: true)   // LSUIElement:弹窗置前(既有惯例)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if hasCmd { copyResume(s) } else { copyId(s) }
        return true
    }
```

(b) `MenuBarController.swift:390-425` 现有 alert 块:在 `!self.isShowingTapAlert` 守卫**内**按 agent 分流——opencode 调 helper,其余走原弹窗;hook 提示限定 Claude 系(评审:对 opencode 推销 ~/.claude/settings.json 完全错误且耗节流配额)。改造后:

```swift
            if result == .targetGone || result == .unsupported {
                await MainActor.run { [weak self] in
                    guard let self, !self.isShowingTapAlert else { return }
                    self.isShowingTapAlert = true
                    defer { self.isShowingTapAlert = false }
                    if session.key.agent == "opencode" {
                        SessionRowActions.showOpenCodeNoJumpAlert(session)
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = "无法跳转到会话"
                    var infoText = "无法跳转到会话终端(可能已关闭,或终端信息不可用)。"
                    // hook 提示限定 Claude 系(评审门控)。
                    let isClaude = ["claude", "claude-code"].contains(session.key.agent)
                    if isJsonlSession && isClaude && self.hookHintThrottle.shouldHint(sessionKey: id) {
                        infoText += "\n\n💡 安装 Hook 可精确跳到这个 tab(会改 settings.json,自动备份/一键卸载)→ 在「首选项」中开启。"
                    }
                    alert.informativeText = infoText
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "好的")
                    alert.runModal()
                }
            }
```

注:现场风格是「off-main 前只捕原语」(391 行注释)——`session` 是 380 行局部 `let`(struct,可捕),但按现场惯例建议预捕 `(agent, sessionId, cwd, customName)` 或直接捕 `session` 值并加注释说明;以现场变量名为准。

(c) `PetWindowController.swift:219-231` 的同构 alert 块:**同样按 agent 分流调 `showOpenCodeNoJumpAlert`**(Pet 侧本无 hook 提示与防连击守卫——helper 内部 runModal 是同步模态,天然串行,无需新增守卫;改造后原 alert 保持原样服务非 opencode 会话)。

(d) 验收 checkbox:MenuBar 与 Pet 两侧点击 opencode 会话都弹新文案、主按钮复制成功、Esc 可取消。

- [ ] **Step 6: copyResume 带目录 + 本地摘要隐藏**

`SessionRowActions.swift`:

```swift
    static func copyResume(_ s: Session) {
        if let cmd = ResumeCommand.display(agent: s.key.agent, sessionId: s.key.sessionId,
                                           directory: s.cwd) {
            copyToPasteboard(cmd)
        } else {
            copyToPasteboard(s.key.sessionId)
        }
    }
```

`SessionPanel.swift:121-123` 本地摘要项包门控(⚠️ 相邻 `Divider()` 一并移进 `if`,否则 DB 型 agent 菜单出现双分隔线——评审):

```swift
                // 本地摘要:DB 型 agent 无 jsonl 转录,必弹「找不到记录文件」死弹窗 → 隐藏(评审)。
                if !AgentManifest.dbBackedAgents.contains(row.agent) {
                    Divider()                    // 原 121/123 行其中一条,随项内移
                    Button("本地摘要") { ... }   // 原有内容原样内移
                }
```

面板行内 noJumpHint 渲染:在显示 `activateOnly` 提示的位置(`SessionPanel.swift:197-200` 附近)同构增加。**堆叠治理**(评审 Major:320px 行宽下「opencode」+「推断」+「无跳转」+相对时间把标题挤空):`noJumpHint` 为真时**抑制「推断」徽标**(`SessionPanel.swift:182-196` 的「推断」显示条件补 `&& !row.noJumpHint`——语义重叠,agent 徽标 tooltip 已承载"状态是推断的");标题 `Text` 加 `.layoutPriority(1)`:

```swift
                    if row.noJumpHint {
                        Text("无跳转")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("OpenCode 在终端中运行,apet 无法定位窗口;点击查看恢复方式")
                    }
```

(help 用「点击查看恢复方式」——「点击可复制恢复命令」不准确:点击是弹窗,且异形 id 无恢复命令。评审。)

agent 徽标 tooltip(`SessionPanel.swift:188` 附近)对 opencode 补边界说明(spec §1「边界必须传达」;含灰显档解释——评审:用户看到灰行要知道是什么):

```swift
                            .help(row.agent == "opencode"
                                  ? "来自 opencode:仅面板可见,无通知(插件增强规划中);状态按内容信号+活动时间推断;30 分钟无活动灰显(会话仍在,活动后恢复),24 小时后移出"
                                  : "来自 \(row.agent)(状态按活动时间粗略推断)")
```

- [ ] **Step 7: 编译 + 全量测试 + 手动冒烟**

Run: `swift build 2>&1 | tail -3` → Build complete
Run: `swift test 2>&1 | tail -3` → 全绿
冒烟(可选,无真机 OpenCode 时跳过):`bash scripts/package-app.sh && open AgentPet.app`,确认面板正常、日志有「OpenCode 会话监控已挂载」。

- [ ] **Step 8: 提交**(noJumpHint 已在 Step 2b 单独提交,此处只剩 GUI 胶水)

```bash
git add Sources/apet/ Sources/AppShellKit/SessionPanel.swift 2>/dev/null; git add Sources/apet/ Tests/
git commit -m "feat(m3c+): OpenCode GUI 接线——无条件双源注册/预置已读集合化/共享无跳转弹窗(门控+Esc)/hook提示限定claude/本地摘要与徽标堆叠治理"
```

---

### Task 8b: OpenCodeHealth 决策表(用户可见健康提示)

评审 Blocker(产品/架构/开源三方合流):spec 承诺「ConfigHealth **用户可见**」,日志不是用户可见面;且「版本过新」必须由 **failed(maxMigrationId:)** 驱动(Task 7 已保证失败携带版本信号)。

**Files:**
- Modify: `Sources/AppShellKit/OpenCodeSource.swift`(追加纯决策表)
- Modify: `Sources/apet/AppCoordinator.swift`(`reportOpenCodeHealthIfChanged()` 去抖上报)
- Modify: `Sources/apet/PreferencesWindow.swift`(约 996 行 ConfigHealth 区追加一行渲染;先读现场结构,沿既有 health 行样式)
- Test: `Tests/AppShellKitTests/OpenCodeHealthTests.swift`(新)

**Interfaces:**
- Consumes: `OpenCodeReadOutcome`(Task 7)
- Produces: `OpenCodeHealth: Equatable`、`OpenCodeHealthDecider.decide(...)`、`OpenCodeHealth.userMessage: String?`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import AppShellKit

/// OpenCodeHealth 决策表(spec §3.3;评审:「未安装」「XDG 失明嫌疑」「版本过新」「旧版」必须可区分)。
final class OpenCodeHealthTests: XCTestCase {

    func test_ok_whenReadSucceeds() {
        XCTAssertEqual(OpenCodeHealthDecider.decide(
            outcome: .ok(rows: [], maxMigrationId: nil),
            dbExists: true, legacyStorageExists: false, configDirExists: true), .ok)
    }
    func test_notInstalled_noTraces() {
        let h = OpenCodeHealthDecider.decide(
            outcome: .ok(rows: [], maxMigrationId: nil),
            dbExists: false, legacyStorageExists: false, configDirExists: false)
        XCTAssertEqual(h, .notInstalled)
        XCTAssertNil(h.userMessage, "未安装是常态,不打扰")
    }
    /// 评审 Blocker(XDG 失明):无 db 但有 opencode 配置痕迹 → 用户可见提示。
    func test_dbNotFound_butConfigDirExists() {
        let h = OpenCodeHealthDecider.decide(
            outcome: .ok(rows: [], maxMigrationId: nil),
            dbExists: false, legacyStorageExists: false, configDirExists: true)
        XCTAssertEqual(h, .dbNotFound)
        XCTAssertNotNil(h.userMessage)
        XCTAssertTrue(h.userMessage!.contains("XDG"), "提示要点名 GUI 读不到 shell 环境变量的场景")
    }
    func test_legacyStorage_upgradeHint() {
        let h = OpenCodeHealthDecider.decide(
            outcome: .ok(rows: [], maxMigrationId: nil),
            dbExists: false, legacyStorageExists: true, configDirExists: true)
        XCTAssertEqual(h, .legacyStorage)
        XCTAssertNotNil(h.userMessage)
    }
    /// spec 合取条件:读失败 ∧ migration 新于已验证 → versionTooNew。
    func test_versionTooNew_requiresBothFailedAndNewer() {
        let newer = "20990101000000_future"
        XCTAssertEqual(OpenCodeHealthDecider.decide(
            outcome: .failed(maxMigrationId: newer),
            dbExists: true, legacyStorageExists: false, configDirExists: true),
            .versionTooNew(maxMigrationId: newer))
        // 读成功 ∧ 新迁移 id → 不报(向后兼容加列大概率无害,spec §2)。
        XCTAssertEqual(OpenCodeHealthDecider.decide(
            outcome: .ok(rows: [], maxMigrationId: newer),
            dbExists: true, legacyStorageExists: false, configDirExists: true), .ok)
        // 读失败 ∧ 版本未超 → 一般性读失败(锁抖动等),不误报版本。
        XCTAssertEqual(OpenCodeHealthDecider.decide(
            outcome: .failed(maxMigrationId: OpenCodeDBReader.verifiedMaxMigrationId),
            dbExists: true, legacyStorageExists: false, configDirExists: true), .readFailed)
    }
}
```

- [ ] **Step 2: 跑测试确认失败** → `swift test --filter OpenCodeHealthTests` 编译失败

- [ ] **Step 3: 实现**(追加到 `OpenCodeSource.swift`)

```swift
// MARK: - OpenCodeHealth(纯决策表,用户可见健康提示)

/// spec §3.3:「未安装」与「版本不匹配/路径失明/旧版」必须可区分——
/// 「会话昨天还在、今天消失且无解释」是最差体验(评审)。
public enum OpenCodeHealth: Equatable {
    case ok
    case notInstalled                          // 无 db 无任何痕迹:常态,不打扰
    case dbNotFound                            // 无 db 但有 ~/.config/opencode 痕迹(XDG 失明嫌疑)
    case legacyStorage                         // 无 db 但有旧 JSON storage:请升级 OpenCode
    case readFailed                            // 本轮读失败(锁抖动/损坏),版本未超
    case versionTooNew(maxMigrationId: String) // 读失败 ∧ migration 新于已验证

    /// 用户可见文案;nil = 不展示(ok/notInstalled)。
    public var userMessage: String? {
        switch self {
        case .ok, .notInstalled:
            return nil
        case .dbNotFound:
            return "OpenCode:找到配置但未找到数据库——若你在 shell 里设置了 XDG_DATA_HOME,GUI 应用读不到它;可用 `launchctl setenv XDG_DATA_HOME <路径>` 后重启 apet"
        case .legacyStorage:
            return "OpenCode:检测到旧版 JSON 存储(未迁 SQLite),apet 不支持——请升级 OpenCode"
        case .readFailed:
            return "OpenCode:数据库暂时读不出(可能被占用),会自动重试"
        case .versionTooNew(let id):
            return "OpenCode:数据库 schema(\(id))新于 apet 已验证版本,暂不支持——请升级 apet 或提 issue"
        }
    }
}

public enum OpenCodeHealthDecider {
    public static func decide(
        outcome: OpenCodeReadOutcome,
        dbExists: Bool,
        legacyStorageExists: Bool,
        configDirExists: Bool
    ) -> OpenCodeHealth {
        if case .failed(let maxId) = outcome {
            if let maxId, OpenCodeDBReader.isNewerThanVerified(maxId) {
                return .versionTooNew(maxMigrationId: maxId)
            }
            return .readFailed
        }
        guard !dbExists else { return .ok }
        if legacyStorageExists { return .legacyStorage }
        if configDirExists { return .dbNotFound }
        return .notInstalled
    }
}
```

- [ ] **Step 4: 跑测试** → 全 PASS

- [ ] **Step 5: GUI 接入**

`AppCoordinator`:实现 Task 8(b) 引用的去抖上报(状态变化才记录+日志一条),并向 Preferences 暴露当前值:

```swift
    /// 最近一次 OpenCode 健康(去抖:状态变化才更新/记日志)。Preferences 健康区读取。
    private(set) var openCodeHealth: OpenCodeHealth = .ok

    private func reportOpenCodeHealthIfChanged() {
        guard let outcome = openCodeLastOutcome else { return }
        let root = (openCodeDBPath as NSString).deletingLastPathComponent
        let health = OpenCodeHealthDecider.decide(
            outcome: outcome,
            dbExists: FileManager.default.fileExists(atPath: openCodeDBPath),
            legacyStorageExists: FileManager.default.fileExists(
                atPath: (root as NSString).appendingPathComponent("storage/session")),
            configDirExists: FileManager.default.fileExists(
                atPath: (NSHomeDirectory() as NSString).appendingPathComponent(".config/opencode")))
        guard health != openCodeHealth else { return }
        openCodeHealth = health
        if let msg = health.userMessage { appendToLog("[warn] \(msg)\n") }
    }
```

`PreferencesWindow.swift`(约 996 行 ConfigHealth 构造/渲染区,先读现场):健康区追加一行——`coordinator.openCodeHealth.userMessage` 非 nil 时以既有 degraded 行样式展示。

- [ ] **Step 6: 全量测试 + 提交**

```bash
git add Sources/AppShellKit/OpenCodeSource.swift Sources/apet/ Tests/AppShellKitTests/OpenCodeHealthTests.swift
git commit -m "feat(m3c+): OpenCodeHealth 决策表——版本过新/XDG失明/旧版/未安装可区分,Preferences 健康区用户可见(评审Blocker)"
```

---

### Task 9: live 门控测试 + 文档交付物 + 收尾

**Files:**
- Test: `Tests/AppShellKitTests/OpenCodeLiveTests.swift`(新,env 门控)
- Modify: `README.md`(多 Agent 清单/能力矩阵/数据流/路线图/上游版本适配声明)
- Modify: `CLAUDE.md`(路线图 M3-C+ / Qoder IDE 搁置 / 遗留)

**Interfaces:**
- Consumes: Task 7 Reader、Task 3 SessionIdRule

- [ ] **Step 1: live 门控测试**(默认 XCTSkip,真机实测门用;评审:可重跑留痕)

```swift
import XCTest
@testable import AppShellKit
import AgentPetCore

/// 真机实测门(spec §6):APET_OPENCODE_LIVE=1 才跑。
/// 用途:合并前对真实 opencode.db 端到端验证;输出贴 PR 作过门证据。
final class OpenCodeLiveTests: XCTestCase {

    func test_live_readRealDatabase() throws {
        guard ProcessInfo.processInfo.environment["APET_OPENCODE_LIVE"] == "1" else {
            throw XCTSkip("live 测试需 APET_OPENCODE_LIVE=1(真机实测门)")
        }
        let path = OpenCodeDBReader.defaultDBPath(env: ProcessInfo.processInfo.environment)
        let outcome = OpenCodeDBReader(dbPath: path).read()
        let rows = try XCTUnwrap(outcome.rows, "真机读取失败——检查版本漂移(migration 上界见输出)")
        print("[live] db=\(path) rows=\(rows.count) maxMigration=\(outcome.maxMigrationId ?? "nil") verified=\(OpenCodeDBReader.verifiedMaxMigrationId)")
        // 版本格式断言(评审 Blocker 的真机哨兵):id 应为全名(含 _ 后缀)且不新于已验证。
        if let maxId = outcome.maxMigrationId {
            XCTAssertTrue(maxId.contains("_"),
                          "migration id 应为全名 <时间戳>_<名字>,got \(maxId)——上游格式变了?重跑 spec §2 核对")
            XCTAssertFalse(OpenCodeDBReader.isNewerThanVerified(maxId),
                           "真机 schema 新于已验证——按 verifiedMaxMigrationId 注释的四步维护流程更新")
        }
        let rule = SessionIdRule.prefixedBase62(prefix: "ses_", length: 26)
        let now = Date().timeIntervalSince1970
        for row in rows {
            // 秒量级哨兵:抓漏换算(≈1.78e12 即毫秒当秒)与方言漂移(评审 tripwire)。
            XCTAssertGreaterThan(row.lastActivity, 1_577_836_800, "2020 之前?换算/方言异常:\(row.sessionId)")
            XCTAssertLessThan(row.lastActivity, now + 86_400, "未来一天开外?\(row.sessionId)")
            // id 不过白名单只打印不断言(spec §6-6:旧迁移异形 id 合法存在,硬断言会误炸真机门)。
            if !rule.validate(row.sessionId) {
                print("[live] 异形 id(旧迁移?):\(row.sessionId)——无恢复命令但应正常展示")
            }
        }
    }
}
```

Run: `swift test --filter OpenCodeLiveTests 2>&1 | tail -3` → 1 skipped(无 env 时)

- [ ] **Step 2: README 更新**(逐处;行号以当前文件为准,先读再改)

1. 功能清单「🤖 多 Agent」条目追加:`**OpenCode**(opencode.db 只读轮询,内容信号优先状态;面板可见/复制恢复命令,无通知无跳转——插件增强规划中)`。
2. 「点通知/点列表跳回终端」行追加如实标注:`OpenCode:无跳转(TUI 宿主终端未知),点击弹窗内一键复制恢复命令`。
3. 「架构」数据流段追加一行:`- **OpenCode**:只读轮询 opencode.db(SQLite),part/消息表活动信号 + assistant 完成信号派生状态,静默不通知。`
4. 「路线图」M3 行加 OpenCode;「遗留」的「Qoder IDE 接入」改为「Qoder IDE 追加接入(**搁置**:产品线合并未定)」;新增「OpenCode 插件增强(P1:精确通知+tty 跳转)」。
5. 新增小节「## 上游版本适配(OpenCode)」:

```markdown
## 上游版本适配(OpenCode)

apet 以**只读**方式(`SQLITE_OPEN_READONLY`,绝不写入)读取 OpenCode 的本地数据库
(`~/.local/share/opencode/opencode*.db`)。该数据库是 OpenCode 的内部实现,上游无兼容性承诺:

- 已验证版本:**v1.17.13**(migration ≤ `20260622202450_simplify_session_input`,2026-07-03)。
- OpenCode 升级导致 schema 变化时,apet 可能暂时看不到其会话——「首选项 → 配置健康」会提示
  「schema 新于已验证版本」;请升级 apet 或提 [issue](https://github.com/clsaa/apet/issues)。
- 旧版 OpenCode(JSON 文件存储,未迁 SQLite)不支持,请升级 OpenCode。
- 状态边界:仅面板可见(无通知/无跳转,插件增强规划中);30 分钟无活动灰显(会话仍在),24 小时移出面板。
```

6. README:22 的「**610 个单元测试全绿**」刷新为实际计数(评审:新增数十条后失真;跑 `swift test 2>&1 | grep -o '[0-9]* tests'` 取值)。

- [ ] **Step 3: CLAUDE.md 更新**

路线图 M3-C 条目追加:`+ **OpenCode 实测接入**(opencode.db 只读轮询/内容信号优先/无条件注册/诚实无跳转降级,见 2026-07-03 spec)`;「真实遗留」删「Qoder IDE 接入」改为:`Qoder IDE 追加接入(搁置:产品线合并未定)、OpenCode 插件增强(P1)、模型摘要 UI、F10 createdAt 注入、**OpenCode 上游维护义务**(watch sst/opencode releases 与 packages/core/src/database/ 变更;版本漂移按 verifiedMaxMigrationId 注释四步流程更新——评审:上游 ~8 迁移/月,无流程必然烂掉)`。

- [ ] **Step 4: 全量测试 + 提交**

Run: `swift test 2>&1 | tail -3` → 全绿(基线 610 + 新增全部)

```bash
git add Tests/AppShellKitTests/OpenCodeLiveTests.swift README.md CLAUDE.md
git commit -m "docs+test(m3c+): live 门控测试(APET_OPENCODE_LIVE)/README 能力矩阵与上游版本适配声明/CLAUDE.md 路线图同步"
```

---

## 完成后(不在本计划内自动执行)

1. **七视角实现评审**(用户流程要求:每核心阶段评审+修复)。
2. **真机实测门**(spec §6,逐项 checklist——评审:一句话指针会在执行时缩水;每项标注证据物):
   - [ ] 前置:安装 latest OpenCode(装机方式待用户确认);**版本 ≠ v1.17.13 时先重跑 spec §2 事实核对**再继续。
   - [ ] ① DB 路径/文件名(含 channel);GUI 启动(`open AgentPet.app`,非终端)下路径解析;自定义 `XDG_DATA_HOME` 场景(证据:日志「已挂载(路径:…)」截图/文本)。
   - [ ] ② 长任务观察:流式期间 part/session_message 实际刷新节奏 + in-flight → completed 翻转及时性(B1/M1 修复的直接验证;证据:操作记录 + 面板状态描述)。
   - [ ] ③ OpenCode 正在写库(WAL 活跃)时轮询无半读/空转(证据:live 测试在会话运行中执行通过)。
   - [ ] ④ resume:会话目录内、非会话目录+位置参数两种执行;含空格目录 display 命令粘贴可用(证据:终端记录)。
   - [ ] ⑤ 面板观感:挂机 TUI 黄点不置顶;stale 灰显不消失;首分钟观感;误报观感(证据:截图)。
   - [ ] ⑥ 抽查最老一条会话 id(旧 JSON 迁移来的),越界则确认「无恢复命令但正常展示」(证据:live 输出的异形 id 行)。
   - [ ] ⑦ `sqlite3 opencode.db ".schema session"` 快照存入 fixtures 校正 DDL 蓝本(**代码交付物**,单独 commit);live 测试输出贴 PR 作过门证据。
3. 分支合并走 superpowers:finishing-a-development-branch。
