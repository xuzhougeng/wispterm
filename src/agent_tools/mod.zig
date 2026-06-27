//! Session-free agent tool runtime entrypoint: owns tool dispatch and routes to
//! focused adapters under `agent_tools/`. Leaf module — depends on ai_chat_types
//! (ToolContext seam) and ai_chat_protocol/skills, never on ai_chat.zig or
//! Session.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../assistant/conversation/types.zig");
const ai_chat_protocol = @import("../assistant/conversation/protocol.zig");
const first_party_tools = @import("../tools/first_party.zig");
const ToolCall = ai_chat_protocol.ToolCall;
const ToolContext = types.ToolContext;
const ToolSurface = types.ToolSurface;
const ToolSnapshot = types.ToolSnapshot;
const ToolHost = types.ToolHost;
const ToolClosedTab = types.ToolClosedTab;
const SshProfileSaveArgs = types.SshProfileSaveArgs;
const SavedSshProfile = types.SavedSshProfile;
const weixin_types = @import("../weixin/types.zig");
const platform_process = @import("../platform/process.zig");
const tool_args = @import("args.zig");
const agent_research = @import("research.zig");
const knowledge = @import("knowledge.zig");
const agent_memory_tool = @import("memory.zig");
const terminal_tools = @import("terminal.zig");
const agent_sessions = @import("sessions.zig");
const tool_access = @import("access.zig");
const agent_files = @import("files.zig");
const agent_exec = @import("exec.zig");
const agent_dynamic = @import("dynamic.zig");
const agent_weixin = @import("weixin.zig");

// ---------------------------------------------------------------------------
// Tool dispatch
// ---------------------------------------------------------------------------

