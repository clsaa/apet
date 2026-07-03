# OpenCode 接入实现七视角评审+修复报告(阶段三收官)

日期:2026-07-03 · 对象:`feature/opencode-source` 实现(11 个实现 commit → +4 个修复 commit)
视角:架构师 / 交互专家 / 产品专家 / AI 专家 / 用户 / 测试 / 开源开发者

## 评审结论概览

- **AI 专家**:六项事实终核全过——SQL 列名/getCurrentAssistant 同构/38 个迁移 id 逐验/OPENCODE_DB join 层级,与上游 v1.17.13(04d236c)完全对齐。
- **开源**:七项验收六项干净通过(attribution/维护流程/契约注记/commit 卫生)。
- **交互**:上一轮 7 条全部核销;MenuBar 分流无行为丢失。
- **产品**:六项 spec 承诺验收全过。
- **用户**:七场景推演全达标,结论「用」。
- **架构**:硬约束逐条合规、spec §3.2 零漂移、委托语义 100% 保持、生命周期无泄漏。
- **测试**:spec §5 语料清单执行度「逐条无缺」,但抓到全场唯一 Blocker。

## Blocker + Major(全部修复,4 个 commit)

| 发现 | 视角 | 修复 |
|---|---|---|
| **json_extract 对坏 JSON 抛错**→ 单条坏 data 毒化整轮读取,面板静默清空(违 spec §3.1) | 测试(Blocker)+架构(Major) | SQL `json_valid` 护栏,坏 data 归 `.none` 窗口兜底;补 malformed/多轮 seq DESC/ISO 编码回归网(a4e3a2c) |
| launchctl 手搓 Process 无超时,绕过已加固的 ProcessRunner 缝;launchd 卡死则启动无限挂起 | 架构 | 改走 `RealProcessRunner`(2s 超时),降 private 消 API 泄漏,统一注入缝风格(e5ca39f) |
| session 表被上游改名 → `ok([])` 静默失明,健康区全绿 | 产品 F1 | session 缺失 ∧ migration 新于已验证 → `.failed` 携带版本信号,零新管道复用 versionTooNew(8d85e85) |
| env→launchctl 次序无测试钉(数组字面量急切求值真踩了) | 测试 | 惰性顺序 lookup + spy 测试;顺带修相对路径 fallthrough(e5ca39f) |
| timer stop 断言恒真(差分抑制自然冻结计数) | 测试 | 每 tick 新 key 使计数单调增,stop 改空函数必红;双处同修(431b455) |
| Pet 侧无防连击守卫,opencode 无 osascript 延迟使弹窗堆叠必现 | 交互 | Pet 补同款 `isShowingTapAlert`(431b455) |
| README「已验证」会被读成「已实测」 | 产品 F2 | 措辞改「源码级核对,真机端到端验证待过」;OpenCode 条目标注(431b455) |

## Minor(采纳修复的代表项)

in-flight 豁免 idleWindow(单工具 >30min 不再中途灰闪,kill 兜底 2h 窗,spec 同步);configDir 走 XDG_CONFIG_HOME lookup;`:memory:` 特判;版本前缀等长保守比较;decider 组合钉死(db 在优先于 legacy);dbNotFound 文案补卸载出路;「取消」按钮 HIG;「无跳转」字号统一+文案中性化;健康行样式对齐 hookStatusRow;灰显 tooltip 与 reap 现实对齐;Onboarding 隐私句四源化;WAL 脏读断言/live createdAt 哨兵/强解包清理;spec Row 定义回写。

**未采纳/后置**:健康区不自动刷新(与既有 ConfigHealth 同构,记录在案);channel 后装需重启(README 已注明边界);per-agent 来源开关(backlog);无通知(P1 插件增强兑现,各处已如实声明)。

## 最终状态

- **708 个单元测试全绿**(基线 610 → +98;1 个 live 门控默认 skip)。
- 三阶段(spec/计划/实现)× 七视角 = 21 份对抗评审,全部 Blocker/Major 闭环。
- 待人工门:① 真机实测(spec §6 七项 checklist,`APET_OPENCODE_LIVE=1` 留痕;需用户确认 OpenCode 装机方式);② 分支合并与 SSH 推送。
