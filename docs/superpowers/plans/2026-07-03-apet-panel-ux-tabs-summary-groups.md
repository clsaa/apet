# 会话面板 UX 升级 实现计划(悬停收藏 / Tab / 自定义分组)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 会话面板:悬停收藏按钮、顶部 Tab 取代分区、可多属的自定义分组。

**Architecture:** 纯逻辑(tab 过滤 / 分组成员 / 组名校验 / 平铺组织)入 AgentPetCore/AppShellKit 单测;GUI(SwiftUI 行/tab 栏/右键)薄胶水。分三里程碑 A→B→C 独立交付(实测决策:内联启发式摘要已砍,标题已是 Claude ai-title 好摘要)。

**Tech Stack:** Swift 5.9(SwiftPM 三 target)、XCTest、SwiftUI/AppKit。

**权威 spec:** `docs/superpowers/specs/2026-07-03-apet-panel-ux-tabs-summary-groups-design.md`。冲突以 spec 为准并回报。

## Global Constraints(每个任务隐含)

- 零第三方依赖;AgentPetCore 只用 Foundation。
- 禁 `Date()`/`Date.now`——`now: Double` 注入(apet 组织层既有 `Date().timeIntervalSince1970` 闭包除外)。
- 归一键 `SessionMetaMerger.metaKey(key) = "agent::root::sessionId"`。
- 测试是规范:失败改实现不改测试;提交前 `swift test` 全绿(当前基线 716)。
- 中文 commit;小步一交付物一 commit;分支 `feature/panel-ux`(不在 main 开发)。
- 面板 320pt 宽;新增文本标签一律 `.lineLimit(1)` + `.fixedSize()`(否则 CJK 竖排乱码——本轮已踩)。

## 文件结构

| 文件 | 责任 | 里程碑 |
|---|---|---|
| `Sources/AgentPetCore/Model/SessionState.swift`(改) | `Session` 加 `groups: [String]`;`SessionMetaMerger.apply` 镜像 groups | B/C |
| `Sources/AgentPetCore/Session/SessionTab.swift`(建) | `SessionTab` 枚举 + `SessionTabFilter` 纯过滤 | B/C |
| `Sources/AgentPetCore/Session/GroupMembership.swift`(建) | 分组增删/组名校验 纯函数 | C |
| `Sources/AppShellKit/SessionListOrganizer.swift`(改) | `organizeFlat` 平铺出口 | B |
| `Sources/AppShellKit/AppConfig.swift`(改) | 加 `sessionGroups: [String]` + `selectedTab: String` | B/C |
| `Sources/apet/SessionPanel.swift`(改) | 悬停☆ / tab 栏 / 分组右键 | A/B/C |
| `Sources/apet/AppCoordinator.swift`(改) | applyMetas 带 groups;tab/组持久化 | B/C |
| `Sources/apet/SessionRowActions.swift`(改) | 「加入分组▸」菜单 / 建组删组 | C |

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

# 里程碑 B:Tab 分流(取代分区)

### Task B1: SessionTab + SessionTabFilter 纯过滤

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
     (注:`Session.groups` 由 Task D1 加;若 C 先于 D 做,先在 SessionState 加空 `groups: [String] = []`——见 Task B1a。)

- [ ] **Step 4a(前置)**:在 `SessionState.swift` 给 `Session` 加 `public var groups: [String] = []`(memberwise init 末位加 `groups: [String] = []`),使本任务编译。此改与 Task C1(分组)合流,提前做无害。

- [ ] **Step 5: 提交**
```bash
git add Sources/AgentPetCore/Session/SessionTab.swift Sources/AgentPetCore/Model/SessionState.swift Tests/AgentPetCoreTests/SessionTabFilterTests.swift
git commit -m "feat(m3d-b): SessionTab 枚举 + SessionTabFilter 纯过滤 + 编码往返"
```

