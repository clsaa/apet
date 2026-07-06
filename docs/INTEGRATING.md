# 第三方 Agent 接入指南(M4 生态)

apet 通过公开契约监控任意 AI 编码 agent 的会话。已实测接入:Claude Code、Qoder CLI/IDE/Work、OpenCode、Codex(Desktop/CLI)——本文以它们为样例,给出三种接入模式。

## 核心契约:NDJSON 事件

向 `~/Library/Application Support/AgentPet/events.ndjson` **追加**(O_APPEND / flock)一行 JSON:

```json
{"v":1,"eventId":"<uuid,去重键>","agent":"<你的agent id>","event":"stop",
 "sessionId":"<会话id>","root":"<数据根绝对路径>","cwd":"/path/to/project",
 "ts":"2026-07-06T12:00:00.000Z",
 "terminal":{"kind":"warp","tty":"/dev/ttys003","pid":12345,"bundleId":"dev.warp.Warp-Stable"}}
```

- **event**:`session_start` | `busy`(进行中,只刷新计时) | `stop`(说完轮到用户→红点+通知) | `attention`(需要用户关注) | `session_end`(终态,不可回退)
- **归一键** `(agent, root, sessionId)`:三者共同唯一确定一个会话——**root 必须稳定**,否则多来源会话分裂(前车之鉴见 CLAUDE.md)
- **排序**:apet 按追加顺序取号(seq),`ts` 仅用于重放老化,**不用于排序**
- **terminal**(可选,给了就有精确跳转+存活保护):
  - `tty`+`pid`:进程存活判定(pid 死→30 分钟清理;活→面板常驻)
  - `kind`: iterm2|terminal|warp|ghostty|vscode|other;iterm2 附 `itermSessionId` 可精确跳 tab
  - **诚实原则**:程序化拉起的会话(父进程非 shell)请降级 `{"kind":"other"}`,别冒充宿主终端
- **防回路**:若你的工具可能被 apet 自身拉起,见到环境变量 `AGENTPET_INTERNAL` 请跳过发事件

## 三种接入模式(按你有什么选)

### 模式 1:你的 agent 支持 hook/插件(最佳——实时+精确跳转+真通知)
在 hook 回调里发上述事件,进程内采集 `tty`(`ps -o tty= -p $PPID`)与环境变量(ITERM_SESSION_ID/TERM_PROGRAM)。
样例:`Resources/apet-emit-event.sh`(Claude/Qoder 共用,AGENTPET_AGENT 参数化)、
`Resources/apet-codex-notify.sh`(notify 链式包装,不覆盖已有 notify)、
`Resources/apet-opencode-notify.js`(事件订阅插件,子会话过滤+去抖)。

### 模式 2:你的 agent 落 jsonl 转录(零配置推断)
若转录与 Claude 同构(user/assistant 行 + ISO 时间戳 + stop_reason),`JSONLDirectoryWatcher` 直接兼容(Qoder CLI 就是零解析代码接入)。schema 不同则写一个 `parse: (path) -> ScannedFile?` 闭包(样例:`CodexRolloutParse`——首行 meta + 轮次信号映射,约 100 行)。
推断模式无终端信息:面板显示空心状态点 + 通用终端图标,点击给恢复命令(诚实降级)。

### 模式 3:你的 agent 用数据库
只读轮询 + 内容信号派生(样例:`OpenCodeDBReader`/`QoderWorkDBReader`——SQLite busy 重试、
版本迁移哨兵 `verifiedMaxMigrationId` 防上游 schema 漂移静默坏数据)。

## AgentManifest 注册

```swift
public static let yourAgent = AgentManifest(
    id: "your-agent",                        // 面板徽标/搜索键
    rootsGlobs: ["~/.your-agent/**"],
    tsDialect: .iso,                         // 或 .epochSeconds
    resumeArgvTemplate: ["your-cli", "--resume", "{id}"],  // 未实测核实请置 nil(红线:不给用户假命令)
    hasStateRules: true                      // 有内容信号(非纯 mtime 推断)才 true
)
```

加入 `builtins`;按能力加入 `noJumpAgents`(无终端信息)/`claudeStyleTranscriptAgents`(转录可摘要)。

## 硬约束(违反即 bug,详见 CLAUDE.md)

排序唯一事实 seq / `ended` 不可回退 / 字段合并 last-non-nil / 不可信输入白名单
(sessionId、tty 均先过白名单再触达系统)/ 推断源不发 OS 通知(hook 级事件才通知)/
安装写用户配置必须门控(预览+确认+备份+可卸载,样例:`HookInstaller`/`CodexNotifyInstaller`/`OpenCodePluginInstaller`)。
