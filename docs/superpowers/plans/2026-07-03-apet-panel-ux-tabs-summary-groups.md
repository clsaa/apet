# 会话面板 UX 升级 实现计划(内联摘要 / 悬停收藏 / Tab / 自定义分组)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 会话面板:目录下内联本地摘要、悬停收藏按钮、顶部 Tab 取代分区、可多属的自定义分组。

**Architecture:** 纯逻辑(摘要刷新决策 / tab 过滤 / 分组成员 / 组名校验 / 平铺组织)入 AgentPetCore/AppShellKit 单测;摘要 I/O 走既有缝后台算并缓存进 `SessionMeta.cachedSummary/summaryAnchor`(预留字段);GUI(SwiftUI 行/tab 栏/右键)薄胶水。分四里程碑 A→B→C→D 独立交付。

**Tech Stack:** Swift 5.9(SwiftPM 三 target)、XCTest、SwiftUI/AppKit。

**权威 spec:** `docs/superpowers/specs/2026-07-03-apet-panel-ux-tabs-summary-groups-design.md`。冲突以 spec 为准并回报。

## Global Constraints(每个任务隐含)

- 零第三方依赖;AgentPetCore 只用 Foundation。
- 禁 `Date()`/`Date.now`——`now: Double` 注入(apet 组织层既有 `Date().timeIntervalSince1970` 闭包除外)。
- 归一键 `SessionMetaMerger.metaKey(key) = "agent::root::sessionId"`。
- 摘要 I/O 绝不在 main 同步/映射内做;走可注入闭包缝,后台队列。
- 测试是规范:失败改实现不改测试;提交前 `swift test` 全绿(当前基线 716)。
- 中文 commit;小步一交付物一 commit;分支 `feature/panel-ux`(不在 main 开发)。
- 面板 320pt 宽;新增文本标签一律 `.lineLimit(1)` + `.fixedSize()`(否则 CJK 竖排乱码——本轮已踩)。

## 文件结构

| 文件 | 责任 | 里程碑 |
|---|---|---|
| `Sources/AgentPetCore/Store/SessionMeta.swift`(改) | 加 `groups: [String]`;merge/apply 带上 | D |
| `Sources/AgentPetCore/Store/SessionMeta.swift`(改) | `SessionMetaMerger.apply` 镜像 groups/summary 进 Session | B/D |
| `Sources/AgentPetCore/Model/SessionState.swift`(改) | `Session` 加 `groups: [String]` + `summary: String?` | B/D |
| `Sources/AgentPetCore/Summarize/SummaryPlanner.swift`(建) | 纯函数:哪些会话需重算摘要 | B |
| `Sources/AgentPetCore/Session/SessionTab.swift`(建) | `SessionTab` 枚举 + `SessionTabFilter` 纯过滤 | C/D |
| `Sources/AgentPetCore/Session/GroupMembership.swift`(建) | 分组增删/组名校验 纯函数 | D |
| `Sources/AppShellKit/SessionListOrganizer.swift`(改) | `organizeFlat` 平铺出口 | C |
| `Sources/AppShellKit/SummaryRefresher.swift`(建) | I/O 缝:对 needsRefresh 会话后台算摘要写回 meta | B |
| `Sources/AppShellKit/AppConfig.swift`(改) | 加 `sessionGroups: [String]` + `selectedTab: String` | C/D |
| `Sources/AppShellKit/SessionRowModel.swift`(改) | `SessionRowModel` 加 `summary: String?`;mapper 注入 | B |
| `Sources/apet/SessionPanel.swift`(改) | 摘要行 / 悬停☆ / tab 栏 / 分组右键 | A/B/C/D |
| `Sources/apet/AppCoordinator.swift`(改) | applyMetas 带 groups/summary;SummaryRefresher 接线;tab/组持久化 | B/C/D |
| `Sources/apet/SessionRowActions.swift`(改) | 「加入分组▸」菜单 / 建组删组 | D |

---

# 里程碑 A:悬停收藏按钮

### Task A1: 行尾悬停☆按钮,收藏视觉统一

**Files:**
- Modify: `Sources/apet/SessionPanel.swift`(`SessionRowCell` body 与标题前星)

**Interfaces:**
- Consumes: `SessionRowModel.favorite`、`onToggleFavorite: (String) -> Void`(面板既有回调)
- Produces: 无新接口(纯 GUI)

- [ ] **Step 1: 移除标题前的已收藏星**

`SessionPanel.swift` 标题 HStack 内删除:
```swift
                    if row.favorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                    }
```
(收藏视觉统一到行尾按钮,spec §3 决策。)

- [ ] **Step 2: SessionRowCell 加 hover 状态 + 行尾星按钮**

`SessionRowCell` 加 `@State private var hovering = false`;在最外层 `HStack` 末尾(相对时间列之后、行 padding 之内)加:
```swift
                // 悬停才现;已收藏常驻(spec §3)。点击 toggle,吞掉点击不触发行跳转。
                Image(systemName: row.favorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(row.favorite ? .yellow : .secondary)
                    .opacity(row.favorite || hovering ? 1 : 0)
                    .frame(width: 16)
                    .contentShape(Rectangle())
                    .onTapGesture { onToggleFavorite(row.id) }
                    .help(row.favorite ? "取消收藏" : "收藏")
```
并给 `SessionRowCell` 的根视图加 `.onHover { hovering = $0 }`。`onToggleFavorite` 需从 `SessionPanel` 传入 `SessionRowCell`(若当前 cell 未持有该回调,把回调透传进 cell 的 init)。

