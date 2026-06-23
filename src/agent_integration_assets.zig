pub const posix_notify_script =
    \\#!/bin/sh
    \\# installed by WispTerm; reinstalling overwrites this file.
    \\payload=""
    \\for arg do payload="$arg"; done
    \\if [ -z "$payload" ]; then
    \\  payload="$(cat 2>/dev/null || true)"
    \\fi
    \\[ -n "$payload" ] || exit 0
    \\command -v python3 >/dev/null 2>&1 || exit 0
    \\WISPTERM_HOOK_PAYLOAD="$payload" python3 - <<'PY'
    \\import json, os, re, sys
    \\payload = os.environ.get("WISPTERM_HOOK_PAYLOAD", "")
    \\title = "Claude Code"
    \\body = "Turn complete"
    \\try:
    \\    event = json.loads(payload) if payload.strip() else {}
    \\except Exception:
    \\    event = {}
    \\hook_event = str(event.get("hook_event_name") or "")
    \\if hook_event == "Notification":
    \\    title = str(event.get("title") or title)
    \\    body = str(event.get("message") or event.get("notification_type") or body)
    \\elif hook_event == "Stop":
    \\    title = "Claude Code"
    \\    body = "Turn complete"
    \\elif event.get("type") is not None:
    \\    title = "Codex"
    \\    body = str(event.get("last-assistant-message") or event.get("type") or body)
    \\def clean(value, limit):
    \\    value = re.sub(r"[\x00-\x1f\x7f;]", "", value or "")
    \\    return value[:limit]
    \\msg = "\033]777;notify;%s;%s\u200b\007\007" % (clean(title, 256), clean(body, 1024))
    \\for path in (os.environ.get("WISPTERM_NOTIFY_TTY"), "/dev/tty"):
    \\    if not path:
    \\        continue
    \\    try:
    \\        with open(path, "wb", buffering=0) as handle:
    \\            handle.write(msg.encode("utf-8"))
    \\        break
    \\    except Exception:
    \\        pass
    \\PY
    \\exit 0
    \\
;

pub const posix_claude_session_hook = posixSessionHook("claude_code", true);
pub const posix_codex_session_hook = posixSessionHook("codex", false);

fn posixSessionHook(comptime app: []const u8, comptime claude: bool) []const u8 {
    const filter = if (claude)
        \\if hook_event == "SubagentStop" or event.get("agent_id"):
        \\    raise SystemExit(0)
        \\
    else
        \\if hook_event and hook_event != "SessionStart":
        \\    raise SystemExit(0)
        \\
    ;
    return
        \\#!/bin/sh
        \\# installed by WispTerm; reinstalling overwrites this file.
        \\set -eu
        \\
        ++ "export WISPTERM_AGENT_APP=" ++ app ++ "\n" ++
        \\
        \\action="${1:-}"
        \\[ "$action" = "session" ] || exit 0
        \\tmp="$(mktemp "${TMPDIR:-/tmp}/wispterm-agent-hook.XXXXXX")" || exit 0
        \\trap 'rm -f "$tmp"' EXIT HUP INT TERM
        \\cat >"$tmp" 2>/dev/null || true
        \\command -v python3 >/dev/null 2>&1 || exit 0
        \\WISPTERM_HOOK_INPUT="$tmp" python3 - <<'PY'
        \\import base64, json, os, re
        \\app = os.environ.get("WISPTERM_AGENT_APP", "")
        \\path = os.environ.get("WISPTERM_HOOK_INPUT", "")
        \\try:
        \\    with open(path, encoding="utf-8") as handle:
        \\        raw = handle.read()
        \\    event = json.loads(raw) if raw.strip() else {}
        \\except Exception:
        \\    event = {}
        \\hook_event = str(event.get("hook_event_name") or "")
        ++ filter ++
        \\sid = event.get("session_id")
        \\if not isinstance(sid, str) or not sid:
        \\    raise SystemExit(0)
        \\def safe(value):
        \\    if not isinstance(value, str) or not value:
        \\        return None
        \\    if re.search(r"[\x00-\x1f\x7f]", value):
        \\        return None
        \\    return value
        \\obj = {"session_id": sid}
        \\transcript = safe(event.get("transcript_path"))
        \\if transcript:
        \\    obj["session_path"] = transcript
        \\source = safe(event.get("source")) if hook_event == "SessionStart" else None
        \\if source:
        \\    obj["session_start_source"] = source
        \\payload = base64.urlsafe_b64encode(json.dumps(obj, separators=(",", ":")).encode()).decode().rstrip("=")
        \\msg = "\033]7748;wispterm-agent;event=session;app=%s;data=%s\007" % (app, payload)
        \\try:
        \\    with open("/dev/tty", "wb", buffering=0) as handle:
        \\        handle.write(msg.encode("utf-8"))
        \\except Exception:
        \\    pass
        \\PY
        \\exit 0
        \\
    ;
}

