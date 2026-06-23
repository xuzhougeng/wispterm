const std = @import("std");
const builtin = @import("builtin");
const Surface = @import("Surface.zig");
const assets = @import("agent_integration_assets.zig");
const install_model = @import("agent_integration_install.zig");
const platform_dirs = @import("platform/dirs.zig");
const platform_atomic_file = @import("platform/atomic_file.zig");
const remote_file = @import("platform/remote_file.zig");
const scp = @import("scp.zig");
const ssh_connection = @import("ssh_connection.zig");

pub const Kind = enum {
    claude,
    codex,
};

pub const Target = union(enum) {
    local,
    wsl,
    ssh: ssh_connection.SshConnection,
};

pub const Outcome = enum {
    installed,
    conflict_existing_codex_notify,
    target_unavailable,
    transport_failed,
    parse_error,
    write_failed,
};

pub const Result = struct {
    outcome: Outcome,
    target_label: [128]u8 = undefined,
    target_label_len: usize = 0,

    pub fn targetLabel(self: *const Result) []const u8 {
        return self.target_label[0..self.target_label_len];
    }
};

pub fn targetFromSurface(surface: *const Surface) ?Target {
    return switch (surface.launch_kind) {
        .local => .local,
        .wsl => .wsl,
        .ssh => if (surface.ssh_connection) |conn| .{ .ssh = conn } else null,
    };
}

pub fn install(allocator: std.mem.Allocator, target: Target, kind: Kind) Result {
    var result: Result = .{ .outcome = .installed };
    fillTargetLabel(&result, target);
    installInner(allocator, target, kind) catch |err| {
        result.outcome = switch (err) {
            error.CodexNotifyConflict => .conflict_existing_codex_notify,
            error.InvalidSettingsJson, error.InvalidHooksJson => .parse_error,
            error.TargetUnavailable => .target_unavailable,
            error.RemoteExecFailed, error.RemoteWriteFailed => .transport_failed,
            else => .write_failed,
        };
    };
    return result;
}

pub fn installClaude(allocator: std.mem.Allocator, target: Target) Result {
    return install(allocator, target, .claude);
}

pub fn installCodex(allocator: std.mem.Allocator, target: Target) Result {
    return install(allocator, target, .codex);
}

fn installInner(allocator: std.mem.Allocator, target: Target, kind: Kind) !void {
    switch (target) {
        .local => {
            if (builtin.os.tag == .windows) {
                try installLocalNative(allocator, kind);
            } else {
                try runPosixInstallerLocal(allocator, kind);
            }
        },
        .wsl => try runPosixInstallerWsl(allocator, kind),
        .ssh => |conn| try runPosixInstallerSsh(allocator, conn, kind),
    }
}

fn fillTargetLabel(result: *Result, target: Target) void {
    const label = switch (target) {
        .local => "local",
        .wsl => "WSL",
        .ssh => |conn| conn.host(),
    };
    const n = @min(label.len, result.target_label.len);
    @memcpy(result.target_label[0..n], label[0..n]);
    result.target_label_len = n;
}

fn installLocalNative(allocator: std.mem.Allocator, kind: Kind) !void {
    const config_dir = try platform_dirs.configDir(allocator);
    defer allocator.free(config_dir);
    const home = try platform_dirs.homeDir(allocator);
    defer allocator.free(home);

    const notify_path = try std.fs.path.join(allocator, &.{ config_dir, "wispterm-notify.ps1" });
    defer allocator.free(notify_path);
    try writeTextFile(notify_path, assets.windows_notify_script);

    switch (kind) {
        .claude => try installLocalNativeClaude(allocator, home, notify_path),
        .codex => try installLocalNativeCodex(allocator, home, notify_path),
    }
}

