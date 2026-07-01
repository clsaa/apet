# M3-A2 / M3-C / M3-D 实现报告（自主推进）

分支 `feature/m3-a2cd`。基线 545 → 561 测试，全绿；`swift build` 通过。用户授权「继续后续所有 M3，不再询问」。

## M3-A2 外观/体验（大部分随上一分支已并入，本轮补充）
- **F5 内置宠物展示名**：`PetDisplayName.builtin`（01默认/02柴犬/03比熊，未知回退），接入选择器。自定义宠物命名持久化需 FileOps 字节读写，**暂缓**。
- **F9 默认快捷键改 ⌥⌘S**：**主动不改**——全局 ⌥⌘S 会系统级拦截所有 App 的「存储为」，是footgun；快捷键本就可在「通用」页自录。保留现默认。
- 面板页脚瘦身、即时生效、F3 自定义色、F1 通知/声音分开、F4 首选项四分页 —— 见上一批。

## M3-C 多 Agent 框架
- `TimestampDialect`（iso / epochMillis 纯解析）——解 Qoder 部分行 epoch 毫秒事实。
- `AgentManifest` DTO（roots/方言/resumeArgv 模板/hasStateRules）+ `renderResumeArgv`（UUID 白名单红队，`{id}` 作单一 argv）。
- 内置 `claude` / `qoder` manifest。**接入目标（用户指定）：Qoder / Qoder Work / Qoder Cli 三产品**——真实路径/格式/resume 待逐一核实，核实前不臆造。
- **未做**：真实 Qoder jsonl 扫描接入（需实测事实）；ProcessRunner 的签名 pin。

## M3-D AI 会话总结（核心，UI 待独立评审）
- `LocalSummarizer` 纯函数：最后指令 + 最近 assistant 动作/stop_reason，**免费即时，默认展示**。
- `ProcessRunner` 协议 + Mock + Real（异步抽干管道防死锁 + 超时 terminate + 显式 stdin）。
- `ModelSummary.argv`/`wrapPrompt` + `SummarizerService`：**严禁 --resume**（红线，测试断言）、包裹不可信输入 + pin 中文、受控临时 cwd、四态（成功/非零/抛错/空）Mock 测试。
- **未做**：把摘要接进面板 UI（行内「本地摘要」入口 + 模型摘要授权开关）——高风险，设计要求「最后做、独立再评审」，故只交付受测的纯核心 + 缝。

## 终端完备性（用户强调 Warp/iTerm2/Terminal）
- 三终端均已支持：iTerm2 精确 tab、Terminal.app 窗口级(tty)、Warp 激活。
- 新增「精确跳转未命中 → 兜底激活对应终端 App」，杜绝「无法跳转」死路。
- Warp bundle id 修正为 `dev.warp.Warp-Stable`；激活改主线程 + openApplication。

## 遗留清单
1. 自定义宠物命名持久化（FileOps 扩展字节读写）。
2. Qoder/Qoder Work/Qoder Cli 真实接入（逐一核实路径/格式/resume）。
3. M3-D 摘要 UI + 模型摘要授权开关（独立评审后接）。
4. F2 状态栏头像变体、英文本地化、无障碍（Defer）。