pub const windows_notify_script =
    \\param([Parameter(ValueFromRemainingArguments = $true)][string[]] $EventArgs)
    \\$payload = ""
    \\if ($EventArgs -and $EventArgs.Count -gt 0) { $payload = $EventArgs[$EventArgs.Count - 1] }
    \\if ([string]::IsNullOrWhiteSpace($payload)) {
    \\  try { if ([Console]::IsInputRedirected) { $payload = [Console]::In.ReadToEnd() } } catch { $payload = "" }
    \\}
    \\if ([string]::IsNullOrWhiteSpace($payload)) { exit 0 }
    \\function Prop($o, $n) { if ($null -eq $o) { return $null }; $p = $o.PSObject.Properties[$n]; if ($null -eq $p) { return $null }; return [string]$p.Value }
    \\try { $event = $payload | ConvertFrom-Json -ErrorAction Stop } catch { $event = $null }
    \\$title = "Claude Code"; $body = "Turn complete"
    \\$hook = Prop $event "hook_event_name"
    \\if ($hook -eq "Notification") {
    \\  $t = Prop $event "title"; $m = Prop $event "message"; if ([string]::IsNullOrEmpty($m)) { $m = Prop $event "notification_type" }
    \\  if (-not [string]::IsNullOrEmpty($t)) { $title = $t }; if (-not [string]::IsNullOrEmpty($m)) { $body = $m }
    \\} elseif ($hook -eq "Stop") {
    \\  $title = "Claude Code"; $body = "Turn complete"
    \\} elseif ($null -ne (Prop $event "type")) {
    \\  $title = "Codex"; $body = Prop $event "last-assistant-message"; if ([string]::IsNullOrEmpty($body)) { $body = Prop $event "type" }
    \\}
    \\function Clean($v, $n) { if ($null -eq $v) { $v = "" }; $v = $v -replace "[\x00-\x1f\x7f;]", ""; if ($v.Length -gt $n) { $v = $v.Substring(0, $n) }; return $v }
    \\$esc=[char]27; $bel=[char]7; $marker=[char]0x200B
    \\$msg="$esc]777;notify;$(Clean $title 256);$(Clean $body 1024)$marker$bel$bel"
    \\$bytes=[Text.Encoding]::UTF8.GetBytes($msg)
    \\try { $s=[IO.File]::OpenWrite("CONOUT$"); try { $s.Write($bytes,0,$bytes.Length) } finally { $s.Dispose() } } catch {}
    \\exit 0
    \\
;

pub const windows_claude_session_hook = windowsSessionHook("claude_code", true);
pub const windows_codex_session_hook = windowsSessionHook("codex", false);

fn windowsSessionHook(comptime app: []const u8, comptime claude: bool) []const u8 {
    const filter = if (claude)
        \\if ($hook -eq "SubagentStop" -or $null -ne (Prop $event "agent_id")) { exit 0 }
        \\
    else
        \\if (-not [string]::IsNullOrEmpty($hook) -and $hook -ne "SessionStart") { exit 0 }
        \\
    ;
    return
        \\param([string] $Action = "")
        \\
        ++ "$app = \"" ++ app ++ "\"\n" ++
        \\
        \\if ($Action -ne "session") { exit 0 }
        \\try { $payload = [Console]::In.ReadToEnd() } catch { $payload = "" }
        \\try { $event = $payload | ConvertFrom-Json -ErrorAction Stop } catch { $event = $null }
        \\function Prop($o, $n) { if ($null -eq $o) { return $null }; $p = $o.PSObject.Properties[$n]; if ($null -eq $p) { return $null }; return [string]$p.Value }
        \\$hook = Prop $event "hook_event_name"
        ++ filter ++
        \\$sid = Prop $event "session_id"
        \\if ([string]::IsNullOrEmpty($sid)) { exit 0 }
        \\function Safe($v) { if ([string]::IsNullOrEmpty($v)) { return $null }; if ($v -match "[\x00-\x1f\x7f]") { return $null }; return $v }
        \\$obj = [ordered]@{ session_id = $sid }
        \\$path = Safe (Prop $event "transcript_path"); if ($null -ne $path) { $obj.session_path = $path }
        \\$source = $null; if ($hook -eq "SessionStart") { $source = Safe (Prop $event "source") }; if ($null -ne $source) { $obj.session_start_source = $source }
        \\$json = ($obj | ConvertTo-Json -Compress)
        \\$data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd("=").Replace("+","-").Replace("/","_")
        \\$esc=[char]27; $bel=[char]7
        \\$msg="$esc]7748;wispterm-agent;event=session;app=$app;data=$data$bel"
        \\$bytes=[Text.Encoding]::UTF8.GetBytes($msg)
        \\try { $s=[IO.File]::OpenWrite("CONOUT$"); try { $s.Write($bytes,0,$bytes.Length) } finally { $s.Dispose() } } catch {}
        \\exit 0
        \\
    ;
}

test "POSIX session hook assets embed app labels through environment lines" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, posix_claude_session_hook, "export WISPTERM_AGENT_APP=claude_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, posix_codex_session_hook, "export WISPTERM_AGENT_APP=codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, posix_claude_session_hook, "app = \"\n") == null);
}

test "Windows session hook assets embed app labels as PowerShell variables" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, windows_claude_session_hook, "$app = \"claude_code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, windows_codex_session_hook, "$app = \"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, windows_codex_session_hook, "app=\n") == null);
}