fn installLocalNativeClaude(allocator: std.mem.Allocator, home: []const u8, notify_path: []const u8) !void {
    const claude_dir = try envPathOrJoin(allocator, "CLAUDE_CONFIG_DIR", &.{ home, ".claude" });
    defer allocator.free(claude_dir);
    const hooks_dir = try std.fs.path.join(allocator, &.{ claude_dir, "hooks" });
    defer allocator.free(hooks_dir);
    const hook_path = try std.fs.path.join(allocator, &.{ hooks_dir, "wispterm-agent-session.ps1" });
    defer allocator.free(hook_path);
    const settings_path = try std.fs.path.join(allocator, &.{ claude_dir, "settings.json" });
    defer allocator.free(settings_path);

    try writeTextFile(hook_path, assets.windows_claude_session_hook);
    const existing = readOptionalFile(allocator, settings_path) catch return error.WriteFailed;
    defer allocator.free(existing);
    const notify_cmd = try std.fmt.allocPrint(allocator, "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"{s}\"", .{notify_path});
    defer allocator.free(notify_cmd);
    const updated = install_model.buildClaudeSettings(allocator, existing, .{
        .session_hook_path = hook_path,
        .notifier_command = notify_cmd,
        .command_style = .windows,
    }) catch return error.InvalidSettingsJson;
    defer allocator.free(updated);
    try writeTextFile(settings_path, updated);
}

fn installLocalNativeCodex(allocator: std.mem.Allocator, home: []const u8, notify_path: []const u8) !void {
    const codex_dir = try envPathOrJoin(allocator, "CODEX_HOME", &.{ home, ".codex" });
    defer allocator.free(codex_dir);
    const hook_path = try std.fs.path.join(allocator, &.{ codex_dir, "wispterm-agent-session.ps1" });
    defer allocator.free(hook_path);
    const hooks_path = try std.fs.path.join(allocator, &.{ codex_dir, "hooks.json" });
    defer allocator.free(hooks_path);
    const config_path = try std.fs.path.join(allocator, &.{ codex_dir, "config.toml" });
    defer allocator.free(config_path);

    try writeTextFile(hook_path, assets.windows_codex_session_hook);
    const hooks_existing = readOptionalFile(allocator, hooks_path) catch return error.WriteFailed;
    defer allocator.free(hooks_existing);
    const hooks_updated = install_model.buildCodexHooksJson(allocator, hooks_existing, .{
        .session_hook_path = hook_path,
        .command_style = .windows,
    }) catch return error.InvalidHooksJson;
    defer allocator.free(hooks_updated);
    try writeTextFile(hooks_path, hooks_updated);

    const config_existing = readOptionalFile(allocator, config_path) catch return error.WriteFailed;
    defer allocator.free(config_existing);
    const notify_value = try std.fmt.allocPrint(allocator, "[\"powershell.exe\", \"-NoProfile\", \"-ExecutionPolicy\", \"Bypass\", \"-File\", \"{s}\"]", .{notify_path});
    defer allocator.free(notify_value);
    const config_updated = install_model.buildCodexConfigToml(allocator, config_existing, .{
        .notifier_command = notify_path,
        .notify_value = notify_value,
    }) catch return error.InvalidSettingsJson;
    defer allocator.free(config_updated.content);
    if (config_updated.notify_status == .conflict) return error.CodexNotifyConflict;
    try writeTextFile(config_path, config_updated.content);
}

fn runPosixInstallerLocal(allocator: std.mem.Allocator, kind: Kind) !void {
    const script = try buildPosixInstaller(allocator, kind);
    defer allocator.free(script);
    const command = try scriptCommand(allocator, script);
    defer allocator.free(command);
    const out = remote_file.localPosixExec(allocator, command, 128 * 1024) catch return error.RemoteExecFailed;
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "WISPTERM_CODEX_NOTIFY_CONFLICT") != null) return error.CodexNotifyConflict;
    if (std.mem.indexOf(u8, out, "WISPTERM_INSTALL_EXIT:0") == null) return error.RemoteExecFailed;
}