- [ ] **Step 3: 编译 + 手动冒烟**

Run: `swift build 2>&1 | tail -1` → Build complete
Run: `swift test 2>&1 | grep -E "Executed.*tests, with" | tail -1` → 716 全绿(无回归)
冒烟:`killall -9 apet; bash scripts/package-app.sh && open -n AgentPet.app`,悬停行现星、点击收藏、已收藏常驻、点星不跳转。

- [ ] **Step 4: 提交**
```bash
git add Sources/apet/SessionPanel.swift
git commit -m "feat(m3d-a): 行尾悬停收藏☆按钮,收藏视觉统一(移除标题前星)"
```

---

# 里程碑 B:内联本地摘要

### Task B1: Session 加 summary 字段;mapper 注入

**Files:**
- Modify: `Sources/AgentPetCore/Model/SessionState.swift`(`Session` 加 `summary: String?`)
- Modify: `Sources/AppShellKit/SessionRowModel.swift`(`SessionRowModel` 加 `summary`;`make` 注入)
- Test: `Tests/AppShellKitTests/SessionRowMapperTests.swift`(追加)

**Interfaces:**
- Produces: `Session.summary: String?`、`SessionRowModel.summary: String?`

- [ ] **Step 1: 写失败测试**(追加到 SessionRowMapperTests)

```swift
    // M3-D-B:Session.summary 透传进行模型。
    func test_summary_passthrough() {
        var s = makeSession()
        s.summary = "指令：修 bug · 最近：完成"
        XCTAssertEqual(SessionRowMapper.make(s).summary, "指令：修 bug · 最近：完成")
    }
    func test_summary_nilByDefault() {
        XCTAssertNil(SessionRowMapper.make(makeSession()).summary)
    }
```

- [ ] **Step 2: 跑测试确认失败**
Run: `swift test --filter SessionRowMapperTests 2>&1 | grep -E "error:" | head -2`
Expected: `value of type 'Session' has no member 'summary'`

- [ ] **Step 3: 实现**

`SessionState.swift` `Session` 结构体加存储属性(放 favorite/customName 旁,默认 nil):
```swift
    /// 面板内联本地摘要(M3-D-B;由 SessionMetaMerger 从 meta 镜像,nil=不显摘要行)。
    public var summary: String?
```
在 `Session` 的 memberwise `init` 里加 `summary: String? = nil` 参数并赋值(放末位保既有构造点不变)。

`SessionRowModel.swift`:结构体加 `public let summary: String?`;init 加 `summary: String? = nil`(放末位)并赋值;`make` 的 return 加 `summary: session.summary`。

- [ ] **Step 4: 跑测试** → PASS;`swift test` 全绿。

- [ ] **Step 5: 提交**
```bash
git add Sources/AgentPetCore/Model/SessionState.swift Sources/AppShellKit/SessionRowModel.swift Tests/AppShellKitTests/SessionRowMapperTests.swift
git commit -m "feat(m3d-b): Session/SessionRowModel 加 summary 字段"
```

### Task B2: SummaryPlanner 纯函数(哪些需重算)

**Files:**
- Create: `Sources/AgentPetCore/Summarize/SummaryPlanner.swift`
- Test: `Tests/AgentPetCoreTests/SummaryPlannerTests.swift`(新)

**Interfaces:**
- Produces: `SummaryPlanner.needsRefresh(agent: String, lastSeq: Int, cachedAnchor: Int?, hasTranscript: Bool) -> Bool`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import AgentPetCore

final class SummaryPlannerTests: XCTestCase {
    func test_transcriptSource_anchorStale_needsRefresh() {
        XCTAssertTrue(SummaryPlanner.needsRefresh(agent: "claude-code", lastSeq: 5, cachedAnchor: 3, hasTranscript: true))
    }
    func test_anchorMatches_noRefresh() {
        XCTAssertFalse(SummaryPlanner.needsRefresh(agent: "claude-code", lastSeq: 5, cachedAnchor: 5, hasTranscript: true))
    }
    func test_neverSummarized_needsRefresh() {
        XCTAssertTrue(SummaryPlanner.needsRefresh(agent: "claude-code", lastSeq: 1, cachedAnchor: nil, hasTranscript: true))
    }
    func test_noTranscriptSource_neverRefresh() {
        // OpenCode/QoderWork 无 jsonl 转录 → 不做本地摘要(spec §4)。
        XCTAssertFalse(SummaryPlanner.needsRefresh(agent: "opencode", lastSeq: 5, cachedAnchor: nil, hasTranscript: false))
        XCTAssertFalse(SummaryPlanner.needsRefresh(agent: "qoder-work", lastSeq: 5, cachedAnchor: nil, hasTranscript: false))
    }
}
```

- [ ] **Step 2: 跑测试确认失败** → `cannot find 'SummaryPlanner'`

- [ ] **Step 3: 实现**

```swift
import Foundation

