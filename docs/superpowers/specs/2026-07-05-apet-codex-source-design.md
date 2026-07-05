# apet Codex CLI 数据源接入设计(M3-C++)

日期:2026-07-05 · 状态:实测驱动(本机 codex 0.118.0 真实会话数据解剖)

## 0. 目标与非目标

**目标**:面板/桌宠零配置看到 OpenAI Codex CLI 的会话(标题/状态/目录),与 Claude/Qoder/OpenCode 并列。
**非目标(遗留)**:
- resume 命令:`codex resume <id>` 无法核实(本机 codex 二进制损坏、README 无记载)→ **不提供**(红线:不复制未核实命令),核实后补 `resumeArgvTemplate`。
- 快速/AI 摘要:rollout 行 schema 与 Claude 不同,`ConversationTailParser` 不适用 → 摘要菜单对 codex 隐藏(新 `claudeStyleTranscriptAgents` 集合门控),后续可写 codex tail 解析。
- 精确跳转:rollout 无终端信息 → 无跳转(诚实降级,与 OpenCode 同)。

## 1. 数据形态(2026-07-05 实测,codex 0.118.0)

- 会话:`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuidv7>.jsonl`
- 索引:`~/.codex/session_index.jsonl`:`{id, thread_name(现成标题), updated_at}` 每会话一行
- rollout 行:`{timestamp: ISO8601, type, payload}`
  - 首行 `session_meta`:payload `{id(sessionId), cwd, originator("Codex Desktop"/cli), cli_version…}`(resume 会追加多条 meta,**取首行**)
  - `event_msg` payload.type:`task_started` / `task_complete`(含 last_agent_message)/ `user_message`(payload.message 纯文本)/ token_count / agent_message
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

seq 唯一序、(agent,root,sessionId) 归一键、jsonl 源不发 OS 通知、markStale 跳过 jsonl 源、sessionId 白名单(uuid hex+dash 通过现有校验)、注入消毒(thread_name/message 展示层已有 sanitize 链)。

## 4. 测试

fixtures 取自本机真实 rollout(脱敏):session_meta 解析、task_complete→end_turn、started-无-complete→running 判定、user_message 提取、非 rollout 文件返 nil、index 标题查找与缓存。
