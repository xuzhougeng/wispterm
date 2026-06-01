//! Session-free agent tool layer: tool dispatch and every tool implementation,
//! shell/argv runners, REPL handling, dangerous-command detection, and write/
//! copilot context. Leaf module — depends on ai_chat_types (ToolContext seam)
//! and ai_chat_protocol/skills, never on ai_chat.zig or Session.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("ai_chat_types.zig");
const ai_chat_protocol = @import("ai_chat_protocol.zig");
const ToolCall = ai_chat_protocol.ToolCall;
const ToolContext = types.ToolContext;
const ToolSurface = types.ToolSurface;
const ToolSnapshot = types.ToolSnapshot;
const ToolHost = types.ToolHost;
const ToolClosedTab = types.ToolClosedTab;
const SshProfileSaveArgs = types.SshProfileSaveArgs;
const SavedSshProfile = types.SavedSshProfile;
const AgentSettings = types.AgentSettings;
const agent_detector = @import("agent_detector.zig");
const skill_registry = @import("skill_registry.zig");
const wispterm_docs = @import("wispterm_docs.zig");
const weixin_types = @import("weixin/types.zig");
const ai_chat_skills = @import("ai_chat_skills.zig");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const platform_agent_prompt = @import("platform/agent_prompt.zig");

/// Number of output lines included in a copilot context block.
pub const COPILOT_CONTEXT_LINES: usize = 40;

// ---------------------------------------------------------------------------
// Tool dispatch
// ---------------------------------------------------------------------------

pub fn executeToolCall(ctx: *ToolContext, call: ToolCall) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    if (std.mem.eql(u8, call.name, "terminal_list")) {
        return terminalListTool(ctx);
    }
    if (std.mem.eql(u8, call.name, "terminal_snapshot")) {
        const args = parseArgs(ctx.allocator, call.arguments);
        defer if (args) |parsed| parsed.deinit();
        const surface_id = if (args) |parsed| jsonStringArg(parsed.value, "surface_id") else null;
        return terminalSnapshotTool(ctx, surface_id);
    }
    if (std.mem.eql(u8, call.name, "terminal_select")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = jsonStringArg(args.value, "surface_id") orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        return terminalSelectTool(ctx, surface_id);
    }
    if (std.mem.eql(u8, call.name, platform_process.localCommandToolName())) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const command = jsonStringArg(args.value, "command") orelse return ctx.allocator.dupe(u8, "Missing command");
        const cwd = jsonStringArg(args.value, "cwd");
        const timeout_ms = jsonIntArg(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return localCommandExecTool(ctx, command, cwd, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "ssh_session_exec")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = jsonStringArg(args.value, "surface_id") orelse defaultExecSurfaceId(ctx) orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        const command = jsonStringArg(args.value, "command") orelse return ctx.allocator.dupe(u8, "Missing command");
        const timeout_ms = jsonIntArg(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return sshSessionExecTool(ctx, surface_id, command, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "wsl_session_exec")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = jsonStringArg(args.value, "surface_id") orelse defaultExecSurfaceId(ctx) orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        const command = jsonStringArg(args.value, "command") orelse return ctx.allocator.dupe(u8, "Missing command");
        const timeout_ms = jsonIntArg(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return wslSessionExecTool(ctx, surface_id, command, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "terminal_repl_exec")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = jsonStringArg(args.value, "surface_id") orelse defaultExecSurfaceId(ctx) orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        const repl = jsonStringArg(args.value, "repl") orelse return ctx.allocator.dupe(u8, "Missing repl");
        const code = jsonStringArg(args.value, "code") orelse return ctx.allocator.dupe(u8, "Missing code");
        const timeout_ms = jsonIntArg(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return terminalReplExecTool(ctx, surface_id, repl, code, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "ssh_profile_save")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const host = jsonStringArg(args.value, "host") orelse return ctx.allocator.dupe(u8, "Missing host");
        const user = jsonStringArg(args.value, "user") orelse return ctx.allocator.dupe(u8, "Missing user");
        return sshProfileSaveTool(ctx, .{
            .name = jsonStringArg(args.value, "name") orelse "",
            .host = host,
            .user = user,
            .password = jsonStringArg(args.value, "password") orelse "",
            .port = jsonStringArg(args.value, "port") orelse "",
            .proxy_jump = jsonStringArg(args.value, "proxy_jump") orelse "",
        });
    }
    if (std.mem.eql(u8, call.name, "ssh_profile_connect")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const profile_name = jsonStringArg(args.value, "profile_name") orelse return ctx.allocator.dupe(u8, "Missing profile_name");
        return sshProfileConnectTool(ctx, profile_name);
    }
    if (std.mem.eql(u8, call.name, "tab_new")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const kind = jsonStringArg(args.value, "kind") orelse "default";
        const command = jsonStringArg(args.value, "command");
        return tabNewTool(ctx, kind, command);
    }
    if (std.mem.eql(u8, call.name, "tab_close")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        var tab_index = jsonIndexArg(args.value, "tab_index");
        if (tab_index == null) {
            if (jsonIndexArg(args.value, "tab_number")) |tab_number| {
                if (tab_number > 0) tab_index = tab_number - 1;
            }
        }
        const surface_id = jsonStringArg(args.value, "surface_id");
        const title = jsonStringArg(args.value, "title");
        return tabCloseTool(ctx, tab_index, surface_id, title);
    }
    if (std.mem.eql(u8, call.name, "skill_info")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const skill_name = jsonStringArg(args.value, "skill_name") orelse return ctx.allocator.dupe(u8, "Missing skill_name");
        return skillInfoTool(ctx.allocator, skill_name);
    }
    if (std.mem.eql(u8, call.name, "wispterm_docs")) {
        const args = parseArgs(ctx.allocator, call.arguments);
        defer if (args) |parsed| parsed.deinit();
        const topic = if (args) |parsed| jsonStringArg(parsed.value, "topic") else null;
        return wisptermDocsTool(ctx.allocator, topic);
    }
    if (std.mem.eql(u8, call.name, "weixin_send_attachment")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const kind_text = jsonStringArg(args.value, "kind") orelse return ctx.allocator.dupe(u8, "Missing kind");
        const kind = weixin_types.AttachmentKind.parse(kind_text) orelse return ctx.allocator.dupe(u8, "Invalid kind; expected file, image, or voice");
        const path = jsonStringArg(args.value, "path") orelse return ctx.allocator.dupe(u8, "Missing path");
        const display_name = jsonStringArg(args.value, "display_name") orelse "";
        return weixinSendAttachmentTool(ctx, kind, path, display_name);
    }
    return std.fmt.allocPrint(ctx.allocator, "Unknown tool: {s}", .{call.name});
}

fn parseArgs(allocator: std.mem.Allocator, text: []const u8) ?std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const body = if (trimmed.len == 0) "{}" else trimmed;
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch null;
}

fn jsonStringArg(root: std.json.Value, name: []const u8) ?[]const u8 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn jsonIntArg(root: std.json.Value, name: []const u8) ?u32 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .integer => |v| if (v > 0 and v <= std.math.maxInt(u32)) @intCast(v) else null,
        .float => |v| if (v > 0 and v <= @as(f64, @floatFromInt(std.math.maxInt(u32)))) @intFromFloat(v) else null,
        else => null,
    };
}

