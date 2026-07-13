//! Agent terminal execution and REPL tool adapters.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../assistant/conversation/types.zig");
const agent_detector = @import("../terminal_agents/detector.zig");
const agent_prompt_answer = @import("../terminal_agents/prompt_answer.zig");
const ai_agent_access = @import("../agent/access.zig");
const terminal_lease = @import("../agent/terminal_lease.zig");
const platform_process = @import("../platform/process.zig");
const terminal_tools = @import("terminal.zig");
const tool_access = @import("access.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;
const ToolSurface = types.ToolSurface;
const ToolSnapshot = types.ToolSnapshot;
const ToolHost = types.ToolHost;
const ToolClosedTab = types.ToolClosedTab;
const SshProfileSaveArgs = types.SshProfileSaveArgs;
const SavedSshProfile = types.SavedSshProfile;
const AgentSettings = types.AgentSettings;

// ---------------------------------------------------------------------------
// Local command exec tool
// ---------------------------------------------------------------------------

/// Combine the destructive-command check with the private file-access guard.
/// `force` => guarded auto mode must prompt; `skip` => ask mode may run without
/// a prompt.
fn accessGate(ctx: *const ToolContext, command: []const u8, cwd: ?[]const u8) tool_access.Gate {
    const dangerous = isDangerousCommand(command);
    const result = if (ctx.settings.access_rules) |rules|
        ai_agent_access.evaluate(ctx.allocator, rules, command, cwd)
    else
        ai_agent_access.EvalResult{};
    const blacklisted = result.decision == .blacklisted;
    const home = if (ctx.settings.access_rules) |rules| rules.home else "";
    const confined = blk: {
        const wd = ctx.settings.working_dir orelse break :blk false;
        const ec = cwd orelse break :blk false;
        break :blk ai_agent_access.workdirConfined(ctx.allocator, command, wd, ec, home);
    };
    return .{
        .dangerous = dangerous,
        .blacklisted = blacklisted,
        .force = dangerous or blacklisted,
        .skip = (result.decision == .whitelisted_safe or confined) and !dangerous and !blacklisted,
        .matched = result.matched,
    };
}

pub fn localCommandExec(ctx: *const ToolContext, command: []const u8, cwd: ?[]const u8, timeout_ms: u32) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const effective_cwd = cwd orelse ctx.settings.working_dir;
    const gate = accessGate(ctx, command, effective_cwd);
    if (tool_access.approvalRequired(ctx.settings.permission, gate)) {
        const bl_reason = if (gate.blacklisted) tool_access.allocBlacklistReason(ctx.allocator, gate.matched) else null;
        defer if (bl_reason) |r| ctx.allocator.free(r);
        const reason = bl_reason orelse if (gate.dangerous) DANGEROUS_COMMAND_APPROVAL_REASON else platform_process.localCommandApprovalLabel();
        if (!ctx.requestApproval(platform_process.localCommandToolName(), command, reason)) {
            return tool_output.deniedResult(ctx.allocator, command, platform_process.localCommandDeniedReason());
        }
    }
    const result = runShellCommand(ctx.allocator, command, effective_cwd, ctx.settings.output_limit, timeout_ms, ctx) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "{s} failed: {}", .{ platform_process.localCommandFailureLabel(), err });
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    if (result.timed_out) try out.appendSlice(ctx.allocator, "timed_out=true\n");
    try out.print(ctx.allocator, "exit_code={d}\nstdout:\n{s}\nstderr:\n{s}", .{ result.exit_code, result.stdout, result.stderr });
    return tool_output.truncateOwned(ctx.allocator, ctx.settings, try out.toOwnedSlice(ctx.allocator));
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
        // In-app sessions never appear on a PTY surface; arm exists for exhaustiveness.
        .assistant => "Copilot",
    };
}

