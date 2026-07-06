#!/usr/bin/env bash
# apet-codex-notify.sh — Codex CLI notify 链式包装(M3-C++ 精确跳转)
#
# 安装形态(config.toml,apet 门控写入):
#   notify = ["<本脚本>", "<原notify程序>", "<原参数>..."]     # 原 notify 存在时链式保留
#   notify = ["<本脚本>"]                                      # 原本无 notify
# codex 会把 payload JSON 追加为**最后一个** argv(上游 legacy_notify.rs 实证):
#   {"type":"agent-turn-complete","thread-id":"<sessionId>","turn-id":...,"cwd":...,...}
#
# 职责:
#   1. 先把 payload 原样转发给原 notify 程序(链式,不破坏 Codex Desktop 的 computer-use)
#   2. 采集终端坐标(tty/$PPID/ITERM_SESSION_ID)→ 给 apet 发 stop 事件 → CLI 会话精确跳转+真通知
#   3. 无 tty(Codex Desktop 端,无终端)→ 跳过发事件(桌面会话走 codex-desktop App 激活,勿混键)
#
# MUST exit 0 always。

set -uo pipefail

# ── 1. 拆参:最后一个 = payload,其余 = 原 notify argv ──
[ "$#" -lt 1 ] && exit 0
PAYLOAD="${@: -1}"
if [ "$#" -ge 2 ]; then
    ORIG=("${@:1:$#-1}")
    # 链式转发(后台 fire-and-forget,失败不影响 apet 侧)
    ("${ORIG[@]}" "$PAYLOAD" >/dev/null 2>&1 &) || true
fi

# ── 2. apet 自 spawn 的子进程防回路(与 apet-emit-event.sh 同约定) ──
[ -n "${AGENTPET_INTERNAL:-}" ] && exit 0

# ── 3. 无 tty = Desktop 端 → 跳过(桌面会话由 rollout 分类为 codex-desktop,App 激活跳转) ──
# 控制终端:notify 是 codex 子进程,与 codex 共享 tty——父进程取不到时回退自身。
TTY_RAW="$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d '[:space:]')"
case "$TTY_RAW" in
    ttys*) ;;
    *) TTY_RAW="$(ps -o tty= -p "$$" 2>/dev/null | tr -d '[:space:]')" ;;
esac
case "$TTY_RAW" in
    ttys*) ;;                # 真终端,继续
    *) exit 0 ;;             # "??"/空 = 无控制终端(Desktop/后台)
esac

# ── 4. 事件输出路径(与 app 约定的默认;可用 AGENTPET_OUT 覆盖) ──
OUT="${AGENTPET_OUT:-$HOME/Library/Application Support/AgentPet/events.ndjson}"
[ -f "$OUT" ] || exit 0      # app 从未运行过 → 不自建文件(app 首启会建)

export _APET_PAYLOAD="$PAYLOAD"
export _APET_OUT="$OUT"
export _APET_TTY="$TTY_RAW"
export _APET_PPID="$PPID"
export _APET_PARENT_COMM="${AGENTPET_PARENT_COMM:-$(ps -o comm= -p "$PPID" 2>/dev/null | tr -d '[:space:]')}"
export _APET_TERM_PROG="${TERM_PROGRAM:-}"
export _APET_ITERM="${ITERM_SESSION_ID:-}"
export _APET_CFBUNDLE="${__CFBundleIdentifier:-}"

/usr/bin/python3 <<'PYEOF' || true
import json, os, fcntl, uuid
from datetime import datetime, timezone

try:
    payload = json.loads(os.environ.get("_APET_PAYLOAD", "{}"))
except Exception:
    raise SystemExit(0)
if payload.get("type") != "agent-turn-complete":
    raise SystemExit(0)
sid = payload.get("thread-id") or ""
# sessionId 白名单:uuid 形态(hex+dash),防伪 payload 注入
if not sid or not all(c in "0123456789abcdefABCDEF-" for c in sid):
    raise SystemExit(0)
cwd = payload.get("cwd") or ""

tty = os.environ.get("_APET_TTY", "")
try:
    pid = int(os.environ.get("_APET_PPID", "0"))
except ValueError:
    pid = 0
term_prog = os.environ.get("_APET_TERM_PROG", "")
iterm_id = os.environ.get("_APET_ITERM", "")
real_bundle = os.environ.get("_APET_CFBUNDLE", "").strip()
# 程序化拉起(父进程非 shell)→ 终端环境变量是继承的谎言,降级 kind=other(与 claude hook 同判别)。
parent = os.path.basename(os.environ.get("_APET_PARENT_COMM", "")).lstrip("-")
spawned = parent != "" and parent not in {"zsh","bash","fish","sh","dash","tcsh","ksh","nu","login"}

# 终端识别(与 apet-emit-event.sh 同款矩阵)
terminal = None
if iterm_id:
    terminal = {"kind": "iterm2", "itermSessionId": iterm_id,
                "bundleId": real_bundle or "com.googlecode.iterm2"}
elif term_prog == "Apple_Terminal":
    terminal = {"kind": "terminal", "bundleId": real_bundle or "com.apple.Terminal"}
elif term_prog == "WarpTerminal":
    terminal = {"kind": "warp", "bundleId": real_bundle or "dev.warp.Warp-Stable"}
elif term_prog == "ghostty":
    terminal = {"kind": "ghostty", "bundleId": real_bundle or "com.mitchellh.ghostty"}
elif term_prog == "vscode":
    terminal = {"kind": "vscode", "bundleId": real_bundle or "com.microsoft.VSCode"}
else:
    terminal = {"kind": "other"}
    if real_bundle:
        terminal["bundleId"] = real_bundle
if spawned:
    terminal = {"kind": "other"}
if tty:
    terminal["tty"] = "/dev/" + tty
if pid > 0:
    terminal["pid"] = pid

obj = {
    "v": 1,
    "eventId": str(uuid.uuid4()),
    "agent": "codex",                 # 有 tty = CLI 端,与 rollout source=="cli" 分类同键
    "event": "stop",                  # agent-turn-complete = 说完轮到你
    "sessionId": sid,
    "root": os.path.expanduser("~/.codex"),
    "cwd": cwd,
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
    "terminal": terminal,
}

line = json.dumps(obj, ensure_ascii=False) + "\n"
out = os.environ["_APET_OUT"]
with open(out, "a") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write(line)
    fcntl.flock(f, fcntl.LOCK_UN)
PYEOF

exit 0