fn jsonIndexArg(root: std.json.Value, name: []const u8) ?usize {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .integer => |v| if (v >= 0 and v <= std.math.maxInt(usize)) @intCast(v) else null,
        .float => |v| if (v >= 0 and v <= @as(f64, @floatFromInt(std.math.maxInt(usize)))) @intFromFloat(v) else null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Skill / docs tools (allocator-only, no context)
// ---------------------------------------------------------------------------

fn skillInfoTool(allocator: std.mem.Allocator, skill_name: []const u8) ![]u8 {
    const roots = try ai_chat_skills.defaultSkillRootPaths(allocator);
    defer ai_chat_skills.freeSkillRootPaths(allocator, roots);
    return skillInfoToolFromRoots(allocator, skill_name, roots);
}

pub fn skillInfoToolFromRoots(allocator: std.mem.Allocator, skill_name: []const u8, root_paths: []const []const u8) ![]u8 {
    var snapshot = ai_chat_skills.loadSkillSnapshotFromRoots(allocator, skill_name, root_paths) catch |err| switch (err) {
        skill_registry.LookupError.SkillNotFound => return std.fmt.allocPrint(allocator, "Skill not found: {s}", .{skill_name}),
        skill_registry.LookupError.DuplicateSkillName => return std.fmt.allocPrint(allocator, "Duplicate skill name: {s}", .{skill_name}),
        skill_registry.LookupError.InvalidSkillMarkdown => return std.fmt.allocPrint(allocator, "Invalid SKILL.md for skill: {s}", .{skill_name}),
        skill_registry.LookupError.SkillTooLarge => return std.fmt.allocPrint(allocator, "SKILL.md too large for skill: {s}", .{skill_name}),
        else => |e| return std.fmt.allocPrint(allocator, "Failed to load skill {s}: {}", .{ skill_name, e }),
    };
    defer snapshot.deinit(allocator);
    return allocator.dupe(u8, snapshot.content);
}

pub fn wisptermDocsTool(allocator: std.mem.Allocator, topic: ?[]const u8) ![]u8 {
    if (topic) |name| {
        if (wispterm_docs.readTopic(name)) |content| {
            return allocator.dupe(u8, content);
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.print(allocator, "Unknown topic \"{s}\". Available topics:", .{name});
        for (wispterm_docs.topics) |t| {
            try out.print(allocator, " {s}", .{t.name});
        }
        return out.toOwnedSlice(allocator);
    }
    return wispterm_docs.listTopics(allocator);
}

// ---------------------------------------------------------------------------
// Weixin attachment tool
// ---------------------------------------------------------------------------

fn weixinSendAttachmentTool(
    ctx: *ToolContext,
    kind: weixin_types.AttachmentKind,
    path: []const u8,
    display_name: []const u8,
) ![]u8 {
    const wx_ctx = ctx.weixin_reply_context orelse {
        return ctx.allocator.dupe(u8, "No active Weixin reply context; cannot send attachment.");
    };
    wx_ctx.sender.sendAttachment(kind, path, display_name, wx_ctx.to_user_id, wx_ctx.context_token) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to send {s} to Weixin: {}", .{ kind.name(), err });
    };
    const shown = if (display_name.len != 0) display_name else std.fs.path.basename(path);
    return std.fmt.allocPrint(ctx.allocator, "Sent {s} to Weixin: {s}", .{ kind.name(), shown });
}

// ---------------------------------------------------------------------------
// Terminal surface helpers
// ---------------------------------------------------------------------------

fn toolSurfaceKind(surface: ToolSurface) []const u8 {
    if (surface.is_ssh) return "ssh";
    if (surface.is_wsl) return "wsl";
    return "terminal";
}

fn terminalListTool(ctx: *const ToolContext) ![]u8 {
    const snapshot = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    const selected = selectedWriteContext(ctx);
    // tab/active_tab are shown one-based to match the tab numbers the user sees
    // in the UI (the internal tab_index is zero-based).
    try out.print(ctx.allocator, "active_tab={d}\n", .{snapshot.active_tab + 1});
    if (selected) |id| {
        try out.print(ctx.allocator, "selected_context={s}\n", .{id});
    } else {
        try out.appendSlice(ctx.allocator, "selected_context=none\n");
    }
    for (snapshot.surfaces) |surface| {
        const is_selected = if (selected) |id| std.mem.eql(u8, id, surface.id) else false;
        try out.print(ctx.allocator, "- id={s} tab={d} focused={} selected={} kind={s} title=\"{s}\" cwd=\"{s}\"", .{
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            is_selected,
            toolSurfaceKind(surface),
            surface.title,
            surface.cwd,
        });
        if (surface.agent_app != .none) {
            try out.print(ctx.allocator, " agent={s}:{s} confidence={d}", .{
                surface.agent_app.label(),
                surface.agent_state.label(),
                surface.agent_confidence,
            });
        }
        try out.append(ctx.allocator, '\n');
    }
    return truncateOwned(ctx.allocator, ctx.settings, try out.toOwnedSlice(ctx.allocator));
}

fn terminalSnapshotTool(ctx: *const ToolContext, surface_id: ?[]const u8) ![]u8 {
    const snapshot = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);

    for (snapshot.surfaces) |surface| {
        if (surface_id) |id| {
            if (!std.mem.eql(u8, surface.id, id)) continue;
        }
        try out.print(ctx.allocator, "surface={s} title=\"{s}\" kind={s} focused={}", .{
            surface.id,
            surface.title,
            toolSurfaceKind(surface),
            surface.focused,
        });
        if (surface.agent_app != .none) {
            try out.print(ctx.allocator, " agent={s}:{s} confidence={d}", .{
                surface.agent_app.label(),
                surface.agent_state.label(),
                surface.agent_confidence,
            });
        }
        try out.append(ctx.allocator, '\n');
        try out.appendSlice(ctx.allocator, surface.snapshot);
        try out.appendSlice(ctx.allocator, "\n---\n");
    }
    if (out.items.len == 0) try out.appendSlice(ctx.allocator, "No matching terminal surface.");
    return truncateOwned(ctx.allocator, ctx.settings, try out.toOwnedSlice(ctx.allocator));
}

fn terminalSelectTool(ctx: *ToolContext, surface_id: []const u8) ![]u8 {
    const snapshot = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const surface = findSurface(snapshot, surface_id) orelse return std.fmt.allocPrint(ctx.allocator, "No matching terminal surface for surface_id={s}.", .{surface_id});
    setWriteContext(ctx, surface.id);
    return std.fmt.allocPrint(
        ctx.allocator,
        "selected surface_id={s} tab={d} focused={} kind={s} title=\"{s}\" cwd=\"{s}\"",
        .{
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            toolSurfaceKind(surface),
            surface.title,
            surface.cwd,
        },
    );
}

pub fn collectToolSnapshot(ctx: *const ToolContext) !ToolSnapshot {
    if (ctx.tool_snapshot) |snapshot| {
        return snapshot.clone(ctx.allocator);
    }
    const host = ctx.tool_host orelse return error.NoTerminalSnapshotHost;
    return host.collectSnapshot(host.ctx, ctx.allocator);
}

pub fn rememberConnectedSurface(ctx: *ToolContext, surface: ToolSurface) !void {
    setWriteContext(ctx, surface.id);
    if (ctx.tool_snapshot) |*snapshot| {
        for (snapshot.surfaces) |*existing| {
            existing.focused = false;
        }
        const prev_len = snapshot.surfaces.len;
        snapshot.surfaces = try ctx.allocator.realloc(snapshot.surfaces, prev_len + 1);
        snapshot.surfaces[prev_len] = surface;
        snapshot.active_tab = surface.tab_index;
        return;
    }

    const surfaces = try ctx.allocator.alloc(ToolSurface, 1);
    surfaces[0] = surface;
    ctx.tool_snapshot = .{
        .surfaces = surfaces,
        .active_tab = surface.tab_index,
    };
}

pub fn rememberClosedTab(ctx: *ToolContext, closed: ToolClosedTab) !void {
    if (ctx.tool_snapshot) |*snapshot| {
        var write: usize = 0;
        const closed_active = snapshot.active_tab == closed.tab_index;
        for (snapshot.surfaces) |*surface| {
            if (surface.tab_index == closed.tab_index) {
                surface.deinit(ctx.allocator);
                continue;
            }
            if (surface.tab_index > closed.tab_index) {
                surface.tab_index -= 1;
            }
            snapshot.surfaces[write] = surface.*;
            write += 1;
        }

        snapshot.surfaces = try ctx.allocator.realloc(snapshot.surfaces, write);
        snapshot.active_tab = closed.active_tab;

        if (closed_active) {
            var focused_set = false;
            for (snapshot.surfaces) |*surface| {
                if (surface.tab_index == snapshot.active_tab and !focused_set) {
                    surface.focused = true;
                    focused_set = true;
                } else {
                    surface.focused = false;
                }
            }
        } else {
            for (snapshot.surfaces) |*surface| {
                surface.focused = surface.focused and surface.tab_index == snapshot.active_tab;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Local command exec tool
// ---------------------------------------------------------------------------

fn localCommandExecTool(ctx: *const ToolContext, command: []const u8, cwd: ?[]const u8, timeout_ms: u32) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const dangerous = isDangerousCommand(command);
    if (ctx.settings.permission != .full or dangerous) {
        const reason = if (dangerous) DANGEROUS_COMMAND_APPROVAL_REASON else platform_process.localCommandApprovalLabel();
        if (!ctx.requestApproval(platform_process.localCommandToolName(), command, reason)) {
            return deniedResult(ctx.allocator, command, platform_process.localCommandDeniedReason());
        }
    }
    const result = runShellCommand(ctx.allocator, command, cwd, ctx.settings.output_limit, timeout_ms, ctx) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "{s} failed: {}", .{ platform_process.localCommandFailureLabel(), err });
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    if (result.timed_out) try out.appendSlice(ctx.allocator, "timed_out=true\n");
    try out.print(ctx.allocator, "exit_code={d}\nstdout:\n{s}\nstderr:\n{s}", .{ result.exit_code, result.stdout, result.stderr });
    return truncateOwned(ctx.allocator, ctx.settings, try out.toOwnedSlice(ctx.allocator));
}

pub const ShellResult = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool = false,
};

pub fn runShellCommand(allocator: std.mem.Allocator, command: []const u8, cwd: ?[]const u8, output_limit: u32, timeout_ms: u32, cancel_ctx: ?*const ToolContext) !ShellResult {
    var index: usize = 0;
    var last_err: ?anyerror = null;
    while (platform_process.localShellFallbackCommandArgv(index, command)) |argv| : (index += 1) {
        if (runArgv(allocator, argv.slice(), cwd, output_limit, timeout_ms, cancel_ctx)) |result| {
            return result;
        } else |err| {
            last_err = err;
        }
    }
    return if (last_err) |err| err else error.NoLocalShellFallback;
}

pub const CaptureOutput = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    max_bytes: usize,
    data: []u8 = &.{},
    truncated: bool = false,
    failed: bool = false,

    fn deinit(self: *CaptureOutput) void {
        self.allocator.free(self.data);
        self.data = &.{};
    }
};

