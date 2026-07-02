# M3 六视角对抗评审 + 修复 + Qoder IDE 收官 —— 报告（2026-07-03，自主推进）

用户授权「每个核心阶段 6 视角子代理评审并修复,不再询问」。本轮=对 M3 全量产出的
第一次六视角面板（架构师/产品/AI/用户/测试/开源开发者，6 个并行只读子代理）+ 修复
+ Qoder IDE 接入收官。基线 584 → 611 测试全绿。

## 评审发现统计

| 视角 | Blocker | Major | Minor | 交叉印证的关键发现 |
|---|---|---|---|---|
| 架构师 | 0 | 5 | 3 | applyMetas 绕过、SQLite 半读、resume 双真相、UTC 时区 |
| 产品 | 0 | 5 | 3 | applyMetas 绕过、agent 辨识度、假命令、热键静默失败、搜索 customName |
| AI | 1 | 4 | 3 | **ProcessRunner cwd/PATH/argv0 三连**、围栏逃逸、SQLite busy |
| 用户 | 1 | 4 | 3 | **幽灵01宠物**、上传三连弹窗、UTC 时区、摘要模态 |
| 测试 | 2 | 5 | 3 | 弱断言掩盖 SummarizerService 必坏、JOIN 缺 GROUP BY、全角 hex |
| 开源 | 1 | 4 | 3 | **LICENSE 缺失**、README 停 M1.5、CLAUDE.md 约束措辞 |

## 修复（4 批,全部 TDD,main 上 `9a91970`→`368f280` + `0868e28`）

**批次1（真实行为 bug）**：applyScanResult 删除绕 applyMetas 的裸刷新(F7 闪烁三重确认)；
搜索匹配 customName；RelativeTime/Organizer 注入 tzOffset 本地日界(修东八区错位)；
QoderWork 粗略 stop 预置已读(不冒充真「等你」)；收藏置顶排序；SQLite busy_timeout+
失败(nil)≠空+半读跳过整轮+GROUP BY 去重+start 幂等；agent 徽标；幽灵01(第一张上传
照片默认命名 01=本人)；上传合窗(命名+抠图一个弹窗,取消无孤儿)；弹窗前 NSApp.activate；
假恢复命令收口(不支持的 agent 不显示菜单项)；桌宠跳转失败反馈。

**批次2（M3-D IO 安全重建）**：ProcessRunner 契约重建——executable 必绝对路径(PathResolver
纯函数 PATH 解析,拒路径分隔符)、arguments 不含 argv[0]、cwd 必传、Mock 记录完整形状、
测试断言完整执行形状(不再只断无 --resume)；RealProcessRunner 超时 SIGTERM→2s→SIGKILL
并 throw timedOut、抽干带 deadline、stdin throwing write、删死代码、补 echo/sleep 超时/pwd
cwd 三条真实集成测试；wrapPrompt 围栏消毒(\"\"\"→''')+24k 强制截断；废弃 qoder stub 移出
builtins(方言以偏概全)+无 glob 重叠断言；部分占位模板拒绝；UUID/HexColor 全角拒绝；
LocalSummarizer 控制符/bidi 消毒+stopReason 限长；ResumeCommand↔Manifest 一致性 tripwire。

**批次3**：热键注册失败提示(register 返回 Bool,面板 hint 显真话)；数据根删除确认。

**批次4（文档）**：MIT LICENSE；README 全量刷新到 M3 现实；CLAUDE.md 硬约束#1 分层
表述+路线图遗留清单更新；spec §3 权威性注记(schema M4 交付)；hook 脚本 wire 契约注释。

## Qoder IDE 接入（三产品全家桶闭环）

实测：会话 jsonl 在 `~/Library/Application Support/Qoder/SharedClientCache/cli/projects/
<编码cwd>/task-<id>.session.execution.jsonl`（state.vscdb 只存视图状态）。ISO 时间戳与
Claude 同构 → 挂现有 watcher（agent=qoder-ide）零解析改动；点击激活 `com.qoder.ide`；
manifest 记录已核实事实。真机日志验证三源（CLI/IDE/Work）同时检测。

## 未修（记录在案,非遗忘）

- **resume 双真相结构性收敛**（架构 M4）：以一致性 tripwire 测试代替重构（层级约束:
  core 不能 import shell）,结构收敛列入 M4 契约工作。
- **F10 createdAt 注入**（架构 m8）：需 birthtime 进 ScannedFile 管道,按「如实降级」处理
  ——README/路线图已改为真实交付（仅 lastActive 相对时间）,注入列入遗留。
- **DotPalette/SessionRowActions 纯逻辑下沉**（测试 m7）：小型重构,收益低于风险窗口,
  列入 backlog。
- **摘要/重命名 NSAlert 模态**（用户 M5 后半）：已加 activate 置前；非模态化(行内展开)
  是 UI 重构,列入 backlog。
- **QoderWorkWatcher start/stop 定时器测试**（测试 M6）：已加 start 幂等(先 stop);
  expectation 型定时器测试易 flaky,权衡后不加。

## 结论

六视角发现 5 Blocker + 27 Major/Minor,其中全部 Blocker 与 90% Major 已修复并有测试
背书;其余以明确理由记录。M3 至此**真正闭环**:代码、测试(611)、文档(README/CLAUDE.md/
spec/LICENSE)三者一致。下一里程碑 M4(公开契约 schema + 校验器 + 第三方样例)。