/// 纯函数:判定某会话是否需要(重新)计算本地摘要。
/// 规则:有转录能力的源 且 缓存锚(上次算摘要时的 lastSeq)与当前 lastSeq 不一致 → 需重算。
/// 无转录源(OpenCode/QoderWork 等 DB 源)一律不做本地摘要(spec §4)。
public enum SummaryPlanner {
    public static func needsRefresh(agent: String, lastSeq: Int, cachedAnchor: Int?, hasTranscript: Bool) -> Bool {
        guard hasTranscript else { return false }
        return cachedAnchor != lastSeq
    }
}
```

- [ ] **Step 4: 跑测试** → PASS

- [ ] **Step 5: 提交**
```bash
git add Sources/AgentPetCore/Summarize/SummaryPlanner.swift Tests/AgentPetCoreTests/SummaryPlannerTests.swift
git commit -m "feat(m3d-b): SummaryPlanner 纯函数——按 lastSeq 锚失效判定,DB 源跳过"
```

### Task B3: apply 镜像 summary 进 Session

**Files:**
- Modify: `Sources/AgentPetCore/Store/SessionMeta.swift`(`SessionMetaMerger.apply`)
- Test: `Tests/AgentPetCoreTests/`(找现有 SessionMeta/Merger 测试追加;若无则新建 `SessionMetaMergerTests.swift`)

**Interfaces:**
- Consumes: `SessionMeta.cachedSummary/summaryAnchor`、`Session.lastSeq`、`Session.summary`
- Produces: `apply` 在 `meta.summaryAnchor == session.lastSeq` 时把 `cachedSummary` 写进 `session.summary`

- [ ] **Step 1: 写失败测试**(先 `grep -rln "SessionMetaMerger.apply" Tests/` 定位现有文件)

```swift
    func test_apply_mirrorsSummary_whenAnchorFresh() {
        let s = makeSession(lastSeq: 7)   // helper 需支持 lastSeq;若无则直接构造 Session
        let meta = SessionMeta(cachedSummary: "指令：X · 最近：Y", summaryAnchor: 7)
        XCTAssertEqual(SessionMetaMerger.apply(into: s, meta: meta).summary, "指令：X · 最近：Y")
    }
    func test_apply_dropsSummary_whenAnchorStale() {
        let s = makeSession(lastSeq: 8)
        let meta = SessionMeta(cachedSummary: "旧摘要", summaryAnchor: 7)
        XCTAssertNil(SessionMetaMerger.apply(into: s, meta: meta).summary, "锚过期不显旧摘要")
    }
```
(若无 makeSession helper,用 `Session(key:..., lastSeq: 7, ...)` 直接构造,参照 SessionRowMapperTests 的构造式。)

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**(`SessionMetaMerger.apply` 末尾、`return s` 前加)

```swift
        // M3-D-B:锚(summaryAnchor)与当前 lastSeq 一致才镜像缓存摘要,否则视为过期不显。
        if let cached = meta.cachedSummary, meta.summaryAnchor == session.lastSeq {
            s.summary = cached
        }
```

- [ ] **Step 4: 跑测试** → PASS;全量绿。

- [ ] **Step 5: 提交**
```bash
git add Sources/AgentPetCore/Store/SessionMeta.swift Tests/AgentPetCoreTests/
git commit -m "feat(m3d-b): apply 按锚镜像缓存摘要进 Session.summary(过期不显)"
```

### Task B4: SummaryRefresher(I/O 缝,后台算写回 meta)

**Files:**
- Create: `Sources/AppShellKit/SummaryRefresher.swift`
- Test: `Tests/AppShellKitTests/SummaryRefresherTests.swift`(新)

**Interfaces:**
- Consumes: `SummaryPlanner`、`LocalSummarizer`、`ConversationTailParser`、`AgentManifest.dbBackedAgents`
- Produces: `SummaryRefresher.refresh(sessions:metas:locate:readTail:now:) -> [String: SessionMeta]`
  - `locate: (SessionKey) -> String?`(转录路径,nil=无);`readTail: (String) -> [String]`(尾部行)
  - 返回**更新后的 metas**(只改需重算会话的 cachedSummary/summaryAnchor);纯函数(I/O 由注入闭包承担,可 mock)

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import AppShellKit
import AgentPetCore

final class SummaryRefresherTests: XCTestCase {
    private func sess(_ agent: String, _ id: String, seq: Int) -> Session {
        Session(key: SessionKey(agent: agent, root: "/r", sessionId: id),
                state: .running, cwd: nil, title: nil, terminal: nil,
                lastSeq: seq, lastActiveAt: 1000, acknowledged: false)
    }
    private let userLine = #"{"type":"user","message":{"content":"修登录 bug"}}"#
    private let asstLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"完成"}],"stop_reason":"end_turn"}}"#

    func test_computesSummary_forTranscriptSource_whenStale() {
        let s = sess("claude-code", "a", seq: 3)
        let out = SummaryRefresher.refresh(
            sessions: [s], metas: [:],
            locate: { _ in "/fake.jsonl" },
            readTail: { _ in [self.userLine, self.asstLine] })
        let m = out[SessionMetaMerger.metaKey(s.key)]
        XCTAssertEqual(m?.summaryAnchor, 3)
        XCTAssertTrue(m?.cachedSummary?.contains("修登录 bug") == true, "\(String(describing: m?.cachedSummary))")
    }
    func test_skips_whenAnchorFresh() {
        let s = sess("claude-code", "a", seq: 3)
        let metas = [SessionMetaMerger.metaKey(s.key): SessionMeta(cachedSummary: "旧", summaryAnchor: 3)]
        var readCalled = false
        let out = SummaryRefresher.refresh(sessions: [s], metas: metas,
            locate: { _ in "/x" }, readTail: { _ in readCalled = true; return [] })
        XCTAssertFalse(readCalled, "锚新鲜不该读文件")
        XCTAssertEqual(out[SessionMetaMerger.metaKey(s.key)]?.cachedSummary, "旧")
    }
    func test_skips_dbBackedSource() {
        let s = sess("opencode", "a", seq: 3)
        var locateCalled = false
        let out = SummaryRefresher.refresh(sessions: [s], metas: [:],
            locate: { _ in locateCalled = true; return "/x" }, readTail: { _ in [] })
        XCTAssertFalse(locateCalled, "DB 源不定位转录")
        XCTAssertNil(out[SessionMetaMerger.metaKey(s.key)]?.cachedSummary)
    }
    func test_noTranscriptFile_marksAnchor_noSummary() {
        // 有转录能力的源但文件找不到(如 hook-only 会话):记锚避免每轮重试,cachedSummary=nil。
        let s = sess("claude-code", "a", seq: 3)
        let out = SummaryRefresher.refresh(sessions: [s], metas: [:],
            locate: { _ in nil }, readTail: { _ in [] })
        let m = out[SessionMetaMerger.metaKey(s.key)]
        XCTAssertEqual(m?.summaryAnchor, 3)
        XCTAssertNil(m?.cachedSummary)
    }
}
```