pub fn runArgv(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, output_limit: u32, timeout_ms: u32, cancel_ctx: ?*const ToolContext) !ShellResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;
    child.create_no_window = true;
    try child.spawn();

    var stdout_capture = CaptureOutput{
        .allocator = allocator,
        .file = child.stdout.?,
        .max_bytes = output_limit,
    };
    errdefer stdout_capture.deinit();
    var stderr_capture = CaptureOutput{
        .allocator = allocator,
        .file = child.stderr.?,
        .max_bytes = output_limit,
    };
    errdefer stderr_capture.deinit();

    const stdout_thread = try std.Thread.spawn(.{}, captureOutputThread, .{&stdout_capture});
    const stderr_thread = try std.Thread.spawn(.{}, captureOutputThread, .{&stderr_capture});

    const wait_ms = @max(timeout_ms, 1);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(wait_ms));
    var timed_out = false;
    var canceled = false;
    while (true) {
        switch (platform_process.childExited(child.id, 25)) {
            .running => {},
            .exited => |code| {
                // On POSIX childExited() already reaped the zombie via
                // waitpid(WNOHANG). Pre-set Child.term so the child.wait()
                // below takes std's cleanup-only fast path instead of calling
                // waitpid() a second time — that second wait would hit ECHILD,
                // which Zig's std.posix.waitpid treats as `unreachable` (abort).
                // On Windows the process handle is NOT consumed by the poll, so
                // leave term unset and let child.wait() close the handle.
                if (builtin.os.tag != .windows) child.term = .{ .Exited = @intCast(code) };
                break;
            },
            .gone => {
                if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
                break;
            },
        }
        if (cancel_ctx) |c| {
            if (c.isCancelled()) {
                canceled = true;
                _ = child.kill() catch {};
                break;
            }
        }
        if (std.time.milliTimestamp() >= deadline) {
            timed_out = true;
            _ = child.kill() catch {};
            break;
        }
    }

    stdout_thread.join();
    stderr_thread.join();

    const exit_code: i32 = if (timed_out or canceled) 124 else blk: {
        const term = try child.wait();
        break :blk switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| -@as(i32, @intCast(sig)),
            .Stopped => |sig| -@as(i32, @intCast(sig)),
            .Unknown => |code| @intCast(code),
        };
    };
    return .{
        .exit_code = exit_code,
        .stdout = stdout_capture.data,
        .stderr = stderr_capture.data,
        .timed_out = timed_out or canceled,
    };
}

pub fn captureOutputThread(capture: *CaptureOutput) void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer {
        if (capture.failed) out.deinit(capture.allocator);
    }

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = capture.file.read(&buf) catch {
            break;
        };
        if (n == 0) break;
        if (out.items.len < capture.max_bytes) {
            const remaining = capture.max_bytes - out.items.len;
            const take = @min(remaining, n);
            out.appendSlice(capture.allocator, buf[0..take]) catch {
                capture.failed = true;
                return;
            };
            if (take < n) capture.truncated = true;
        } else {
            capture.truncated = true;
        }
    }

    if (capture.truncated) {
        out.appendSlice(capture.allocator, "\n...[truncated]\n") catch {};
    }
    capture.data = out.toOwnedSlice(capture.allocator) catch blk: {
        capture.failed = true;
        break :blk &.{};
    };
}

// ---------------------------------------------------------------------------
// Unix session (SSH/WSL) exec tools
// ---------------------------------------------------------------------------

pub const UnixSessionKind = enum {
    ssh,
    wsl,

    fn toolName(self: UnixSessionKind) []const u8 {
        return switch (self) {
            .ssh => "ssh_session_exec",
            .wsl => "wsl_session_exec",
        };
    }

    fn label(self: UnixSessionKind) []const u8 {
        return switch (self) {
            .ssh => "SSH",
            .wsl => "WSL",
        };
    }

    fn matches(self: UnixSessionKind, surface: ToolSurface) bool {
        return switch (self) {
            .ssh => surface.is_ssh,
            .wsl => surface.is_wsl,
        };
    }
};

fn agentAppDisplayName(app: agent_detector.App) []const u8 {
    return switch (app) {
        .none => "terminal app",
        .codex => "Codex",
        .claude_code => "Claude Code",
    };
}

fn agentAppReplName(app: agent_detector.App) []const u8 {
    return switch (app) {
        .none => "plain",
        .codex => "codex",
        .claude_code => "claude_code",
    };
}

fn shellExecAgentAppRefusal(allocator: std.mem.Allocator, kind: UnixSessionKind, surface: ToolSurface) !?[]u8 {
    if (surface.agent_app == .none or surface.agent_state == .none or surface.agent_confidence < 60) return null;
    const message = try std.fmt.allocPrint(
        allocator,
        "Refusing to run {s} shell command in an active {s} terminal (agent={s}:{s}, confidence={d}). Use terminal_repl_exec with repl={s} to send user-facing text, or exit {s} before using {s}.",
        .{
            kind.label(),
            agentAppDisplayName(surface.agent_app),
            surface.agent_app.label(),
            surface.agent_state.label(),
            surface.agent_confidence,
            agentAppReplName(surface.agent_app),
            agentAppDisplayName(surface.agent_app),
            kind.toolName(),
        },
    );
    return message;
}

fn commandWordApp(command: []const u8) ?agent_detector.App {
    const trimmed = std.mem.trimLeft(u8, command, " \t\r\n");
    if (trimmed.len == 0) return null;
    var end: usize = 0;
    while (end < trimmed.len and !std.ascii.isWhitespace(trimmed[end]) and trimmed[end] != ';') : (end += 1) {}
    var word = std.mem.trim(u8, trimmed[0..end], "\"'");
    if (std.mem.lastIndexOfAny(u8, word, "/\\")) |slash| word = word[slash + 1 ..];
    if (std.ascii.eqlIgnoreCase(word, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(word, "claude") or std.ascii.eqlIgnoreCase(word, "claude-code")) return .claude_code;
    return null;
}

fn commandHasNonInteractiveAgentFlag(command: []const u8) bool {
    return containsWord(command, "--help") or
        containsWord(command, "-h") or
        containsWord(command, "--version") or
        containsWord(command, "-V") or
        containsWord(command, "version");
}

pub fn shellExecInteractiveAgentCommandRefusal(allocator: std.mem.Allocator, kind: UnixSessionKind, command: []const u8) !?[]u8 {
    const app = commandWordApp(command) orelse return null;
    if (commandHasNonInteractiveAgentFlag(command)) return null;
    const message = try std.fmt.allocPrint(
        allocator,
        "Refusing to start interactive {s} with {s}. {s} wraps commands with sentinels and waits for them to exit, which corrupts full-screen agent apps. Use terminal_repl_exec with repl=plain to type `{s}` at the shell prompt, then use terminal_repl_exec with repl={s} to send prompts.",
        .{
            agentAppDisplayName(app),
            kind.toolName(),
            kind.toolName(),
            command,
            agentAppReplName(app),
        },
    );
    return message;
}

fn sshSessionExecTool(ctx: *ToolContext, surface_id: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
    return unixSessionExecTool(ctx, .ssh, surface_id, command, timeout_ms);
}

fn wslSessionExecTool(ctx: *ToolContext, surface_id: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
    return unixSessionExecTool(ctx, .wsl, surface_id, command, timeout_ms);
}

// ---------------------------------------------------------------------------
// REPL tools
// ---------------------------------------------------------------------------

pub const ReplKind = enum {
    r,
    python,
    codex,
    claude_code,
    plain,

    pub fn parse(value: []const u8) ?ReplKind {
        if (std.ascii.eqlIgnoreCase(value, "r") or std.ascii.eqlIgnoreCase(value, "R")) return .r;
        if (std.ascii.eqlIgnoreCase(value, "python") or std.ascii.eqlIgnoreCase(value, "py")) return .python;
        if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
        if (std.ascii.eqlIgnoreCase(value, "claude") or
            std.ascii.eqlIgnoreCase(value, "claude_code") or
            std.ascii.eqlIgnoreCase(value, "claude-code"))
        {
            return .claude_code;
        }
        if (std.ascii.eqlIgnoreCase(value, "plain") or std.ascii.eqlIgnoreCase(value, "text")) return .plain;
        return null;
    }

    pub fn label(self: ReplKind) []const u8 {
        return switch (self) {
            .r => "R",
            .python => "Python",
            .codex => "Codex",
            .claude_code => "Claude Code",
            .plain => "plain",
        };
    }
};

fn terminalReplExecTool(ctx: *ToolContext, surface_id: []const u8, repl_name: []const u8, code: []const u8, timeout_ms: u32) ![]u8 {
    const repl = ReplKind.parse(repl_name) orelse return std.fmt.allocPrint(ctx.allocator, "Unsupported repl \"{s}\". Use r, python, codex, claude_code, or plain.", .{repl_name});
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const dangerous = isDangerousCommand(code);
    if (ctx.settings.permission != .full or dangerous) {
        var reason_buf: [96]u8 = undefined;
        const reason = if (dangerous)
            DANGEROUS_COMMAND_APPROVAL_REASON
        else
            std.fmt.bufPrint(&reason_buf, "Type input into opened {s} REPL/app terminal", .{repl.label()}) catch "Type input into terminal";
        if (!ctx.requestApproval("terminal_repl_exec", code, reason)) {
            return deniedResult(ctx.allocator, code, "operator rejected REPL terminal input");
        }
    }

    const snapshot = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    const surface = findSurface(snapshot, surface_id) orelse return ctx.allocator.dupe(u8, "No matching terminal surface.");
    if (try ensureWriteContext(ctx, surface)) |message| return message;

    return switch (repl) {
        .r => rSessionEvalTool(ctx, host, surface, code, timeout_ms),
        .python => pythonSessionEvalTool(ctx, host, surface, code, timeout_ms),
        .codex, .claude_code => plainReplInputTool(ctx, host, surface, repl, code, timeout_ms),
        .plain => plainReplInputTool(ctx, host, surface, repl, code, timeout_ms),
    };
}

fn plainReplSubmitKey(repl: ReplKind, surface: ToolSurface) []const u8 {
    if (repl == .codex and surface.agent_state == .running) return "\t";
    if (repl == .codex) return "\n";
    return "\r";
}

pub fn allocPlainReplInput(allocator: std.mem.Allocator, repl: ReplKind, surface: ToolSurface, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ text, plainReplSubmitKey(repl, surface) });
}