pub fn executeToolCall(ctx: *ToolContext, call: ToolCall) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    if (first_party_tools.isKnown(call.name) and first_party_tools.isDisabledName(ctx.settings.disabled_first_party_tools, call.name)) {
        return std.fmt.allocPrint(ctx.allocator, "Tool is disabled: {s}", .{call.name});
    }
    if (std.mem.eql(u8, call.name, "terminal_list")) {
        return terminal_tools.list(ctx);
    }
    if (std.mem.eql(u8, call.name, "terminal_context")) {
        return terminal_tools.context(ctx);
    }
    if (std.mem.eql(u8, call.name, "terminal_snapshot")) {
        const args = tool_args.parse(ctx.allocator, call.arguments);
        defer if (args) |parsed| parsed.deinit();
        const surface_id = if (args) |parsed| tool_args.string(parsed.value, "surface_id") else null;
        return terminal_tools.snapshot(ctx, surface_id);
    }
    if (std.mem.eql(u8, call.name, "terminal_select")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = tool_args.string(args.value, "surface_id") orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        return terminal_tools.select(ctx, surface_id);
    }
    if (std.mem.eql(u8, call.name, platform_process.localCommandToolName())) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const command = tool_args.string(args.value, "command") orelse return ctx.allocator.dupe(u8, "Missing command");
        const cwd = tool_args.string(args.value, "cwd");
        const timeout_ms = tool_args.int(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return agent_exec.localCommandExec(ctx, command, cwd, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "ssh_session_exec")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = tool_args.string(args.value, "surface_id") orelse terminal_tools.defaultExecSurfaceId(ctx) orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        const command = tool_args.string(args.value, "command") orelse return ctx.allocator.dupe(u8, "Missing command");
        const timeout_ms = tool_args.int(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return agent_exec.sshSessionExec(ctx, surface_id, command, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "wsl_session_exec")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = tool_args.string(args.value, "surface_id") orelse terminal_tools.defaultExecSurfaceId(ctx) orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        const command = tool_args.string(args.value, "command") orelse return ctx.allocator.dupe(u8, "Missing command");
        const timeout_ms = tool_args.int(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return agent_exec.wslSessionExec(ctx, surface_id, command, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "terminal_repl_exec")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = tool_args.string(args.value, "surface_id") orelse terminal_tools.defaultExecSurfaceId(ctx) orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        const repl = tool_args.string(args.value, "repl") orelse return ctx.allocator.dupe(u8, "Missing repl");
        const code = tool_args.string(args.value, "code") orelse return ctx.allocator.dupe(u8, "Missing code");
        const timeout_ms = tool_args.int(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return agent_exec.terminalReplExec(ctx, surface_id, repl, code, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "terminal_answer_prompt")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = tool_args.string(args.value, "surface_id");
        const answer = tool_args.string(args.value, "answer") orelse return ctx.allocator.dupe(u8, "Missing answer");
        return agent_exec.terminalAnswerPrompt(ctx, surface_id, answer);
    }
    if (std.mem.eql(u8, call.name, "ask_user")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const question = tool_args.string(args.value, "question") orelse return ctx.allocator.dupe(u8, "Missing question");
        var opts_buf: [16]types.QuestionOption = undefined;
        const options = parseAskOptions(args.value, &opts_buf);
        return askUserTool(ctx, question, options);
    }
    if (std.mem.eql(u8, call.name, "ssh_profile_save")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const host = tool_args.string(args.value, "host") orelse return ctx.allocator.dupe(u8, "Missing host");
        const user = tool_args.string(args.value, "user") orelse return ctx.allocator.dupe(u8, "Missing user");
        return agent_sessions.sshProfileSave(ctx, .{
            .name = tool_args.string(args.value, "name") orelse "",
            .host = host,
            .user = user,
            .password = tool_args.string(args.value, "password") orelse "",
            .port = tool_args.string(args.value, "port") orelse "",
            .proxy_jump = tool_args.string(args.value, "proxy_jump") orelse "",
            .auth_method = tool_args.string(args.value, "auth_method") orelse "",
            .identity_file = tool_args.string(args.value, "identity_file") orelse "",
        });
    }
    if (std.mem.eql(u8, call.name, "ssh_profile_connect")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const profile_name = tool_args.string(args.value, "profile_name") orelse return ctx.allocator.dupe(u8, "Missing profile_name");
        return agent_sessions.sshProfileConnect(ctx, profile_name);
    }
    if (std.mem.eql(u8, call.name, "tab_new")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const kind = tool_args.string(args.value, "kind") orelse "default";
        const command = tool_args.string(args.value, "command");
        return agent_sessions.tabNew(ctx, kind, command);
    }
    if (std.mem.eql(u8, call.name, "tab_close")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        var tab_index = tool_args.index(args.value, "tab_index");
        if (tab_index == null) {
            if (tool_args.index(args.value, "tab_number")) |tab_number| {
                if (tab_number > 0) tab_index = tab_number - 1;
            }
        }
        const surface_id = tool_args.string(args.value, "surface_id");
        const title = tool_args.string(args.value, "title");
        return agent_sessions.tabClose(ctx, tab_index, surface_id, title);
    }
    if (std.mem.eql(u8, call.name, "read_file")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const path = tool_args.string(args.value, "path") orelse return ctx.allocator.dupe(u8, "Missing path");
        const surface_id = tool_args.string(args.value, "surface_id");
        const offset = tool_args.index(args.value, "offset") orelse 0;
        const limit = tool_args.index(args.value, "limit") orelse 0;
        return agent_files.readFile(ctx, path, surface_id, offset, limit);
    }
    if (std.mem.eql(u8, call.name, "copy_file")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const source_path = tool_args.string(args.value, "source_path") orelse return ctx.allocator.dupe(u8, "Missing source_path");
        const source_surface_id = tool_args.string(args.value, "source_surface_id");
        const dest_surface_id = tool_args.string(args.value, "dest_surface_id");
        const dest_path = tool_args.string(args.value, "dest_path");
        const dest_name = tool_args.string(args.value, "dest_name");
        return agent_files.copyFile(ctx, source_path, source_surface_id, dest_surface_id, dest_path, dest_name);
    }
    if (std.mem.eql(u8, call.name, "write_file")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const path = tool_args.string(args.value, "path") orelse return ctx.allocator.dupe(u8, "Missing path");
        // content may be empty (truncate to an empty file), so do NOT use
        // jsonStringArg (it rejects ""). Read the raw .string.
        const content = blk: {
            if (args.value != .object) break :blk null;
            const v = args.value.object.get("content") orelse break :blk null;
            break :blk if (v == .string) v.string else null;
        } orelse return ctx.allocator.dupe(u8, "Missing content");
        const surface_id = tool_args.string(args.value, "surface_id");
        return agent_files.writeFile(ctx, path, content, surface_id);
    }
    if (std.mem.eql(u8, call.name, "edit_file")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const path = tool_args.string(args.value, "path") orelse return ctx.allocator.dupe(u8, "Missing path");
        const old_string = tool_args.string(args.value, "old_string") orelse return ctx.allocator.dupe(u8, "Missing old_string");
        // new_string may be empty (deletion), so do NOT use jsonStringArg (it rejects ""). Read the raw .string.
        const new_string = blk: {
            if (args.value != .object) break :blk null;
            const v = args.value.object.get("new_string") orelse break :blk null;
            break :blk if (v == .string) v.string else null;
        } orelse return ctx.allocator.dupe(u8, "Missing new_string");
        const replace_all = tool_args.boolean(args.value, "replace_all") orelse false;
        const surface_id = tool_args.string(args.value, "surface_id");
        return agent_files.editFile(ctx, path, old_string, new_string, replace_all, surface_id);
    }
    if (std.mem.eql(u8, call.name, "skill_info")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const skill_name = tool_args.string(args.value, "skill_name") orelse return ctx.allocator.dupe(u8, "Missing skill_name");
        return knowledge.skillInfo(ctx.allocator, skill_name);
    }
    if (std.mem.eql(u8, call.name, "wispterm_docs")) {
        const args = tool_args.parse(ctx.allocator, call.arguments);
        defer if (args) |parsed| parsed.deinit();
        const topic = if (args) |parsed| tool_args.string(parsed.value, "topic") else null;
        return knowledge.wisptermDocs(ctx.allocator, topic);
    }
    if (std.mem.eql(u8, call.name, "weixin_send_attachment")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const kind_text = tool_args.string(args.value, "kind") orelse return ctx.allocator.dupe(u8, "Missing kind");
        const kind = weixin_types.AttachmentKind.parse(kind_text) orelse return ctx.allocator.dupe(u8, "Invalid kind; expected file, image, or voice");
        const path = tool_args.string(args.value, "path") orelse return ctx.allocator.dupe(u8, "Missing path");
        const display_name = tool_args.string(args.value, "display_name") orelse "";
        return agent_weixin.sendAttachment(ctx, kind, path, display_name);
    }
    if (std.mem.eql(u8, call.name, "websearch")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const query = tool_args.string(args.value, "query") orelse return ctx.allocator.dupe(u8, "Missing query");
        const max_results = tool_args.int(args.value, "max_results");
        return agent_research.webSearch(ctx.allocator, query, max_results);
    }
    if (std.mem.eql(u8, call.name, "webread")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const url = tool_args.string(args.value, "url") orelse return ctx.allocator.dupe(u8, "Missing url");
        return agent_research.webRead(ctx.allocator, url, ctx.settings.working_dir);
    }
    if (std.mem.eql(u8, call.name, "pubmed")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const query = tool_args.string(args.value, "query") orelse return ctx.allocator.dupe(u8, "Missing query");
        const max_results = tool_args.int(args.value, "max_results");
        return agent_research.pubMed(ctx.allocator, query, max_results);
    }
    if (std.mem.startsWith(u8, call.name, "memory_") and !ctx.settings.memory_enabled) {
        return ctx.allocator.dupe(u8, "Memory is disabled (ai-memory-enabled = false).");
    }
    if (std.mem.eql(u8, call.name, "memory_save")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        return agent_memory_tool.save(ctx, args.value);
    }
    if (std.mem.eql(u8, call.name, "memory_recall")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        return agent_memory_tool.recall(ctx, args.value);
    }
    if (std.mem.eql(u8, call.name, "memory_delete")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        return agent_memory_tool.delete(ctx, args.value);
    }
    if (agent_dynamic.find(ctx.settings.dynamic_binary_tools, call.name)) |tool| {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const argv_args = tool_args.stringArray(ctx.allocator, args.value, "args") catch |err| switch (err) {
            error.InvalidToolArguments => return ctx.allocator.dupe(u8, "Invalid tool arguments"),
            else => return err,
        };
        defer tool_args.freeStringArray(ctx.allocator, argv_args);
        const cwd = tool_args.string(args.value, "cwd") orelse ctx.settings.working_dir;
        const timeout_ms = tool_args.int(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return agent_dynamic.run(ctx, tool, argv_args, cwd, timeout_ms);
    }
    return std.fmt.allocPrint(ctx.allocator, "Unknown tool: {s}", .{call.name});
}

/// Extract the `options` array of an ask_user call into `buf`. Each item needs a
/// non-empty string `label`; `description` is optional. The returned slices
/// borrow the parsed JSON (valid for the duration of the tool call). Items past
/// `buf.len`, or with a missing/empty label, are skipped.
fn parseAskOptions(root: std.json.Value, buf: []types.QuestionOption) []const types.QuestionOption {
    if (root != .object) return buf[0..0];
    const value = root.object.get("options") orelse return buf[0..0];
    if (value != .array) return buf[0..0];
    var n: usize = 0;
    for (value.array.items) |item| {
        if (n >= buf.len) break;
        if (item != .object) continue;
        const label_v = item.object.get("label") orelse continue;
        if (label_v != .string or label_v.string.len == 0) continue;
        const description: []const u8 = blk: {
            const d = item.object.get("description") orelse break :blk "";
            if (d != .string) break :blk "";
            break :blk d.string;
        };
        buf[n] = .{ .label = label_v.string, .description = description };
        n += 1;
    }
    return buf[0..n];
}

/// ask_user executor: validate ≥2 options, block on the user via the ToolContext
/// hook, and format the answer as the tool result string. `options` is owned by
/// the caller and stays valid here, so the selected option's label/description
/// are read straight from it after the blocking call returns.
fn askUserTool(ctx: *ToolContext, question: []const u8, options: []const types.QuestionOption) ![]u8 {
    if (options.len < 2) {
        return ctx.allocator.dupe(u8, "ask_user needs at least 2 options.");
    }
    return switch (ctx.askUser(question, options)) {
        .option_index => |i| blk: {
            // i is in range: the Session only resolves a valid option index, and
            // it duped exactly these options, so options[i] is safe.
            const opt = options[i];
            if (opt.description.len != 0) {
                break :blk std.fmt.allocPrint(ctx.allocator, "User selected option {d}: \"{s}\" — {s}", .{ i + 1, opt.label, opt.description });
            }
            break :blk std.fmt.allocPrint(ctx.allocator, "User selected option {d}: \"{s}\"", .{ i + 1, opt.label });
        },
        .custom => |text| std.fmt.allocPrint(ctx.allocator, "User answered (custom): \"{s}\"", .{text}),
        .cancelled => ctx.allocator.dupe(u8, "User did not answer (request cancelled)."),
    };
}

// ---------------------------------------------------------------------------
// SSH profile tools
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// TDD isolation test (proves module compiles without Session/ChatRequest)
// ---------------------------------------------------------------------------

fn fakeApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}
fn fakeCancelled(_: *anyopaque) bool {
    return false;
}

const FakeApprover = struct {
    allowed: bool,
    called: bool = false,

    fn approve(ctx: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
        const self: *FakeApprover = @ptrCast(@alignCast(ctx));
        self.called = true;
        return self.allowed;
    }
};

const FakeAsker = struct {
    result: types.AskResult,
    captured_count: usize = 0,

    fn ask(ctx: *anyopaque, question: []const u8, options: []const types.QuestionOption) types.AskResult {
        const self: *FakeAsker = @ptrCast(@alignCast(ctx));
        _ = question; // borrows the parsed JSON, freed after the call — don't retain
        self.captured_count = options.len;
        return self.result;
    }
};

fn askCtx(asker: *FakeAsker) ToolContext {
    return .{
        .allocator = std.testing.allocator,
        .ctx = asker,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
        .ask = FakeAsker.ask,
    };
}

fn askCall() ToolCall {
    return .{
        .id = @constCast("c1"),
        .name = @constCast("ask_user"),
        .arguments = @constCast(
            \\{"question":"Which DB?","options":[{"label":"Postgres"},{"label":"SQLite","description":"local dev"}]}
        ),
    };
}

test "ask_user tool formats the selected option with its label and description" {
    var asker = FakeAsker{ .result = .{ .option_index = 1 } };
    var ctx = askCtx(&asker);
    const out = try executeToolCall(&ctx, askCall());
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "option 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SQLite") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "local dev") != null);
    try std.testing.expectEqual(@as(usize, 2), asker.captured_count);
}