fn agentAppReplName(app: agent_detector.App) []const u8 {
    return switch (app) {
        .none => "plain",
        .codex => "codex",
        .claude_code => "claude_code",
        .assistant => "assistant",
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

/// Detect a *bare* interactive REPL launcher (the word alone, e.g. `python`,
/// `R`, `node`). The shell-exec sentinel wrapper waits for the command to exit,
/// which never happens for an interactive REPL, so the gate refuses it. Returns
/// the launcher word, or null if the command runs-and-exits (`python app.py`,
/// `python --version`, `pip ...`) or is not a REPL.
fn commandLaunchesBareRepl(command: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return null;
    // First token, stopping at whitespace or a shell separator.
    var end: usize = 0;
    while (end < trimmed.len and !std.ascii.isWhitespace(trimmed[end]) and
        trimmed[end] != ';' and trimmed[end] != '&' and trimmed[end] != '|') : (end += 1)
    {}
    var word = std.mem.trim(u8, trimmed[0..end], "\"'");
    if (std.mem.lastIndexOfAny(u8, word, "/\\")) |slash| word = word[slash + 1 ..];
    // Anything after the launcher word means it runs and exits (a script, -c,
    // -m, --version, …), which is fine through shell exec — do not refuse.
    if (std.mem.trim(u8, trimmed[end..], " \t\r\n").len != 0) return null;
    const repls = [_][]const u8{ "python", "python3", "ipython", "R", "node", "irb" };
    for (repls) |r| {
        if (std.mem.eql(u8, word, r)) return r;
    }
    return null;
}

/// REPL name to pass to terminal_repl_exec for a detected launcher word.
fn evalReplForLauncher(launcher: []const u8) []const u8 {
    if (std.mem.eql(u8, launcher, "R")) return "r";
    if (std.mem.eql(u8, launcher, "python") or std.mem.eql(u8, launcher, "python3") or std.mem.eql(u8, launcher, "ipython")) return "python";
    return "plain";
}

fn shellExecBareReplRefusal(allocator: std.mem.Allocator, kind: UnixSessionKind, command: []const u8) !?[]u8 {
    const launcher = commandLaunchesBareRepl(command) orelse return null;
    return try std.fmt.allocPrint(
        allocator,
        "Refusing to start interactive {s} via {s}: the shell-exec wrapper waits for the command to exit, which never happens for a REPL (it hangs and floods the screen). Use terminal_repl_exec with repl=plain code=\"{s}\" to launch it, then terminal_repl_exec with repl={s} to run code.",
        .{ launcher, kind.toolName(), launcher, evalReplForLauncher(launcher) },
    );
}

pub fn sshSessionExec(ctx: *ToolContext, surface_id: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
    return unixSessionExecTool(ctx, .ssh, surface_id, command, timeout_ms);
}

pub fn wslSessionExec(ctx: *ToolContext, surface_id: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
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

/// If `code` (trimmed) is exactly one recognized control-key token, return the
/// raw byte to send. Whole-string match only, so ordinary text that merely
/// contains a token is sent verbatim.
fn controlKeyByte(code: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, code, " \t\r\n");
    const Pair = struct { token: []const u8, byte: u8 };
    const pairs = [_]Pair{
        .{ .token = "<ctrl-c>", .byte = 0x03 },
        .{ .token = "<ctrl-d>", .byte = 0x04 },
        .{ .token = "<ctrl-u>", .byte = 0x15 },
        .{ .token = "<esc>", .byte = 0x1b },
        .{ .token = "<enter>", .byte = 0x0d },
        .{ .token = "<cr>", .byte = 0x0d },
    };
    for (pairs) |p| {
        if (std.ascii.eqlIgnoreCase(trimmed, p.token)) return p.byte;
    }
    return null;
}

/// Send a single raw control byte (no submit key appended), wait briefly for the
/// terminal to react, and return a fresh snapshot so the model sees the
/// recovered state.
fn sendControlKey(ctx: *const ToolContext, host: ToolHost, surface: ToolSurface, label: []const u8, byte: u8) ![]u8 {
    const bytes = [_]u8{byte};
    if (!host.writeSurface(host.ctx, surface.id, surface.ptr, &bytes)) {
        return ctx.allocator.dupe(u8, "Failed to write control key to terminal surface.");
    }

    const deadline = std.time.milliTimestamp() + 400;
    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    const latest = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch
        return std.fmt.allocPrint(ctx.allocator, "Sent {s}; failed to read terminal snapshot.", .{label});
    defer ctx.allocator.free(latest);
    const out = try std.fmt.allocPrint(ctx.allocator, "Sent {s} to terminal.\nLatest snapshot:\n{s}", .{ label, latest });
    return tool_output.truncateTailOwned(ctx.allocator, ctx.settings, out);
}

pub fn terminalReplExec(ctx: *ToolContext, surface_id: []const u8, repl_name: []const u8, code: []const u8, timeout_ms: u32) ![]u8 {
    const repl = ReplKind.parse(repl_name) orelse return std.fmt.allocPrint(ctx.allocator, "Unsupported repl \"{s}\". Use r, python, codex, claude_code, or plain.", .{repl_name});
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const control = controlKeyByte(code);
    const gate = accessGate(ctx, code, null);
    if (tool_access.approvalRequired(ctx.settings.permission, gate)) {
        var reason_buf: [96]u8 = undefined;
        const bl_reason = if (gate.blacklisted) tool_access.allocBlacklistReason(ctx.allocator, gate.matched) else null;
        defer if (bl_reason) |r| ctx.allocator.free(r);
        const reason = bl_reason orelse if (gate.dangerous)
            DANGEROUS_COMMAND_APPROVAL_REASON
        else if (control != null)
            std.fmt.bufPrint(&reason_buf, "Send control key {s} to terminal", .{std.mem.trim(u8, code, " \t\r\n")}) catch "Send control key to terminal"
        else
            std.fmt.bufPrint(&reason_buf, "Type input into opened {s} REPL/app terminal", .{repl.label()}) catch "Type input into terminal";
        if (!ctx.requestApproval("terminal_repl_exec", code, reason)) {
            return tool_output.deniedResult(ctx.allocator, code, "operator rejected REPL terminal input");
        }
    }

    const snapshot = terminal_tools.collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    const surface = terminal_tools.resolveSurfaceId(snapshot, surface_id, terminal_tools.selectedWriteContext(ctx)) orelse return terminal_tools.allocNoSurfaceError(ctx.allocator, snapshot, surface_id);
    if (try terminal_tools.ensureWriteContext(ctx, surface)) |message| return message;

    if (control) |byte| {
        return sendControlKey(ctx, host, surface, std.mem.trim(u8, code, " \t\r\n"), byte);
    }

    return switch (repl) {
        .r, .python, .plain => lineReplEvalTool(ctx, host, surface, repl, code, timeout_ms),
        .codex, .claude_code => plainReplInputTool(ctx, host, surface, repl, code, timeout_ms),
    };
}

fn allocPromptOptionsHint(allocator: std.mem.Allocator, options: []const agent_prompt_answer.Option, screen: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Could not map that answer to an on-screen option. Options:\n");
    for (options) |o| {
        try out.print(allocator, "  {d}. {s}{s}\n", .{ o.number, o.label, if (o.highlighted) " [highlighted]" else "" });
    }
    try out.appendSlice(allocator, "Pass answer as an explicit digit (e.g. \"1\"), or approve/approve_all/reject.\nLatest snapshot:\n");
    try out.appendSlice(allocator, screen);
    return out.toOwnedSlice(allocator);
}

/// Answer a Claude Code / Codex approval menu: read the live screen, confirm a
/// prompt is awaiting input, map the semantic `answer` to a keystroke, send it,
/// and return the resulting live screen. Never sends a key it cannot justify
/// from the on-screen options.
pub fn terminalAnswerPrompt(ctx: *ToolContext, surface_id: ?[]const u8, answer: []const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const intent = agent_prompt_answer.parseIntent(answer) orelse
        return std.fmt.allocPrint(ctx.allocator, "Unknown answer \"{s}\". Use approve, approve_all, reject, enter, esc, or a digit 1-9.", .{answer});
    const option_number: u8 = if (intent == .option) (agent_prompt_answer.parseOptionNumber(answer) orelse 0) else 0;

    const snapshot = terminal_tools.collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    const sid = surface_id orelse "focused";
    const surface = terminal_tools.resolveSurfaceId(snapshot, sid, terminal_tools.selectedWriteContext(ctx)) orelse return terminal_tools.allocNoSurfaceError(ctx.allocator, snapshot, sid);
    if (try terminal_tools.ensureWriteAccess(ctx, surface)) |message| return message;

    // Read the LIVE screen (per-surface, mutex-protected, worker-safe).
    const screen = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch
        return ctx.allocator.dupe(u8, "Failed to read terminal snapshot.");
    defer ctx.allocator.free(screen);

    const detection: agent_detector.Detection = .{
        .app = surface.agent_app,
        .state = surface.agent_state,
        .confidence = surface.agent_confidence,
    };
    if (detection.app == .none or (detection.state != .waiting_approval and detection.state != .needs_input)) {
        const out = try std.fmt.allocPrint(
            ctx.allocator,
            "No Claude Code/Codex prompt is awaiting an answer (agent={s}:{s}). Nothing sent.\nLatest snapshot:\n{s}",
            .{ detection.app.label(), detection.state.label(), screen },
        );
        return tool_output.truncateTailOwned(ctx.allocator, ctx.settings, out);
    }

    var options_buf: [12]agent_prompt_answer.Option = undefined;
    const n = agent_prompt_answer.parsePromptOptions(screen, &options_buf);
    const keystroke = agent_prompt_answer.resolveAnswer(options_buf[0..n], screen, intent, option_number) orelse {
        const out = try allocPromptOptionsHint(ctx.allocator, options_buf[0..n], screen);
        return tool_output.truncateTailOwned(ctx.allocator, ctx.settings, out);
    };

    // Approval gate mirrors terminal_repl_exec: the payload is a single selector
    // key, not a destructive command, so auto runs it and confirm prompts. Note
    // the gate sees only the keystroke, not the command the agent app would run
    // on confirmation — like terminal_repl_exec control keys, the app's own
    // approval prompt is the real boundary for that command.
    const gate = accessGate(ctx, keystroke.bytes, null);
    if (tool_access.approvalRequired(ctx.settings.permission, gate)) {
        if (!ctx.requestApproval("terminal_answer_prompt", answer, "Answer a Claude Code/Codex approval prompt")) {
            return tool_output.deniedResult(ctx.allocator, answer, "operator rejected prompt answer");
        }
    }

    // Bind the agent write context to the resolved surface we are answering on
    // (mirrors terminal_select). This is the explicitly-targeted prompt surface,
    // so it is safe — and it avoids ensureWriteContext refusing when nothing is
    // pre-selected (e.g. a non-copilot caller).
    terminal_tools.setWriteContext(ctx, surface.id);

    if (!host.writeSurface(host.ctx, surface.id, surface.ptr, keystroke.bytes)) {
        return ctx.allocator.dupe(u8, "Failed to write to terminal surface.");
    }
    if (keystroke.confirm_enter) {
        std.Thread.sleep(CODEX_SUBMIT_DELAY_MS * std.time.ns_per_ms);
        _ = host.writeSurface(host.ctx, surface.id, surface.ptr, "\r");
    }

    const deadline = std.time.milliTimestamp() + 400;
    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    const latest = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch
        return std.fmt.allocPrint(ctx.allocator, "Answer sent ({s}); failed to read terminal snapshot.", .{answer});
    defer ctx.allocator.free(latest);
    const out = try std.fmt.allocPrint(ctx.allocator, "Answered prompt ({s}).\nLatest snapshot:\n{s}", .{ answer, latest });
    return tool_output.truncateTailOwned(ctx.allocator, ctx.settings, out);
}

/// Pause between writing a Codex message body and its submit keystroke so the
/// Enter lands as its own key event instead of being folded into Codex's
/// paste-burst (which would leave a literal newline and never submit).
const CODEX_SUBMIT_DELAY_MS: u64 = 120;

fn plainReplSubmitKey(repl: ReplKind, surface: ToolSurface) []const u8 {
    // Codex queues a follow-up while it is working with Tab ("tab to queue
    // message"); otherwise Enter (\r) submits. A literal \n is inserted as a
    // newline by the Codex composer rather than submitting, so never use it.
    if (repl == .codex and surface.agent_state == .running) return "\t";
    return "\r";
}

pub fn allocPlainReplInput(allocator: std.mem.Allocator, repl: ReplKind, surface: ToolSurface, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ text, plainReplSubmitKey(repl, surface) });
}