pub fn plainReplInputTool(ctx: *const ToolContext, host: ToolHost, surface: ToolSurface, repl: ReplKind, text: []const u8, timeout_ms: u32) ![]u8 {
    const input = try allocPlainReplInput(ctx.allocator, repl, surface, text);
    defer ctx.allocator.free(input);

    if (!host.writeSurface(host.ctx, surface.ptr, input)) {
        return ctx.allocator.dupe(u8, "Failed to write to terminal surface.");
    }

    if (repl == .codex or repl == .claude_code) {
        return waitForAgentAppReplResult(ctx, host, surface, repl, timeout_ms);
    }

    const wait_ms = @min(@max(timeout_ms, 500), 5000);
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(wait_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    const latest = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.ptr) catch return ctx.allocator.dupe(u8, "Input sent; failed to read terminal snapshot.");
    return truncateOwned(ctx.allocator, ctx.settings, latest);
}

fn agentAppStateIsTerminal(state: agent_detector.State) bool {
    return switch (state) {
        .waiting_approval, .needs_input, .halted, .failed, .done => true,
        .none, .running => false,
    };
}

fn replSnapshotLooksBusy(repl: ReplKind, snapshot: []const u8) bool {
    return switch (repl) {
        .codex => std.ascii.indexOfIgnoreCase(snapshot, "working (") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "esc to interrupt") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "waited for background terminal") != null,
        .claude_code => std.ascii.indexOfIgnoreCase(snapshot, "thinking") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "esc to interrupt") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "Update(") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "Edit(") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "MultiEdit(") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "Write(") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "Bash(") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "Read(") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "Grep(") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "Glob(") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "Task(") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "TodoWrite(") != null or
            std.ascii.indexOfIgnoreCase(snapshot, "WebFetch(") != null,
        .r, .python, .plain => false,
    };
}

fn allocAgentAppReplResult(
    allocator: std.mem.Allocator,
    settings: AgentSettings,
    repl: ReplKind,
    app: agent_detector.App,
    state: agent_detector.State,
    confidence: u8,
    note: []const u8,
    snapshot: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(
        allocator,
        "Input sent; {s} {s} (agent={s}:{s}, confidence={d}).\nLatest snapshot:\n",
        .{ repl.label(), note, app.label(), state.label(), confidence },
    );
    try out.appendSlice(allocator, snapshot);
    return truncateOwned(allocator, settings, try out.toOwnedSlice(allocator));
}

fn waitForAgentAppReplResult(ctx: *const ToolContext, host: ToolHost, surface: ToolSurface, repl: ReplKind, timeout_ms: u32) ![]u8 {
    const wait_ms = @max(timeout_ms, 1000);
    const quiet_ms: i64 = 1500;
    const min_wait_ms: i64 = 750;
    const started = std.time.milliTimestamp();
    const deadline = started + @as(i64, @intCast(wait_ms));
    var last_change_ms = started;
    var changed_once = false;
    var last_app = surface.agent_app;
    var last_state = surface.agent_state;
    var last_confidence = surface.agent_confidence;
    var last_snapshot = try ctx.allocator.dupe(u8, surface.snapshot);
    defer ctx.allocator.free(last_snapshot);

    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        const now = std.time.milliTimestamp();
        const live = host.collectSnapshot(host.ctx, ctx.allocator) catch null;
        if (live) |snapshot| {
            defer snapshot.deinit(ctx.allocator);
            if (findSurface(snapshot, surface.id)) |latest| {
                last_app = latest.agent_app;
                last_state = latest.agent_state;
                last_confidence = latest.agent_confidence;
                if (!std.mem.eql(u8, last_snapshot, latest.snapshot)) {
                    const new_snapshot = try ctx.allocator.dupe(u8, latest.snapshot);
                    ctx.allocator.free(last_snapshot);
                    last_snapshot = new_snapshot;
                    last_change_ms = now;
                    changed_once = true;
                }
                if (agentAppStateIsTerminal(latest.agent_state)) {
                    return allocAgentAppReplResult(
                        ctx.allocator,
                        ctx.settings,
                        repl,
                        latest.agent_app,
                        latest.agent_state,
                        latest.agent_confidence,
                        "reported a terminal state",
                        latest.snapshot,
                    );
                }
                const settled = changed_once and now >= started + min_wait_ms and now - last_change_ms >= quiet_ms;
                if (settled and !replSnapshotLooksBusy(repl, latest.snapshot)) {
                    return allocAgentAppReplResult(
                        ctx.allocator,
                        ctx.settings,
                        repl,
                        latest.agent_app,
                        latest.agent_state,
                        latest.agent_confidence,
                        "screen settled without an active busy marker",
                        latest.snapshot,
                    );
                }
            }
        }
        std.Thread.sleep(250 * std.time.ns_per_ms);
    }

    const note = try std.fmt.allocPrint(
        ctx.allocator,
        "is still waiting after {d} ms; treat this as in progress, not a final result",
        .{wait_ms},
    );
    defer ctx.allocator.free(note);
    return allocAgentAppReplResult(
        ctx.allocator,
        ctx.settings,
        repl,
        last_app,
        last_state,
        last_confidence,
        note,
        last_snapshot,
    );
}

fn rSessionEvalTool(ctx: *const ToolContext, host: ToolHost, surface: ToolSurface, code: []const u8, timeout_ms: u32) ![]u8 {
    const nonce = std.time.milliTimestamp();
    const code_literal = try rStringLiteral(ctx.allocator, code);
    defer ctx.allocator.free(code_literal);

    const wrapped = try std.fmt.allocPrint(
        ctx.allocator,
        "cat(\"\\n__WISPTERM_AGENT_START_{d}__\\n\", sep=\"\")\n.wispterm_agent_status <- 0L\n.wispterm_agent_code <- {s}\ntryCatch({{\n  eval(parse(text=.wispterm_agent_code), envir=.GlobalEnv)\n}}, error=function(e) {{\n  .wispterm_agent_status <<- 1L\n  message(\"Error: \", conditionMessage(e))\n}})\ncat(\"\\n__WISPTERM_AGENT_END_{d}__:\", .wispterm_agent_status, \"\\n\", sep=\"\")\nrm(.wispterm_agent_status, .wispterm_agent_code)\r",
        .{ nonce, code_literal, nonce },
    );
    defer ctx.allocator.free(wrapped);

    if (!host.writeSurface(host.ctx, surface.ptr, wrapped)) {
        return ctx.allocator.dupe(u8, "Failed to write to R terminal surface.");
    }

    const start_marker = try std.fmt.allocPrint(ctx.allocator, "__WISPTERM_AGENT_START_{d}__", .{nonce});
    defer ctx.allocator.free(start_marker);
    const end_marker = try std.fmt.allocPrint(ctx.allocator, "__WISPTERM_AGENT_END_{d}__", .{nonce});
    defer ctx.allocator.free(end_marker);
    return waitForSentinelResult(ctx, host, surface, "R", start_marker, end_marker, timeout_ms);
}

fn pythonSessionEvalTool(ctx: *const ToolContext, host: ToolHost, surface: ToolSurface, code: []const u8, timeout_ms: u32) ![]u8 {
    const nonce = std.time.milliTimestamp();
    const code_literal = try pythonStringLiteral(ctx.allocator, code);
    defer ctx.allocator.free(code_literal);

    const wrapper = try std.fmt.allocPrint(
        ctx.allocator,
        "print(\"\\\\n__WISPTERM_AGENT_START_{d}__\")\n__wispterm_agent_status = 0\n__wispterm_agent_code = {s}\ntry:\n    exec(__wispterm_agent_code, globals())\nexcept Exception:\n    __wispterm_agent_status = 1\n    import traceback\n    traceback.print_exc()\nprint(\"\\\\n__WISPTERM_AGENT_END_{d}__:%s\" % __wispterm_agent_status)\ndel __wispterm_agent_status, __wispterm_agent_code",
        .{ nonce, code_literal, nonce },
    );
    defer ctx.allocator.free(wrapper);

    const wrapper_literal = try pythonStringLiteral(ctx.allocator, wrapper);
    defer ctx.allocator.free(wrapper_literal);
    const wrapped = try std.fmt.allocPrint(ctx.allocator, "exec({s})\r", .{wrapper_literal});
    defer ctx.allocator.free(wrapped);

    if (!host.writeSurface(host.ctx, surface.ptr, wrapped)) {
        return ctx.allocator.dupe(u8, "Failed to write to Python terminal surface.");
    }

    const start_marker = try std.fmt.allocPrint(ctx.allocator, "__WISPTERM_AGENT_START_{d}__", .{nonce});
    defer ctx.allocator.free(start_marker);
    const end_marker = try std.fmt.allocPrint(ctx.allocator, "__WISPTERM_AGENT_END_{d}__", .{nonce});
    defer ctx.allocator.free(end_marker);
    return waitForSentinelResult(ctx, host, surface, "Python", start_marker, end_marker, timeout_ms);
}