test "ask_user tool formats a free-text custom answer" {
    var asker = FakeAsker{ .result = .{ .custom = "用 DuckDB" } };
    var ctx = askCtx(&asker);
    const out = try executeToolCall(&ctx, askCall());
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "custom") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "用 DuckDB") != null);
}

test "ask_user tool reports cancellation" {
    var asker = FakeAsker{ .result = .cancelled };
    var ctx = askCtx(&asker);
    const out = try executeToolCall(&ctx, askCall());
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "cancel") != null);
}

test "ask_user tool rejects fewer than two options without asking" {
    var asker = FakeAsker{ .result = .{ .option_index = 0 } };
    var ctx = askCtx(&asker);
    const call = ToolCall{
        .id = @constCast("c1"),
        .name = @constCast("ask_user"),
        .arguments = @constCast(
            \\{"question":"Only one?","options":[{"label":"A"}]}
        ),
    };
    const out = try executeToolCall(&ctx, call);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "at least 2") != null);
    try std.testing.expectEqual(@as(usize, 0), asker.captured_count); // ask hook never called
}

test "executeToolCall rejects disabled first-party webread before validating args" {
    const disabled = [_][]const u8{"webread"};
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = std.testing.allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{
            .disabled_first_party_tools = disabled[0..],
        },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const out = try executeToolCall(&ctx, .{
        .id = @constCast("c1"),
        .name = @constCast("webread"),
        .arguments = @constCast("not-json"),
    });
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings("Tool is disabled: webread", out);
}