pub fn plainReplInputTool(ctx: *const ToolContext, host: ToolHost, surface: ToolSurface, repl: ReplKind, text: []const u8, timeout_ms: u32) ![]u8 {
    // Line REPLs (.r/.python/.plain) go through lineReplEvalTool instead; this
    // tool is only for the agent TUIs, whose completion is judged by busy markers.
    std.debug.assert(repl == .codex or repl == .claude_code);
    if (repl == .codex) {
        // Codex's TUI treats a fast input burst as a paste and folds a trailing
        // Enter into the pasted text, leaving a literal newline that never
        // submits (the "多余的换行" / unsent-at-prompt symptom). Send the body,
        // pause so the burst ends, then send the submit key as its own
        // keystroke — emulating type-then-Enter.
        if (!host.writeSurface(host.ctx, surface.id, surface.ptr, text)) {
            return ctx.allocator.dupe(u8, "Failed to write to terminal surface.");
        }
        std.Thread.sleep(CODEX_SUBMIT_DELAY_MS * std.time.ns_per_ms);
        if (!host.writeSurface(host.ctx, surface.id, surface.ptr, plainReplSubmitKey(repl, surface))) {
            return ctx.allocator.dupe(u8, "Failed to write to terminal surface.");
        }
    } else {
        const input = try allocPlainReplInput(ctx.allocator, repl, surface, text);
        defer ctx.allocator.free(input);
        if (!host.writeSurface(host.ctx, surface.id, surface.ptr, input)) {
            return ctx.allocator.dupe(u8, "Failed to write to terminal surface.");
        }
    }

    // Only Codex / Claude Code reach this tool now (line REPLs use
    // lineReplEvalTool); both settle on the busy-marker-aware waiter.
    return waitForAgentAppReplResult(ctx, host, surface, repl, timeout_ms);
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
    return tool_output.truncateTailOwned(allocator, settings, try out.toOwnedSlice(allocator));
}

fn waitForAgentAppReplResult(ctx: *const ToolContext, host: ToolHost, surface: ToolSurface, repl: ReplKind, timeout_ms: u32) ![]u8 {
    const wait_ms = @max(timeout_ms, 1000);
    const quiet_ms: i64 = 1500;
    const min_wait_ms: i64 = 750;
    const started = std.time.milliTimestamp();
    const deadline = started + @as(i64, @intCast(wait_ms));

    // Read the live screen via the per-surface snapshot. It holds the surface's
    // render mutex over heap-owned terminal state, so it works from the agent
    // request worker thread. collectSnapshot() must NOT be used here: the tab
    // model is thread-local to the UI thread and reads empty on the worker (see
    // the pre-capture comment in assistant/conversation/session.zig), which
    // previously left this wait blind and spinning to the full timeout while the
    // model saw a stale screen.
    var last_text = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch
        try ctx.allocator.dupe(u8, surface.snapshot);
    defer ctx.allocator.free(last_text);
    var last_change_ms = started;

    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        std.Thread.sleep(150 * std.time.ns_per_ms);
        const now = std.time.milliTimestamp();

        const text = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch continue;
        if (std.mem.eql(u8, last_text, text)) {
            ctx.allocator.free(text);
        } else {
            ctx.allocator.free(last_text);
            last_text = text;
            last_change_ms = now;
        }

        // Settle on a screen that has been stable for quiet_ms (after a min-wait
        // floor) and shows no active busy marker. The busy-marker gate keeps us
        // waiting while Codex/Claude Code is still working.
        const settled = now - started >= min_wait_ms and now - last_change_ms >= quiet_ms;
        if (settled and !replSnapshotLooksBusy(repl, last_text)) {
            return allocAgentAppReplResult(
                ctx.allocator,
                ctx.settings,
                repl,
                surface.agent_app,
                surface.agent_state,
                surface.agent_confidence,
                "screen settled without an active busy marker",
                last_text,
            );
        }
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
        surface.agent_app,
        surface.agent_state,
        surface.agent_confidence,
        note,
        last_text,
    );
}

/// Run code in a line-oriented REPL (Python, R, Node, IPython, Julia, psql, ...)
/// the way a human does: capture the current prompt, type the raw code + Enter,
/// then wait until the screen settles back at a ready prompt. No sentinel wrapper
/// is injected, so the REPL echoes the user's code verbatim and the value of a
/// bare expression (e.g. `1+1`) is displayed normally. Errors appear as the REPL's
/// native traceback in the returned snapshot; there is no synthetic status code.
fn lineReplEvalTool(ctx: *const ToolContext, host: ToolHost, surface: ToolSurface, repl: ReplKind, code: []const u8, timeout_ms: u32) ![]u8 {
    // Learn the prompt currently shown so we can recognise its return. Read the
    // live per-surface snapshot (collectSnapshot is empty on the worker thread).
    const before = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch
        try ctx.allocator.dupe(u8, surface.snapshot);
    defer ctx.allocator.free(before);
    const captured_prompt = try ctx.allocator.dupe(u8, extractPromptLine(before));
    defer ctx.allocator.free(captured_prompt);

    const input = try allocPlainReplInput(ctx.allocator, repl, surface, code);
    defer ctx.allocator.free(input);
    if (!host.writeSurface(host.ctx, surface.id, surface.ptr, input)) {
        return ctx.allocator.dupe(u8, "Failed to write to terminal surface.");
    }

    return waitForReplPromptReturn(ctx, host, surface, repl, captured_prompt, timeout_ms);
}