pub fn rStringLiteral(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return doubleQuotedStringLiteral(allocator, text);
}

pub fn pythonStringLiteral(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return doubleQuotedStringLiteral(allocator, text);
}

fn doubleQuotedStringLiteral(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    for (text) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn unixSessionExecTool(ctx: *ToolContext, kind: UnixSessionKind, surface_id: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const dangerous = isDangerousCommand(command);
    if (ctx.settings.permission != .full or dangerous) {
        var reason_buf: [64]u8 = undefined;
        const reason = if (dangerous)
            DANGEROUS_COMMAND_APPROVAL_REASON
        else
            std.fmt.bufPrint(&reason_buf, "Type command into opened {s} terminal", .{kind.label()}) catch "Type command into terminal";
        if (!ctx.requestApproval(kind.toolName(), command, reason)) {
            return deniedResult(ctx.allocator, command, if (kind == .ssh) "operator rejected SSH PTY command" else "operator rejected WSL PTY command");
        }
    }
    const snapshot = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    const surface = findSurface(snapshot, surface_id) orelse return ctx.allocator.dupe(u8, "No matching terminal surface.");
    if (try ensureWriteContext(ctx, surface)) |message| return message;
    if (!kind.matches(surface)) {
        return std.fmt.allocPrint(ctx.allocator, "Target surface is not an opened {s} session.", .{kind.label()});
    }
    if (try shellExecAgentAppRefusal(ctx.allocator, kind, surface)) |message| return message;
    if (try shellExecInteractiveAgentCommandRefusal(ctx.allocator, kind, command)) |message| return message;

    const nonce = std.time.milliTimestamp();
    // Keep the agent's injected command out of the user's shell history. We
    // enable ignore-space (zsh HIST_IGNORE_SPACE / bash HISTCONTROL=ignorespace)
    // and prefix the whole line with a single leading space. An interactive
    // shell decides whether to record a line at submit time, so the option must
    // be on *before* the line is read: once the first agent command in a session
    // has run, the option stays set and every subsequent space-prefixed line is
    // dropped from history. At most the very first line can leak. The user's own
    // typed commands are unaffected. (fish is not supported here, as it already
    // isn't by the bash-syntax wrapper.)
    const wrapped = try std.fmt.allocPrint(
        ctx.allocator,
        " setopt hist_ignore_space 2>/dev/null; HISTCONTROL=ignorespace; printf '\\n__WISPTERM_AGENT_START_{d}__\\n'; {{ {s}; }} 2>&1; __wispterm_agent_status=$?; printf '\\n__WISPTERM_AGENT_END_{d}__:%s\\n' \"$__wispterm_agent_status\"\r",
        .{ nonce, command, nonce },
    );
    defer ctx.allocator.free(wrapped);

    if (!host.writeSurface(host.ctx, surface.ptr, wrapped)) {
        return std.fmt.allocPrint(ctx.allocator, "Failed to write to {s} terminal surface.", .{kind.label()});
    }

    const start_marker = try std.fmt.allocPrint(ctx.allocator, "__WISPTERM_AGENT_START_{d}__", .{nonce});
    defer ctx.allocator.free(start_marker);
    const end_marker = try std.fmt.allocPrint(ctx.allocator, "__WISPTERM_AGENT_END_{d}__", .{nonce});
    defer ctx.allocator.free(end_marker);
    return waitForSentinelResult(ctx, host, surface, kind.label(), start_marker, end_marker, timeout_ms);
}

fn waitForSentinelResult(
    ctx: *const ToolContext,
    host: ToolHost,
    surface: ToolSurface,
    label: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
    timeout_ms: u32,
) ![]u8 {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(@max(timeout_ms, 1000)));
    var last: ?[]u8 = null;
    defer if (last) |text| ctx.allocator.free(text);

    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        if (last) |old| ctx.allocator.free(old);
        last = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.ptr) catch null;
        if (last) |text| {
            if (std.mem.indexOf(u8, text, end_marker) != null) {
                return extractUnixCommandResult(ctx.allocator, text, start_marker, end_marker);
            }
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    if (last) |text| {
        return std.fmt.allocPrint(ctx.allocator, "Timed out waiting for {s} command sentinel.\nLatest snapshot:\n{s}", .{ label, text });
    }
    return std.fmt.allocPrint(ctx.allocator, "Timed out waiting for {s} command sentinel.", .{label});
}

// ---------------------------------------------------------------------------
// SSH profile tools
// ---------------------------------------------------------------------------

pub fn sshProfileSaveApprovalText(allocator: std.mem.Allocator, args: SshProfileSaveArgs) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "name=\"{s}\" host=\"{s}\" user=\"{s}\" port=\"{s}\" proxy_jump=\"{s}\" password={s}",
        .{
            if (args.name.len > 0) args.name else "<default>",
            args.host,
            args.user,
            if (args.port.len > 0) args.port else "22",
            if (args.proxy_jump.len > 0) args.proxy_jump else "<none>",
            if (args.password.len > 0) "<redacted>" else "<empty>",
        },
    );
}

fn sshProfileSaveTool(ctx: *ToolContext, args: SshProfileSaveArgs) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const approval_text = try sshProfileSaveApprovalText(ctx.allocator, args);
    defer ctx.allocator.free(approval_text);
    if (ctx.settings.permission != .full) {
        if (!ctx.requestApproval("ssh_profile_save", approval_text, "Save SSH server profile")) {
            return deniedResult(ctx.allocator, approval_text, "operator rejected saved SSH profile update");
        }
    }

    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    var saved = host.saveSshProfile(host.ctx, ctx.allocator, args) catch |err| switch (err) {
        error.InvalidProfile => return ctx.allocator.dupe(u8, "Invalid SSH profile. Provide a non-empty safe host and user, and a numeric port."),
        error.ProfileLimit => return ctx.allocator.dupe(u8, "Cannot save SSH profile: profile limit reached."),
        else => return std.fmt.allocPrint(ctx.allocator, "Failed to save SSH profile: {}", .{err}),
    };
    defer saved.deinit(ctx.allocator);

    const out = try std.fmt.allocPrint(
        ctx.allocator,
        "saved profile=\"{s}\" host=\"{s}\" user=\"{s}\" port=\"{s}\" updated_existing={} password_saved={}. Use ssh_profile_connect with profile_name=\"{s}\" to open it.",
        .{
            saved.name,
            saved.host,
            saved.user,
            saved.port,
            saved.updated_existing,
            saved.password_saved,
            saved.name,
        },
    );
    return truncateOwned(ctx.allocator, ctx.settings, out);
}

fn sshProfileConnectTool(ctx: *ToolContext, profile_name: []const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    if (ctx.settings.permission != .full) {
        if (!ctx.requestApproval("ssh_profile_connect", profile_name, "Open saved SSH server in a new tab")) {
            return deniedResult(ctx.allocator, profile_name, "operator rejected saved SSH profile connection");
        }
    }

    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    var surface = host.connectSshProfile(host.ctx, ctx.allocator, profile_name) catch |err| switch (err) {
        error.ProfileNotFound => return std.fmt.allocPrint(ctx.allocator, "No saved SSH profile matched \"{s}\".", .{profile_name}),
        else => return std.fmt.allocPrint(ctx.allocator, "Failed to connect saved SSH profile \"{s}\": {}", .{ profile_name, err }),
    };
    var surface_owned = true;
    errdefer if (surface_owned) surface.deinit(ctx.allocator);

    const out = try std.fmt.allocPrint(
        ctx.allocator,
        "connected profile=\"{s}\" surface_id={s} tab={d} focused={} kind={s} title=\"{s}\" cwd=\"{s}\"",
        .{
            profile_name,
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            toolSurfaceKind(surface),
            surface.title,
            surface.cwd,
        },
    );
    errdefer ctx.allocator.free(out);

    try rememberConnectedSurface(ctx, surface);
    surface_owned = false;
    return truncateOwned(ctx.allocator, ctx.settings, out);
}

// ---------------------------------------------------------------------------
// Tab management tools
// ---------------------------------------------------------------------------

fn tabNewTool(ctx: *ToolContext, kind: []const u8, command: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const trimmed_kind = std.mem.trim(u8, kind, " \t\r\n");
    const command_for_approval = command orelse trimmed_kind;
    if (ctx.settings.permission != .full) {
        if (!ctx.requestApproval("tab_new", command_for_approval, "Open a new local terminal tab")) {
            return deniedResult(ctx.allocator, command_for_approval, "operator rejected new tab creation");
        }
    }

    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    var surface = host.spawnTab(host.ctx, ctx.allocator, trimmed_kind, command) catch |err| switch (err) {
        error.CommandRequired => return ctx.allocator.dupe(u8, "tab_new kind=command requires a non-empty command."),
        error.InvalidTabKind => return std.fmt.allocPrint(ctx.allocator, "Unsupported tab kind \"{s}\". Use {s}.", .{ trimmed_kind, platform_pty_command.tabKindUsage() }),
        else => return std.fmt.allocPrint(ctx.allocator, "Failed to create new tab: {}", .{err}),
    };
    var surface_owned = true;
    errdefer if (surface_owned) surface.deinit(ctx.allocator);

    const out = try std.fmt.allocPrint(
        ctx.allocator,
        "created tab kind={s} surface_id={s} tab={d} focused={} surface_kind={s} title=\"{s}\" cwd=\"{s}\"",
        .{
            if (trimmed_kind.len > 0) trimmed_kind else "default",
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            toolSurfaceKind(surface),
            surface.title,
            surface.cwd,
        },
    );
    errdefer ctx.allocator.free(out);

    try rememberConnectedSurface(ctx, surface);
    surface_owned = false;
    return truncateOwned(ctx.allocator, ctx.settings, out);
}