fn runPosixInstallerWsl(allocator: std.mem.Allocator, kind: Kind) !void {
    const script = try buildPosixInstaller(allocator, kind);
    defer allocator.free(script);
    const command = try scriptCommand(allocator, script);
    defer allocator.free(command);
    const out = remote_file.wslExec(allocator, command) orelse return error.RemoteExecFailed;
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "WISPTERM_CODEX_NOTIFY_CONFLICT") != null) return error.CodexNotifyConflict;
    if (std.mem.indexOf(u8, out, "WISPTERM_INSTALL_EXIT:0") == null) return error.RemoteExecFailed;
}

fn runPosixInstallerSsh(allocator: std.mem.Allocator, conn: ssh_connection.SshConnection, kind: Kind) !void {
    const script = try buildPosixInstaller(allocator, kind);
    defer allocator.free(script);

    const home_out = remote_file.sshExecCapture(allocator, conn, "printf %s \"$HOME\"") catch return error.RemoteExecFailed;
    defer allocator.free(home_out);
    const home = std.mem.trim(u8, home_out, " \t\r\n");
    if (home.len == 0) return error.TargetUnavailable;

    const remote_dir = try std.fmt.allocPrint(allocator, "{s}/.config/wispterm/integration-setup", .{home});
    defer allocator.free(remote_dir);
    const remote_dir_q = try shellQuote(allocator, remote_dir);
    defer allocator.free(remote_dir_q);
    const mkdir_cmd = try std.fmt.allocPrint(allocator, "mkdir -p {s}", .{remote_dir_q});
    defer allocator.free(mkdir_cmd);
    {
        var cap = remote_file.sshExecCaptureFull(allocator, conn, mkdir_cmd) catch return error.RemoteExecFailed;
        defer cap.deinit(allocator);
        if (!cap.exited_ok) return error.RemoteExecFailed;
    }

    const remote_script = try std.fmt.allocPrint(allocator, "{s}/install-agent-integration.sh", .{remote_dir});
    defer allocator.free(remote_script);
    if (!scp.sshWriteFile(allocator, &conn, remote_script, script)) return error.RemoteWriteFailed;

    const remote_script_q = try shellQuote(allocator, remote_script);
    defer allocator.free(remote_script_q);
    const run_cmd = try std.fmt.allocPrint(allocator, "sh {s}", .{remote_script_q});
    defer allocator.free(run_cmd);
    var cap = remote_file.sshExecCaptureFull(allocator, conn, run_cmd) catch return error.RemoteExecFailed;
    defer cap.deinit(allocator);
    if (std.mem.indexOf(u8, cap.stdout, "WISPTERM_CODEX_NOTIFY_CONFLICT") != null) return error.CodexNotifyConflict;
    if (!cap.exited_ok) return error.RemoteExecFailed;
}

fn buildPosixInstaller(allocator: std.mem.Allocator, kind: Kind) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\#!/bin/sh
        \\set -eu
        \\command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 12; }
        \\wispterm_dir="${XDG_CONFIG_HOME:-$HOME/.config}/wispterm"
        \\mkdir -p "$wispterm_dir"
        \\notify="$wispterm_dir/wispterm-notify.sh"
        \\cat > "$notify" <<'WISPTERM_NOTIFY'
        \\
    );
    try out.appendSlice(allocator, assets.posix_notify_script);
    try out.appendSlice(allocator,
        \\WISPTERM_NOTIFY
        \\chmod +x "$notify"
        \\
    );
    switch (kind) {
        .claude => try appendPosixClaudeInstall(allocator, &out),
        .codex => try appendPosixCodexInstall(allocator, &out),
    }
    return try out.toOwnedSlice(allocator);
}