/// Poll the live per-surface snapshot until the screen has been unchanged for
/// `quiet_ms` (after a `min_wait_ms` floor) AND a ready prompt has returned, then
/// hand back the screen. On timeout, return the latest screen tagged as still in
/// progress so the model does not treat a partial result as final.
fn waitForReplPromptReturn(
    ctx: *const ToolContext,
    host: ToolHost,
    surface: ToolSurface,
    repl: ReplKind,
    captured_prompt: []const u8,
    timeout_ms: u32,
) ![]u8 {
    const wait_ms = @max(timeout_ms, 1000);
    // Line REPLs respond faster than the agent TUIs (waitForAgentAppReplResult
    // uses 1500/750), so settle a bit sooner. The min_wait_ms floor also defends
    // against returning before the typed input has echoed and reset the screen.
    const quiet_ms: i64 = 1000;
    const min_wait_ms: i64 = 500;
    const started = std.time.milliTimestamp();
    const deadline = started + @as(i64, @intCast(wait_ms));

    var last_text = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch
        try ctx.allocator.dupe(u8, surface.snapshot);
    defer ctx.allocator.free(last_text);
    var last_change_ms = started;

    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        std.Thread.sleep(150 * std.time.ns_per_ms);
        const now = std.time.milliTimestamp();

        const text = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch continue;
        if (std.mem.eql(u8, last_text, text)) {
            ctx.allocator.free(text);
        } else {
            ctx.allocator.free(last_text);
            last_text = text;
            last_change_ms = now;
        }

        const quiesced = now - started >= min_wait_ms and now - last_change_ms >= quiet_ms;
        if (quiesced and promptReturned(last_text, captured_prompt)) {
            return tool_output.truncateOwned(ctx.allocator, ctx.settings, try ctx.allocator.dupe(u8, last_text));
        }
    }

    const note = try std.fmt.allocPrint(
        ctx.allocator,
        "\n[{s} REPL still busy after {d} ms; treat this as in progress, not a final result]",
        .{ repl.label(), wait_ms },
    );
    defer ctx.allocator.free(note);
    const combined = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ last_text, note });
    return tool_output.truncateOwned(ctx.allocator, ctx.settings, combined);
}

/// The trailing prompt of a terminal snapshot: the last non-empty line, trimmed
/// of surrounding whitespace. Returns "" when no non-empty line exists. Used to
/// learn a REPL's prompt dynamically so completion detection is language-agnostic.
fn extractPromptLine(snapshot: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, snapshot, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return "";
}

/// Heuristic: does a trailing line look like an interactive REPL prompt waiting
/// for input? True for `>>>`, `>`, `In [3]:`, `julia>`, `dbname=#`, `$`, ... .
/// Conservative on length so long output lines are not mistaken for a prompt.
/// This is only the *fallback* signal; an exact match against the prompt captured
/// before typing (see `promptReturned`) is the primary, precise signal.
fn looksLikeReadyPrompt(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 64) return false;
    return switch (trimmed[trimmed.len - 1]) {
        '>', ':', '$', '#' => true,
        else => false,
    };
}

/// True when the snapshot's trailing line shows the REPL is back at a ready
/// prompt: it equals the prompt captured before we typed, or it matches the
/// generic ready-prompt heuristic. The exact match handles prompts that stayed
/// the same; the heuristic handles prompts that changed (e.g. `$ ` -> `>>> `).
fn promptReturned(snapshot: []const u8, captured_prompt: []const u8) bool {
    const line = extractPromptLine(snapshot);
    if (captured_prompt.len != 0 and std.mem.eql(u8, line, captured_prompt)) return true;
    return looksLikeReadyPrompt(line);
}

const AGENT_START_PREFIX = "__WISPTERM_AGENT_START_";

/// Whether the snapshot's most recent agent command never reported completion:
/// find the last START marker, read its nonce, and report true if no completed
/// END (`__WISPTERM_AGENT_END_<nonce>__:<digit>`) appears after it. If the
/// start has scrolled out of the snapshot we report false (idle) — an
/// acceptable false-negative. Marker scan only; see agentCommandStillRunning
/// for the actual busy-guard predicate.
fn hasPendingAgentCommand(snapshot: []const u8) bool {
    const last_start = std.mem.lastIndexOf(u8, snapshot, AGENT_START_PREFIX) orelse return false;
    const nonce_start = last_start + AGENT_START_PREFIX.len;
    var i = nonce_start;
    while (i < snapshot.len and std.ascii.isDigit(snapshot[i])) : (i += 1) {}
    const nonce = snapshot[nonce_start..i];
    if (nonce.len == 0) return false;

    var buf: [64]u8 = undefined;
    const end_marker = std.fmt.bufPrint(&buf, "__WISPTERM_AGENT_END_{s}__", .{nonce}) catch return false;
    return findCompletedEnd(snapshot[last_start..], end_marker) == null;
}

/// Busy-guard predicate for injecting a new wrapped command. A pending START
/// without a completed END only means "still running" while the terminal has
/// not returned to a ready prompt. An interrupted command (<ctrl-c>) never
/// prints its END marker, so the marker scan alone would latch the guard on
/// until the stale START scrolls out of the snapshot window — refusing every
/// new command on this surface even though the shell sits idle. A trailing
/// ready prompt overrides the markers: a foreground command cannot still be
/// running while the shell is showing its prompt.
fn agentCommandStillRunning(snapshot: []const u8) bool {
    if (!hasPendingAgentCommand(snapshot)) return false;
    return !looksLikeReadyPrompt(extractPromptLine(snapshot));
}

fn unixSessionExecTool(ctx: *ToolContext, kind: UnixSessionKind, surface_id: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const gate = accessGate(ctx, command, null);
    if (tool_access.approvalRequired(ctx.settings.permission, gate)) {
        var reason_buf: [64]u8 = undefined;
        const bl_reason = if (gate.blacklisted) tool_access.allocBlacklistReason(ctx.allocator, gate.matched) else null;
        defer if (bl_reason) |r| ctx.allocator.free(r);
        const reason = bl_reason orelse if (gate.dangerous)
            DANGEROUS_COMMAND_APPROVAL_REASON
        else
            std.fmt.bufPrint(&reason_buf, "Type command into opened {s} terminal", .{kind.label()}) catch "Type command into terminal";
        if (!ctx.requestApproval(kind.toolName(), command, reason)) {
            return tool_output.deniedResult(ctx.allocator, command, if (kind == .ssh) "operator rejected SSH PTY command" else "operator rejected WSL PTY command");
        }
    }
    const snapshot = terminal_tools.collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    const surface = terminal_tools.resolveSurfaceId(snapshot, surface_id, terminal_tools.selectedWriteContext(ctx)) orelse return terminal_tools.allocNoSurfaceError(ctx.allocator, snapshot, surface_id);
    if (try terminal_tools.ensureWriteContext(ctx, surface)) |message| return message;
    if (!kind.matches(surface)) {
        return std.fmt.allocPrint(ctx.allocator, "Target surface is not an opened {s} session.", .{kind.label()});
    }
    if (try shellExecAgentAppRefusal(ctx.allocator, kind, surface)) |message| return message;
    if (try shellExecInteractiveAgentCommandRefusal(ctx.allocator, kind, command)) |message| return message;
    if (try shellExecBareReplRefusal(ctx.allocator, kind, command)) |message| return message;

    // Refuse to inject a new command while the previous one is still running:
    // interleaved sentinels confuse parsing and the model tends to re-issue,
    // duplicating side effects (e.g. a second git clone). A fresh snapshot is
    // authoritative; the cached surface snapshot may be stale.
    if (host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch null) |guard_snapshot| {
        defer ctx.allocator.free(guard_snapshot);
        if (agentCommandStillRunning(guard_snapshot)) {
            return allocStillRunningBusyGuard(ctx.allocator, kind.label());
        }
    }

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

    if (!host.writeSurface(host.ctx, surface.id, surface.ptr, wrapped)) {
        return std.fmt.allocPrint(ctx.allocator, "Failed to write to {s} terminal surface.", .{kind.label()});
    }

    const start_marker = try std.fmt.allocPrint(ctx.allocator, "__WISPTERM_AGENT_START_{d}__", .{nonce});
    defer ctx.allocator.free(start_marker);
    const end_marker = try std.fmt.allocPrint(ctx.allocator, "__WISPTERM_AGENT_END_{d}__", .{nonce});
    defer ctx.allocator.free(end_marker);
    return waitForSentinelResult(ctx, host, surface, kind.label(), start_marker, end_marker, timeout_ms);
}