fn tabCloseTool(ctx: *ToolContext, tab_index: ?usize, surface_id: ?[]const u8, title: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    var selector_buf: [256]u8 = undefined;
    const selector = if (surface_id) |id|
        std.fmt.bufPrint(&selector_buf, "surface_id={s}", .{id}) catch "surface_id"
    else if (title) |text|
        std.fmt.bufPrint(&selector_buf, "title={s}", .{text}) catch "title"
    else if (tab_index) |idx|
        std.fmt.bufPrint(&selector_buf, "tab={d}", .{idx + 1}) catch "tab"
    else
        "active terminal tab";

    if (ctx.settings.permission != .full) {
        if (!ctx.requestApproval("tab_close", selector, "Close a terminal tab")) {
            return deniedResult(ctx.allocator, selector, "operator rejected tab close");
        }
    }

    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    var closed = host.closeTab(host.ctx, ctx.allocator, tab_index, surface_id, title) catch |err| switch (err) {
        error.TabNotFound => return ctx.allocator.dupe(u8, "No matching terminal tab was found."),
        error.CannotCloseAiChatTab => return ctx.allocator.dupe(u8, "Refusing to close an AI Chat tab from the agent."),
        error.LastTab => return ctx.allocator.dupe(u8, "Refusing to close the last remaining tab."),
        else => return std.fmt.allocPrint(ctx.allocator, "Failed to close tab: {}", .{err}),
    };
    defer closed.deinit(ctx.allocator);

    try rememberClosedTab(ctx, closed);

    const out = try std.fmt.allocPrint(
        ctx.allocator,
        "closed tab={d} title=\"{s}\" active_tab={d}",
        .{ closed.tab_index + 1, closed.title, closed.active_tab + 1 },
    );
    return truncateOwned(ctx.allocator, ctx.settings, out);
}

// ---------------------------------------------------------------------------
// Surface lookup and write-context helpers
// ---------------------------------------------------------------------------

pub fn findSurface(snapshot: ToolSnapshot, surface_id: []const u8) ?ToolSurface {
    for (snapshot.surfaces) |surface| {
        if (std.mem.eql(u8, surface.id, surface_id)) return surface;
    }
    return null;
}

/// Build the per-message copilot context block from a full surface snapshot:
/// the cwd plus the last COPILOT_CONTEXT_LINES lines of output. Owned result.
pub fn buildCopilotContext(allocator: std.mem.Allocator, cwd: []const u8, snapshot: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, snapshot, "\n");
    var start: usize = trimmed.len;
    var newlines: usize = 0;
    while (start > 0) {
        const c = trimmed[start - 1];
        if (c == '\n') {
            newlines += 1;
            if (newlines > COPILOT_CONTEXT_LINES) break;
        }
        start -= 1;
    }
    const tail = trimmed[start..];
    return std.fmt.allocPrint(
        allocator,
        "[wispterm current terminal]\ncwd: {s}\nrecent output:\n{s}",
        .{ cwd, tail },
    );
}

fn selectedWriteContext(ctx: *const ToolContext) ?[]const u8 {
    return ctx.writeContextSurfaceId();
}

pub fn setWriteContext(ctx: *ToolContext, surface_id: []const u8) void {
    const len = @min(surface_id.len, ctx.write_context_surface_id.len);
    @memcpy(ctx.write_context_surface_id[0..len], surface_id[0..len]);
    ctx.write_context_surface_id_len = len;
}

/// Copilot fallback: when an exec tool omits surface_id, use the context's
/// pre-seeded write-context (the bound/focused terminal). Non-copilot requests
/// keep the original "Missing surface_id" behavior.
fn defaultExecSurfaceId(ctx: *const ToolContext) ?[]const u8 {
    if (!ctx.copilot) return null;
    return ctx.writeContextSurfaceId();
}

pub fn ensureWriteContext(ctx: *ToolContext, surface: ToolSurface) !?[]u8 {
    const context = selectedWriteContext(ctx) orelse {
        const message = try std.fmt.allocPrint(
            ctx.allocator,
            "Refusing to write to surface_id={s} tab={d} title=\"{s}\" because no agent terminal context is selected. Call terminal_select with the intended surface_id before writing.",
            .{ surface.id, surface.tab_index + 1, surface.title },
        );
        return message;
    };
    if (std.mem.eql(u8, context, surface.id)) return null;

    const message = try std.fmt.allocPrint(
        ctx.allocator,
        "Refusing to write to surface_id={s} tab={d} title=\"{s}\" because selected agent terminal context is surface_id={s}. Call terminal_select with the intended surface_id before writing to another panel.",
        .{
            surface.id,
            surface.tab_index + 1,
            surface.title,
            context,
        },
    );
    return message;
}

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------

fn extractUnixCommandResult(allocator: std.mem.Allocator, text: []const u8, start_marker: []const u8, end_marker: []const u8) ![]u8 {
    const start = std.mem.indexOf(u8, text, start_marker) orelse return allocator.dupe(u8, text);
    const body_start = start + start_marker.len;
    const end = std.mem.indexOfPos(u8, text, body_start, end_marker) orelse return allocator.dupe(u8, text[body_start..]);
    return allocator.dupe(u8, std.mem.trim(u8, text[body_start..end], " \t\r\n"));
}

fn deniedResult(allocator: std.mem.Allocator, command: []const u8, reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "DENIED by operator (reason: {s})\ncommand: {s}", .{ reason, command });
}

fn truncateOwned(allocator: std.mem.Allocator, settings: AgentSettings, text: []u8) ![]u8 {
    const limit = settings.output_limit;
    if (text.len <= limit) return text;
    const truncated = try std.fmt.allocPrint(allocator, "{s}\n...[truncated to {d} bytes]", .{ text[0..limit], limit });
    allocator.free(text);
    return truncated;
}

pub const DANGEROUS_COMMAND_APPROVAL_REASON = "Destructive command (delete/rename/format) - confirm to run";

/// Whether a command is destructive enough to always require operator approval,
/// even under full-permission mode: deletes, renames/moves, disk formatting,
/// and a few other irreversible operations.
pub fn isDangerousCommand(command: []const u8) bool {
    // Distinctive multi-token / punctuated patterns: a plain substring scan is
    // safe here (these cannot collide with ordinary words).
    const patterns = [_][]const u8{
        "Remove-Item",
        "Format-Volume",
        "Stop-Computer",
        "Restart-Computer",
        "git push --force",
        "git push -f",
        "git reset --hard",
        "git clean -f",
        "git clean -d",
        ":(){",
        "dd if=",
        "of=/dev/",
        "> /dev/sd",
        "mkswap",
    };
    for (patterns) |needle| {
        if (std.ascii.indexOfIgnoreCase(command, needle) != null) return true;
    }
    // Bare destructive verbs, matched as whole words so "rm file", "mv a b"
    // (rename) and "format c:" trigger while "confirm", "perform", "arm" and
    // option flags like "--format"/"--force" do not (we treat '-' as part of a
    // word). Safety-biased: a false positive only adds an extra confirm prompt.
    const verbs = [_][]const u8{
        // delete
        "rm",       "rmdir",  "unlink", "shred",  "trash", "del", "rd",
        // rename / move
        "mv",       "move",   "rename", "ren",
        // format / wipe disk
        "format",   "mkfs",   "fdisk",  "diskpart",
        // power
        "shutdown", "reboot", "halt",   "poweroff",
    };
    for (verbs) |verb| {
        if (containsWord(command, verb)) return true;
    }
    return false;
}

/// True if `word` appears in `haystack` as a whole token (case-insensitive):
/// not flanked by other word characters. '-' counts as a word character so
/// option flags such as "--format" are not mistaken for the bare "format" verb.
pub fn containsWord(haystack: []const u8, word: []const u8) bool {
    if (word.len == 0 or word.len > haystack.len) return false;
    const last = haystack.len - word.len;
    var pos: usize = 0;
    while (pos <= last) : (pos += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[pos .. pos + word.len], word)) continue;
        const before_ok = pos == 0 or !isWordChar(haystack[pos - 1]);
        const after = pos + word.len;
        const after_ok = after == haystack.len or !isWordChar(haystack[after]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

// ---------------------------------------------------------------------------
// TDD isolation test (proves module compiles without Session/ChatRequest)
// ---------------------------------------------------------------------------

fn fakeApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}
fn fakeCancelled(_: *anyopaque) bool {
    return false;
}