- [ ] **Step 2: 跑测试确认失败** → `cannot find 'SummaryRefresher'`

- [ ] **Step 3: 实现**

```swift
import Foundation
import AgentPetCore

/// 会话本地摘要刷新(I/O 缝可注入,纯粹靠闭包做 I/O 便于单测)。
/// 对需重算(SummaryPlanner)的会话:定位转录 → 读尾部 → 解析 → LocalSummarizer,
/// 写回 meta.cachedSummary/summaryAnchor;返回更新后的整个 metas map(未变的原样)。
/// 找不到转录文件也记锚(避免每轮重试),cachedSummary 置 nil。
public enum SummaryRefresher {
    public static func refresh(
        sessions: [Session],
        metas: [String: SessionMeta],
        locate: (SessionKey) -> String?,
        readTail: (String) -> [String]
    ) -> [String: SessionMeta] {
        var out = metas
        for s in sessions {
            let hasTranscript = !AgentManifest.dbBackedAgents.contains(s.key.agent)
            let mk = SessionMetaMerger.metaKey(s.key)
            let anchor = out[mk]?.summaryAnchor
            guard SummaryPlanner.needsRefresh(agent: s.key.agent, lastSeq: s.lastSeq,
                                              cachedAnchor: anchor, hasTranscript: hasTranscript) else { continue }
            var meta = out[mk] ?? SessionMeta()
            if let path = locate(s.key) {
                let turns = ConversationTailParser.turns(lines: readTail(path))
                meta.cachedSummary = turns.isEmpty ? nil : LocalSummarizer.summarize(turns: turns)
            } else {
                meta.cachedSummary = nil
            }
            meta.summaryAnchor = s.lastSeq
            out[mk] = meta
        }
        return out
    }
}
```

- [ ] **Step 4: 跑测试** → PASS;全量绿。

- [ ] **Step 5: 提交**
```bash
git add Sources/AppShellKit/SummaryRefresher.swift Tests/AppShellKitTests/SummaryRefresherTests.swift
git commit -m "feat(m3d-b): SummaryRefresher——needsRefresh 会话后台算本地摘要写回 meta(I/O 缝可测)"
```

### Task B5: AppCoordinator 接线 + 面板摘要行

**Files:**
- Modify: `Sources/apet/AppCoordinator.swift`(change handler 里调 SummaryRefresher,后台队列;applyMetas 已经过 apply 自动带 summary)
- Modify: `Sources/apet/SessionPanel.swift`(目录下方渲染摘要行)

**Interfaces:**
- Consumes: `SummaryRefresher.refresh`、`SessionTranscriptLocator.find`、`TailLineReader.lastLines`、`SessionRowModel.summary`

- [ ] **Step 1: AppCoordinator 摘要刷新接线**