/// Timeout result for a sentinel command that never reported completion. Frames
/// it as "still running, do not re-issue" with recovery hints, so the model
/// waits/re-checks instead of re-running the command (which duplicates side
/// effects, e.g. a second git clone).
fn allocStillRunningBusyGuard(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "A previous command is still running in this {s} terminal. Do not start another command. Use continue_later to re-check with terminal_snapshot after a sensible delay, or interrupt it first with terminal_repl_exec repl=plain code=<ctrl-c>.", .{label});
}

fn allocStillRunningTimeout(allocator: std.mem.Allocator, label: []const u8, elapsed_s: i64, snapshot: ?[]const u8) ![]u8 {
    if (snapshot) |text| {
        return std.fmt.allocPrint(allocator, "The {s} command has not returned after {d}s; it is most likely still running. Do NOT re-issue it. Use continue_later to re-check with terminal_snapshot after a sensible delay, or interrupt with terminal_repl_exec repl=plain code=<ctrl-c>.\nLatest snapshot:\n{s}", .{ label, elapsed_s, text });
    }
    return std.fmt.allocPrint(allocator, "The {s} command has not returned after {d}s; it is most likely still running. Do NOT re-issue it. Use continue_later to re-check with terminal_snapshot after a sensible delay, or interrupt with terminal_repl_exec repl=plain code=<ctrl-c>.", .{ label, elapsed_s });
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
    const started = std.time.milliTimestamp();
    const deadline = started + @as(i64, @intCast(@max(timeout_ms, 1000)));
    var last: ?[]u8 = null;
    defer if (last) |text| ctx.allocator.free(text);

    while (std.time.milliTimestamp() < deadline) {
        if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        if (last) |old| ctx.allocator.free(old);
        last = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch null;
        if (last) |text| {
            if (findCompletedEnd(text, end_marker) != null) {
                return extractUnixCommandResult(ctx.allocator, text, start_marker, end_marker);
            }
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    const elapsed_s = @divFloor(std.time.milliTimestamp() - started, 1000);
    return allocStillRunningTimeout(ctx.allocator, label, elapsed_s, last);
}

// Utility helpers
// ---------------------------------------------------------------------------

/// Find the END sentinel that marks real completion: the first occurrence of
/// `end_marker` immediately followed by `:` and an ASCII digit (the exit
/// status). The shell echoes the wrapped command line, which contains the bare
/// marker followed by `:%s` (or, for R, `:"`); those never satisfy the digit
/// test, so the echo is ignored. Returns the byte index of the marker, or null
/// if the command has not completed yet.
fn findCompletedEnd(text: []const u8, end_marker: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, end_marker)) |idx| {
        const colon = idx + end_marker.len;
        if (colon + 1 < text.len and text[colon] == ':' and std.ascii.isDigit(text[colon + 1])) {
            return idx;
        }
        from = idx + 1;
    }
    return null;
}

fn extractUnixCommandResult(allocator: std.mem.Allocator, text: []const u8, start_marker: []const u8, end_marker: []const u8) ![]u8 {
    const end = findCompletedEnd(text, end_marker) orelse return allocator.dupe(u8, text);

    // Exit status: digits after the matched marker's ':'.
    const status_start = end + end_marker.len + 1;
    var status_end = status_start;
    while (status_end < text.len and std.ascii.isDigit(text[status_end])) : (status_end += 1) {}
    const status = text[status_start..status_end];

    // The real START sits just above the output; the echo's START is further up.
    // Take the last START before the completed END.
    const start = std.mem.lastIndexOf(u8, text[0..end], start_marker) orelse {
        const body = std.mem.trim(u8, text[0..end], " \t\r\n");
        return std.fmt.allocPrint(allocator, "exit_status={s}\n{s}", .{ status, body });
    };
    const body = std.mem.trim(u8, text[start + start_marker.len .. end], " \t\r\n");
    return std.fmt.allocPrint(allocator, "exit_status={s}\n{s}", .{ status, body });
}

pub const DANGEROUS_COMMAND_APPROVAL_REASON = "Destructive command (delete/rename/format) - confirm to run";

/// Whether a command is destructive enough to require operator approval in
/// auto mode: deletes, renames/moves, disk formatting, and a few other
/// irreversible operations.
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
        "rm",
        "rmdir",
        "unlink",
        "shred",
        "trash",
        "del",
        "rd",
        // rename / move
        "mv",
        "move",
        "rename",
        "ren",
        // format / wipe disk
        "format",
        "mkfs",
        "fdisk",
        "diskpart",
        // power
        "shutdown",
        "reboot",
        "halt",
        "poweroff",
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
// Tests
// ---------------------------------------------------------------------------

fn fakeApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}
fn fakeCancelled(_: *anyopaque) bool {
    return false;
}

