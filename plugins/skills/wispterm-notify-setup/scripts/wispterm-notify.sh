#!/usr/bin/env sh
# wispterm-notify.sh — agent-agnostic notifier. Reads a Claude Code hook event
# from stdin OR a Codex event JSON as the last argv, builds a sanitized
# title/body, finds the agent's terminal, and writes OSC 777 + BEL so WispTerm
# shows a desktop notification (toast on macOS w/ OSC support) and/or bell badge.
# Always exits 0; never blocks the agent.

# --- 1. Collect payload: Codex passes event JSON as the LAST argv; Claude Code
#        pipes it on stdin. ---
payload=""
if [ "$#" -gt 0 ]; then
  for a in "$@"; do payload="$a"; done   # last argument
elif [ ! -t 0 ]; then
  payload="$(cat)"
fi
[ -z "$payload" ] && exit 0

# --- 2. Title/body. Use jq when available; otherwise a safe generic default. ---
title="Claude Code"
body="Notification"
if command -v jq >/dev/null 2>&1; then
  ev="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"
  if [ "$ev" = "Stop" ]; then
    title="Claude Code"; body="完成，轮到你了"
  elif [ "$ev" = "Notification" ]; then
    title="$(printf '%s' "$payload" | jq -r '.title // "Claude Code"' 2>/dev/null)"
    body="$(printf '%s' "$payload" | jq -r '.message // .notification_type // "需要你确认"' 2>/dev/null)"
  else
    typ="$(printf '%s' "$payload" | jq -r '.type // empty' 2>/dev/null)"
    if [ -n "$typ" ]; then
      title="Codex"
      body="$(printf '%s' "$payload" | jq -r '."last-assistant-message" // .type // "Turn complete"' 2>/dev/null)"
    fi
  fi
fi

# --- 3. Sanitize: strip ESC/BEL/CR/LF and ';' (OSC 777 field delimiter); truncate. ---
sanitize() { printf '%s' "$1" | tr -d '\033\007\r\n;' | cut -c1-"$2"; }
title="$(sanitize "$title" 256)"
body="$(sanitize "$body" 1024)"

# --- 4. Find the terminal. Hooks have no controlling tty (/dev/tty = ENXIO), so
#        walk the parent chain to the agent process's tty. Test override wins. ---
notify_tty=""
if [ -n "${WISPTERM_NOTIFY_TTY:-}" ]; then
  notify_tty="$WISPTERM_NOTIFY_TTY"
else
  os="$(uname -s 2>/dev/null || echo unknown)"
  pid=$$
  i=0
  while [ "$i" -lt 12 ]; do
    case "$os" in
      Linux)
        for fd in 1 0 2; do
          t="$(readlink "/proc/$pid/fd/$fd" 2>/dev/null)" || continue
          case "$t" in /dev/pts/*) notify_tty="$t"; break ;; esac
        done
        [ -n "$notify_tty" ] && break
        pid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
        ;;
      Darwin)
        t="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
        case "$t" in ttys*) notify_tty="/dev/$t"; break ;; esac
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
        ;;
      *) break ;;
    esac
    [ -z "$pid" ] && break
    { [ "$pid" = 0 ] || [ "$pid" = 1 ]; } && break
    i=$((i + 1))
  done
fi
[ -z "$notify_tty" ] && exit 0

# --- 5. Emit one OSC 777 (title+body) + BEL. Only OSC 777 (not OSC 9) to avoid
#        double-notifying terminals that support both.
# A trailing zero-width space (U+200B) in the body marks the notification for
# WeChat forwarding; WispTerm strips it (notification.zig). Other terminals show
# nothing extra. The bare BEL after is the bell-badge fallback. ---
{
  printf '\033]777;notify;%s;%s\342\200\213\007' "$title" "$body"
  printf '\a'
} >"$notify_tty" 2>/dev/null || true
exit 0
