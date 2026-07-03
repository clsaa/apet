# OpenCode 真机实测门过门报告

日期:2026-07-03 · 环境:macOS(本机),OpenCode **v1.17.13**(npm 安装,与源码核对版本精确一致——免重跑 §2 事实核对)· 模型:opencode/deepseek-v4-flash-free(免费档)

## 七项 checklist(spec §6)

| # | 项 | 结果 | 证据 |
|---|---|---|---|
| ① | DB 路径/文件名 | ✅ | `~/.local/share/opencode/opencode.db`,WAL(-wal 597KB/-shm 并存);live 测试输出 `db=…/opencode.db rows=1 maxMigration=20260622202450_simplify_session_input verified=同值`。本机未设 XDG(env/launchctl 皆空)→ 默认路径;XDG 场景由 defaultDBPath 单测矩阵钉 |
| ② | 长任务刷新/翻转 | ✅ | 300 词生成流式期间:最新 assistant `completed` **为空**(→in-flight→running);完成后 `=1783089933105`(→completed→waitingStop);part 13→15 流式插入 |
| ③ | WAL 活跃写入轮询 | ✅ | 流式写入进行中查询成功;live 测试在未 checkpoint 的 WAL 库上读取通过 |
| ④ | resume 双场景 | ✅ | 在 `/private/tmp` 执行 `opencode /Users/nathan/workspace/apet --session ses_0d7973…` → **续接同一会话**(session 计数不变,新 user/assistant 消息追加,completed 翻转)——位置参数跨目录精确恢复 |
| ⑤ | 面板观感 | ✅(日志级) | AgentPet.app 打包运行,日志:两个 opencode 会话 upserted(key/agent/root 正确),waitingStop 后 `acknowledgedCount 1→2` **预置已读真机生效**,全程无通知。视觉观感请用户过目(App 已开) |
| ⑥ | 最老会话 id 抽查 | ✅ | fresh install,全部 id 合规 `ses_`+12hex+14base62(如 `ses_0d7973bfcffeEugMUXEYOSDZpT`);live 无异形打印 |
| ⑦ | `.schema` 快照校正 | ✅ | v1 `message` 表 DDL 从真机 `.schema` 实录进 fixture(见下发现) |

## 实测门发现(1 个 Major 级漂移,已修)

**v1.17.13 CLI 实际写 v1 `message` 表**(role 在 data JSON、无 seq、按 time_created 排序),`session_message`(v2)存在但**为空**——源码级核对以 v2 投影为准,真机 CLI 走的是 v1 持久化。不修则完成信号在真机永远缺席、只走窗口兜底(状态精度回退)。

修复(commit `df90ec3` 附近):信号链 v2 → v1 COALESCE 回退(v1 用 `json_extract(data,'$.role')='assistant'` + `time_created DESC`);活动链纳入 v1 `MAX(time_created)`;v1 坏 JSON 防御;fixture 增 v1 表;5 条回归测试;spec §2 真机事实回写。**这正是实测门存在的意义**——三轮七视角评审都没能替代一次真实数据。

## 结论

**712 测试全绿**(1 live 门控本次实跑通过)。真机端到端:安装 → 真会话 → 面板摄取 → 预置已读 → 跨目录恢复,全链路闭环。README「真机验证待过」标注可删(随合并 commit 处理)。