const ReplWaitTestHost = struct {
    const Ctx = struct {
        collect_calls: usize = 0,
        snap_calls: usize = 0,
        write_calls: usize = 0,
        // Number of leading surface-snapshot reads that still look busy before
        // the screen settles. The wait must settle off the *live* per-surface
        // read, not collectSnapshot (which is empty on the worker thread).
        busy_until: usize = 2,
        settled_text: []const u8 = "Claude Code\nDone. result = 563894910\n> ",
        last_write: [256]u8 = undefined,
        last_write_len: usize = 0,
        // Concatenation of every write, to distinguish a single combined write
        // (body+key) from a separated body + submit-key keystroke.
        all_writes: [256]u8 = undefined,
        all_len: usize = 0,
    };

    // Simulates the real worker thread: the tab model is thread-local to the UI
    // thread, so collectSnapshot reads empty here. Tools must not depend on it.
    fn collectSnapshot(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!ToolSnapshot {
        const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
        ctx.collect_calls += 1;
        const surfaces = try allocator.alloc(ToolSurface, 0);
        return .{ .surfaces = surfaces, .active_tab = 0 };
    }

    // The per-surface snapshot holds the surface's render mutex and therefore
    // works from the worker thread. It reports a busy screen, then a settled one.
    fn surfaceSnapshot(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: *anyopaque) anyerror![]u8 {
        const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
        ctx.snap_calls += 1;
        const busy = ctx.snap_calls <= ctx.busy_until;
        return allocator.dupe(u8, if (busy) "Claude Code\nthinking… (esc to interrupt)" else ctx.settled_text);
    }

    fn writeSurface(ctx_ptr: *anyopaque, _: []const u8, _: *anyopaque, data: []const u8) bool {
        const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
        const len = @min(data.len, ctx.last_write.len);
        @memcpy(ctx.last_write[0..len], data[0..len]);
        ctx.last_write_len = len;
        ctx.write_calls += 1;
        const room = ctx.all_writes.len - ctx.all_len;
        const take = @min(room, data.len);
        @memcpy(ctx.all_writes[ctx.all_len..][0..take], data[0..take]);
        ctx.all_len += take;
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
test "shell exec refuses bare REPL launchers but allows run-and-exit invocations" {
    const allocator = std.testing.allocator;
    const bare = [_][]const u8{ "python", "python3", "ipython", "R", "node", "irb", "/usr/bin/python", "python " };
    for (bare) |cmd| {
        const m = (try shellExecBareReplRefusal(allocator, .wsl, cmd)) orelse {
            std.debug.print("expected a refusal for bare launcher: {s}\n", .{cmd});
            return error.TestExpectedRefusal;
        };
        defer allocator.free(m);
        try std.testing.expect(std.mem.indexOf(u8, m, "repl=plain") != null);
    }
    const allowed = [_][]const u8{ "python app.py", "python -c 'x=1'", "python --version", "R --version", "node app.js", "which python", "pip install foo", "ls" };
    for (allowed) |cmd| {
        try std.testing.expect((try shellExecBareReplRefusal(allocator, .wsl, cmd)) == null);
    }
}

test "extractPromptLine returns the trailing non-empty prompt line" {
    try std.testing.expectEqualStrings(">>>", extractPromptLine("hello\nworld\n>>> "));
    try std.testing.expectEqualStrings("In [3]:", extractPromptLine("Out[2]: 5\n\nIn [3]: "));
    try std.testing.expectEqualStrings("julia>", extractPromptLine("julia> "));
    try std.testing.expectEqualStrings("", extractPromptLine("\n  \n"));
    try std.testing.expectEqualStrings("", extractPromptLine(""));
}

test "looksLikeReadyPrompt accepts prompts and rejects output" {
    try std.testing.expect(looksLikeReadyPrompt(">>>"));
    try std.testing.expect(looksLikeReadyPrompt(">"));
    try std.testing.expect(looksLikeReadyPrompt("In [3]:"));
    try std.testing.expect(looksLikeReadyPrompt("julia>"));
    try std.testing.expect(looksLikeReadyPrompt("dbname=#"));
    try std.testing.expect(looksLikeReadyPrompt("$"));
    try std.testing.expect(!looksLikeReadyPrompt(""));
    try std.testing.expect(!looksLikeReadyPrompt("2"));
    try std.testing.expect(!looksLikeReadyPrompt("TypeError: unsupported operand"));
    try std.testing.expect(!looksLikeReadyPrompt("this is a very long line of output that should not be treated as a prompt at all"));
}

test "promptReturned matches the captured prompt or a generic prompt" {
    try std.testing.expect(promptReturned("foo\n>>> ", ">>>"));
    try std.testing.expect(promptReturned("$ python\nPython 3.12\n>>> ", "$"));
    try std.testing.expect(!promptReturned("computing...\n42", ">>>"));
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
    // Idle Codex submits with a real Enter (\r). A literal \n is treated by the
    // Codex composer as an inserted newline, not a submit.
    try std.testing.expectEqualStrings("/status\r", idle_input);
}

test "codex repl input submits the Enter keystroke separately from the message body" {
    const allocator = std.testing.allocator;
    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 0, .settled_text = "codex idle\n› " };
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
        .id = @constCast("surface-codex"),
        .title = @constCast("codex"),
        .cwd = @constCast("/home/xzg"),
        .snapshot = @constCast("› "),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = true,
        .agent_app = .codex,
        .agent_state = .done,
        .agent_confidence = 70,
        .ptr = @ptrCast(&host_ctx),
    };

    const result = try plainReplInputTool(&ctx, ReplWaitTestHost.host(&host_ctx), surface, .codex, "hello codex", 1000);
    defer allocator.free(result);
    // Codex's paste-burst detection folds a same-write Enter into the pasted
    // text, so the body and the Enter keystroke must be two separate writes.
    try std.testing.expectEqual(@as(usize, 2), host_ctx.write_calls);
    try std.testing.expectEqualStrings("hello codex\r", host_ctx.all_writes[0..host_ctx.all_len]);
}

test "line REPL eval types raw code and settles on the returned prompt" {
    const allocator = std.testing.allocator;
    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 2, .settled_text = ">>> 1+1\n2\n>>> " };
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
        .id = @constCast("surface-py"),
        .title = @constCast("python"),
        .cwd = @constCast("/home/xzg"),
        .snapshot = @constCast(">>> "),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrCast(&host_ctx),
    };

    const result = try lineReplEvalTool(&ctx, ReplWaitTestHost.host(&host_ctx), surface, .python, "1+1", 5000);
    defer allocator.free(result);

    // Raw code typed (code + Enter), NOT an exec()-wrapped sentinel blob.
    try std.testing.expectEqualStrings("1+1\r", host_ctx.all_writes[0..host_ctx.all_len]);
    try std.testing.expect(std.mem.indexOf(u8, result, "__WISPTERM_AGENT_START_") == null);
    // The REPL's own output is handed back for the model to read.
    try std.testing.expect(std.mem.indexOf(u8, result, "2") != null);
}

test "agent control-key tokens parse to raw bytes, plain text is unaffected" {
    try std.testing.expectEqual(@as(?u8, 0x03), controlKeyByte("<ctrl-c>"));
    try std.testing.expectEqual(@as(?u8, 0x03), controlKeyByte("  <Ctrl-C> "));
    try std.testing.expectEqual(@as(?u8, 0x04), controlKeyByte("<ctrl-d>"));
    try std.testing.expectEqual(@as(?u8, 0x15), controlKeyByte("<ctrl-u>"));
    try std.testing.expectEqual(@as(?u8, 0x1b), controlKeyByte("<esc>"));
    try std.testing.expectEqual(@as(?u8, 0x0d), controlKeyByte("<enter>"));
    try std.testing.expectEqual(@as(?u8, 0x0d), controlKeyByte("<cr>"));
    // A substring inside real text must NOT be interpreted as a control key.
    try std.testing.expectEqual(@as(?u8, null), controlKeyByte("echo <ctrl-c>"));
    try std.testing.expectEqual(@as(?u8, null), controlKeyByte("ls -la"));
}

test "agent exec detects a still-pending previous command" {
    // Real START present, no completed END -> pending.
    const pending = "__WISPTERM_AGENT_START_222__\nCloning into 'x'...\n";
    try std.testing.expect(hasPendingAgentCommand(pending));

    // Echo end (:%s) only, no real :<digit> -> still pending.
    const echo_only =
        "$  printf '\\n__WISPTERM_AGENT_END_222__:%s\\n'\n__WISPTERM_AGENT_START_222__\nfoo\n";
    try std.testing.expect(hasPendingAgentCommand(echo_only));

    // Completed END present -> not pending.
    const done = "__WISPTERM_AGENT_START_222__\nhi\n__WISPTERM_AGENT_END_222__:0\n$ ";
    try std.testing.expect(!hasPendingAgentCommand(done));

    // No agent markers at all -> not pending.
    try std.testing.expect(!hasPendingAgentCommand("(base) u@h:~$ "));
}