test "isDangerousCommand flags destructive verbs without a Session" {
    var dummy: u8 = 0;
    var ctx = types.ToolContext{
        .allocator = std.testing.allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    _ = &ctx;
    try std.testing.expect(isDangerousCommand("rm -rf /tmp/x"));
    try std.testing.expect(!isDangerousCommand("ls -la"));
}

// ---------------------------------------------------------------------------
// Moved tool-layer tests
// ---------------------------------------------------------------------------

test "buildCopilotContext keeps cwd and the last N lines" {
    const snap = "l1\nl2\nl3\nl4\nl5\n";
    const out = try buildCopilotContext(std.testing.allocator, "/home/u", snap);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "cwd: /home/u") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "l5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "l1") != null);
}

test "buildCopilotContext truncates to the last COPILOT_CONTEXT_LINES" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 100) : (i += 1) try buf.print(std.testing.allocator, "line{d}\n", .{i});
    const out = try buildCopilotContext(std.testing.allocator, "/x", buf.items);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "line99") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line0\n") == null);
}

test "ai chat tools prefer request-local terminal snapshot" {
    const allocator = std.testing.allocator;
    var surfaces = try allocator.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "surface-1"),
        .title = try allocator.dupe(u8, "Local Shell"),
        .cwd = try allocator.dupe(u8, "/home/user"),
        .snapshot = try allocator.dupe(u8, "$ "),
        .tab_index = 1,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    const cached_snapshot = ToolSnapshot{
        .surfaces = surfaces,
        .active_tab = 1,
    };
    defer cached_snapshot.deinit(allocator);

    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = cached_snapshot,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const snapshot = try collectToolSnapshot(&ctx);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.active_tab);
    try std.testing.expectEqual(@as(usize, 1), snapshot.surfaces.len);
    try std.testing.expectEqualStrings("surface-1", snapshot.surfaces[0].id);
    try std.testing.expect(snapshot.surfaces[0].id.ptr != cached_snapshot.surfaces[0].id.ptr);
}

test "ai chat write context requires explicit selection and can switch surfaces" {
    const allocator = std.testing.allocator;
    var surfaces = try allocator.alloc(ToolSurface, 2);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "surface-a"),
        .title = try allocator.dupe(u8, "panel1"),
        .cwd = try allocator.dupe(u8, ""),
        .snapshot = try allocator.dupe(u8, ""),
        .tab_index = 0,
        .focused = false,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    surfaces[1] = .{
        .id = try allocator.dupe(u8, "surface-b"),
        .title = try allocator.dupe(u8, "panel2"),
        .cwd = try allocator.dupe(u8, ""),
        .snapshot = try allocator.dupe(u8, ""),
        .tab_index = 0,
        .focused = false,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(2),
    };
    const snapshot = ToolSnapshot{
        .surfaces = surfaces,
        .active_tab = 0,
    };
    defer snapshot.deinit(allocator);

    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const missing = (try ensureWriteContext(&ctx, snapshot.surfaces[1])).?;
    defer allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "no agent terminal context is selected") != null);

    setWriteContext(&ctx, snapshot.surfaces[1].id);
    try std.testing.expectEqualStrings("surface-b", ctx.write_context_surface_id[0..ctx.write_context_surface_id_len]);
    try std.testing.expect(try ensureWriteContext(&ctx, snapshot.surfaces[1]) == null);

    const message = (try ensureWriteContext(&ctx, snapshot.surfaces[0])).?;
    defer allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "selected agent terminal context is surface_id=surface-b") != null);

    setWriteContext(&ctx, snapshot.surfaces[0].id);
    try std.testing.expectEqualStrings("surface-a", ctx.write_context_surface_id[0..ctx.write_context_surface_id_len]);
    try std.testing.expect(try ensureWriteContext(&ctx, snapshot.surfaces[0]) == null);
    const switched = (try ensureWriteContext(&ctx, snapshot.surfaces[1])).?;
    defer allocator.free(switched);
    try std.testing.expect(std.mem.indexOf(u8, switched, "selected agent terminal context is surface_id=surface-a") != null);
}

test "terminal_list shows one-based tab numbers matching the UI" {
    const allocator = std.testing.allocator;
    var surfaces = try allocator.alloc(ToolSurface, 2);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "surface-a"),
        .title = try allocator.dupe(u8, "panel1"),
        .cwd = try allocator.dupe(u8, "/tmp"),
        .snapshot = try allocator.dupe(u8, ""),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    surfaces[1] = .{
        .id = try allocator.dupe(u8, "surface-b"),
        .title = try allocator.dupe(u8, "panel2"),
        .cwd = try allocator.dupe(u8, "/tmp"),
        .snapshot = try allocator.dupe(u8, ""),
        .tab_index = 1,
        .focused = false,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(2),
    };
    const snapshot = ToolSnapshot{ .surfaces = surfaces, .active_tab = 0 };
    defer snapshot.deinit(allocator);

    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = snapshot,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const out = try terminalListTool(&ctx);
    defer allocator.free(out);

    // The first tab is shown as 1 and the second as 2, even though they are
    // internally zero-based (tab_index 0 and 1) — matching the UI tab numbers.
    try std.testing.expect(std.mem.indexOf(u8, out, "active_tab=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "id=surface-a tab=1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "id=surface-b tab=2 ") != null);
    // The zero-based index must never leak into the user-facing listing.
    try std.testing.expect(std.mem.indexOf(u8, out, "tab=0") == null);
}

test "shell exec refuses interactive Codex launcher commands" {
    const allocator = std.testing.allocator;
    const refused = (try shellExecInteractiveAgentCommandRefusal(allocator, .wsl, "codex --model o4-mini")).?;
    defer allocator.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "Refusing to start interactive Codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "terminal_repl_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "repl=plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "repl=codex") != null);

    try std.testing.expect(try shellExecInteractiveAgentCommandRefusal(allocator, .wsl, "which codex") == null);
    try std.testing.expect(try shellExecInteractiveAgentCommandRefusal(allocator, .wsl, "codex --version") == null);
}

test "ai chat R string literal escapes code for REPL eval" {
    const allocator = std.testing.allocator;
    const literal = try rStringLiteral(allocator, "print(\"hello\")\npath <- \"C:\\\\tmp\"");
    defer allocator.free(literal);

    try std.testing.expectEqualStrings("\"print(\\\"hello\\\")\\npath <- \\\"C:\\\\\\\\tmp\\\"\"", literal);
}

test "ai chat REPL kind parses Python Codex and Claude Code aliases" {
    try std.testing.expectEqual(ReplKind.python, ReplKind.parse("python").?);
    try std.testing.expectEqual(ReplKind.python, ReplKind.parse("py").?);
    try std.testing.expectEqual(ReplKind.codex, ReplKind.parse("codex").?);
    try std.testing.expectEqual(ReplKind.claude_code, ReplKind.parse("claude").?);
    try std.testing.expectEqual(ReplKind.claude_code, ReplKind.parse("claude-code").?);
}

test "ai chat Codex running REPL input queues with tab instead of enter" {
    const allocator = std.testing.allocator;
    const surface = ToolSurface{
        .id = @constCast("surface-1"),
        .title = @constCast("codex"),
        .cwd = @constCast(""),
        .snapshot = @constCast("Working (5m 16s - esc to interrupt)\ntab to queue message"),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .codex,
        .agent_state = .running,
        .agent_confidence = 82,
        .ptr = @ptrFromInt(1),
    };

    const input = try allocPlainReplInput(allocator, .codex, surface, "/status");
    defer allocator.free(input);
    try std.testing.expectEqualStrings("/status\t", input);

    var idle_surface = surface;
    idle_surface.agent_state = .done;
    const idle_input = try allocPlainReplInput(allocator, .codex, idle_surface, "/status");
    defer allocator.free(idle_input);
    try std.testing.expectEqualStrings("/status\n", idle_input);
}

test "ai chat Python string literal escapes code for REPL eval" {
    const allocator = std.testing.allocator;
    const literal = try pythonStringLiteral(allocator, "print(\"hello\")\npath = \"C:\\\\tmp\"");
    defer allocator.free(literal);

    try std.testing.expectEqualStrings("\"print(\\\"hello\\\")\\npath = \\\"C:\\\\\\\\tmp\\\"\"", literal);
}

test "ai chat detects dangerous shell commands" {
    // delete
    try std.testing.expect(isDangerousCommand("rm -rf /tmp/demo"));
    try std.testing.expect(isDangerousCommand("rm report.csv"));
    try std.testing.expect(isDangerousCommand("find . -name '*.tmp' -exec rm {} \\;"));
    try std.testing.expect(isDangerousCommand("rmdir build"));
    try std.testing.expect(isDangerousCommand("del C:\\temp\\old.log"));
    // rename / move
    try std.testing.expect(isDangerousCommand("mv old.txt new.txt"));
    try std.testing.expect(isDangerousCommand("rename a.txt b.txt"));
    // format / disk
    try std.testing.expect(isDangerousCommand("format C:"));
    try std.testing.expect(isDangerousCommand("mkfs.ext4 /dev/sdb1"));
    try std.testing.expect(isDangerousCommand("dd if=/dev/zero of=/dev/sda"));
    // power + git
    try std.testing.expect(isDangerousCommand("git push --force origin main"));
    try std.testing.expect(isDangerousCommand("git reset --hard HEAD~3"));
    try std.testing.expect(isDangerousCommand("shutdown -h now"));
    // must NOT false-positive on look-alikes
    try std.testing.expect(!isDangerousCommand("Get-ComputerInfo | Select-Object OsName"));
    try std.testing.expect(!isDangerousCommand("ls -la"));
    try std.testing.expect(!isDangerousCommand("git commit -m 'confirm the fix'"));
    try std.testing.expect(!isDangerousCommand("git log --format=oneline"));
    try std.testing.expect(!isDangerousCommand("echo perform a dry run"));
}

