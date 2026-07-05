# apet Codex CLI 数据源接入设计(M3-C++)

日期:2026-07-05 · 状态:实测驱动(本机 codex 0.118.0 真实会话数据解剖)

## 0. 目标与非目标

**目标**:面板/桌宠零配置看到 OpenAI Codex CLI 的会话(标题/状态/目录),与 Claude/Qoder/OpenCode 并列。
**非目标(遗留)**:
- ~~resume 不提供~~ → **已核实并提供**(评审更新 2026-07-05):AI 专家用 Codex.app 内置 codex-cli 0.142.5 实跑 `resume --help` 核实 `codex resume [SESSION_ID]`(UUID 直传不走 picker);`resumeArgvTemplate=["codex","resume","{id}"]`,id 过 uuid 白名单。npm 0.118 损坏根因:arm64 机装了 x64 平台包且缺主程序。
- 快速/AI 摘要:rollout 行 schema 与 Claude 不同,`ConversationTailParser` 不适用 → 摘要菜单对 codex 隐藏(新 `claudeStyleTranscriptAgents` 集合门控),后续可写 codex tail 解析。
- 精确跳转:rollout 无终端信息(Codex 不像 apet hook 会采集 tty)。**Desktop/CLI 分流**(2026-07-05 用户需求):
  首条 meta `source=="vscode"` → agent=`codex-desktop`,点击**激活 Codex.app**(com.openai.codex,仅切到 App 档);
  `source=="cli"`/未知 → agent=`codex`,诚实无跳转+恢复命令(未知默认 CLI:宁少跳转不乱激活)。
  身份取首条 meta(真机实锤有会话 Desktop/CLI 混用,摇摆会致 SessionKey 分裂)。
  CLI 精确跳转的可能路径(P2 遗留):codex config.toml 的 `notify` 钩子可像 claude hook 一样采集 tty。

## 1. 数据形态(2026-07-05 实测,codex 0.118.0)

- 会话:`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuidv7>.jsonl`
- 索引:`~/.codex/session_index.jsonl`:`{id, thread_name(现成标题), updated_at}` 每会话一行
- rollout 行:`{timestamp: ISO8601, type, payload}`
  - 首行 `session_meta`:payload `{id(sessionId), cwd, originator("Codex Desktop"/cli), cli_version…}`(resume 会追加多条 meta,**取首行**)
  - `event_msg` payload.type:`task_started` / `task_complete`(含 last_agent_message)/ **`turn_aborted`**(Esc 中断,视作轮次终结;上游 policy.rs 实证 error 不持久化)/ `user_message`(payload.message 纯文本;`# Files mentioned by the user` 前缀是 CLI 附件注入需跳过)/ token_count / agent_message
  - 0.142.5(Codex Desktop)**每轮**追加一条 session_meta+turn_context:id 恒一致(取首行对),cwd 取**最新**(换目录 resume)
  - `response_item`:message/function_call/reasoning(user message 的 content 含注入的 `<environment_context>`,**标题回退用 event_msg user_message 而非它**)

## 2. 架构:复用 JSONLDirectoryWatcher 全套

`JSONLDirectoryWatcher` 的 parse 是注入闭包、目录枚举递归——YYYY/MM/DD 布局天然兼容,滞回/差分/幽灵对账全复用。只新增:

- **`CodexRolloutParse`**(AppShellKit):`parse(path, root, titleLookup) -> ScannedFile?`
  - 首行 session_meta → sessionId/cwd;非 rollout 文件(无 session_meta)→ nil
  - 尾部 N 行:最后 `task_complete` ts vs 最后 `task_started` ts:
    - complete ≥ started → `lastAssistantStopReason="end_turn"`(→ scanner 判 waitingStop)
    - started > complete(跑到一半)→ stopReason=nil + lastAssistantTs=最新活动 ts(→ runningWindow 内判 running)
  - `lastPrompt` ← 尾部最后一条 `user_message.message`;`title` ← titleLookup(sessionId)
  - `lastConversationTs` ← 末行 timestamp;mtime ← FileManager
- **`CodexSessionIndex`**(AppShellKit):读 `session_index.jsonl` → `[id: thread_name]`,按 mtime 缓存
- **AgentManifest.codex**:id="codex",rootsGlobs=["~/.codex/sessions/**"],ISO 方言,resume=nil,无 stateRules
- **挂载**(AppCoordinator):`~/.codex/sessions` 存在即挂 watcher(agent="codex",root=~/.codex)
- **状态派生**:复用 `JSONLSessionScanner.scan`(end_turn→waitingStop / 窗口→running / tooOld→ignore),零改动

## 3. 硬约束继承

seq 唯一序、(agent,root,sessionId) 归一键、jsonl 源不发 OS 通知、markStale 跳过 jsonl 源、sessionId 白名单(uuid hex+dash 通过现有校验)、注入消毒:**DisplaySanitizer**(评审后新增)在 SessionRowMapper 展示边界剥 bidi/控制字符——thread_name/ai-title 等模型生成标题是半可信输入,所有源统一受益。

## 3.5 评审记录(2026-07-05,架构/AI/测试三视角)

Major 全修:①长轮次尾窗截断误 stale(assistant 活动 ts 兜底)②turn_aborted 漏判 ③无跳转诚实降级(noJumpAgents + showCodexNoJumpAlert)④title 消毒链落地(DisplaySanitizer)。
Minor 修:sessionId uuid 白名单、hasStateRules=true、cwd 取最新、附件前缀跳过、index 缓存/四象限/集成链补测(30 用例)。
遗留:resume 若新建同 id 文件的差分互踢(真机门待验证)、全历史尾读 mtime 预过滤(共性优化)、>2min shell 命令执行期无写盘误翻 waitingStop(数据源固有)。

## 4. 测试

fixtures 取自本机真实 rollout(脱敏):session_meta 解析、task_complete→end_turn、started-无-complete→running 判定、user_message 提取、非 rollout 文件返 nil、index 标题查找与缓存。