test "agent exec busy guard clears at a ready prompt after an interrupt" {
    // A wrapped command was interrupted with <ctrl-c>: its END marker never
    // printed, so the stale START stays in scrollback. The shell is back at a
    // ready prompt, so nothing is running in the foreground — the guard must
    // let the next command through instead of latching on forever.
    const interrupted =
        "__WISPTERM_AGENT_START_444__\n" ++
        "Cloning into 'x'...\n" ++
        "^C\n" ++
        "(base) root@guozi-server02:~# ";
    try std.testing.expect(hasPendingAgentCommand(interrupted));
    try std.testing.expect(!agentCommandStillRunning(interrupted));

    // Still streaming output, no trailing prompt -> still running, keep refusing.
    const running = "__WISPTERM_AGENT_START_444__\nCloning into 'x'...\n";
    try std.testing.expect(agentCommandStillRunning(running));

    // Running silently: the last line is the START marker itself, not a prompt.
    const silent = "(base) u@h:~$  printf ...\n__WISPTERM_AGENT_START_444__\n";
    try std.testing.expect(agentCommandStillRunning(silent));

    // Completed normally -> not running regardless of the prompt heuristic.
    const done = "__WISPTERM_AGENT_START_444__\nhi\n__WISPTERM_AGENT_END_444__:0\n$ ";
    try std.testing.expect(!agentCommandStillRunning(done));
}

test "agent exec timeout message says still running, do not re-issue" {
    const allocator = std.testing.allocator;
    const msg = try allocStillRunningTimeout(allocator, "SSH", 60, "Cloning into 'x'...");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "still running") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Do NOT re-issue") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "continue_later") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Use continue_later to re-check with terminal_snapshot after a sensible delay") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "code=<ctrl-c>") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Cloning into 'x'...") != null);

    const no_snapshot_msg = try allocStillRunningTimeout(allocator, "SSH", 60, null);
    defer allocator.free(no_snapshot_msg);
    try std.testing.expect(std.mem.indexOf(u8, no_snapshot_msg, "still running") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_snapshot_msg, "Do NOT re-issue") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_snapshot_msg, "Use continue_later to re-check with terminal_snapshot after a sensible delay") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_snapshot_msg, "code=<ctrl-c>") != null);
}

test "agent exec busy guard message points at continue_later" {
    const allocator = std.testing.allocator;
    const msg = try allocStillRunningBusyGuard(allocator, "SSH");
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "previous command is still running") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "continue_later") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "terminal_snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "code=<ctrl-c>") != null);
}

test "agent exec sentinel ignores the echoed command line" {
    const allocator = std.testing.allocator;
    // The shell echoes the whole wrapped command (with literal \n and %s) above
    // the real printf output. Only the real END line ends in `:<digit>`.
    const snapshot =
        "(base) u@h:~$  printf '\\n__WISPTERM_AGENT_START_111__\\n'; { echo hi; } 2>&1;" ++
        " __wispterm_agent_status=$?; printf '\\n__WISPTERM_AGENT_END_111__:%s\\n' \"$s\"\n" ++
        "\n__WISPTERM_AGENT_START_111__\n" ++
        "hi\n" ++
        "\n__WISPTERM_AGENT_END_111__:0\n" ++
        "(base) u@h:~$ ";

    // findCompletedEnd points at the real END (the `:0` one), not the echo.
    const end = findCompletedEnd(snapshot, "__WISPTERM_AGENT_END_111__").?;
    try std.testing.expect(std.mem.startsWith(u8, snapshot[end..], "__WISPTERM_AGENT_END_111__:0"));

    const result = try extractUnixCommandResult(allocator, snapshot, "__WISPTERM_AGENT_START_111__", "__WISPTERM_AGENT_END_111__");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("exit_status=0\nhi", result);
}

test "agent exec sentinel treats echo-only snapshot as not finished" {
    const incomplete =
        "(base) u@h:~$  printf '\\n__WISPTERM_AGENT_END_222__:%s\\n' \"$s\"\n" ++
        "\n__WISPTERM_AGENT_START_222__\n" ++
        "Cloning into 'x'...\n";
    try std.testing.expect(findCompletedEnd(incomplete, "__WISPTERM_AGENT_END_222__") == null);
}

test "agent exec sentinel parses multi-digit exit status" {
    const allocator = std.testing.allocator;
    const snapshot =
        "\n__WISPTERM_AGENT_START_333__\n" ++
        "boom\n" ++
        "\n__WISPTERM_AGENT_END_333__:128\n";
    const result = try extractUnixCommandResult(allocator, snapshot, "__WISPTERM_AGENT_START_333__", "__WISPTERM_AGENT_END_333__");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("exit_status=128\nboom", result);
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
test "accessGate forces approval for denied paths and skips safe allowed reads" {
    const a = std.testing.allocator;
    var rules = try ai_agent_access.parseRules(a, "allow /work/ok\n", "/home/u");
    defer rules.deinit();

    var session_dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &session_dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = &rules },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    // Denied path → force approval in auto mode.
    const denied = accessGate(&ctx, "cat ~/.ssh/id_rsa", null);
    try std.testing.expect(denied.force);
    try std.testing.expect(denied.blacklisted);

    // Safe read confined to an allow root → skip even in confirm mode.
    ctx.settings.permission = .confirm;
    const safe = accessGate(&ctx, "cat /work/ok/readme.md", null);
    try std.testing.expect(safe.skip);
    try std.testing.expect(!safe.force);

    // Unrelated read → neutral (no force, no skip).
    const neutral = accessGate(&ctx, "cat /work/other.txt", null);
    try std.testing.expect(!neutral.force);
    try std.testing.expect(!neutral.skip);
}

test "permission modes map ask auto and full approval policy" {
    const a = std.testing.allocator;
    var rules = try ai_agent_access.parseRules(a, "allow /work/ok\n", "/home/u");
    defer rules.deinit();

    var session_dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &session_dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .auto, .access_rules = &rules },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const denied = accessGate(&ctx, "cat ~/.ssh/id_rsa", null);
    try std.testing.expect(tool_access.approvalRequired(.auto, denied));
    try std.testing.expect(!tool_access.approvalRequired(.full, denied));

    const dangerous = accessGate(&ctx, "rm /work/ok/readme.md", null);
    try std.testing.expect(tool_access.approvalRequired(.auto, dangerous));
    try std.testing.expect(!tool_access.approvalRequired(.full, dangerous));

    const neutral = accessGate(&ctx, "cat /work/other.txt", null);
    try std.testing.expect(tool_access.approvalRequired(.confirm, neutral));
    try std.testing.expect(!tool_access.approvalRequired(.auto, neutral));

    const allowed_read = accessGate(&ctx, "cat /work/ok/readme.md", null);
    try std.testing.expect(!tool_access.approvalRequired(.confirm, allowed_read));
}