test "executeToolCall does not treat disabled dynamic names as first-party tools" {
    const disabled = [_][]const u8{"project_dynamic_tool"};
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = std.testing.allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{
            .disabled_first_party_tools = disabled[0..],
        },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const out = try executeToolCall(&ctx, .{
        .id = @constCast("c1"),
        .name = @constCast("project_dynamic_tool"),
        .arguments = @constCast("{}"),
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "Unknown tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Tool is disabled") == null);
}

test "executeToolCall dispatches enabled binary tool by argv" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    const executable = if (builtin.os.tag == .windows) "cmd.exe" else "/bin/echo";
    const arguments = if (builtin.os.tag == .windows)
        "{\"args\":[\"/C\",\"echo\",\"hello\",\"world\"]}"
    else
        "{\"args\":[\"hello\",\"world\"]}";
    const tools = [_]types.DynamicBinaryTool{.{
        .function_name = "fake_tool",
        .executable_abs = executable,
        .description = "Echo test",
    }};
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{
            .permission = .full,
            .working_dir = null,
            .dynamic_binary_tools = tools[0..],
        },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try executeToolCall(&ctx, .{
        .id = @constCast("1"),
        .name = @constCast("fake_tool"),
        .arguments = @constCast(arguments),
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Unknown tool") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "world") != null);
}

test "executeToolCall asks before binary tool in auto mode" {
    var asker = FakeApprover{ .allowed = false };
    const tools = [_]types.DynamicBinaryTool{.{
        .function_name = "fake_tool",
        .executable_abs = "/bin/echo",
        .description = "Echo",
    }};
    var ctx = ToolContext{
        .allocator = std.testing.allocator,
        .ctx = &asker,
        .settings = .{
            .permission = .auto,
            .dynamic_binary_tools = tools[0..],
        },
        .tool_host = null,
        .tool_snapshot = null,
        .approve = FakeApprover.approve,
        .cancelled = fakeCancelled,
    };
    const out = try executeToolCall(&ctx, .{
        .id = @constCast("1"),
        .name = @constCast("fake_tool"),
        .arguments = @constCast("{\"args\":[\"hi\"]}"),
    });
    defer std.testing.allocator.free(out);
    try std.testing.expect(asker.called);
    try std.testing.expect(std.mem.indexOf(u8, out, "denied") != null);
}

test "executeToolCall reports invalid dynamic binary tool args as a tool result" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    const tools = [_]types.DynamicBinaryTool{.{
        .function_name = "fake_tool",
        .executable_abs = "/bin/echo",
        .description = "Echo test",
    }};
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{
            .permission = .full,
            .dynamic_binary_tools = tools[0..],
        },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try executeToolCall(&ctx, .{
        .id = @constCast("1"),
        .name = @constCast("fake_tool"),
        .arguments = @constCast("{\"args\":\"not-array\"}"),
    });
    defer a.free(out);
    try std.testing.expectEqualStrings("Invalid tool arguments", out);
}