在 change handler(store 变更 → applyMetas 之前)加后台刷新:定位并读尾部走既有 `SessionTranscriptLocator.find` + `TailLineReader.lastLines(path:maxLines:100,maxBytes:524_288)`;`.ok(lines)` 取 lines 否则 `[]`。刷新在**后台队列**跑,完成回主线程写 `self.sessionMetas`、`sessionMetaStore.save`、触发面板刷新。示意:
```swift
        // M3-D-B:本地摘要后台刷新(needsRefresh 会话才算,零网络零成本)。
        let snapshot = store.activeSessions()
        let metasNow = self.sessionMetas
        DispatchQueue.global(qos: .utility).async {
            let updated = SummaryRefresher.refresh(
                sessions: snapshot, metas: metasNow,
                locate: { SessionTranscriptLocator.find(root: $0.root, sessionId: $0.sessionId) },
                readTail: { path in
                    if case .ok(let lines) = TailLineReader.lastLines(path: path, maxLines: 100, maxBytes: 524_288) {
                        return lines
                    }
                    return []
                })
            DispatchQueue.main.async { [weak self] in
                guard let self, updated != self.sessionMetas else { return }
                self.sessionMetas = updated
                try? self.sessionMetaStore.save(updated)
                self.refreshPanels()   // 用既有刷新路径(applyMetas → menuBar/petWindow update)
            }
        }
```
(`refreshPanels()` 用现场既有的刷新方法名;若无独立方法,复用 reap timer 里那段 `applyMetas(store.activeSessions())` → `menuBar?.update` / `petWindow?.update`。放进一个私有方法便于调用。)

- [ ] **Step 2: 面板摘要行**

`SessionPanel.swift` `SessionRowCell` 的 VStack 里,`subtitle`(目录)之后加:
```swift
                if let summary = row.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
```

- [ ] **Step 3: 编译 + 全量 + 冒烟**

Run: `swift build 2>&1 | tail -1` / `swift test 2>&1 | grep -E "tests, with" | tail -1`(全绿)
冒烟:重启 App,有转录的 Claude 会话目录下出现「指令：… · 最近：…」;OpenCode 会话无摘要行;新提问后摘要更新。

- [ ] **Step 4: 提交**
```bash
git add Sources/apet/AppCoordinator.swift Sources/apet/SessionPanel.swift
git commit -m "feat(m3d-b): 面板目录下内联本地摘要——后台刷新写回缓存,按 seq 失效"
```

---

# 里程碑 C:Tab 分流(取代分区)

### Task C1: SessionTab + SessionTabFilter 纯过滤

**Files:**
- Create: `Sources/AgentPetCore/Session/SessionTab.swift`
- Test: `Tests/AgentPetCoreTests/SessionTabFilterTests.swift`(新)

**Interfaces:**
- Produces:
  - `SessionTab { case all, favorites, running, read; case group(String) }`(Equatable)
  - `SessionTabFilter.filter(_ sessions: [Session], tab: SessionTab) -> [Session]`
  - `SessionTab.encoded: String` / `SessionTab(encoded:) -> SessionTab`(config 持久化用;`group(x)`↔`"group:x"`,内置↔`"all"/"favorites"/"running"/"read"`,未知→`.all`)

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import AgentPetCore

final class SessionTabFilterTests: XCTestCase {
    private func s(_ id: String, state: SessionState = .running, fav: Bool = false,
                   ack: Bool = false, groups: [String] = []) -> Session {
        var x = Session(key: SessionKey(agent: "claude-code", root: "/r", sessionId: id),
                        state: state, cwd: nil, title: nil, terminal: nil,
                        lastSeq: 1, lastActiveAt: 1000, acknowledged: ack)
        x.favorite = fav; x.groups = groups; return x
    }
    func test_all_returnsEverything() {
        let all = [s("a"), s("b", state: .waiting(.stop))]
        XCTAssertEqual(SessionTabFilter.filter(all, tab: .all).count, 2)
    }
    func test_favorites() {
        XCTAssertEqual(SessionTabFilter.filter([s("a", fav: true), s("b")], tab: .favorites).map(\.key.sessionId), ["a"])
    }
    func test_running() {
        XCTAssertEqual(SessionTabFilter.filter([s("a"), s("b", state: .stale)], tab: .running).map(\.key.sessionId), ["a"])
    }
    func test_read_acknowledgedWaiting() {
        let read = s("a", state: .waiting(.stop), ack: true)
        let unread = s("b", state: .waiting(.stop), ack: false)
        XCTAssertEqual(SessionTabFilter.filter([read, unread], tab: .read).map(\.key.sessionId), ["a"])
    }
    func test_group_membership_multiMember() {
        let x = s("a", groups: ["工作", "重要"])
        XCTAssertEqual(SessionTabFilter.filter([x, s("b")], tab: .group("工作")).map(\.key.sessionId), ["a"])
        XCTAssertEqual(SessionTabFilter.filter([x], tab: .group("重要")).count, 1)
        XCTAssertTrue(SessionTabFilter.filter([x], tab: .group("不存在")).isEmpty)
    }
    func test_encode_roundtrip() {
        for t in [SessionTab.all, .favorites, .running, .read, .group("工作:含冒号")] {
            XCTAssertEqual(SessionTab(encoded: t.encoded), t)
        }
        XCTAssertEqual(SessionTab(encoded: "垃圾未知"), .all)
    }
}
```

- [ ] **Step 2: 跑测试确认失败** → `cannot find 'SessionTab'`

- [ ] **Step 3: 实现**

```swift
import Foundation

/// 面板顶部标签页(取代分区)。group 为自定义分组名。
public enum SessionTab: Equatable {
    case all, favorites, running, read
    case group(String)

