# M3-B 会话管理 Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development / executing-plans。Steps 用 `- [ ]` 追踪。

**Goal:** 30 个会话时的定位刚需(用户评审最高价值):面板**搜索** + 「等你的」**置顶高亮** + 会话**重命名/收藏**(F7) + 创建/修改**时间**(F10) + **复制 sessionID / 恢复命令**(F11)。

**Architecture:** 可决策逻辑全下沉纯函数(`SessionListOrganizer` 搜索/分组/置顶、`RelativeTime` 时间、`ResumeCommand` argv 渲染、`SessionMetaMerger` 合并),`now: Double` 注入;新 IO 缝 `SessionMetaStore` 协议化 + Mock;GUI 薄接线。

**依赖发现:** 现仓**无** `SessionMeta`/`SessionMetaStore`/`SessionListOrganizer`,Session 无 favorite/customName/createdAt。M3-B 需先建 A2 持久化地基(F7 依赖)。

## Global Constraints
- 零依赖、core 无副作用不调 `Date()`、`now: Double` 注入;新 IO 缝协议化 + Mock;向后兼容 decodeIfPresent。
- metaKey = `"\(agent)::\(root)::\(sessionId)"`(**含 root**,CLAUDE.md #3)。
- **acknowledged 真值仍在状态机,不进 SessionMetaStore**(只持久 favorite/customName/cachedSummary/firstSeenAt)。save 仅显式用户操作触发。
- 测试是规范;镜像路径;小步提交中文 message;`swift test` 提交前全绿(基线 500)。
- 分支 `feature/m3-b-session-mgmt`。

---

### Task 1: SessionListOrganizer 纯函数(搜索 + 分组 + 等我置顶)
**Files:** Create `Sources/AppShellKit/SessionListOrganizer.swift`;Test `Tests/AppShellKitTests/SessionListOrganizerTests.swift`
**Interfaces:**
- `enum GroupDimension { case status, date, agent }`
- `struct OrganizedList: Equatable { pinned: [SessionRowModel]; groups: [(title: String, rows: [SessionRowModel])] }`（pinned=未读「等你」置顶）
- `enum SessionListOrganizer { static func organize(rows: [SessionRowModel], dimension:, filter: String, now: Double) -> OrganizedList }`
- filter 前缀/包含匹配 title/subtitle(cwd)/id;大小写不敏感;空 filter 不过滤。
- pinned = `dot ∈ {doneWaiting, attention}`(未读等你);其余按 dimension 分组。date 维度用 now 注入,今天/昨天/本周/更早,跨午夜用例。
- [ ] 写失败测试(过滤命中/不命中/大小写、置顶挑选、状态分组、日期分组跨午夜、空 filter) → 跑红 → 实现 → 跑绿 → commit

### Task 2: SessionMeta + SessionMetaStore(A2 持久化地基)
**Files:** Create `Sources/AgentPetCore/Store/SessionMeta.swift`(SessionMeta + SessionMetaMerger 纯);`Sources/AppShellKit/SessionMetaStore.swift`(协议 FileOps 注入,落 `~/Library/Application Support/AgentPet/session-meta.json`,损坏→空);Tests 两处。
**Interfaces:**
- `struct SessionMeta: Codable, Equatable { favorite: Bool=false; customName: String?; firstSeenAt: Double?; cachedSummary: String?; summaryAnchor: Int? }`
- `enum SessionMetaMerger { static func metaKey(_ key: SessionKey) -> String; static func apply(into: Session, meta: SessionMeta?) -> Session }`(镜像 favorite/customName→Session;firstSeenAt→createdAt 取 min)
- `SessionMetaStore`：`load() -> [String: SessionMeta]`、`save(_:)`；损坏 json 回退空(对标 ConfigStore)。
- [ ] 测试(合并 last-non-nil-wins、firstSeenAt min、metaKey 含 root、损坏 json 回退、round-trip) → 红→绿→commit

### Task 3: F10 createdAt + 相对时间纯函数
**Files:** Session 加 `createdAt: Double?`(运行时镜像,IO 缝注入);Create `Sources/AppShellKit/RelativeTime.swift`;Tests。
**Interfaces:** `enum RelativeTime { static func short(from ts: Double, now: Double) -> String }`(“刚刚/几分钟前/今天/昨天/更早”,now 注入,跨午夜)。SessionRowModel 加 `createdText/lastActiveText`(可选,组织层填)。
- [ ] 测试(各时间桶 + 跨午夜边界) → 红→绿→commit

### Task 4: F11 复制 ID + 恢复命令 argv 渲染
**Files:** Create `Sources/AgentPetCore/Terminal/ResumeCommand.swift`;Tests。
**Interfaces:** `enum ResumeCommand { static func argv(agent: String, sessionId: String) -> [String]?; static func display(agent:, sessionId:) -> String? }`。claude → `["claude","--resume","<id>"]`;sessionId 过 UUID 白名单(非法→nil);未知 agent → nil(M3-C 接 Qoder 再补)。**红队用例**:恶意 id 被当单一 argv/被拒。
- [ ] 测试(claude 渲染、UUID 白名单、恶意 id、未知 agent nil) → 红→绿→commit

### Task 5: UI 接线(搜索框 + 置顶区 + 重命名/收藏 + 时间 + 复制)
**Files:** `SessionPanel.swift`(顶部搜索框 `@State filter`;置顶「⏳ N 个等你」高亮区 + 分组折叠;行 hover/右键菜单:重命名 sheet / 收藏 / 复制 ID / 复制恢复命令 / 相对时间);`MenuBarController`+`AppCoordinator`(注入 SessionMetaStore、组织 rows、写 meta 显式 save、复制到 NSPasteboard)。
- SessionRowModel 加 `favorite: Bool`、`displayName` 经 SessionMetaMerger 镜像。
- [ ] GUI 接线 + `swift build` 通过 + 手测项(搜索定位、收藏置顶、重命名持久、复制粘贴、点击仍标已读)。

## 验收
全量 `swift test` 绿(新增覆盖组织/合并/时间/argv 红队);`swift build` 无新警;手测搜索/收藏/重命名/复制/时间。安全:resume argv 化 + UUID 白名单红队。
完成写 `.superpowers/sdd/task-m3b-report.md`。
