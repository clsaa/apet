# apet 历史会话 + 手动摘要设计

日期:2026-07-06 · 需求原文:「加一个历史所有的会话记录,便于搜索和查找。除了重命名外,还可以手动摘要」

## 1. 手动摘要(note)

- **模型**:`SessionMeta.note: String?`(与 favorite/customName 同店同键同 merge 语义:last-non-nil);
  apply 镜像进 `Session.note` → `SessionRowModel.note`。
- **编辑**:行右键/⋯「编辑摘要…」→ **行内编辑**(副标题位变 TextField,回车存/Esc 取消,与重命名同交互;
  存空 = 清除)。快速/AI 摘要 banner 增「存为摘要」按钮(与「设为名称」并列)。
- **显示**:有 note 时副标题显示 `✎ note`(路径退居 tooltip);无 note 照旧显示路径。
- **搜索**:organizeFlat 的 matches 纳入 note。
- 消毒:展示走 DisplaySanitizer 既有链;长度 ≤200。

## 2. 历史会话(history tab)

- **入口**:tab 栏「已读」后新增内置 tab「历史」。选中时列表数据源切换为 HistoryIndex(非 store)。
- **数据**:`HistoryIndexer`(AppShellKit)聚合:
  - claude/qoder-cli/qoder-ide:枚举 projects/**.jsonl(跳过 subagents),标题经 JSONLParse(限行);
  - codex:`session_index.jsonl`(id+thread_name)∪ sessions/** rollout 枚举(mtime 为时间);
  - opencode:DB 全量顶层会话(复用 reader)。
  - 条目:(agent, root, sessionId, cwd?, title?, lastTs)。
- **缓存**:内存 `[path: (mtime, entry)]`,jsonl 未变不重析;首开异步构建(行内「加载中…」),后续增量。
- **行为**:排序 lastTs desc;搜索复用现有 filter(标题/目录/ID/agent/note);行 dot=stale 样式;
  右键保留 收藏/重命名/编辑摘要/摘要/复制ID/恢复命令(meta 按同键生效——历史里收藏的,活跃时也收藏);
  点击 = 无跳转诚实提示条(历史无终端信息)+ 复制恢复命令。
- **计数**:tab 徽标显示条目数(搜索时随过滤)。
- 非目标:历史分页/虚拟化(LazyVStack 天然惰性,数百行可行)、跨机同步、删除历史(数据属各 agent)。