    /// config 持久化编码。group 用 "group:" 前缀 + 原名(名内允许冒号,只切首个前缀)。
    public var encoded: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .running: return "running"
        case .read: return "read"
        case .group(let n): return "group:" + n
        }
    }
    public init(encoded: String) {
        switch encoded {
        case "all": self = .all
        case "favorites": self = .favorites
        case "running": self = .running
        case "read": self = .read
        default:
            if encoded.hasPrefix("group:") { self = .group(String(encoded.dropFirst("group:".count))) }
            else { self = .all }
        }
    }
}

public enum SessionTabFilter {
    public static func filter(_ sessions: [Session], tab: SessionTab) -> [Session] {
        switch tab {
        case .all: return sessions
        case .favorites: return sessions.filter { $0.favorite }
        case .running: return sessions.filter { if case .running = $0.state { return true }; return false }
        case .read: return sessions.filter {
            guard case .waiting = $0.state else { return false }
            return $0.acknowledged
        }
        case .group(let name): return sessions.filter { $0.groups.contains(name) }
        }
    }
}
```

- [ ] **Step 4: 跑测试** → PASS
     (注:`Session.groups` 由 Task D1 加;若 C 先于 D 做,先在 SessionState 加空 `groups: [String] = []`——见 Task C1a。)

- [ ] **Step 4a(前置)**:若 `Session` 尚无 `groups`,先在 `SessionState.swift` 加 `public var groups: [String] = []`(memberwise init 末位加 `groups: [String] = []`),使本任务编译。此改与 Task D1 合流,提前做无害。

- [ ] **Step 5: 提交**
```bash
git add Sources/AgentPetCore/Session/SessionTab.swift Sources/AgentPetCore/Model/SessionState.swift Tests/AgentPetCoreTests/SessionTabFilterTests.swift
git commit -m "feat(m3d-c): SessionTab 枚举 + SessionTabFilter 纯过滤 + 编码往返"
```

### Task C2: organizeFlat 平铺出口

**Files:**
- Modify: `Sources/AppShellKit/SessionListOrganizer.swift`
- Test: `Tests/AppShellKitTests/`(找现有 SessionListOrganizerTests 追加)

**Interfaces:**
- Consumes: `SessionTabFilter.filter`、现有 `matches`/`isUnreadWaiting` 私有逻辑
- Produces: `OrganizedFlat { pinned: [SessionRowModel]; rest: [SessionRowModel] }`;`organizeFlat(sessions:tab:filter:now:tzOffset:) -> OrganizedFlat`

- [ ] **Step 1: 写失败测试**(追加到 SessionListOrganizerTests)

```swift
    func test_organizeFlat_tabFilters_and_pinsUnreadWaiting() {
        let run = sess("a", state: .running)                       // 进行中
        let waitUnread = sess("b", state: .waiting(.stop))          // 未读 waiting → 置顶
        let out = SessionListOrganizer.organizeFlat(
            sessions: [run, waitUnread], tab: .all, filter: "", now: 2000)
        XCTAssertEqual(out.pinned.map(\.sessionId), ["b"], "未读 waiting 置顶")
        XCTAssertEqual(out.rest.map(\.sessionId), ["a"])
    }
    func test_organizeFlat_runningTab_excludesOthers() {
        let out = SessionListOrganizer.organizeFlat(
            sessions: [sess("a", state: .running), sess("b", state: .stale)],
            tab: .running, filter: "", now: 2000)
        XCTAssertEqual((out.pinned + out.rest).map(\.sessionId), ["a"])
    }
```
(`sess` helper 参照该测试文件既有构造式;无则新增。)

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**(SessionListOrganizer.swift 加)

```swift
public struct OrganizedFlat: Equatable {
    public let pinned: [SessionRowModel]
    public let rest: [SessionRowModel]
    public init(pinned: [SessionRowModel], rest: [SessionRowModel]) {
        self.pinned = pinned; self.rest = rest
    }
}

