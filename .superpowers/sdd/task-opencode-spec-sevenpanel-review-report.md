# OpenCode 接入 spec 七视角对抗评审报告(阶段一)

日期:2026-07-03 · 对象:`docs/superpowers/specs/2026-07-03-apet-opencode-source-design.md` v1 → v2(commit 8ecf112)
视角:架构师 / 交互专家 / 产品专家 / AI 专家 / 用户 / 测试 / 开源开发者(7 个独立子 agent,只读对抗评审)

## Blocker(4,全部修复)

| # | 发现 | 视角 | 修复(spec v2) |
|---|---|---|---|
| B1 | `session.time_updated` 只在用户提交 prompt 时刷新,流式/工具/完成均不动——120/1800 窗口建立在不成立的刷新假设上,长轮次状态系统性反转,完成永远检测不到 | AI | 活动信号改 `MAX(part.time_created)`→`session_message`→`time_updated` 降级链;完成态读最后 assistant 消息 `$.time.completed`(内容信号优先,约束 11);辅助表缺失探测降级 session-only |
| B2 | 粗略态预置已读缺位:挂机 TUI 会以「等你」涌入置顶+🟠计数,回退架构 m6 已裁决的修复 | 交互+用户+架构 | opencode `.stop` 一律 `acknowledge`;agent 字符串硬编码收敛为集合/manifest 查表 |
| B3 | spec 引用的「激活最前终端」兜底在代码中不存在,真实路径是 `terminal==nil → .unsupported → 错误弹窗`死路 | 交互+用户+架构 | 诚实降级:行内「无跳转」提示;定制弹窗+内置「复制恢复命令」按钮;复制命令升格为主操作出口 |
| B4 | watcher 行为测试全仓仅 2 个,注释宣称的幂等测试不存在——拿它当 DBPollWatcher 泛化回归网兜不住 | 测试 | 泛化前先补 4 条(复活重 emit/读失败轮后恰一条 stale/双 key 交错/start-stop 生命周期),先绿再动刀 |

## Major(12,去重后全部吸收)

DB 文件名非钉死(`OPENCODE_DB`/channel 后缀 → glob);XDG 对 GUI 进程不可见(`defaultDBPath(env:)` 注入+ConfigHealth);resume 缺目录上下文(源码核实位置参数 → `opencode <dir> --session <id>`,display 层 shell 引用);无条件注册 watcher(安装顺序击穿零配置);migration 表版本探测+「版本过新」用户可见降级;文档交付物清单(README 能力矩阵如实标注/上游版本适配声明);实测门补 8 项(GUI 启动/XDG/WAL 活跃/跨目录 resume/长任务刷新观察/最老 id 抽查/schema 快照/live 留痕);挂机 30 分钟消失 → 三档 stale(staleHorizon=86400);hook 提示误推销 Claude 配置 → agent 门控;本地摘要死弹窗 → 无转录 agent 隐藏(qoder-work 顺手治);WAL fixture 语料;插件增强升格 P1 里程碑(触发条件:零配置真机验证通过)。

## Minor(采纳的代表项)

`SessionIdRule` length=前缀外 26(全长 30,防 off-by-4)、M4 契约按 prefix+charset+range 建模防单案例锁死、毫秒→秒双真相 tripwire 断言、SessionIdRule 逐条对抗语料(组合字符/NUL/全角)、空库无 session 表归 `[]`(装了没跑过是常态)、`directory` 空串→nil、占位标题原样展示决策、fixture 蓝本改 schema.gen.ts+MIT attribution、事实表 verified-as-of+commit SHA、迁移速度如实 38 个/5 月、DBPollWatcher queue:.main+start 幂等契约、argv 双源一致性遍历测试、轮询 SQL 不能按 time_updated 下推(B1 同根)。

## 事实核查结论

§2 表格经 AI/架构/开源三方对源码逐行核对:DB 路径/WAL/毫秒方言/`ses_`+26 格式/`--session` flag/`parent_id`(fork 不设)/`time_archived` 过滤均属实;两处纠偏:time_updated 语义(B1)、文件名非恒定。

## 结论

v1 工程骨架(QoderWork 同构缝/失败≠空/防注入白名单)七方一致认可;核心整改是「粗略态会话冒充精确会话」一族问题(B1/B2/B3 同根)与测试规范承接。v2 已全部吸收并提交,进入阶段二(实现计划)。
