#!/usr/bin/env sh
# install-wispterm-notify.sh — idempotently install the WispTerm notify program
# and wire Claude Code Stop/Notification hooks. (Codex wiring added later.)
# Unix only (Linux/WSL + macOS). Backs up before editing; only adds, never deletes.
set -eu

SRC_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NOTIFY_SRC="$SRC_DIR/wispterm-notify.sh"
DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wispterm"
DEST="$DEST_DIR/wispterm-notify.sh"

# --- 1. Install the notify program ---
mkdir -p "$DEST_DIR"
cp "$NOTIFY_SRC" "$DEST"
chmod +x "$DEST"
echo "notify program -> $DEST"

# --- 2. Wire Claude Code settings.json (idempotent merge) ---
CC_DIR="$HOME/.claude"
CC="$CC_DIR/settings.json"
mkdir -p "$CC_DIR"
[ -f "$CC" ] || printf '{}\n' >"$CC"
cp "$CC" "$CC.bak"

if command -v python3 >/dev/null 2>&1; then
  DEST="$DEST" python3 - "$CC" <<'PY'
import json, os, sys
path = sys.argv[1]; dest = os.environ["DEST"]
try:
    with open(path) as f: cfg = json.load(f)
except Exception:
    cfg = {}
if not isinstance(cfg, dict): cfg = {}
hooks = cfg.setdefault("hooks", {})
def ensure(ev):
    arr = hooks.setdefault(ev, [])
    for entry in arr:
        for h in entry.get("hooks", []):
            if h.get("type") == "command" and h.get("command") == dest:
                return "present"
    arr.append({"hooks": [{"type": "command", "command": dest}]})
    return "added"
s = ensure("Stop"); n = ensure("Notification")
with open(path, "w") as f:
    json.dump(cfg, f, indent=2); f.write("\n")
print(f"claude: Stop {s}, Notification {n}")
PY
elif command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq --arg d "$DEST" '
    .hooks //= {} | .hooks.Stop //= [] | .hooks.Notification //= []
    | (if any(.hooks.Stop[]?.hooks[]?; .type=="command" and .command==$d)
        then . else .hooks.Stop += [{"hooks":[{"type":"command","command":$d}]}] end)
    | (if any(.hooks.Notification[]?.hooks[]?; .type=="command" and .command==$d)
        then . else .hooks.Notification += [{"hooks":[{"type":"command","command":$d}]}] end)
  ' "$CC" >"$tmp" && mv "$tmp" "$CC"
  echo "claude: hooks merged via jq"
else
  echo "WARN: no python3 or jq found. Add to $CC manually:"
  echo "  hooks.Stop[]   -> { \"hooks\": [ { \"type\": \"command\", \"command\": \"$DEST\" } ] }"
  echo "  hooks.Notification[] -> (same)"
fi