extension SessionListOrganizer {
    /// 平铺出口(M3-D-C:tab 取代分区,无 section 标题)。
    /// tab 过滤 → 搜索过滤 → 未读 waiting 置顶(收藏优先)+ 其余(收藏优先稳定序)。
    public static func organizeFlat(
        sessions: [Session], tab: SessionTab, filter: String,
        now: Double, tzOffset: Double = 0
    ) -> OrganizedFlat {
        let tabbed = SessionTabFilter.filter(sessions, tab: tab)
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = tabbed.filter { needle.isEmpty || matches($0, needle) }
        var pinned: [SessionRowModel] = []
        var rest: [Session] = []
        for s in matched {
            if isUnreadWaiting(s) { pinned.append(SessionRowMapper.make(s, now: now, tzOffset: tzOffset)) }
            else { rest.append(s) }
        }
        pinned.sort { $0.favorite && !$1.favorite }
        let restSorted = rest.enumerated().sorted { a, b in
            if a.element.favorite != b.element.favorite { return a.element.favorite }
            return a.offset < b.offset
        }.map { SessionRowMapper.make($0.element, now: now, tzOffset: tzOffset) }
        return OrganizedFlat(pinned: pinned, rest: restSorted)
    }
}
```
(`matches`/`isUnreadWaiting` 现为 private——改为 `internal`(去掉 private)或 `fileprivate` 不够跨 extension 时同文件 extension 可访问 private?同文件内 extension 可访问 private。organizeFlat 若写在同文件则可直接用。**放同文件**。)

- [ ] **Step 4: 跑测试** → PASS;全量绿。

- [ ] **Step 5: 提交**
```bash
git add Sources/AppShellKit/SessionListOrganizer.swift Tests/AppShellKitTests/
git commit -m "feat(m3d-c): organizeFlat 平铺出口——tab 过滤 + 未读置顶,无分区标题"
```

### Task C3: config 加 selectedTab;面板 tab 栏 + 改用 organizeFlat

**Files:**
- Modify: `Sources/AppShellKit/AppConfig.swift`(加 `selectedTab: String`)
- Modify: `Sources/apet/SessionPanel.swift`(tab 栏 UI + 渲染改 organizeFlat)
- Modify: `Sources/apet/AppCoordinator.swift`(传 selectedTab、切换持久化)
- Test: `Tests/AppShellKitTests/AppConfigTests.swift`(若有,追加 selectedTab 默认/往返)

**Interfaces:**
- Consumes: `SessionTab`、`OrganizedFlat`、`AppConfig.selectedTab`

- [ ] **Step 1: AppConfig 加字段(向后兼容)**

`AppConfig.swift`:结构体加 `public var selectedTab: String`;memberwise init 加 `selectedTab: String = "all"`;`CodingKeys` 加 `selectedTab`;`init(from:)` 加 `selectedTab = try c.decodeIfPresent(String.self, forKey: .selectedTab) ?? "all"`;`defaults`/默认构造处传 `"all"`。若有 AppConfigTests,追加:缺字段解码默认 "all"、编码往返。

- [ ] **Step 2: 面板 tab 栏 + organizeFlat**

`SessionPanel.swift`:搜索框下方加 tab 栏(内置四个;分组 tab 见 D)。tab 栏用 HStack/ScrollView 横向按钮,选中态高亮;点击回调 `onSelectTab(SessionTab)`。列表渲染从「pinned + groups sections」改为消费 `OrganizedFlat`(pinned 段 + rest 段,无 section 标题)。空 → 「该分组暂无会话」。`AppCoordinator` 用 `config.selectedTab` 解码为 `SessionTab` 传入 organizeFlat;`onSelectTab` 里更新 `config.selectedTab = tab.encoded` + 持久化 + 刷新。

- [ ] **Step 3: 编译 + 全量 + 冒烟**

冒烟:tab 栏切换只显对应类;进行中/收藏/已读过滤正确;重启后停在上次 tab;pinned(等你)在「全部」仍置顶。

- [ ] **Step 4: 提交**
```bash
git add Sources/AppShellKit/AppConfig.swift Sources/apet/SessionPanel.swift Sources/apet/AppCoordinator.swift Tests/
git commit -m "feat(m3d-c): 面板 tab 栏取代分区——全部/收藏/进行中/已读,选中态持久化"
```

---

# 里程碑 D:自定义分组

### Task D1: SessionMeta.groups + apply 镜像 + GroupMembership 纯函数

**Files:**
- Modify: `Sources/AgentPetCore/Store/SessionMeta.swift`(加 `groups`;merge/apply 带上)
- Create: `Sources/AgentPetCore/Session/GroupMembership.swift`
- Test: `Tests/AgentPetCoreTests/GroupMembershipTests.swift`(新)+ SessionMeta 测试追加

**Interfaces:**
- Produces:
  - `SessionMeta.groups: [String]`(默认 `[]`);merge 并集去重;apply 镜像进 `session.groups`
  - `GroupMembership.toggle(_ group: String, in groups: [String]) -> [String]`(有则移除无则加,去重)
  - `GroupMembership.isValidName(_ s: String) -> Bool`(非空 trim、长度 ≤ 30、无控制字符/bidi)

- [ ] **Step 1: 写失败测试**

`GroupMembershipTests.swift`:
```swift
import XCTest
@testable import AgentPetCore

final class GroupMembershipTests: XCTestCase {
    func test_toggle_addsThenRemoves() {
        XCTAssertEqual(GroupMembership.toggle("工作", in: []), ["工作"])
        XCTAssertEqual(GroupMembership.toggle("工作", in: ["工作"]), [])
    }
    func test_toggle_dedups() {
        XCTAssertEqual(GroupMembership.toggle("A", in: ["A", "A"]), [])   // 全移除
        XCTAssertEqual(GroupMembership.toggle("B", in: ["A"]).sorted(), ["A", "B"])
    }
    func test_isValidName() {
        XCTAssertTrue(GroupMembership.isValidName("工作"))
        XCTAssertFalse(GroupMembership.isValidName(""))
        XCTAssertFalse(GroupMembership.isValidName("   "))
        XCTAssertFalse(GroupMembership.isValidName(String(repeating: "x", count: 31)))
        XCTAssertFalse(GroupMembership.isValidName("坏\u{202E}名"))
        XCTAssertFalse(GroupMembership.isValidName("控\u{0007}制"))
    }
}
```
SessionMeta 测试追加:merge 的 groups 并集去重;apply 把 meta.groups 镜像进 session.groups。

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

`SessionMeta.swift`:加 `public var groups: [String]`(init 默认 `[]`;CodingKeys 加;`init(from:)` `groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []`);`merge` 加 `groups: Array(Set(old.groups).union(new.groups)).sorted()`;`SessionMetaMerger.apply` 加 `s.groups = meta.groups`。

`GroupMembership.swift`:
```swift
import Foundation

