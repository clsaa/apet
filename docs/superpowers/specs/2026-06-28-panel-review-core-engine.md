# 核心引擎 5 视角面板评审报告（Tasks 1–7 完成后）

> 日期：2026-06-28 ｜ 阶段：SessionStore 核心引擎成型后的重要阶段评审
> 方法：5 个独立子 Agent 并行，各一视角（架构师 / 产品专家 / AI 专家 / 用户 / 测试专家），互不可见，独立产出分级发现。多视角独立命中 = 高置信度。

## 交叉收敛矩阵（去重后）

| 编号 | 问题 | 命中视角 | 处置 |
|---|---|---|---|
| B1 | `aggregateState()` 中 RUNNING 掩盖 WAITING，多 Agent 下宠物永远"忙碌"、"喊你"动画不出现 | 用户(Blocker)、产品(Blocker) | 改引擎：新增 `summary()` 富聚合（hasWaiting/attentionCount/staleCount/runningCount），保留三态枚举不破坏 |
| B2 | `markStale` 把 WAITING(尤其 attention) 也超时降级 → "等你授权"信号被静默 | 用户(Blocker)、AI(Blocker)、产品(Minor) | 改引擎：markStale 只把 RUNNING 标 stale；WAITING 不因无事件降级（等人本就无活动） |
| B3 | 首事件 `session_end` 在新会话分支建出僵尸 `.ended` 记录，违反 spec §6"(无)+session_end→忽略" | 架构(Minor)、AI(Blocker)、测试(隐含) | 改引擎：新会话分支 `guard kind != .sessionEnd`；并修正 Task4 中前提错误的回归测试 |
| B4 | `activeSessions()` 按 lastSeq 倒序 → WAITING 沉底；且跨插件 seq 命名空间独立、比较无意义 | 用户(Blocker)、架构(Minor)、产品(Major)、测试(Major) | 改引擎：按状态优先级(attention>stop>running>stale) 再按 `lastActiveAt` 倒序 |
| B5 | 未知 `reason`/`notify` 枚举值使 `try?` 丢弃整条合法事件（前向兼容性差） | 测试(Blocker) | 改引擎：`WaitingReason`/`NotifyClass` 宽容解码（未知→nil），与 EventKind/TerminalKind 一致 |
| B6 | `SessionStore` 无并发保护（class+可变字典），Plan B 三线程共享=数据竞争；变更是 pull 非 push | 架构(Blocker×2) | 文档化线程契约（非线程安全，owner 串行；Plan B 用 @MainActor）；加 `onChange` 发布回调，不引入 Combine 依赖 |
| B7 | 测试覆盖 24 条缺口（等值 seq、全 stale→idle、waiting→stale、排序方向、unknown 入 store、`{}`、缺字段、terminal 降级、边界等） | 测试(系统清单) | 批量补测（P0–P2 优先） |

## 改引擎（本阶段实施，TDD）
B1 富聚合 `summary()` · B2 markStale 仅 RUNNING · B3 僵尸 guard · B4 状态优先级排序 · B5 宽容解码 · B6 线程契约文档+onChange 回调 · B7 批量补测。

## seq 语义澄清（解 B4 与架构 Minor-8、测试 Blocker-1）
ingestor 对**所有来源的所有行**赋**单一全局单调 seq**（= 合并后的 append 顺序），故"等值 seq"不会发生，`seq <= lastSeq` 丢弃是正确的（无需 spec §4 的来源 tiebreak，spec 据此简化）。状态推进/去重用全局 seq；**面板展示排序**改用状态优先级 + `lastActiveAt`，不用 seq。

## 并入 Plan B / 后续（文档化，非引擎当下能解）

| 来源 | 问题 | 去向 |
|---|---|---|
| AI(Major) | `session_end` 无可靠信号：kill/关 tab/崩溃不触发 hook → 僵尸会话永不消失 | Plan B：按 terminal.ref(pid/tty) 探活，进程消失合成 `session_end`；spec 增"STALE 超时 N 后自动 ENDED"可选 |
| AI(Major)、用户、产品 | 长工具执行期(PreToolUse→PostToolUse)无 hook 心跳 → STALE 误判"假死" | Plan B：内置 hook 在 PostToolUse 主动发 busy 心跳；STALE 默认阈值提到 20–30 分钟 |
| AI(Major) | 并行 subagent 的 busy/stop 交错 → 状态抖动 + 通知爆炸 | spec §3 增可选 `parentSessionId`；PetPresenter 折叠子会话；NotifyCenter 父会话级聚合 |
| AI(Minor) | `attention` 的真实 hook 触发路径未定义（工具授权走终端 UI 不走 hook） | Plan B hook 脚本设计：明确 attention 来自哪个 hook/payload |
| AI(Minor) | logscan "最新行" 未定义 → 启动重评历史误触发 | spec §3：评估窗口=文件末尾近 N 行 + mtime 过滤 |
| 用户、产品 | STALE 与 ENDED 同灰、无区分；STALE 无通知钩子 | Plan B 面板：STALE 橙色 `?` 图标；可选低优先级"疑似停滞"通知 |
| 用户、产品 | 多 profile 同名项目面板两行雷同 → 跳错 | Plan B：Session 暴露 `profileLabel`(从 root 提取)，冲突时展示 |
| 用户、产品 | 用户正聚焦该终端 tab 时仍弹通知 → 打扰 | Plan B NotifyCenter：跳转成功/焦点在对应 App 时压制该次通知 |
| 产品 | 单会话静音/免打扰时段无建模钩子 | M2 首选项：`Session.isMuted` + `PreferencesProvider` 注入 NotifyCenter |
| 架构 | StoreChange 缺 `removed`、replay 标志未透传；seenEventIds/ended 无清理 | 随 Plan B 内存清理落地：加 `removed(SessionKey)`、ended TTL 驱逐；replay 由 ingestor 在调用层 gate NotifyCenter（M1 重启重建，暂不致命） |

## 总评
单会话状态机扎实（终态、可复活、字段合并、seq 排序均兑现红队要求）。**聚合层**是最大短板——把多会话压成单枚举丢了"虽忙但有人等你/紧急 vs 完成/谁置顶"三条产品关键信息；**STALE 语义**对真实 Agent 行为（长任务、attention 等待、不可靠终结）适配不足。本阶段先在引擎闭合 B1–B7，其余结构性问题随 Plan B 解决并已逐条登记。