fn twoSurfaceSnapshotForTest(allocator: std.mem.Allocator) !ToolSnapshot {
    var surfaces = try allocator.alloc(ToolSurface, 2);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "aaa"),
        .title = try allocator.dupe(u8, "shell"),
        .cwd = try allocator.dupe(u8, "/"),
        .snapshot = try allocator.dupe(u8, "$ "),
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
        .id = try allocator.dupe(u8, "bbb"),
        .title = try allocator.dupe(u8, "codex"),
        .cwd = try allocator.dupe(u8, "/"),
        .snapshot = try allocator.dupe(u8, "› "),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .codex,
        .agent_state = .none,
        .agent_confidence = 50,
        .ptr = @ptrFromInt(2),
    };
    return .{ .surfaces = surfaces, .active_tab = 0 };
}

test "terminal_context reports the selected write context" {
    const allocator = std.testing.allocator;
    const cached = try twoSurfaceSnapshotForTest(allocator);
    defer cached.deinit(allocator);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = cached,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    terminal_tools.setWriteContext(&ctx, "aaa");
    const call = ToolCall{ .id = @constCast("c1"), .name = @constCast("terminal_context"), .arguments = @constCast("{}") };

    const out = try executeToolCall(&ctx, call);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "selected surface_id=aaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tab=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "focused=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "title=\"shell\"") != null);
    try std.testing.expectEqualStrings("aaa", ctx.write_context_surface_id[0..ctx.write_context_surface_id_len]);
}