fn appendPosixClaudeInstall(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator,
        \\claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
        \\mkdir -p "$claude_dir/hooks"
        \\claude_hook="$claude_dir/hooks/wispterm-agent-session.sh"
        \\cat > "$claude_hook" <<'WISPTERM_CLAUDE_HOOK'
        \\
    );
    try out.appendSlice(allocator, assets.posix_claude_session_hook);
    try out.appendSlice(allocator,
        \\WISPTERM_CLAUDE_HOOK
        \\chmod +x "$claude_hook"
        \\claude_settings="$claude_dir/settings.json"
        \\[ -f "$claude_settings" ] || printf '{}\n' > "$claude_settings"
        \\python3 - "$claude_settings" "$claude_hook" "$notify" <<'PY'
        \\import json, shlex, sys
        \\path, hook_path, notify = sys.argv[1:4]
        \\with open(path, encoding="utf-8") as f:
        \\    raw = f.read().strip()
        \\cfg = json.loads(raw or "{}")
        \\if not isinstance(cfg, dict):
        \\    raise SystemExit(13)
        \\hooks = cfg.setdefault("hooks", {})
        \\if not isinstance(hooks, dict):
        \\    raise SystemExit(13)
        \\def has_command(arr, needle):
        \\    return any(needle in str(h.get("command", "")) for g in arr if isinstance(g, dict) for h in g.get("hooks", []) if isinstance(h, dict))
        \\def add(event, command, matcher=None, timeout=None, needle=None):
        \\    arr = hooks.setdefault(event, [])
        \\    if not isinstance(arr, list):
        \\        raise SystemExit(13)
        \\    if has_command(arr, needle or command):
        \\        return
        \\    hook = {"type": "command", "command": command}
        \\    if timeout is not None:
        \\        hook["timeout"] = timeout
        \\    group = {"hooks": [hook]}
        \\    if matcher is not None:
        \\        group["matcher"] = matcher
        \\    arr.append(group)
        \\add("SessionStart", "bash " + shlex.quote(hook_path) + " session", matcher="*", timeout=10, needle="wispterm-agent-session")
        \\add("UserPromptSubmit", "bash " + shlex.quote(hook_path) + " state running", needle="state running")
        \\add("PreToolUse", "bash " + shlex.quote(hook_path) + " state running", matcher="*", needle="state running")
        \\add("Notification", "bash " + shlex.quote(hook_path) + " state waiting_approval", needle="state waiting_approval")
        \\add("Stop", "bash " + shlex.quote(hook_path) + " state done", needle="state done")
        \\add("Stop", notify)
        \\add("Notification", notify)
        \\with open(path, "w", encoding="utf-8") as f:
        \\    json.dump(cfg, f, indent=2)
        \\    f.write("\n")
        \\PY
        \\
    );
}

