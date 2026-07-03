# OpenCode 实现计划七视角对抗评审报告(阶段二)

日期:2026-07-03 · 对象:`docs/superpowers/plans/2026-07-03-apet-opencode-source.md` 初稿 → 修订版
视角:架构师 / 交互专家 / 产品专家 / AI 专家 / 用户 / 测试 / 开源开发者(7 个独立子 agent)

## Blocker(去重后 5,全部吸收)

| # | 发现 | 视角 | 修复 |
|---|---|---|---|
| P-B1 | migration id 是**全名**(`20260622202450_simplify_session_input`),裸时间戳字符串比较在已验证版本上恒误报;fixture 用错误格式自证——教科书假绿 | 开源+AI(双证) | 常量存全名 + `isNewerThanVerified` 取前导数字前缀比较;fixture/live 全名断言 |
| P-B2 | 版本健康三重偏离:出口是文件日志非 ConfigHealth;migration 探测排主查询后,schema 破坏性升级时信号永远带不出(唯一需要它的场景必失效);时机两难 | 产品+架构+AI(三方合流) | Reader 改三态 `OpenCodeReadOutcome`(migration **先探**,failed 携带版本);新增 Task 8b:`OpenCodeHealth` 决策表 + PreferencesWindow 健康区渲染 + 去抖 |
| P-B3 | `AgentManifest.swift` 实际没有 `import AgentPetCore`,计划断言"已有"——照抄必编译失败 | 测试+架构 | 改为"需新增"并给代码 |
| P-B4 | XDG GUI 失明:env 注入只修了可测性没修问题(GUI 进程 env 无 shell 的 XDG);两条 ConfigHealth 恰好都盖不住这个更常见的失败 | 用户 | `defaultDBPath` 补 `launchctl getenv` 兜底缝;`OpenCodeHealth.dbNotFound`(有 config 痕迹无 db)用户可见提示 |
| P-B5 | 活动链前提不成立:part 的 upsert 只 set data,`time_created` 冻结(projector.ts:319-324)——长工具/长文本期间时间链停摆,窗口判据必误降;`part.time_updated` 补链同样不可靠(drizzle $onUpdate 不作用于 upsert) | AI+用户(独立发现同一现象) | 状态判据 v3:**in-flight 布尔**(最后 assistant `completed IS NULL` → running,上游 getCurrentAssistant 同构);ε 时间比较整个消灭;年龄降档兜 kill 场景 |

## Major(代表项,全部吸收)

弹窗四方合流:Pet/MenuBar 不同构 → 抽 `showOpenCodeNoJumpAlert` 共享 helper;复制按钮继承 `hasResumeCommand` 门控(异形 id 降级「复制会话 ID」);Esc 键位。`stop()` 漏停 openCodeWatcher。WAL 语料空转(close 自动 checkpoint)→ 常开写者 + `wal_autocheckpoint=0` 真形态。fixture NOT NULL 保真(part/session_message/migration 三处)。徽标堆叠:noJumpHint 抑制「推断」+ layoutPriority。实测门 7 项 checklist 化(每项标注证据物)。spec §5 缺口 4 项(占位标题/title NUL 不归并/DBPollWatcher 幂等直测/live 措辞偏离注记)。维护义务落 CLAUDE.md + 常量 doc 注释四步流程。

## Minor(采纳的代表项)

`OPENCODE_DB` 相对路径 join 数据目录(上游语义相反于初稿);completed 列 CASE 包裹容 ISO 编码;`dispatchPrecondition(.onQueue(.main))`;commit 粒度拆分(noJumpHint 独立);README 测试计数刷新 + issue 链接 + 灰显边界;attribution 补 URL/版权行;`dbBackedAgents`/`rootsGlobs` 的 M4 契约注记;`?? nil` 冗余、测试名不撒谎、XCTUnwrap 风格。

## 正面核查(不凑数,但值得记录)

分层全合规(SessionIdRule 入核心成立);Task 2 委托签名与 AppCoordinator 三调用点零改动兼容;任务序无环;Task 5 一致性遍历六样本两侧相等;Task 1 四测为"现状钉死型"应直接绿且不 flaky;Task 3 语料 26 位逐字符数对;计划 SQL 与上游 getCurrentAssistant 同构、`$.time.completed` 毫秒编码/seq 单调/revert 语义全部核实成立。

## 结论

初稿工程骨架正确,但「版本过新检测」若按初稿实现会在第一天全量误报且被 fixture 自证掩盖(P-B1+P-B2 叠加),「长任务状态」会周期性抖动(P-B5)——两组问题都在计划落地前被评审拦下。修订版已提交;spec 同步升级(in-flight 判据/migration 全名/OPENCODE_DB join/launchctl 兜底)。进入阶段三(逐任务实现)。
