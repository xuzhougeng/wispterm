#!/usr/bin/env sh
# Test harness for wispterm-notify-setup. Pure POSIX sh. Exits non-zero on any failure.
set -u
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NOTIFY="$HERE/wispterm-notify.sh"
INSTALL="$HERE/install-wispterm-notify.sh"
FAILS=0
ESC="$(printf '\033')"
BEL="$(printf '\007')"
MARKER="$(printf '\342\200\213')"

ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS+1)); }
assert_contains() { # file needle desc
  if LC_ALL=C grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3 (missing: $2)"; fi
}
assert_not_contains() {
  if LC_ALL=C grep -qF -- "$2" "$1"; then fail "$3 (unexpected: $2)"; else ok "$3"; fi
}
assert_file_exists() {
  if [ -f "$1" ]; then ok "$2"; else fail "$2 (missing: $1)"; fi
}

# ---- notify: Claude Code Notification on stdin ----
t="$(mktemp)"
printf '%s' '{"hook_event_name":"Notification","title":"WispTerm","message":"hi"}' \
  | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"
assert_contains "$t" "${ESC}]777;notify;WispTerm;hi${MARKER}${BEL}" "CC Notification -> OSC777 title+body"
assert_contains "$t" "$BEL" "CC Notification -> emits BEL"

# ---- notify: Claude Code Stop on stdin ----
t="$(mktemp)"
printf '%s' '{"hook_event_name":"Stop"}' | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"
assert_contains "$t" "${ESC}]777;notify;Claude Code;完成，轮到你了${MARKER}${BEL}" "CC Stop -> OSC777 Claude Code title+body"

# ---- notify: Codex event as LAST argv ----
t="$(mktemp)"
WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY" '{"type":"agent-turn-complete","last-assistant-message":"done deal"}'
assert_contains "$t" "${ESC}]777;notify;Codex;done deal${MARKER}${BEL}" "Codex argv -> OSC777 Codex/body"

# ---- notify: sanitization (strip ';' delimiter from title and body) ----
t="$(mktemp)"
printf '%s' '{"hook_event_name":"Notification","title":"a;b","message":"x;y"}' \
  | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"
assert_contains "$t" "${ESC}]777;notify;ab;xy${MARKER}${BEL}" "sanitize strips ';' from title and body"

# ---- notify: sanitization strips control bytes (ESC/BEL) decoded by jq ----
t="$(mktemp)"
printf '%s' '{"hook_event_name":"Notification","title":"a","message":"b\u001bc\u0007d"}' \
  | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"
assert_contains "$t" "${ESC}]777;notify;a;bcd${MARKER}${BEL}" "sanitize strips ESC/BEL control bytes from body"

# ---- notify: empty payload -> no output, exit 0 ----
t="$(mktemp)"
printf '' | WISPTERM_NOTIFY_TTY="$t" sh "$NOTIFY"; rc=$?
[ "$rc" -eq 0 ] && ok "empty payload exits 0" || fail "empty payload exit code ($rc)"
[ ! -s "$t" ] && ok "empty payload writes nothing" || fail "empty payload wrote output"


# ================= installer: Claude Code settings.json =================
# Run installer against a throwaway HOME with a pre-existing PreToolUse hook.
FAKE="$(mktemp -d)"
mkdir -p "$FAKE/.claude"
cat > "$FAKE/.claude/settings.json" <<'JSON'
{ "model": "opus", "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/existing/rtk.sh" } ] } ] } }
JSON
HOME="$FAKE" sh "$INSTALL" >/dev/null 2>&1

CC="$FAKE/.claude/settings.json"
DEST="$FAKE/.config/wispterm/wispterm-notify.sh"
[ -x "$DEST" ] && ok "installer copied notify program (executable)" || fail "notify program not installed at $DEST"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CC" 2>/dev/null \
    && ok "settings.json is valid JSON after merge" || fail "settings.json invalid JSON"
fi
assert_contains "$CC" '/existing/rtk.sh' "preserved pre-existing PreToolUse hook"
assert_contains "$CC" "$DEST" "wired notify command into settings.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$CC" "$DEST" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1])); dest=sys.argv[2]
def has(ev):
    return any(h.get("command")==dest for e in cfg.get("hooks",{}).get(ev,[]) for h in e.get("hooks",[]))
sys.exit(0 if has("Stop") and has("Notification") else 1)
PY
  [ $? -eq 0 ] && ok "Stop and Notification both wired" || fail "Stop/Notification not both wired"
fi

# Idempotency: run again, assert exactly one command per event (no duplication).
HOME="$FAKE" sh "$INSTALL" >/dev/null 2>&1
if command -v python3 >/dev/null 2>&1; then
  python3 - "$CC" "$DEST" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1])); dest=sys.argv[2]
n=sum(1 for ev in ("Stop","Notification") for e in cfg["hooks"].get(ev,[]) for h in e.get("hooks",[]) if h.get("command")==dest)
sys.exit(0 if n==2 else 1)
PY
  [ $? -eq 0 ] && ok "re-run is idempotent (no duplicate CC hooks)" || fail "CC hooks duplicated on re-run"
fi


# ---- carryover (Task 2 review): backup + unrelated-key preservation ----
[ -f "$CC.bak" ] && ok "installer wrote settings.json.bak backup" || fail "no settings.json.bak"
assert_contains "$CC" '"opus"' "preserved unrelated top-level key (model)"

# ================= installer: Codex config.toml =================
# Case A: no prior notify -> added, top-level (before any [section]).
FAKE2="$(mktemp -d)"
mkdir -p "$FAKE2/.claude" "$FAKE2/.codex"
printf '{}\n' > "$FAKE2/.claude/settings.json"
cat > "$FAKE2/.codex/config.toml" <<'TOML'
model = "gpt-5"