fn appendPosixCodexInstall(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator,
        \\codex_dir="${CODEX_HOME:-$HOME/.codex}"
        \\mkdir -p "$codex_dir"
        \\codex_hook="$codex_dir/wispterm-agent-session.sh"
        \\cat > "$codex_hook" <<'WISPTERM_CODEX_HOOK'
        \\
    );
    try out.appendSlice(allocator, assets.posix_codex_session_hook);
    try out.appendSlice(allocator,
        \\WISPTERM_CODEX_HOOK
        \\chmod +x "$codex_hook"
        \\codex_hooks="$codex_dir/hooks.json"
        \\[ -f "$codex_hooks" ] || printf '{}\n' > "$codex_hooks"
        \\python3 - "$codex_hooks" "$codex_hook" <<'PY'
        \\import json, shlex, sys
        \\path, hook_path = sys.argv[1:3]
        \\with open(path, encoding="utf-8") as f:
        \\    raw = f.read().strip()
        \\cfg = json.loads(raw or "{}")
        \\if not isinstance(cfg, dict):
        \\    raise SystemExit(13)
        \\hooks = cfg.setdefault("hooks", {})
        \\if not isinstance(hooks, dict):
        \\    raise SystemExit(13)
        \\arr = hooks.setdefault("SessionStart", [])
        \\if not isinstance(arr, list):
        \\    raise SystemExit(13)
        \\if not any("wispterm-agent-session" in str(h.get("command", "")) for g in arr if isinstance(g, dict) for h in g.get("hooks", []) if isinstance(h, dict)):
        \\    arr.append({"hooks": [{"type": "command", "command": "bash " + shlex.quote(hook_path) + " session", "timeout": 10}]})
        \\with open(path, "w", encoding="utf-8") as f:
        \\    json.dump(cfg, f, indent=2)
        \\    f.write("\n")
        \\PY
        \\codex_config="$codex_dir/config.toml"
        \\[ -f "$codex_config" ] || : > "$codex_config"
        \\python3 - "$codex_config" "$notify" <<'PY'
        \\import re, sys
        \\path, notify = sys.argv[1:3]
        \\text = open(path, encoding="utf-8").read()
        \\lines = text.splitlines()
        \\first_header = next((i for i,l in enumerate(lines) if re.match(r"^\s*\[", l)), len(lines))
        \\notify_re = re.compile(r"^\s*notify\s*=")
        \\notify_idx = next((i for i,l in enumerate(lines[:first_header]) if notify_re.match(l)), None)
        \\if notify_idx is None:
        \\    lines.insert(0, 'notify = ["%s"]' % notify.replace("\\", "\\\\").replace('"', '\\"'))
        \\elif notify not in lines[notify_idx]:
        \\    print("WISPTERM_CODEX_NOTIFY_CONFLICT")
        \\def header_name(line):
        \\    m = re.match(r"^\s*\[([^\[\]]+)\]\s*$", line)
        \\    return m.group(1).strip() if m else None
        \\features = next((i for i,l in enumerate(lines) if header_name(l) == "features"), None)
        \\if features is None:
        \\    if lines and lines[-1] != "":
        \\        lines.append("")
        \\    lines.extend(["[features]", "hooks = true"])
        \\else:
        \\    end = next((i for i in range(features + 1, len(lines)) if header_name(lines[i]) is not None), len(lines))
        \\    i = features + 1
        \\    hooks_idx = None
        \\    while i < end:
        \\        if re.match(r"^\s*codex_hooks\s*=", lines[i]):
        \\            del lines[i]; end -= 1; continue
        \\        if re.match(r"^\s*hooks\s*=", lines[i]):
        \\            hooks_idx = i
        \\        i += 1
        \\    if hooks_idx is None:
        \\        lines.insert(features + 1, "hooks = true")
        \\    else:
        \\        lines[hooks_idx] = "hooks = true"
        \\open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
        \\PY
        \\
    );
}

test "POSIX Claude installer writes lifecycle state hooks" {
    const script = try buildPosixInstaller(std.testing.allocator, .claude);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "state running") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "state waiting_approval") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "state done") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "add(\"SessionStart\", \"bash \" + shlex.quote(hook_path) + \" session\"") != null);
}

test "POSIX Codex installer routes SessionStart to session hook, not notifier" {
    const script = try buildPosixInstaller(std.testing.allocator, .codex);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "python3 - \"$codex_hooks\" \"$codex_hook\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "python3 - \"$codex_hooks\" \"$notify\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "\"command\": \"bash \" + shlex.quote(hook_path) + \" session\"") != null);
}

fn scriptCommand(allocator: std.mem.Allocator, script: []const u8) ![]u8 {
    const quoted = try shellQuote(allocator, script);
    defer allocator.free(quoted);
    return std.fmt.allocPrint(allocator,
        "tmp=\"${{TMPDIR:-/tmp}}/wispterm-agent-integration-$$.sh\"; printf %s {s} > \"$tmp\" && sh \"$tmp\"; rc=$?; rm -f \"$tmp\"; printf '\\nWISPTERM_INSTALL_EXIT:%s\\n' \"$rc\"; exit $rc",
        .{quoted},
    );
}

fn shellQuote(allocator: std.mem.Allocator, arg: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (arg) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

fn envPathOrJoin(allocator: std.mem.Allocator, env_name: []const u8, parts: []const []const u8) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, env_name)) |value| {
        if (value.len > 0) return value;
        allocator.free(value);
    } else |_| {}
    return std.fs.path.join(allocator, parts);
}

fn readOptionalFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => err,
    };
}

fn writeTextFile(path: []const u8, content: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    try std.fs.cwd().makePath(dir);
    try platform_atomic_file.writeFileReplaceSafe(path, content);
}
