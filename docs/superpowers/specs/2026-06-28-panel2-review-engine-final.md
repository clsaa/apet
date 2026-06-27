# 核心引擎第二次 5 视角面板评审（Plan A 全部完成后）

> 日期：2026-06-28 ｜ 阶段：Plan A 10 任务 + H1/H2 完成、81 测试全绿后的收尾整分支评审
> 方法：5 独立子 Agent（架构/产品/AI/用户/测试）并行，重点审第一次没见过的 3 个新组件（Ingestor/NotificationDecider/TerminalLocator）+ 确认 B1-B7 闭合 + Plan B 放行。

## B1-B7 闭合确认（架构+测试视角）
全部闭合：B1 富聚合 summary()✅ B2 markStale 仅 RUNNING✅ B3 僵尸 guard✅ B4 状态优先排序✅ B5 宽容解码✅ B6 onChange+线程契约（部分，单槽待扩）⚠️ B7 24 缺口全补✅。

## 交叉收敛 → H3 引擎硬化 2（本阶段实施）

| 编号 | 问题 | 命中视角 | 处置 |
|---|---|---|---|
| H3-1 | **replay 链路断裂**：applyInner 收到 replay 不用；onChange 不带 replay → 重启回放重发历史通知 + 历史被 kill 会话重建成绿点 RUNNING | 架构(Blocker)、AI(Major)、产品(Major) | applyInner：`replay && newState==.running → .stale`；onChange 改扇出数组带 `isReplay`；补真实 replay 测试 |
| H3-2 | **onChange 单槽** → 三订阅者静默覆盖 | 架构(Major) | `onChangeHandlers: [([StoreChange],Bool)->Void]` 扇出 |
| H3-3 | **僵尸会话+内存无界**：无可靠 session_end，STALE/WAITING 会话与 seenEventIds 永久累积 | AI(Major)、架构(Major)、用户(Minor) | 加 `reap(now:endedAfter:waitingEndedAfter:)`：STALE→ENDED、WAITING→ENDED（更长阈值）、驱逐 ended + 清 seenEventIds，发 `StoreChange.removed` |
| H3-4 | **iTerm2 跳转静默成功**：tab 关闭后脚本退出码 0 → §9"不静默失败"做不到 | 用户(Blocker) | 脚本未命中时 `error "session not found" number -1` |
| H3-5 | **通知无项目身份**：多会话全是"claude-code：需要你输入" | 产品(Major)、用户 | body 用 cwd 末段 `[project]` 前缀；alert 路径给正确 fallback body |
| H3-6 | **多 profile 面板行雷同** | 产品(Major)、用户(Minor) | `Session.profileLabel`（从 root 派生，computed） |
| H3-7 | **角标计数语义未定** | 产品(Minor) | `PetSummary.badgeCount`（computed：attentionCount>0?attentionCount:waitingCount） |
| H3-8 | StoreChange 缺 removed | 架构(Major) | 随 H3-3 加 `case removed(SessionKey)` |
| H3-9 | 测试缺口（markStale onChange 路径、startSeq≠0、Locator argv[1] 精确、ring title/body 回退、passive×everyStop、summary 空/全 ended、stale 排序、ingest 返回值/空/全坏/CRLF、空 id→invalidRef） | 测试(P0-P2) | H3-tests 批量补 + 顺手 trim `\r`（CRLF 健壮性） |

## 不收紧/保留（控制者裁决）
- **ITermSessionId 正则不收紧到 `w\d+t\d+p\d+`**（架构 Minor-5）：iTerm2 `id of session` 真实格式可能是 UUID（plan 自检已标 Plan B 待确认），过度收紧会拒掉合法 id；当前 ASCII 白名单已守注入底线、格式无关，保留，留 Plan B 验证真实 id 后再定。
- **跨会话同 eventId 全局去重**：有意设计（真实 eventId 是 ULID/UUID 全局唯一），文档化为预期行为。
- **aggregateState()**：加文档注释推荐 summary()，不硬 @deprecated（避免既有测试 warning 噪声）。

## 并入 Plan B（文档登记，非引擎当下闭合）
- ⚠️ **最大风险（用户 Blocker、AI Finding）**：纯 hook 档下 `attention`（工具授权等待）无可靠触发源——Claude Code 工具确认走终端 readline 不走 hook。`WAITING(.attention)`→通知链在 M1 hook 档可能是死路。**M1 必须用真实 hook 验证 attention 路径**，否则核心"叫你授权"承诺兑现不了；需 Plan B logscan stateRules 或进程探测补。
- 通知节流（同 session cooldown）= NotifyCenter 职责（产品 Major、架构 Minor）。
- NDJSONIngestor `(fileId,byteOffset)` checkpoint = Plan B（重启续读性能）。
- ActivateOnlyLocator + kind→locator 分派表 = Plan B（Terminal/Warp）。
- onChange 扇出后，PetPresenter/NotifyCenter/SessionPanel 各自注册。
- §3 协议预留 `PreToolUse/PostToolUse` 事件位（映射 busy 心跳），避免后续 manifest 破坏。

## 总评
引擎状态机扎实，B1-B7 闭合。剩余引擎级硬伤集中在 replay 链路（H3-1）与僵尸/内存（H3-3）——纯计时可解、不依赖 hook，趁简单修。attention hook 触发是最大的非引擎风险，M1 接真实 hook 时必须头一个验证。