test "accessGate with no rules degrades to dangerous-only behavior" {
    const a = std.testing.allocator;
    var session_dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &session_dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    try std.testing.expect(!accessGate(&ctx, "cat foo.txt", null).force);
    try std.testing.expect(accessGate(&ctx, "rm foo.txt", null).force); // dangerous still forces
}

test "Claude Code REPL input settles off the live surface snapshot, not the worker-empty collectSnapshot" {
    const allocator = std.testing.allocator;
    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 2 };
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

    const result = try plainReplInputTool(&ctx, ReplWaitTestHost.host(&host_ctx), surface, .claude_code, "analyze system", 3000);
    defer allocator.free(result);
    // The input was submitted with the Claude Code submit key.
    try std.testing.expectEqual(@as(usize, 1), host_ctx.write_calls);
    try std.testing.expectEqualStrings("analyze system\r", host_ctx.last_write[0..host_ctx.last_write_len]);
    // The wait read the live per-surface snapshot and ignored the worker-empty
    // collectSnapshot path entirely.
    try std.testing.expectEqual(@as(usize, 0), host_ctx.collect_calls);
    try std.testing.expect(host_ctx.snap_calls > 0);
    // It returned the settled live screen, not the stale pre-input snapshot.
    try std.testing.expect(std.mem.indexOf(u8, result, "563894910") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "thinking") == null);
}

test "accessGate: working-dir sandbox skips confined non-dangerous, still forces dangerous/deny" {
    const a = std.testing.allocator;
    var rules = try ai_agent_access.parseRules(a, "", "/home/u");
    defer rules.deinit();
    var dummy: u8 = 0;
    const ctx = types.ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .working_dir = "/home/u/proj", .access_rules = &rules },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    // confined write -> auto-approve
    const g1 = accessGate(&ctx, "curl http://x -o out.bin", "/home/u/proj");
    try std.testing.expect(g1.skip);
    try std.testing.expect(!g1.force);
    try std.testing.expect(!tool_access.approvalRequired(.confirm, g1)); // confirm now auto-runs inside the dir
    try std.testing.expect(!tool_access.approvalRequired(.auto, g1));
    // confined dangerous -> still forced
    const g2 = accessGate(&ctx, "rm -rf build", "/home/u/proj");
    try std.testing.expect(!g2.skip);
    try std.testing.expect(g2.force);
    try std.testing.expect(tool_access.approvalRequired(.confirm, g2));
    try std.testing.expect(tool_access.approvalRequired(.auto, g2));
    // escaping write -> not confined, normal gating (no skip, no force)
    const g3 = accessGate(&ctx, "cp /etc/hosts .", "/home/u/proj");
    try std.testing.expect(!g3.skip);
    try std.testing.expect(!g3.force);
    // deny-listed read inside cwd -> forced regardless of sandbox
    const g4 = accessGate(&ctx, "cat /home/u/.ssh/id_rsa", "/home/u/proj");
    try std.testing.expect(g4.force);
    try std.testing.expect(!g4.skip);
}

test "accessGate: no working dir leaves behavior unchanged" {
    const a = std.testing.allocator;
    var rules = try ai_agent_access.parseRules(a, "", "/home/u");
    defer rules.deinit();
    var dummy: u8 = 0;
    const ctx = types.ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .access_rules = &rules }, // working_dir = null
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const g = accessGate(&ctx, "curl http://x -o out.bin", null);
    try std.testing.expect(!g.skip);
    try std.testing.expect(!g.force);
}
test "terminal_answer_prompt sends the Yes digit for an approve answer" {
    const a = std.testing.allocator;
    const screen =
        \\Do you want to make this edit to index.html?
        \\  1. Yes
        \\  2. Yes, allow all edits during this session (shift+tab)
        \\  3. No
    ;
    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 0, .settled_text = screen };
    var dummy: u8 = 0;

    const surfaces = try a.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = @constCast("surface-claude"),
        .title = @constCast("Claude Code"),
        .cwd = @constCast("/home/xzg"),
        .snapshot = @constCast(""),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .claude_code,
        .agent_state = .waiting_approval,
        .agent_confidence = 90,
        .ptr = @ptrCast(&host_ctx),
    };
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = ReplWaitTestHost.host(&host_ctx),
        .tool_snapshot = .{ .surfaces = surfaces, .active_tab = 0 },
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    // Free only the slice we allocated; the surface string fields are literals,
    // so do NOT call snap.deinit (it would free static memory). The tool operates
    // on a clone internally, so the literal-backed originals are never freed.
    defer if (ctx.tool_snapshot) |snap| a.free(snap.surfaces);

    const result = try terminalAnswerPrompt(&ctx, @as(?[]const u8, "surface-claude"), "approve");
    defer a.free(result);

    try std.testing.expectEqualStrings("1", host_ctx.all_writes[0..host_ctx.all_len]);
    try std.testing.expect(std.mem.indexOf(u8, result, "Answered prompt") != null);
}

test "terminal_answer_prompt sends nothing when no prompt is awaiting" {
    const a = std.testing.allocator;
    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 0, .settled_text = "Claude Code\nthinking… (esc to interrupt)" };
    var dummy: u8 = 0;

    const surfaces = try a.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = @constCast("surface-claude"),
        .title = @constCast("Claude Code"),
        .cwd = @constCast("/home/xzg"),
        .snapshot = @constCast(""),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .claude_code,
        .agent_state = .running,
        .agent_confidence = 82,
        .ptr = @ptrCast(&host_ctx),
    };
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = ReplWaitTestHost.host(&host_ctx),
        .tool_snapshot = .{ .surfaces = surfaces, .active_tab = 0 },
        .settings = .{ .permission = .full },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    defer if (ctx.tool_snapshot) |snap| a.free(snap.surfaces);

    const result = try terminalAnswerPrompt(&ctx, @as(?[]const u8, "surface-claude"), "approve");
    defer a.free(result);

    try std.testing.expectEqual(@as(usize, 0), host_ctx.all_len);
    try std.testing.expect(std.mem.indexOf(u8, result, "awaiting an answer") != null);
}

test "terminal_answer_prompt cannot read another Agent's screen" {
    const a = std.testing.allocator;
    const registry = terminal_lease.active();
    registry.clear();
    defer registry.clear();
    registry.beginSync();
    registry.observe("surface-claude");
    registry.finishSync();
    try std.testing.expect(registry.claim(202, "surface-claude"));

    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 0, .settled_text = "1. Yes" };
    var dummy: u8 = 0;
    const surfaces = try a.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = @constCast("surface-claude"),
        .title = @constCast("Claude Code"),
        .cwd = @constCast("/home/xzg"),
        .snapshot = @constCast(""),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .claude_code,
        .agent_state = .waiting_approval,
        .agent_confidence = 90,
        .ptr = @ptrCast(&host_ctx),
    };
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = ReplWaitTestHost.host(&host_ctx),
        .tool_snapshot = .{ .surfaces = surfaces, .active_tab = 0 },
        .settings = .{ .permission = .full },
        .agent_instance_id = 101,
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    defer if (ctx.tool_snapshot) |snap| a.free(snap.surfaces);

    const result = try terminalAnswerPrompt(&ctx, @as(?[]const u8, "surface-claude"), "approve");
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Terminal access denied") != null);
    try std.testing.expectEqual(@as(usize, 0), host_ctx.snap_calls);
    try std.testing.expectEqual(@as(usize, 0), host_ctx.all_len);
}