test "terminal_context reports no selected write context" {
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
    };
    const call = ToolCall{ .id = @constCast("c1"), .name = @constCast("terminal_context"), .arguments = @constCast("{}") };

    const out = try executeToolCall(&ctx, call);
    defer allocator.free(out);

    try std.testing.expectEqualStrings("No terminal context is selected.", out);
}

test "terminal_context reports a stale selected write context" {
    const allocator = std.testing.allocator;
    const cached = try twoSurfaceSnapshotForTest(allocator);
    defer cached.deinit(allocator);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = cached,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    terminal_tools.setWriteContext(&ctx, "closed-surface");
    const call = ToolCall{ .id = @constCast("c1"), .name = @constCast("terminal_context"), .arguments = @constCast("{}") };

    const out = try executeToolCall(&ctx, call);
    defer allocator.free(out);

    try std.testing.expectEqualStrings("Selected terminal context surface_id=closed-surface is no longer open.", out);
    try std.testing.expectEqualStrings("closed-surface", ctx.write_context_surface_id[0..ctx.write_context_surface_id_len]);
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

test "remoteFileGate: writes force approval, reads do not" {
    try std.testing.expect(tool_access.remoteFileGate(true).force);
    try std.testing.expect(!tool_access.remoteFileGate(false).force);
    try std.testing.expect(tool_access.remoteFileGate(false).skip);
}

test "fileAccessGate: read of a normal path does not force approval" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .confirm, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const gate = tool_access.fileGate(&ctx, "/work/readme.txt", false);
    try std.testing.expect(!gate.force);
    try std.testing.expect(gate.skip);
}