test "ai chat ssh profile save approval text redacts password" {
    const allocator = std.testing.allocator;
    const args = SshProfileSaveArgs{
        .name = "lab",
        .host = "192.0.2.10",
        .user = "alice",
        .password = "super-secret",
        .port = "2222",
        .proxy_jump = "admin@bastion.example.com:22",
    };
    const text = try sshProfileSaveApprovalText(allocator, args);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "lab") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "192.0.2.10") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2222") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "admin@bastion.example.com:22") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "super-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<redacted>") != null);
}

test "ai chat skill_info loads from explicit root paths" {
    const allocator = std.testing.allocator;
    const root = ".zig-cache/skill-root-load-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    try std.fs.cwd().makePath(root ++ "/bin/skills/web");
    try std.fs.cwd().writeFile(.{
        .sub_path = root ++ "/bin/skills/web/SKILL.md",
        .data = "---\nname: web\ndescription: Browse pages.\n---\n# Web Skill\n",
    });

    const roots = [_][]const u8{
        root ++ "/cwd/skills",
        root ++ "/bin/skills",
    };
    const output = try skillInfoToolFromRoots(allocator, "web", roots[0..]);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "# Skill: web") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "# Web Skill") != null);
}

test "wispterm_docs tool lists topics when no topic is given" {
    const a = std.testing.allocator;
    const text = try wisptermDocsTool(a, null);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "faq") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "configuration") != null);
}

test "wispterm_docs tool returns content for a known topic" {
    const a = std.testing.allocator;
    const text = try wisptermDocsTool(a, "faq");
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "FAQ") != null);
}

test "wispterm_docs tool reports unknown topic with the topic list" {
    const a = std.testing.allocator;
    const text = try wisptermDocsTool(a, "does-not-exist");
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Unknown topic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "faq") != null);
}

const WeixinAttachmentCapture = struct {
    called: bool = false,
    kind: weixin_types.AttachmentKind = .file,
    path: []const u8 = "",
    display_name: []const u8 = "",
    to_user_id: []const u8 = "",
    context_token: []const u8 = "",
    path_buf: [512]u8 = undefined,
    display_name_buf: [256]u8 = undefined,
    to_user_id_buf: [256]u8 = undefined,
    context_token_buf: [256]u8 = undefined,

    fn copyField(buf: []u8, value: []const u8) []const u8 {
        const n = @min(buf.len, value.len);
        @memcpy(buf[0..n], value[0..n]);
        return buf[0..n];
    }

    fn send(
        ctx: *anyopaque,
        kind: weixin_types.AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) anyerror!void {
        const self: *WeixinAttachmentCapture = @ptrCast(@alignCast(ctx));
        self.called = true;
        self.kind = kind;
        self.path = copyField(&self.path_buf, path);
        self.display_name = copyField(&self.display_name_buf, display_name);
        self.to_user_id = copyField(&self.to_user_id_buf, to_user_id);
        self.context_token = copyField(&self.context_token_buf, context_token);
    }
};

fn testWeixinSender(capture: *WeixinAttachmentCapture) weixin_types.AttachmentSender {
    return .{ .ctx = capture, .send_attachment = WeixinAttachmentCapture.send };
}

test "weixin_send_attachment without reply context returns a clear tool result" {
    const allocator = std.testing.allocator;
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
        .weixin_reply_context = null,
    };

    const call = ToolCall{
        .id = @constCast("call_1"),
        .name = @constCast("weixin_send_attachment"),
        .arguments = @constCast("{\"kind\":\"image\",\"path\":\"C:\\\\tmp\\\\plot.png\"}"),
    };

    const result = try executeToolCall(&ctx, call);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("No active Weixin reply context; cannot send attachment.", result);
}

test "weixin_send_attachment calls the active Weixin sender" {
    const allocator = std.testing.allocator;
    var capture = WeixinAttachmentCapture{};
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
        .weixin_reply_context = try types.WeixinReplyContext.init(allocator, .{
            .sender = testWeixinSender(&capture),
            .to_user_id = "wx-user",
            .context_token = "ctx-1",
        }),
    };
    defer if (ctx.weixin_reply_context) |*wx| wx.deinit(allocator);

    const call = ToolCall{
        .id = @constCast("call_1"),
        .name = @constCast("weixin_send_attachment"),
        .arguments = @constCast("{\"kind\":\"file\",\"path\":\"C:\\\\tmp\\\\report.pdf\",\"display_name\":\"report.pdf\"}"),
    };

    const result = try executeToolCall(&ctx, call);
    defer allocator.free(result);

    try std.testing.expect(capture.called);
    try std.testing.expectEqual(weixin_types.AttachmentKind.file, capture.kind);
    try std.testing.expectEqualStrings("C:\\tmp\\report.pdf", capture.path);
    try std.testing.expectEqualStrings("report.pdf", capture.display_name);
    try std.testing.expectEqualStrings("wx-user", capture.to_user_id);
    try std.testing.expectEqualStrings("ctx-1", capture.context_token);
    try std.testing.expectEqualStrings("Sent file to Weixin: report.pdf", result);
}

const ReplWaitTestHost = struct {
    const Ctx = struct {
        collect_calls: usize = 0,
        write_calls: usize = 0,
        done_after: usize = 2,
        last_write: [256]u8 = undefined,
        last_write_len: usize = 0,
    };

    fn collectSnapshot(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!ToolSnapshot {
        const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
        ctx.collect_calls += 1;
        const done = ctx.collect_calls >= ctx.done_after;
        var surfaces = try allocator.alloc(ToolSurface, 1);
        surfaces[0] = .{
            .id = try allocator.dupe(u8, "surface-claude"),
            .title = try allocator.dupe(u8, "Claude Code"),
            .cwd = try allocator.dupe(u8, "/home/xzg"),
            .snapshot = try allocator.dupe(u8, if (done) "Claude Code\nFINISHED" else "Claude Code\nthinking"),
            .tab_index = 0,
            .focused = true,
            .is_ssh = false,
            .is_wsl = true,
            .agent_app = .claude_code,
            .agent_state = if (done) .done else .running,
            .agent_confidence = 82,
            .ptr = @ptrCast(ctx),
        };
        return .{ .surfaces = surfaces, .active_tab = 0 };
    }

    fn surfaceSnapshot(_: *anyopaque, allocator: std.mem.Allocator, _: *anyopaque) anyerror![]u8 {
        return allocator.dupe(u8, "fallback snapshot");
    }

    fn writeSurface(ctx_ptr: *anyopaque, _: *anyopaque, data: []const u8) bool {
        const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
        const len = @min(data.len, ctx.last_write.len);
        @memcpy(ctx.last_write[0..len], data[0..len]);
        ctx.last_write_len = len;
        ctx.write_calls += 1;
        return true;
    }

    fn unsupportedSpawn(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8) anyerror!ToolSurface {
        return error.Unsupported;
    }

    fn unsupportedClose(_: *anyopaque, _: std.mem.Allocator, _: ?usize, _: ?[]const u8, _: ?[]const u8) anyerror!ToolClosedTab {
        return error.Unsupported;
    }

    fn unsupportedSaveSsh(_: *anyopaque, _: std.mem.Allocator, _: SshProfileSaveArgs) anyerror!SavedSshProfile {
        return error.Unsupported;
    }

    fn unsupportedConnectSsh(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!ToolSurface {
        return error.Unsupported;
    }

    fn host(ctx: *Ctx) ToolHost {
        return .{
            .ctx = @ptrCast(ctx),
            .collectSnapshot = collectSnapshot,
            .surfaceSnapshot = surfaceSnapshot,
            .writeSurface = writeSurface,
            .spawnTab = unsupportedSpawn,
            .closeTab = unsupportedClose,
            .saveSshProfile = unsupportedSaveSsh,
            .connectSshProfile = unsupportedConnectSsh,
        };
    }
};

test "Claude Code REPL input waits for app state before returning" {
    const allocator = std.testing.allocator;
    var host_ctx = ReplWaitTestHost.Ctx{ .done_after = 2 };
    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = ReplWaitTestHost.host(&host_ctx),
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const surface = ToolSurface{
        .id = @constCast("surface-claude"),
        .title = @constCast("Claude Code"),
        .cwd = @constCast("/home/xzg"),
        .snapshot = @constCast("Claude Code\n> "),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = true,
        .agent_app = .claude_code,
        .agent_state = .none,
        .agent_confidence = 45,
        .ptr = @ptrCast(&host_ctx),
    };

    const result = try plainReplInputTool(&ctx, ReplWaitTestHost.host(&host_ctx), surface, .claude_code, "analyze system", 2000);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), host_ctx.write_calls);
    try std.testing.expect(host_ctx.collect_calls >= 2);
    try std.testing.expectEqualStrings("analyze system\r", host_ctx.last_write[0..host_ctx.last_write_len]);
    try std.testing.expect(std.mem.indexOf(u8, result, "reported a terminal state") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "FINISHED") != null);
}
