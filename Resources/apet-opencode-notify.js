// apet-notify — apet 的 OpenCode 插件(勿手改;由 AgentPet 安装/卸载)
// 订阅 session.idle(→stop)/question.asked(→attention),向 apet 事件流发 hook 级事件:
// 精确跳转(采集 tty/pid/iTerm id)+ 真 OS 通知 + pid 存活保护。
// __APET_OUT__/__APET_ROOT__ 由安装器烤入(root 必须与 apet 的 OpenCode DB watcher 同键,否则会话分裂)。
export const ApetNotify = async ({ directory }) => {
  const OUT = "__APET_OUT__"
  const ROOT = "__APET_ROOT__"
  if (process.env.AGENTPET_INTERNAL) return {}   // apet 自 spawn 防回路(与各 hook 同约定)

  const fs = await import("node:fs")
  const cp = await import("node:child_process")

  // 终端坐标:插件跑在 opencode 进程内,tty 取自身,取不到回退父进程。
  let tty = ""
  for (const pid of [process.pid, process.ppid]) {
    try {
      const t = cp.execSync(`ps -o tty= -p ${pid}`, { timeout: 2000 }).toString().trim()
      if (/^ttys\d+$/.test(t)) { tty = t; break }
    } catch {}
  }
  const term = (() => {
    const tp = process.env.TERM_PROGRAM || ""
    const iterm = process.env.ITERM_SESSION_ID || ""
    const bundle = (process.env.__CFBundleIdentifier || "").trim()
    let t
    if (iterm) t = { kind: "iterm2", itermSessionId: iterm, bundleId: bundle || "com.googlecode.iterm2" }
    else if (tp === "Apple_Terminal") t = { kind: "terminal", bundleId: bundle || "com.apple.Terminal" }
    else if (tp === "WarpTerminal") t = { kind: "warp", bundleId: bundle || "dev.warp.Warp-Stable" }
    else if (tp === "ghostty") t = { kind: "ghostty", bundleId: bundle || "com.mitchellh.ghostty" }
    else if (tp === "vscode") t = { kind: "vscode", bundleId: bundle || "com.microsoft.VSCode" }
    else { t = { kind: "other" }; if (bundle) t.bundleId = bundle }
    if (tty) t.tty = "/dev/" + tty
    if (process.pid > 0) t.pid = process.pid
    return t
  })()

  const emit = (kind, sessionID) => {
    // sessionId 白名单(ses_ 前缀 base62;防伪事件注入 wire)
    if (!/^[A-Za-z0-9_-]{4,80}$/.test(sessionID || "")) return
    try {
      if (!fs.existsSync(OUT)) return   // app 从未运行 → 不自建
      const line = JSON.stringify({
        v: 1,
        eventId: (globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`),
        agent: "opencode",
        event: kind,
        sessionId: sessionID,
        root: ROOT,
        cwd: directory || "",
        ts: new Date().toISOString().replace(/\.\d{3}Z$/, ".000Z"),
        terminal: term,
      }) + "\n"
      fs.appendFileSync(OUT, line)   // O_APPEND 小行原子
    } catch {}
  }

  return {
    event: async ({ event }) => {
      if (event.type === "session.idle") emit("stop", event.properties?.sessionID)
      else if (event.type === "question.asked") emit("attention", event.properties?.sessionID)
      // 实测 1.17.13:session.status busy 事件流存在 → 实时 running(DB 轮询只有粗略态)
      else if (event.type === "session.status" && event.properties?.status?.type === "busy")
        emit("busy", event.properties?.sessionID)
    },
  }
}