test "fileAccessGate: write outside the working dir forces approval" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .confirm, .access_rules = null, .working_dir = "/home/u/proj" },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const gate = tool_access.fileGate(&ctx, "/etc/hosts", true);
    try std.testing.expect(gate.force); // risky: absolute path outside working dir
    try std.testing.expect(!gate.skip);
}

test "copy_file copies a local artifact into wispterm-files by default" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "source.bin", .data = "artifact-bytes" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null, .working_dir = root },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try executeToolCall(&ctx, .{
        .id = @constCast("call-copy"),
        .name = @constCast("copy_file"),
        .arguments = @constCast("{\"source_path\":\"source.bin\",\"dest_name\":\"copied.bin\"}"),
    });
    defer a.free(out);

    const copied = try tmp.dir.readFileAlloc(a, "wispterm-files/copied.bin", 1024);
    defer a.free(copied);
    try std.testing.expectEqualStrings("artifact-bytes", copied);
    try std.testing.expect(std.mem.indexOf(u8, out, "local_path=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "wispterm-files") != null);
}

test "executeToolCall handles memory_save and memory_recall" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const dirs_mod = @import("../platform/dirs.zig");
    dirs_mod.setTestConfigDirForCurrentThread(root);
    defer dirs_mod.clearTestConfigDirForCurrentThread();

    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .memory_enabled = true },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const save = try executeToolCall(&ctx, .{
        .id = @constCast("1"),
        .name = @constCast("memory_save"),
        .arguments = @constCast("{\"tier\":\"global\",\"name\":\"t1\",\"description\":\"d1\",\"body\":\"b1\"}"),
    });
    defer a.free(save);
    try std.testing.expect(std.mem.indexOf(u8, save, "t1") != null);

    const recall = try executeToolCall(&ctx, .{
        .id = @constCast("2"),
        .name = @constCast("memory_recall"),
        .arguments = @constCast("{\"name\":\"t1\"}"),
    });
    defer a.free(recall);
    try std.testing.expect(std.mem.indexOf(u8, recall, "b1") != null);
}

test "executeToolCall reports memory disabled when ai-memory-enabled is off" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{}, // memory_enabled defaults to false
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try executeToolCall(&ctx, .{
        .id = @constCast("1"),
        .name = @constCast("memory_save"),
        .arguments = @constCast("{\"tier\":\"global\",\"name\":\"t1\",\"description\":\"d1\",\"body\":\"b1\"}"),
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "disabled") != null);
}

test "terminal_snapshot keeps the live screen tail when output exceeds the limit" {
    const a = std.testing.allocator;
    // A long screen whose only prompt marker is at the very bottom.
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(a);
    var i: usize = 0;
    while (i < 2000) : (i += 1) try big.appendSlice(a, "old scrollback line\n");
    try big.appendSlice(a, "Do you want to proceed? PROMPT_AT_BOTTOM");

    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 0, .settled_text = big.items };
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
        .settings = .{ .output_limit = 4096 },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    // Free only the slice we allocated; the surface string fields are literals,
    // so do NOT call snap.deinit (it would free static memory). The tool operates
    // on a clone internally, so the literal-backed originals are never freed.
    defer if (ctx.tool_snapshot) |snap| a.free(snap.surfaces);

    const result = try terminal_tools.snapshot(&ctx, @as(?[]const u8, "surface-claude"));
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "PROMPT_AT_BOTTOM") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "older output truncated") != null);
}

test "executeToolCall pubmed reports missing query" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try executeToolCall(&ctx, .{
        .id = @constCast("1"),
        .name = @constCast("pubmed"),
        .arguments = @constCast("{}"),
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Missing query") != null);
}