public enum GroupMembership {
    public static func toggle(_ group: String, in groups: [String]) -> [String] {
        if groups.contains(group) { return groups.filter { $0 != group } }
        return groups + [group]
    }
    public static func isValidName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 30 else { return false }
        let bidi: Set<Character> = ["\u{202A}","\u{202B}","\u{202C}","\u{202D}","\u{202E}",
                                    "\u{2066}","\u{2067}","\u{2068}","\u{2069}"]
        return !t.contains { c in
            guard let u = c.unicodeScalars.first else { return true }
            if u.value < 0x20 || (u.value >= 0x7F && u.value <= 0x9F) { return true }
            return bidi.contains(c)
        }
    }
}
```

- [ ] **Step 4: 跑测试** → PASS;全量绿。

- [ ] **Step 5: 提交**
```bash
git add Sources/AgentPetCore/Store/SessionMeta.swift Sources/AgentPetCore/Session/GroupMembership.swift Tests/AgentPetCoreTests/
git commit -m "feat(m3d-d): SessionMeta.groups(并集去重)+ apply 镜像 + GroupMembership.toggle/isValidName"
```

### Task D2: config 分组注册表 + 右键加入分组 + tab 栏动态分组

**Files:**
- Modify: `Sources/AppShellKit/AppConfig.swift`(加 `sessionGroups: [String]`)
- Modify: `Sources/apet/SessionRowActions.swift`(「加入分组▸」菜单 + 建组)
- Modify: `Sources/apet/SessionPanel.swift`(右键子菜单 + tab 栏追加分组 tab + 「+」建组 + 删组)
- Modify: `Sources/apet/AppCoordinator.swift`(分组增删持久化 + meta.groups 写入)
- Test: `Tests/AppShellKitTests/AppConfigTests.swift`(sessionGroups 默认/往返)

**Interfaces:**
- Consumes: `GroupMembership`、`SessionMeta.groups`、`AppConfig.sessionGroups`、`SessionTab.group`

- [ ] **Step 1: AppConfig 加 sessionGroups(向后兼容)**

同 C3 模式:`public var sessionGroups: [String]`;init 默认 `[]`;CodingKeys + `decodeIfPresent(...) ?? []`。测试:缺字段默认 `[]`、往返。

- [ ] **Step 2: 右键「加入分组▸」+ 建组/删组接线**

`SessionRowActions`/`SessionPanel` 右键菜单加 `Menu("加入分组")`:遍历 `config.sessionGroups` 出 `Toggle`(勾选态 = `session.groups.contains(name)`),toggle → `AppCoordinator` 写 `meta.groups = GroupMembership.toggle(name, in: meta.groups)` + 持久化 + 刷新;末尾 `Button("新建分组…")` → `promptRename` 同款输入 → `GroupMembership.isValidName` 校验 → 加入 `config.sessionGroups`(去重)+ 把当前会话加入该组。tab 栏「+」建空组同理。分组 tab 右键「删除分组」→ 确认 → 从 `config.sessionGroups` 移除 + 清各 `meta.groups` 的该名 + 若当前选中被删则回退 `.all`。

- [ ] **Step 3: tab 栏追加分组 tab**

`SessionPanel` tab 栏在内置四个后,按 `config.sessionGroups` 顺序追加 `#<name>` tab(`SessionTab.group(name)`);多时横向滚动。

- [ ] **Step 4: 编译 + 全量 + 冒烟**

冒烟:右键加入「工作」→ 出现 #工作 tab → 切过去只显该会话;一个会话可加多组;删组后 tab 消失、会话回全部;重启保留分组与成员。

- [ ] **Step 5: 提交**
```bash
git add Sources/AppShellKit/AppConfig.swift Sources/apet/ Tests/
git commit -m "feat(m3d-d): 自定义分组——config 注册表 + 右键加入/建组/删组 + tab 栏动态分组 tab"
```

### Task D3: 文档同步

**Files:**
- Modify: `README.md`(会话管理功能补 tab/分组/内联摘要/悬停收藏)
- Modify: `CLAUDE.md`(路线图 M3-D 条目)

- [ ] **Step 1: README/CLAUDE.md 更新**

README「🗂 会话管理」条目补:内联本地摘要、Tab 分流(全部/收藏/进行中/已读+自定义分组)、悬停收藏、可多属分组。CLAUDE.md 路线图加 M3-D 条目指向本 spec。测试计数刷新为实际值。

- [ ] **Step 2: 全量 + 提交**
```bash
git add README.md CLAUDE.md
git commit -m "docs(m3d): README/CLAUDE.md 同步面板 UX 升级(tab/分组/内联摘要/悬停收藏)"
```

---

## 完成后(不在本计划内自动执行)

1. **七视角实现评审**(用户流程要求:每核心阶段评审+修复)。
2. 分支合并走 superpowers:finishing-a-development-branch。
