#!/usr/bin/env bash
# apet-emit-event.sh — Claude Code hook script
# Reads the hook JSON payload from stdin, maps hook_event_name to an apet event kind,
# and appends one NDJSON line to $AGENTPET_OUT with fcntl-based file locking.
#
# MUST exit 0 always — a non-zero exit breaks the Claude hook chain.
#
# Required env:
#   AGENTPET_OUT   absolute path to events.ndjson file to append to
# Optional env:
#   AGENTPET_ROOT       data-root string (default: ~/.claude)
#   ITERM_SESSION_ID    iTerm2 session id (e.g. w0t1p0:ABC)
#   TERM_PROGRAM        terminal app name (Apple_Terminal | WarpTerminal | ghostty | vscode)
#
# Wire contract (for third-party adapters mirroring this script):
#   Legal event kinds: session_start | busy | stop | attention | session_end | plugin_error
#   Unmapped hook events pass through as lowercase(hook_event_name) and land in
#   EventKind.unknown on the app side (kept, not dropped) — do NOT rely on that
#   for real states; emit one of the legal kinds above.

set -uo pipefail

# Read hook payload from stdin before any redirections occur
HOOK_JSON="$(cat)"

AGENTPET_OUT="${AGENTPET_OUT:-}"
[ -z "$AGENTPET_OUT" ] && exit 0

# apet 自己 spawn 的子进程(如 AI 摘要的 `claude -p`)带此标记:直接跳过,
# 否则会为一次性 -p 调用凭空造一个无 jsonl 的幽灵会话进面板(反馈回路)。
[ -n "${AGENTPET_INTERNAL:-}" ] && exit 0

# Export config for the python3 subprocess (avoids shell-quoting issues with
# cwd/title values that may contain spaces, quotes, or backslashes)
export _APET_HOOK_JSON="$HOOK_JSON"
export _APET_OUT="$AGENTPET_OUT"
export _APET_ROOT="${AGENTPET_ROOT:-$HOME/.claude}"
export _APET_ITERM="${ITERM_SESSION_ID:-}"
export _APET_TERM_PROG="${TERM_PROGRAM:-}"
# 真 bundleId(macOS LaunchServices 给 GUI app 设,children 继承):区分 Cursor/Warp-Preview。
export _APET_CFBUNDLE="${__CFBundleIdentifier:-}"
# Controlling tty of the parent (the terminal running Claude). hook stdin is the
# payload (not a tty), so we read the parent's tty via ps. Yields e.g. "ttys001"
# or "??"/empty when detached; python validates before use.
export _APET_TTY="$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d '[:space:]')"

# python3 ships on macOS dev machines; use json.dumps for injection-safe JSON building
# and fcntl.flock for atomic append under concurrent hook invocations.
/usr/bin/python3 <<'PYEOF' || true
import sys, json, os, fcntl, uuid
from datetime import datetime, timezone

def main():
    hook_json_str = os.environ.get("_APET_HOOK_JSON", "{}")
    out_path  = os.environ.get("_APET_OUT", "")
    root      = os.environ.get("_APET_ROOT", "~/.claude")
    iterm_id  = os.environ.get("_APET_ITERM", "")
    term_prog = os.environ.get("_APET_TERM_PROG", "")
    raw_tty   = os.environ.get("_APET_TTY", "")
    # macOS 给 GUI 启动的 app 设的真 bundleId——Cursor(vscode fork)/Warp-Preview 靠它区分,
    # 否则会被硬编码成 VS Code / Warp-Stable(AI 评审:错图标+错激活+错标已读)。
    real_bundle = os.environ.get("_APET_CFBUNDLE", "").strip()

    # Normalize tty: "ttys001" → "/dev/ttys001"; only accept /dev/tty + alnum.
    tty = ""
    if raw_tty and raw_tty not in ("??", "?"):
        cand = raw_tty if raw_tty.startswith("/dev/") else "/dev/" + raw_tty
        tail = cand[len("/dev/tty"):] if cand.startswith("/dev/tty") else None
        if tail is not None and tail != "" and tail.isalnum():
            tty = cand

    if not out_path:
        return

    try:
        hook = json.loads(hook_json_str)
    except Exception:
        return

    # Map Claude hook_event_name → apet event kind
    hook_event = hook.get("hook_event_name", "")
    event_map = {
        "SessionStart": "session_start",
        "Stop":         "stop",
        "Notification": "attention",
        "PreToolUse":   "busy",
        "PostToolUse":  "busy",
        "SubagentStop": "busy",
    }
    apet_event = event_map.get(
        hook_event,
        hook_event.lower() if hook_event else "unknown"
    )

    session_id = hook.get("session_id", "")
    cwd        = hook.get("cwd", "")
    title      = os.path.basename(cwd) if cwd else ""
    event_id   = str(uuid.uuid4())
    ts         = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

    obj = {
        "v":         1,
        "eventId":   event_id,
        "agent":     "claude-code",
        "event":     apet_event,
        "sessionId": session_id,
        "root":      root,
        "cwd":       cwd,
        "title":     title,
        "ts":        ts,
    }

    # Attach terminal info when available.
    # TERM_PROGRAM values: Apple_Terminal / WarpTerminal / ghostty / vscode (Cursor also sets vscode).
    terminal = None
    if iterm_id:
        terminal = {
            "kind":           "iterm2",
            "itermSessionId": iterm_id,
            "bundleId":       "com.googlecode.iterm2",
        }
    elif term_prog == "Apple_Terminal":
        terminal = {"kind": "terminal", "bundleId": real_bundle or "com.apple.Terminal"}
    elif term_prog == "WarpTerminal":
        # Warp Preview 的 bundleId 是 dev.warp.Warp-Preview,Stable 是 dev.warp.Warp-Stable。
        terminal = {"kind": "warp", "bundleId": real_bundle or "dev.warp.Warp-Stable"}
    elif term_prog == "ghostty":
        terminal = {"kind": "ghostty", "bundleId": real_bundle or "com.mitchellh.ghostty"}
    elif term_prog == "vscode":
        # Cursor 也设 TERM_PROGRAM=vscode,但 __CFBundleIdentifier 是 Cursor 的——用真值,
        # kind 仍归 vscode(能力分级同档:activate-only + 手动切标签)。
        terminal = {"kind": "vscode", "bundleId": real_bundle or "com.microsoft.VSCode"}

    if terminal is not None:
        # tty enables Terminal.app window-level focus; harmless extra field for others.
        if tty:
            terminal["tty"] = tty
        obj["terminal"] = terminal

    line = json.dumps(obj, ensure_ascii=False, separators=(',', ':'))

    # Create parent directory if needed
    parent = os.path.dirname(out_path)
    if parent:
        os.makedirs(parent, exist_ok=True)

    # flock-based exclusive lock so concurrent hooks don't interleave lines
    lock_path = out_path + ".lock"
    with open(lock_path, "w") as lf:
        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        with open(out_path, "a") as f:
            f.write(line + "\n")

try:
    main()
except Exception:
    pass
PYEOF

exit 0