### Task B2: organizeFlat 平铺出口

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
    /// U1:未读 waiting 跨 tab 常驻——即便选「收藏」tab 且它非收藏,仍在 pinned。
    func test_organizeFlat_unreadWaiting_pinnedAcrossTabs() {
        let waitUnread = sess("b", state: .waiting(.stop))   // 非收藏、未读 waiting
        let out = SessionListOrganizer.organizeFlat(
            sessions: [waitUnread], tab: .favorites, filter: "", now: 2000)
        XCTAssertEqual(out.pinned.map(\.sessionId), ["b"], "等你会话不被 favorites tab 过滤掉")
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
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let searched = sessions.filter { needle.isEmpty || matches($0, needle) }
        // U1(交互评审 P0-1):未读 waiting「等你」pinned **跨 tab 常驻**——tab 过滤只作用于 rest。
        // 否则停在「收藏/分组」tab 会藏掉刚变等你的会话(菜单栏显🟠却点不到)。
        var pinnedS: [Session] = []
        var others: [Session] = []
        for s in searched {
            if isUnreadWaiting(s) { pinnedS.append(s) } else { others.append(s) }
        }
        let restFiltered = SessionTabFilter.filter(others, tab: tab)   // tab 只过滤非置顶
        var pinned = pinnedS.map { SessionRowMapper.make($0, now: now, tzOffset: tzOffset) }
        pinned.sort { $0.favorite && !$1.favorite }
        let restSorted = restFiltered.enumerated().sorted { a, b in
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
git commit -m "feat(m3d-b): organizeFlat 平铺出口——tab 过滤 + 未读置顶,无分区标题"
```

### Task B3: config 加 selectedTab;面板 tab 栏 + 改用 organizeFlat

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
git commit -m "feat(m3d-b): 面板 tab 栏取代分区——全部/收藏/进行中/已读,选中态持久化"
```

---

# 里程碑 C:自定义分组

### Task C1: SessionMeta.groups + apply 镜像 + GroupMembership 纯函数

**Files:**
- Modify: `Sources/AgentPetCore/Store/SessionMeta.swift`(加 `groups`;merge/apply 带上)
- Create: `Sources/AgentPetCore/Session/GroupMembership.swift`
- Test: `Tests/AgentPetCoreTests/GroupMembershipTests.swift`(新)+ SessionMeta 测试追加

**Interfaces:**
- Produces:
  - `SessionMeta.groups: [String]`(默认 `[]`);merge 并集去重;apply 镜像进 `session.groups`(`Session.groups` 字段已由 Task B1 Step 4a 加)
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
git commit -m "feat(m3d-c): SessionMeta.groups(并集去重)+ apply 镜像 + GroupMembership.toggle/isValidName"
```

### Task C2: config 分组注册表 + 右键加入分组 + tab 栏动态分组

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
git commit -m "feat(m3d-c): 自定义分组——config 注册表 + 右键加入/建组/删组 + tab 栏动态分组 tab"
```

### Task C3: 文档同步

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

# 里程碑 D:终端图标(真 app 图标)

### Task D1: TerminalKind.bundleId 纯映射(收敛双份)

**Files:**
- Modify: `Sources/AgentPetCore/Model/AgentEvent.swift`(给 `TerminalKind` 加 `bundleId`)
- Modify: `Sources/apet/TerminalFocusService.swift`(`fallbackBundleId` 复用)
- Test: `Tests/AgentPetCoreTests/`(找 TerminalCapability/AgentEvent 测试文件追加;无则新建 `TerminalKindTests.swift`)

**Interfaces:**
- Produces: `TerminalKind.bundleId: String?`

- [ ] **Step 1: 写失败测试**
```swift
import XCTest
@testable import AgentPetCore

final class TerminalKindTests: XCTestCase {
    func test_bundleId_perKind() {
        XCTAssertEqual(TerminalKind.iterm2.bundleId, "com.googlecode.iterm2")
        XCTAssertEqual(TerminalKind.terminal.bundleId, "com.apple.Terminal")
        XCTAssertEqual(TerminalKind.warp.bundleId, "dev.warp.Warp-Stable")
        XCTAssertEqual(TerminalKind.ghostty.bundleId, "com.mitchellh.ghostty")
        XCTAssertEqual(TerminalKind.vscode.bundleId, "com.microsoft.VSCode")
        XCTAssertNil(TerminalKind.other.bundleId)
    }
}
```

- [ ] **Step 2: 跑测试确认失败** → `has no member 'bundleId'`

- [ ] **Step 3: 实现**(`AgentEvent.swift`,`TerminalKind` 加扩展)
```swift
public extension TerminalKind {
    /// 默认 app bundleId(图标 + 激活兜底共用;other 未知→nil)。
    var bundleId: String? {
        switch self {
        case .iterm2:   return "com.googlecode.iterm2"
        case .terminal: return "com.apple.Terminal"
        case .warp:     return "dev.warp.Warp-Stable"
        case .ghostty:  return "com.mitchellh.ghostty"
        case .vscode:   return "com.microsoft.VSCode"
        case .other:    return nil
        }
    }
}
```
`TerminalFocusService.fallbackBundleId` 内 `switch ref.kind` 那段替换为 `return ref.bundleId ?? ref.kind.bundleId`。

- [ ] **Step 4: 跑测试** → PASS;全量绿。

- [ ] **Step 5: 提交**
```bash
git add Sources/AgentPetCore/Model/AgentEvent.swift Sources/apet/TerminalFocusService.swift Tests/AgentPetCoreTests/
git commit -m "feat(m3d-d): TerminalKind.bundleId 纯映射,fallbackBundleId 复用(收敛双份)"
```

### Task D2: SessionRowModel.terminalBundleId + mapper

**Files:**
- Modify: `Sources/AppShellKit/SessionRowModel.swift`
- Test: `Tests/AppShellKitTests/SessionRowMapperTests.swift`(追加)

**Interfaces:**
- Produces: `SessionRowModel.terminalBundleId: String?`(`terminal?.bundleId ?? terminal?.kind.bundleId`;terminal nil→nil)

- [ ] **Step 1: 写失败测试**
```swift
    func test_terminalBundleId_fromKind() {
        let s = makeSession(terminal: TerminalRef(kind: .warp))
        XCTAssertEqual(SessionRowMapper.make(s).terminalBundleId, "dev.warp.Warp-Stable")
    }
    func test_terminalBundleId_prefersExplicitRefBundleId() {
        let s = makeSession(terminal: TerminalRef(kind: .other, bundleId: "com.qoder.work"))
        XCTAssertEqual(SessionRowMapper.make(s).terminalBundleId, "com.qoder.work")
    }
    func test_terminalBundleId_nilWhenNoTerminal() {
        XCTAssertNil(SessionRowMapper.make(makeSession()).terminalBundleId)
    }
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**:`SessionRowModel` 加 `public let terminalBundleId: String?`;init 末位加 `terminalBundleId: String? = nil`;`make` 内 `let terminalBundleId = session.terminal?.bundleId ?? session.terminal?.kind.bundleId`,return 带上。

- [ ] **Step 4: 跑测试** → PASS

- [ ] **Step 5: 提交**
```bash
git add Sources/AppShellKit/SessionRowModel.swift Tests/AppShellKitTests/SessionRowMapperTests.swift
git commit -m "feat(m3d-d): SessionRowModel.terminalBundleId(kind→bundleId,未知nil)"
```

### Task D3: AppIconCache + 行首终端图标(GUI)

**Files:**
- Create: `Sources/apet/AppIconCache.swift`
- Modify: `Sources/apet/SessionPanel.swift`(状态圆点右、标题左插图标)

- [ ] **Step 1: AppIconCache**
```swift
import AppKit

/// 按 bundleId 取 app 图标,进程内缓存(图标不变)。取不到→nil(调用方兜底 SF Symbol)。
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(bundleId: String) -> NSImage? {
        if let c = cache[bundleId] { return c }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleId] = img
        return img
    }
}
```

- [ ] **Step 2: 行首图标**(`SessionRowCell`,状态圆点之后、VStack 之前)
```swift
                if let bid = row.terminalBundleId {
                    if let icon = AppIconCache.icon(bundleId: bid) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
```
(`terminalBundleId == nil` 不占位。)

- [ ] **Step 3: 编译 + 冒烟**:Claude/hook 会话行首现 iTerm2/Warp 真图标;纯 jsonl 无 hook 会话不显图标;QoderWork 现 Qoder 图标。

- [ ] **Step 4: 提交**
```bash
git add Sources/apet/AppIconCache.swift Sources/apet/SessionPanel.swift
git commit -m "feat(m3d-d): 行首终端真 app 图标(NSWorkspace 缓存,取不到退 terminal 符号)"
```

---

# 里程碑 E:视觉打磨(UI review P0)

### Task E1: PathAbbreviator 纯函数 + 副标题折叠

**Files:**
- Create: `Sources/AgentPetCore/Session/PathAbbreviator.swift`
- Modify: `Sources/AppShellKit/SessionRowModel.swift`(subtitle 用它)
- Test: `Tests/AgentPetCoreTests/PathAbbreviatorTests.swift`(新)

**Interfaces:**
- Produces: `PathAbbreviator.abbreviate(_ path: String, home: String, maxLen: Int = 32) -> String`

- [ ] **Step 1: 写失败测试**
```swift
import XCTest
@testable import AgentPetCore

final class PathAbbreviatorTests: XCTestCase {
    func test_homePrefix_toTilde() {
        XCTAssertEqual(PathAbbreviator.abbreviate("/Users/n/workspace/apet", home: "/Users/n"), "~/workspace/apet")
    }
    func test_nonHome_unchanged_ifShort() {
        XCTAssertEqual(PathAbbreviator.abbreviate("/opt/x", home: "/Users/n"), "/opt/x")
    }
    func test_tooLong_collapsesToParentLeaf() {
        let long = "/Users/n/a/b/c/d/e/f/g/really-long-project-name-here"
        let out = PathAbbreviator.abbreviate(long, home: "/Users/n", maxLen: 24)
        XCTAssertTrue(out.hasPrefix("…/"), out)
        XCTAssertTrue(out.hasSuffix("really-long-project-name-here"), out)
    }
    func test_empty_returnsEmpty() {
        XCTAssertEqual(PathAbbreviator.abbreviate("", home: "/Users/n"), "")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**
```swift
import Foundation

/// 面板副标题路径折叠:home→`~`;仍超 maxLen → `…/<父>/<叶>`(纯函数)。
public enum PathAbbreviator {
    public static func abbreviate(_ path: String, home: String, maxLen: Int = 32) -> String {
        guard !path.isEmpty else { return "" }
        var p = path
        if !home.isEmpty, p == home || p.hasPrefix(home + "/") {
            p = "~" + p.dropFirst(home.count)
        }
        if p.count <= maxLen { return p }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return p }
        let leaf = parts[parts.count - 1], parent = parts[parts.count - 2]
        return "…/\(parent)/\(leaf)"
    }
}
```

- [ ] **Step 4: 跑测试** → PASS

- [ ] **Step 5: 接线 + 提交**:`SessionRowModel.make` 的 `subtitle = session.cwd ?? ""` 改为 `PathAbbreviator.abbreviate(session.cwd ?? "", home: NSHomeDirectory())`(NSHomeDirectory 在 AppShellKit 可用;若 core 层则由 apet 注入 home——**放 mapper(AppShellKit)用 NSHomeDirectory 即可**)。
```bash
git add Sources/AgentPetCore/Session/PathAbbreviator.swift Sources/AppShellKit/SessionRowModel.swift Tests/AgentPetCoreTests/PathAbbreviatorTests.swift
git commit -m "feat(m3d-e): PathAbbreviator 路径折叠(home→~/超长→…/父/叶),副标题去重复前缀"
```

### Task E2: 状态指示器加形状(色盲无障碍)

**Files:**
- Modify: `Sources/apet/SessionPanel.swift`(圆点 → 每状态 SF Symbol)

- [ ] **Step 1: 实现**(`SessionRowCell` 的 `Circle().fill(dotColor)` 替换)
```swift
                Image(systemName: dotSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(dotColor)
                    .frame(width: 12)
```
加计算属性(state→symbol,复用现有 dot→color):
```swift
    private var dotSymbol: String {
        switch row.dot {
        case .running:     return "circle.fill"
        case .attention:   return "exclamationmark.circle.fill"
        case .doneWaiting: return "stop.circle.fill"
        case .read:        return "checkmark.circle.fill"
        case .stale:       return "minus.circle"
        }
    }
```
(`dotColor` 保留;isInferred 的降透明保留。)

- [ ] **Step 2: 编译 + 冒烟**:五种状态形状可区分(灰度截图下也能分)。
- [ ] **Step 3: 提交**
```bash
git add Sources/apet/SessionPanel.swift
git commit -m "feat(m3d-e): 状态指示器形状+色(色盲无障碍,UI review P0)"
```

### Task E3: 元数据统一 + 整行 hover 背景 + 字号收敛

**Files:**
- Modify: `Sources/apet/SessionPanel.swift`

- [ ] **Step 1: 元数据统一**:「仅激活」「推断」「无跳转」三者统一为 size 10 `.foregroundStyle(.tertiary)` 灰字(去掉「推断」的 chip 背景);**只有 agent 徽标保留紫色 chip**。

- [ ] **Step 2: 整行 hover 背景**:`SessionRowCell` 根视图(已有 `hovering` 状态自组件 A)加 `.background(hovering ? Color.primary.opacity(0.06) : .clear)`。

- [ ] **Step 3: 字号核对**:标题 13 / 副标题 11 / 徽标·时间·次要标签 10,三档灰度(primary/secondary/tertiary)。

- [ ] **Step 4: 编译 + 冒烟 + 提交**
```bash
git add Sources/apet/SessionPanel.swift
git commit -m "feat(m3d-e): 元数据视觉统一(次要状态灰字/仅agent彩chip)+ 整行hover背景 + 字号三级"
```

---

# 里程碑 F:可缩放面板窗口

### Task F1: AppConfig 加 panelWidth/panelHeight

**Files:**
- Modify: `Sources/AppShellKit/AppConfig.swift`
- Test: `Tests/AppShellKitTests/AppConfigTests.swift`(若有)

- [ ] **Step 1**:`AppConfig` 加 `panelWidth: Double`/`panelHeight: Double`;memberwise init 默认 `360`/`480`;CodingKeys + `decodeIfPresent(...) ?? 360/480`。测试:缺字段默认、往返。
- [ ] **Step 2**:全量绿。
- [ ] **Step 3**:提交 `feat(m3d-f): AppConfig 面板尺寸持久化字段`

### Task F2: 菜单栏面板换可缩放 NSWindow

**Files:**
- Modify: `Sources/apet/MenuBarController.swift`(NSPopover → 可缩放 NSWindow)
- Modify: `Sources/apet/SessionPanel.swift`(去写死 width,改 min/ideal/max)

- [ ] **Step 1**:`SessionPanel` 根 `.frame(width: 320)` → `.frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)`;行内元素靠既有 fixedSize/layoutPriority 撑(本轮竖排教训,勿回退)。
- [ ] **Step 2**:菜单栏点击从 `popover.show` 改为 toggle 一个 `.titled/.resizable/.utilityWindow` 或复用 `ApeFloatingWindow` 加 `.resizable` 的窗口;初始 frame 用 `config.panelWidth/Height`;定位在菜单栏图标下方。
- [ ] **Step 3**:`NSWindowDelegate.windowDidResize` → 写 `config.panelWidth/Height` + 持久化(去抖);失焦行为:`.nonactivatingPanel`,点别处可关(或保留,记决策)。
- [ ] **Step 4**:编译 + 冒烟(拖拽改大小、重启保留尺寸、行随宽自适应不竖排)。桌宠 popover 暂留(记遗留)。
- [ ] **Step 5**:提交 `feat(m3d-f): 菜单栏面板换可缩放浮动窗口,尺寸持久化(放弃popover手感,用户选A)`

---

## 完成后(不在本计划内自动执行)

1. **七视角实现评审**(用户流程要求:每核心阶段评审+修复)。
2. 分支合并走 superpowers:finishing-a-development-branch。