[history]
persistence = "save-all"
TOML
HOME="$FAKE2" sh "$INSTALL" >/dev/null 2>&1
CODEX="$FAKE2/.codex/config.toml"
DEST2="$FAKE2/.config/wispterm/wispterm-notify.sh"
assert_contains "$CODEX" "notify = [\"$DEST2\"]" "codex: notify added"
firstsec="$(grep -n '^\[' "$CODEX" | head -1 | cut -d: -f1)"
notifyln="$(grep -n '^notify' "$CODEX" | head -1 | cut -d: -f1)"
[ -n "$notifyln" ] && [ -n "$firstsec" ] && [ "$notifyln" -lt "$firstsec" ] \
  && ok "codex: notify is top-level (before [section])" || fail "codex: notify not top-level"
HOME="$FAKE2" sh "$INSTALL" >/dev/null 2>&1
[ "$(grep -c '^notify' "$CODEX")" -eq 1 ] && ok "codex: idempotent (one notify line)" || fail "codex: notify duplicated"

# Case A': absent ~/.codex dir + no config.toml -> bootstrapped + notify added.
FAKE4="$(mktemp -d)"
mkdir -p "$FAKE4/.claude"
printf '{}\n' > "$FAKE4/.claude/settings.json"
HOME="$FAKE4" sh "$INSTALL" >/dev/null 2>&1
DEST4="$FAKE4/.config/wispterm/wispterm-notify.sh"
[ -f "$FAKE4/.codex/config.toml" ] && ok "codex: bootstrapped config.toml when absent" || fail "codex: config.toml not created"
assert_contains "$FAKE4/.codex/config.toml" "notify = [\"$DEST4\"]" "codex: notify added to bootstrapped config"

# Case B: pre-existing DIFFERENT notify -> left untouched + warning.
FAKE3="$(mktemp -d)"
mkdir -p "$FAKE3/.claude" "$FAKE3/.codex"
printf '{}\n' > "$FAKE3/.claude/settings.json"
printf 'notify = ["/some/other/notifier.sh"]\n' > "$FAKE3/.codex/config.toml"
out="$(HOME="$FAKE3" sh "$INSTALL" 2>/dev/null)"
assert_contains "$FAKE3/.codex/config.toml" '/some/other/notifier.sh' "codex: existing notify preserved"
assert_not_contains "$FAKE3/.codex/config.toml" 'wispterm-notify.sh' "codex: did not clobber existing notify"
printf '%s' "$out" | grep -qi 'warn' && ok "codex: warned about existing notify" || fail "codex: no warning on conflict"

# Case B': indented top-level notify (legal TOML) -> detected, not duplicated.
FAKE5="$(mktemp -d)"
mkdir -p "$FAKE5/.claude" "$FAKE5/.codex"
printf '{}\n' > "$FAKE5/.claude/settings.json"
printf '  notify = ["/some/indented/notifier.sh"]\n' > "$FAKE5/.codex/config.toml"
out5="$(HOME="$FAKE5" sh "$INSTALL" 2>/dev/null)"
assert_contains "$FAKE5/.codex/config.toml" '/some/indented/notifier.sh' "codex: indented top-level notify preserved"
[ "$(grep -cE '^[[:space:]]*notify[[:space:]]*=' "$FAKE5/.codex/config.toml")" -eq 1 ] \
  && ok "codex: no duplicate notify for indented top-level" || fail "codex: duplicated indented notify"

# ================= skill workflow guardrails =================
SKILL="$HERE/../SKILL.md"
PS_NOTIFY="$HERE/wispterm-notify.ps1"
PS_INSTALL="$HERE/install-wispterm-notify.ps1"
PS_REMOTE_INSTALL="$HERE/install-wispterm-notify-remote.ps1"
assert_contains "$SKILL" 'terminal_list' "skill tells agents to inspect WispTerm surfaces"
assert_contains "$SKILL" 'ssh_profile_connect' "skill tells agents to connect saved SSH profiles"
assert_contains "$SKILL" 'wsl_session_exec' "skill tells agents to install inside WSL surfaces"
assert_contains "$SKILL" 'powershell_exec' "skill tells agents to install from PowerShell"
assert_contains "$SKILL" 'scp' "skill requires scp transfer for remote SSH profiles"
assert_contains "$SKILL" 'Never ask the user to re-provide SSH host/user/port/password' "skill forbids re-asking for saved profile credentials"
assert_file_exists "$PS_NOTIFY" "PowerShell notifier script is bundled"
assert_file_exists "$PS_INSTALL" "PowerShell installer script is bundled"
assert_file_exists "$PS_REMOTE_INSTALL" "PowerShell remote profile installer is bundled"
if [ -f "$PS_NOTIFY" ]; then
  assert_contains "$PS_NOTIFY" 'CONOUT$' "PowerShell notifier writes to attached console"
fi
if [ -f "$PS_INSTALL" ]; then
  assert_contains "$PS_INSTALL" 'settings.json' "PowerShell installer wires Claude settings"
  assert_contains "$PS_INSTALL" 'config.toml' "PowerShell installer wires Codex config"
fi
if [ -f "$PS_REMOTE_INSTALL" ]; then
  assert_contains "$PS_REMOTE_INSTALL" 'ssh_hosts' "remote installer reads WispTerm SSH profiles"
  assert_contains "$PS_REMOTE_INSTALL" 'scp.exe' "remote installer transfers scripts with scp"
  assert_contains "$PS_REMOTE_INSTALL" 'SSH_ASKPASS' "remote installer supports saved password profiles"
fi

printf '\n%s test(s) failed\n' "$FAILS"
[ "$FAILS" -eq 0 ]
