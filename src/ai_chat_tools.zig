//! Session-free agent tool layer: tool dispatch and every tool implementation,
//! shell/argv runners, REPL handling, dangerous-command detection, and write/
//! copilot context. Leaf module — depends on ai_chat_types (ToolContext seam)
//! and ai_chat_protocol/skills, never on ai_chat.zig or Session.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("ai_chat_types.zig");
const agent_file_edit = @import("agent_file_edit.zig");
const agent_file_copy = @import("agent_file_copy.zig");
const platform_atomic_file = @import("platform/atomic_file.zig");
const scp = @import("scp.zig");
const ToolSshConnection = types.SshConnection;
const ai_chat_protocol = @import("ai_chat_protocol.zig");
const first_party_tools = @import("tools/first_party.zig");
const ToolCall = ai_chat_protocol.ToolCall;
const ToolContext = types.ToolContext;
const ToolSurface = types.ToolSurface;
const ToolSnapshot = types.ToolSnapshot;
const ToolHost = types.ToolHost;
const ToolClosedTab = types.ToolClosedTab;
const SshProfileSaveArgs = types.SshProfileSaveArgs;
const SavedSshProfile = types.SavedSshProfile;
const AgentSettings = types.AgentSettings;
const AgentPermission = types.AgentPermission;
const agent_detector = @import("agent_detector.zig");
const agent_prompt_answer = @import("agent_prompt_answer.zig");
const weixin_types = @import("weixin/types.zig");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const platform_wsl = @import("platform/wsl.zig");
const platform_agent_prompt = @import("platform/agent_prompt.zig");
const ai_agent_access = @import("ai_agent_access.zig");
const tool_args = @import("agent_tools/args.zig");
const agent_research = @import("agent_tools/research.zig");
const knowledge = @import("agent_tools/knowledge.zig");
const agent_memory = @import("agent_memory.zig");

/// Number of output lines included in a copilot context block.
pub const COPILOT_CONTEXT_LINES: usize = 40;

// ---------------------------------------------------------------------------
// Tool dispatch
// ---------------------------------------------------------------------------

pub fn executeToolCall(ctx: *ToolContext, call: ToolCall) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    if (first_party_tools.isKnown(call.name) and first_party_tools.isDisabledName(ctx.settings.disabled_first_party_tools, call.name)) {
        return std.fmt.allocPrint(ctx.allocator, "Tool is disabled: {s}", .{call.name});
    }
    if (std.mem.eql(u8, call.name, "terminal_list")) {
        return terminalListTool(ctx);
    }
    if (std.mem.eql(u8, call.name, "terminal_context")) {
        return terminalContextTool(ctx);
    }
    if (std.mem.eql(u8, call.name, "terminal_snapshot")) {
        const args = tool_args.parse(ctx.allocator, call.arguments);
        defer if (args) |parsed| parsed.deinit();
        const surface_id = if (args) |parsed| tool_args.string(parsed.value, "surface_id") else null;
        return terminalSnapshotTool(ctx, surface_id);
    }
    if (std.mem.eql(u8, call.name, "terminal_select")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = tool_args.string(args.value, "surface_id") orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        return terminalSelectTool(ctx, surface_id);
    }
    if (std.mem.eql(u8, call.name, platform_process.localCommandToolName())) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const command = tool_args.string(args.value, "command") orelse return ctx.allocator.dupe(u8, "Missing command");
        const cwd = tool_args.string(args.value, "cwd");
        const timeout_ms = tool_args.int(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return localCommandExecTool(ctx, command, cwd, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "ssh_session_exec")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = tool_args.string(args.value, "surface_id") orelse defaultExecSurfaceId(ctx) orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        const command = tool_args.string(args.value, "command") orelse return ctx.allocator.dupe(u8, "Missing command");
        const timeout_ms = tool_args.int(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return sshSessionExecTool(ctx, surface_id, command, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "wsl_session_exec")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = tool_args.string(args.value, "surface_id") orelse defaultExecSurfaceId(ctx) orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        const command = tool_args.string(args.value, "command") orelse return ctx.allocator.dupe(u8, "Missing command");
        const timeout_ms = tool_args.int(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return wslSessionExecTool(ctx, surface_id, command, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "terminal_repl_exec")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = tool_args.string(args.value, "surface_id") orelse defaultExecSurfaceId(ctx) orelse return ctx.allocator.dupe(u8, "Missing surface_id");
        const repl = tool_args.string(args.value, "repl") orelse return ctx.allocator.dupe(u8, "Missing repl");
        const code = tool_args.string(args.value, "code") orelse return ctx.allocator.dupe(u8, "Missing code");
        const timeout_ms = tool_args.int(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return terminalReplExecTool(ctx, surface_id, repl, code, timeout_ms);
    }
    if (std.mem.eql(u8, call.name, "terminal_answer_prompt")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const surface_id = tool_args.string(args.value, "surface_id");
        const answer = tool_args.string(args.value, "answer") orelse return ctx.allocator.dupe(u8, "Missing answer");
        return terminalAnswerPromptTool(ctx, surface_id, answer);
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
        return sshProfileSaveTool(ctx, .{
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
        return sshProfileConnectTool(ctx, profile_name);
    }
    if (std.mem.eql(u8, call.name, "tab_new")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const kind = tool_args.string(args.value, "kind") orelse "default";
        const command = tool_args.string(args.value, "command");
        return tabNewTool(ctx, kind, command);
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
        return tabCloseTool(ctx, tab_index, surface_id, title);
    }
    if (std.mem.eql(u8, call.name, "read_file")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const path = tool_args.string(args.value, "path") orelse return ctx.allocator.dupe(u8, "Missing path");
        const surface_id = tool_args.string(args.value, "surface_id");
        const offset = tool_args.index(args.value, "offset") orelse 0;
        const limit = tool_args.index(args.value, "limit") orelse 0;
        return readFileTool(ctx, path, surface_id, offset, limit);
    }
    if (std.mem.eql(u8, call.name, "copy_file")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const source_path = tool_args.string(args.value, "source_path") orelse return ctx.allocator.dupe(u8, "Missing source_path");
        const source_surface_id = tool_args.string(args.value, "source_surface_id");
        const dest_surface_id = tool_args.string(args.value, "dest_surface_id");
        const dest_path = tool_args.string(args.value, "dest_path");
        const dest_name = tool_args.string(args.value, "dest_name");
        return copyFileTool(ctx, source_path, source_surface_id, dest_surface_id, dest_path, dest_name);
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
        return writeFileTool(ctx, path, content, surface_id);
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
        return editFileTool(ctx, path, old_string, new_string, replace_all, surface_id);
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
        return weixinSendAttachmentTool(ctx, kind, path, display_name);
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
        const name = tool_args.string(args.value, "name") orelse return ctx.allocator.dupe(u8, "Missing name");
        const description = tool_args.string(args.value, "description") orelse return ctx.allocator.dupe(u8, "Missing description");
        const body = blk: {
            if (args.value != .object) break :blk null;
            const v = args.value.object.get("body") orelse break :blk null;
            break :blk if (v == .string) v.string else null;
        } orelse return ctx.allocator.dupe(u8, "Missing body");
        const tier_text = tool_args.string(args.value, "tier") orelse "global";
        const tier: agent_memory.Tier = if (std.mem.eql(u8, tier_text, "project")) .project else .global;
        const type_ = agent_memory.MemoryType.fromString(tool_args.string(args.value, "type") orelse "user");
        return agent_memory.saveMemory(ctx.allocator, tier, ctx.settings.working_dir, name, description, type_, body);
    }
    if (std.mem.eql(u8, call.name, "memory_recall")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const name = tool_args.string(args.value, "name") orelse return ctx.allocator.dupe(u8, "Missing name");
        return agent_memory.recallMemory(ctx.allocator, ctx.settings.working_dir orelse "", name);
    }
    if (std.mem.eql(u8, call.name, "memory_delete")) {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const name = tool_args.string(args.value, "name") orelse return ctx.allocator.dupe(u8, "Missing name");
        const tier_opt: ?agent_memory.Tier = if (tool_args.string(args.value, "tier")) |t|
            (if (std.mem.eql(u8, t, "project")) .project else if (std.mem.eql(u8, t, "global")) .global else null)
        else
            null;
        return agent_memory.deleteMemory(ctx.allocator, ctx.settings.working_dir orelse "", name, tier_opt);
    }
    if (findDynamicBinaryTool(ctx.settings.dynamic_binary_tools, call.name)) |tool| {
        const args = tool_args.parse(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const argv_args = tool_args.stringArray(ctx.allocator, args.value, "args") catch |err| switch (err) {
            error.InvalidToolArguments => return ctx.allocator.dupe(u8, "Invalid tool arguments"),
            else => return err,
        };
        defer tool_args.freeStringArray(ctx.allocator, argv_args);
        const cwd = tool_args.string(args.value, "cwd") orelse ctx.settings.working_dir;
        const timeout_ms = tool_args.int(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return dynamicBinaryTool(ctx, tool, argv_args, cwd, timeout_ms);
    }
    return std.fmt.allocPrint(ctx.allocator, "Unknown tool: {s}", .{call.name});
}

fn findDynamicBinaryTool(tools: []const types.DynamicBinaryTool, name: []const u8) ?types.DynamicBinaryTool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.function_name, name)) return tool;
    }
    return null;
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
    // Sending an attachment reads the file off disk and uploads it to a remote
    // user, so a protected path here is an exfiltration risk. In auto mode,
    // protected paths still require approval; full mode intentionally bypasses
    // this guard.
    if (ctx.settings.access_rules) |rules| {
        if (ai_agent_access.isPathDenied(ctx.allocator, rules, path, null)) {
            const gate = AccessGate{ .dangerous = false, .blacklisted = true, .force = true, .skip = false, .matched = path };
            if (approvalRequiredForGate(ctx.settings.permission, gate)) {
                const bl_reason = allocBlacklistReason(ctx.allocator, path);
                defer if (bl_reason) |r| ctx.allocator.free(r);
                const reason = bl_reason orelse "Sends a protected file — confirm to allow";
                if (!ctx.requestApproval("weixin_send_attachment", path, reason)) {
                    return deniedResult(ctx.allocator, path, "operator rejected sending a protected file");
                }
            }
        }
    }
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

fn terminalContextTool(ctx: *const ToolContext) ![]u8 {
    const selected = selectedWriteContext(ctx) orelse return ctx.allocator.dupe(u8, "No terminal context is selected.");
    const snapshot = collectToolSnapshot(ctx) catch {
        return std.fmt.allocPrint(ctx.allocator, "Selected terminal context surface_id={s}; terminal snapshot host unavailable.", .{selected});
    };
    defer snapshot.deinit(ctx.allocator);
    const surface = findSurface(snapshot, selected) orelse {
        return std.fmt.allocPrint(ctx.allocator, "Selected terminal context surface_id={s} is no longer open.", .{selected});
    };
    if (surface.agent_app != .none) {
        return std.fmt.allocPrint(
            ctx.allocator,
            "selected surface_id={s} tab={d} focused={} kind={s} title=\"{s}\" cwd=\"{s}\" agent={s}:{s} confidence={d}",
            .{
                surface.id,
                surface.tab_index + 1,
                surface.focused,
                toolSurfaceKind(surface),
                surface.title,
                surface.cwd,
                surface.agent_app.label(),
                surface.agent_state.label(),
                surface.agent_confidence,
            },
        );
    }
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

    // Resolve a focused-surface alias (focused/active/current/empty) to a
    // concrete id so the filter below matches the focused terminal.
    var target_id = surface_id;
    if (surface_id) |sid| {
        if (resolveSurfaceId(snapshot, sid, selectedWriteContext(ctx))) |s| target_id = s.id;
    }

    for (snapshot.surfaces) |surface| {
        if (target_id) |id| {
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

        // For a specifically targeted surface, read the LIVE screen via the
        // per-surface snapshot (mutex-protected, works on the worker thread)
        // rather than the request-start pre-capture, which goes stale mid-turn.
        var live: ?[]u8 = null;
        defer if (live) |t| ctx.allocator.free(t);
        if (target_id != null) {
            if (ctx.tool_host) |host| {
                live = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch null;
            }
        }
        try out.appendSlice(ctx.allocator, live orelse surface.snapshot);
        try out.appendSlice(ctx.allocator, "\n---\n");
    }
    if (out.items.len == 0) {
        if (surface_id) |sid| return allocNoSurfaceError(ctx.allocator, snapshot, sid);
        try out.appendSlice(ctx.allocator, "No matching terminal surface.");
    }
    return truncateTailOwned(ctx.allocator, ctx.settings, try out.toOwnedSlice(ctx.allocator));
}

fn terminalSelectTool(ctx: *ToolContext, surface_id: []const u8) ![]u8 {
    const snapshot = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const surface = resolveSurfaceId(snapshot, surface_id, selectedWriteContext(ctx)) orelse return allocNoSurfaceError(ctx.allocator, snapshot, surface_id);
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

const AccessGate = struct {
    dangerous: bool,
    blacklisted: bool,
    force: bool,
    skip: bool,
    matched: []const u8,
};

/// Combine the destructive-command check with the private file-access guard.
/// `force` => guarded auto mode must prompt; `skip` => ask mode may run without
/// a prompt.
fn accessGate(ctx: *const ToolContext, command: []const u8, cwd: ?[]const u8) AccessGate {
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

fn approvalRequiredForGate(permission: AgentPermission, gate: AccessGate) bool {
    return switch (permission) {
        .confirm => !gate.skip,
        .auto => gate.force,
        .full => false,
    };
}

/// Gate a local file path. Reads only check the deny-list; writes additionally
/// flag paths outside the working dir as risky (force). `working_dir` is the
/// effective cwd for resolving relatives. Reuses the command guard's semantics
/// via the shared AccessGate shape so approvalRequiredForGate maps the same way.
fn fileAccessGate(ctx: *const ToolContext, path: []const u8, is_write: bool) AccessGate {
    const rules = ctx.settings.access_rules;
    const denied = if (rules) |r| ai_agent_access.isPathDenied(ctx.allocator, r, path, ctx.settings.working_dir) else false;
    const home = if (rules) |r| r.home else "";
    const confined = blk: {
        const wd = ctx.settings.working_dir orelse break :blk false;
        break :blk ai_agent_access.pathConfined(ctx.allocator, path, wd, wd, home);
    };
    const risky = is_write and !confined;
    return .{
        .dangerous = risky,
        .blacklisted = denied,
        .force = denied or risky,
        .skip = if (is_write) (confined and !denied) else !denied,
        .matched = if (denied) path else "",
    };
}

/// Gate a remote file op: reads never prompt; writes are risky-by-default
/// (cannot confine-check a remote path) so they prompt unless permission=full.
fn remoteFileGate(is_write: bool) AccessGate {
    return .{
        .dangerous = is_write,
        .blacklisted = false,
        .force = is_write,
        .skip = !is_write,
        .matched = "",
    };
}

/// Allocate a human-readable approval reason naming the protected path. Returns
/// null on OOM (callers fall back to a static reason).
fn allocBlacklistReason(allocator: std.mem.Allocator, matched: []const u8) ?[]u8 {
    return std.fmt.allocPrint(allocator, "Reads protected path \"{s}\" — confirm to allow", .{matched}) catch null;
}

fn localCommandExecTool(ctx: *const ToolContext, command: []const u8, cwd: ?[]const u8, timeout_ms: u32) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const effective_cwd = cwd orelse ctx.settings.working_dir;
    const gate = accessGate(ctx, command, effective_cwd);
    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        const bl_reason = if (gate.blacklisted) allocBlacklistReason(ctx.allocator, gate.matched) else null;
        defer if (bl_reason) |r| ctx.allocator.free(r);
        const reason = bl_reason orelse if (gate.dangerous) DANGEROUS_COMMAND_APPROVAL_REASON else platform_process.localCommandApprovalLabel();
        if (!ctx.requestApproval(platform_process.localCommandToolName(), command, reason)) {
            return deniedResult(ctx.allocator, command, platform_process.localCommandDeniedReason());
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
    return truncateOwned(ctx.allocator, ctx.settings, try out.toOwnedSlice(ctx.allocator));
}

fn dynamicBinaryTool(ctx: *ToolContext, tool: types.DynamicBinaryTool, args: []const []const u8, cwd: ?[]const u8, timeout_ms: u32) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    var approval_text = std.ArrayListUnmanaged(u8).empty;
    defer approval_text.deinit(ctx.allocator);
    try approval_text.appendSlice(ctx.allocator, tool.function_name);
    for (args) |arg| {
        try approval_text.append(ctx.allocator, ' ');
        try approval_text.appendSlice(ctx.allocator, arg);
    }

    switch (ctx.settings.permission) {
        .confirm, .auto => {
            if (!ctx.requestApproval(tool.function_name, approval_text.items, "Run installed binary tool")) {
                return deniedResult(ctx.allocator, approval_text.items, "operator denied binary tool execution");
            }
        },
        .full => {},
    }

    const argv = try ctx.allocator.alloc([]const u8, args.len + 1);
    defer ctx.allocator.free(argv);
    argv[0] = tool.executable_abs;
    for (args, 0..) |arg, i| argv[i + 1] = arg;

    const result = runArgv(ctx.allocator, argv, cwd, ctx.settings.output_limit, timeout_ms, ctx) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Binary tool {s} failed: {}", .{ tool.function_name, err });
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
    return truncateTailOwned(ctx.allocator, ctx.settings, out);
}

fn terminalReplExecTool(ctx: *ToolContext, surface_id: []const u8, repl_name: []const u8, code: []const u8, timeout_ms: u32) ![]u8 {
    const repl = ReplKind.parse(repl_name) orelse return std.fmt.allocPrint(ctx.allocator, "Unsupported repl \"{s}\". Use r, python, codex, claude_code, or plain.", .{repl_name});
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const control = controlKeyByte(code);
    const gate = accessGate(ctx, code, null);
    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        var reason_buf: [96]u8 = undefined;
        const bl_reason = if (gate.blacklisted) allocBlacklistReason(ctx.allocator, gate.matched) else null;
        defer if (bl_reason) |r| ctx.allocator.free(r);
        const reason = bl_reason orelse if (gate.dangerous)
            DANGEROUS_COMMAND_APPROVAL_REASON
        else if (control != null)
            std.fmt.bufPrint(&reason_buf, "Send control key {s} to terminal", .{std.mem.trim(u8, code, " \t\r\n")}) catch "Send control key to terminal"
        else
            std.fmt.bufPrint(&reason_buf, "Type input into opened {s} REPL/app terminal", .{repl.label()}) catch "Type input into terminal";
        if (!ctx.requestApproval("terminal_repl_exec", code, reason)) {
            return deniedResult(ctx.allocator, code, "operator rejected REPL terminal input");
        }
    }

    const snapshot = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    const surface = resolveSurfaceId(snapshot, surface_id, selectedWriteContext(ctx)) orelse return allocNoSurfaceError(ctx.allocator, snapshot, surface_id);
    if (try ensureWriteContext(ctx, surface)) |message| return message;

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
fn terminalAnswerPromptTool(ctx: *ToolContext, surface_id: ?[]const u8, answer: []const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const intent = agent_prompt_answer.parseIntent(answer) orelse
        return std.fmt.allocPrint(ctx.allocator, "Unknown answer \"{s}\". Use approve, approve_all, reject, enter, esc, or a digit 1-9.", .{answer});
    const option_number: u8 = if (intent == .option) (agent_prompt_answer.parseOptionNumber(answer) orelse 0) else 0;

    const snapshot = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    const sid = surface_id orelse "focused";
    const surface = resolveSurfaceId(snapshot, sid, selectedWriteContext(ctx)) orelse return allocNoSurfaceError(ctx.allocator, snapshot, sid);

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
        return truncateTailOwned(ctx.allocator, ctx.settings, out);
    }

    var options_buf: [12]agent_prompt_answer.Option = undefined;
    const n = agent_prompt_answer.parsePromptOptions(screen, &options_buf);
    const keystroke = agent_prompt_answer.resolveAnswer(options_buf[0..n], screen, intent, option_number) orelse {
        const out = try allocPromptOptionsHint(ctx.allocator, options_buf[0..n], screen);
        return truncateTailOwned(ctx.allocator, ctx.settings, out);
    };

    // Approval gate mirrors terminal_repl_exec: the payload is a single selector
    // key, not a destructive command, so auto runs it and confirm prompts. Note
    // the gate sees only the keystroke, not the command the agent app would run
    // on confirmation — like terminal_repl_exec control keys, the app's own
    // approval prompt is the real boundary for that command.
    const gate = accessGate(ctx, keystroke.bytes, null);
    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        if (!ctx.requestApproval("terminal_answer_prompt", answer, "Answer a Claude Code/Codex approval prompt")) {
            return deniedResult(ctx.allocator, answer, "operator rejected prompt answer");
        }
    }

    // Bind the agent write context to the resolved surface we are answering on
    // (mirrors terminal_select). This is the explicitly-targeted prompt surface,
    // so it is safe — and it avoids ensureWriteContext refusing when nothing is
    // pre-selected (e.g. a non-copilot caller).
    setWriteContext(ctx, surface.id);

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
    return truncateTailOwned(ctx.allocator, ctx.settings, out);
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
    return truncateTailOwned(allocator, settings, try out.toOwnedSlice(allocator));
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
    // the pre-capture comment in ai_chat.zig), which previously left this wait
    // blind and spinning to the full timeout while the model saw a stale screen.
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
            return truncateOwned(ctx.allocator, ctx.settings, try ctx.allocator.dupe(u8, last_text));
        }
    }

    const note = try std.fmt.allocPrint(
        ctx.allocator,
        "\n[{s} REPL still busy after {d} ms; treat this as in progress, not a final result]",
        .{ repl.label(), wait_ms },
    );
    defer ctx.allocator.free(note);
    const combined = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ last_text, note });
    return truncateOwned(ctx.allocator, ctx.settings, combined);
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
    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        var reason_buf: [64]u8 = undefined;
        const bl_reason = if (gate.blacklisted) allocBlacklistReason(ctx.allocator, gate.matched) else null;
        defer if (bl_reason) |r| ctx.allocator.free(r);
        const reason = bl_reason orelse if (gate.dangerous)
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
    const surface = resolveSurfaceId(snapshot, surface_id, selectedWriteContext(ctx)) orelse return allocNoSurfaceError(ctx.allocator, snapshot, surface_id);
    if (try ensureWriteContext(ctx, surface)) |message| return message;
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
            return std.fmt.allocPrint(ctx.allocator, "A previous command is still running in this {s} terminal. Do not start another command. Wait and re-check with terminal_snapshot, or interrupt it first with terminal_repl_exec repl=plain code=<ctrl-c>.", .{kind.label()});
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
fn allocStillRunningTimeout(allocator: std.mem.Allocator, label: []const u8, elapsed_s: i64, snapshot: ?[]const u8) ![]u8 {
    if (snapshot) |text| {
        return std.fmt.allocPrint(allocator, "The {s} command has not returned after {d}s; it is most likely still running. Do NOT re-issue it. Re-check later with terminal_snapshot, or interrupt with terminal_repl_exec repl=plain code=<ctrl-c>.\nLatest snapshot:\n{s}", .{ label, elapsed_s, text });
    }
    return std.fmt.allocPrint(allocator, "The {s} command has not returned after {d}s; it is most likely still running. Do NOT re-issue it. Re-check later with terminal_snapshot, or interrupt with terminal_repl_exec repl=plain code=<ctrl-c>.", .{ label, elapsed_s });
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

// ---------------------------------------------------------------------------
// SSH profile tools
// ---------------------------------------------------------------------------

pub fn sshProfileSaveApprovalText(allocator: std.mem.Allocator, args: SshProfileSaveArgs) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "name=\"{s}\" host=\"{s}\" user=\"{s}\" port=\"{s}\" proxy_jump=\"{s}\" auth_method=\"{s}\" identity_file=\"{s}\" password={s}",
        .{
            if (args.name.len > 0) args.name else "<default>",
            args.host,
            args.user,
            if (args.port.len > 0) args.port else "22",
            if (args.proxy_jump.len > 0) args.proxy_jump else "<none>",
            if (args.auth_method.len > 0) args.auth_method else "<auto>",
            if (args.identity_file.len > 0) args.identity_file else "<none>",
            if (args.password.len > 0) "<redacted>" else "<empty>",
        },
    );
}

fn sshProfileSaveTool(ctx: *ToolContext, args: SshProfileSaveArgs) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const approval_text = try sshProfileSaveApprovalText(ctx.allocator, args);
    defer ctx.allocator.free(approval_text);
    if (ctx.settings.permission == .confirm) {
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
        "saved profile=\"{s}\" host=\"{s}\" user=\"{s}\" port=\"{s}\" auth_method=\"{s}\" updated_existing={} password_saved={} identity_file_saved={}. Use ssh_profile_connect with profile_name=\"{s}\" to open it.",
        .{
            saved.name,
            saved.host,
            saved.user,
            saved.port,
            saved.auth_method,
            saved.updated_existing,
            saved.password_saved,
            saved.identity_file_saved,
            saved.name,
        },
    );
    return truncateOwned(ctx.allocator, ctx.settings, out);
}

fn sshProfileConnectTool(ctx: *ToolContext, profile_name: []const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    if (ctx.settings.permission == .confirm) {
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
    if (ctx.settings.permission == .confirm) {
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

    if (ctx.settings.permission == .confirm) {
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

/// Sentinel surface ids that mean "the terminal the user is looking at".
fn isFocusedSurfaceAlias(surface_id: []const u8) bool {
    const t = std.mem.trim(u8, surface_id, " \t\r\n");
    return t.len == 0 or
        std.ascii.eqlIgnoreCase(t, "focused") or
        std.ascii.eqlIgnoreCase(t, "active") or
        std.ascii.eqlIgnoreCase(t, "current");
}

fn focusedSurface(snapshot: ToolSnapshot) ?ToolSurface {
    for (snapshot.surfaces) |surface| {
        if (surface.focused) return surface;
    }
    return null;
}

/// Resolve a tool surface_id, honoring focused-surface aliases. A selected
/// write-context wins over UI focus so scheduled Copilot work stays attached to
/// the terminal that created it; otherwise aliases resolve to the focused
/// terminal. Returns null if nothing matches.
pub fn resolveSurfaceId(snapshot: ToolSnapshot, surface_id: []const u8, write_context: ?[]const u8) ?ToolSurface {
    if (isFocusedSurfaceAlias(surface_id)) {
        if (write_context) |wc| {
            if (findSurface(snapshot, wc)) |surface| return surface;
        }
        if (focusedSurface(snapshot)) |surface| return surface;
        return null;
    }
    return findSurface(snapshot, surface_id);
}

/// Error result for an unmatched surface_id that lists the open surfaces, so the
/// model can retry in one step instead of calling terminal_list.
fn allocNoSurfaceError(allocator: std.mem.Allocator, snapshot: ToolSnapshot, surface_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "No terminal surface matches surface_id={s}. Open surfaces:\n", .{surface_id});
    if (snapshot.surfaces.len == 0) try out.appendSlice(allocator, "(none)\n");
    for (snapshot.surfaces) |surface| {
        try out.print(allocator, "- id={s} tab={d} focused={} kind={s} title=\"{s}\"\n", .{
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            toolSurfaceKind(surface),
            surface.title,
        });
    }
    try out.appendSlice(allocator, "Use one of these ids, or surface_id=focused for the focused terminal.");
    return out.toOwnedSlice(allocator);
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

// ---------------------------------------------------------------------------
// File tool helpers
// ---------------------------------------------------------------------------

/// Resolve `path` against `working_dir` if relative, then return an owned copy.
fn resolveLocalPath(allocator: std.mem.Allocator, path: []const u8, working_dir: ?[]const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    if (working_dir) |wd| if (wd.len != 0) return std.fs.path.join(allocator, &.{ wd, path });
    return allocator.dupe(u8, path);
}

fn writeLocalFileAtomic(allocator: std.mem.Allocator, resolved: []const u8, content: []const u8) !void {
    _ = allocator;
    try platform_atomic_file.writeFileReplaceSafe(resolved, content);
}

fn renderReadResult(ctx: *ToolContext, path: []const u8, bytes: []const u8, offset: usize, limit: usize) ![]u8 {
    if (bytes.len >= agent_file_edit.MAX_FILE_BYTES) {
        return std.fmt.allocPrint(ctx.allocator, "File {s} is too large (>= {d} bytes). Use offset/limit to read a range.", .{ path, agent_file_edit.MAX_FILE_BYTES });
    }
    if (agent_file_edit.looksBinary(bytes)) {
        return std.fmt.allocPrint(ctx.allocator, "File {s} appears to be binary; refusing to read as text.", .{path});
    }
    const numbered = try agent_file_edit.sliceLinesAlloc(ctx.allocator, bytes, offset, limit);
    return truncateOwned(ctx.allocator, ctx.settings, numbered);
}

// ---------------------------------------------------------------------------
// File tool target resolution
// ---------------------------------------------------------------------------

const FileTarget = union(enum) {
    local,
    remote: ToolSshConnection,
    /// Owned error message to return verbatim to the model.
    err: []u8,
};

const CopyEndpoint = union(enum) {
    local: ?ToolSurface,
    wsl: ToolSurface,
    ssh: struct {
        surface: ToolSurface,
        conn: ToolSshConnection,
    },
    err: []u8,
};

/// Resolve a file tool's optional `surface_id` to a local or remote target.
/// A missing surface_id means local. A provided surface_id (including the
/// focused/active/current aliases) is resolved against the snapshot: an SSH
/// surface -> remote (its connection), a local/WSL surface -> local, no match
/// -> err (lists open surfaces).
fn resolveFileTarget(ctx: *ToolContext, surface_id: ?[]const u8) !FileTarget {
    const sid = surface_id orelse return .local;
    const snapshot = ctx.tool_snapshot orelse return .local;
    const surface = resolveSurfaceId(snapshot, sid, selectedWriteContext(ctx)) orelse {
        return .{ .err = try allocNoSurfaceError(ctx.allocator, snapshot, sid) };
    };
    if (!surface.is_ssh) return .local;
    if (surface.ssh_connection) |conn| return .{ .remote = conn };
    if (ctx.sshConnectionForSurface(surface.id)) |conn| return .{ .remote = conn };
    return .{ .err = try std.fmt.allocPrint(ctx.allocator, "Surface {s} is an SSH terminal but its connection is unavailable.", .{surface.id}) };
}

fn resolveCopyEndpoint(ctx: *ToolContext, surface_id: ?[]const u8) !CopyEndpoint {
    const sid = surface_id orelse return .{ .local = null };
    const snapshot = ctx.tool_snapshot orelse return .{
        .err = try std.fmt.allocPrint(ctx.allocator, "No terminal snapshot is available for surface_id={s}.", .{sid}),
    };
    const surface = resolveSurfaceId(snapshot, sid, selectedWriteContext(ctx)) orelse {
        return .{ .err = try allocNoSurfaceError(ctx.allocator, snapshot, sid) };
    };
    if (surface.is_ssh) {
        if (surface.ssh_connection) |conn| {
            return .{ .ssh = .{ .surface = surface, .conn = conn } };
        }
        if (ctx.sshConnectionForSurface(surface.id)) |conn| {
            return .{ .ssh = .{ .surface = surface, .conn = conn } };
        }
        return .{ .err = try std.fmt.allocPrint(ctx.allocator, "Surface {s} is an SSH terminal but its connection is unavailable.", .{surface.id}) };
    }
    if (surface.is_wsl) return .{ .wsl = surface };
    return .{ .local = surface };
}

fn posixPathIsAbsolute(path: []const u8) bool {
    return path.len > 0 and (path[0] == '/' or path[0] == '~');
}

fn posixJoin(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) ![]u8 {
    if (parent.len == 0) return allocator.dupe(u8, child);
    if (parent[parent.len - 1] == '/') return std.fmt.allocPrint(allocator, "{s}{s}", .{ parent, child });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, child });
}

fn endpointCwd(ctx: *ToolContext, endpoint: CopyEndpoint) ?[]const u8 {
    return switch (endpoint) {
        .local => |surface| if (surface) |s| if (s.cwd.len > 0) s.cwd else ctx.settings.working_dir else ctx.settings.working_dir,
        .wsl => |surface| if (surface.cwd.len > 0) surface.cwd else null,
        .ssh => |remote| if (remote.surface.cwd.len > 0) remote.surface.cwd else null,
        .err => null,
    };
}

fn resolveEndpointPath(ctx: *ToolContext, endpoint: CopyEndpoint, path: []const u8) ![]u8 {
    return switch (endpoint) {
        .local => {
            if (std.fs.path.isAbsolute(path)) return ctx.allocator.dupe(u8, path);
            const cwd = endpointCwd(ctx, endpoint) orelse return error.MissingWorkingDir;
            return std.fs.path.join(ctx.allocator, &.{ cwd, path });
        },
        .wsl, .ssh => {
            if (posixPathIsAbsolute(path)) return ctx.allocator.dupe(u8, path);
            const cwd = endpointCwd(ctx, endpoint) orelse return error.MissingWorkingDir;
            return posixJoin(ctx.allocator, cwd, path);
        },
        .err => unreachable,
    };
}

fn defaultDestinationPath(ctx: *ToolContext, dest_endpoint: CopyEndpoint, source_path: []const u8, dest_name: ?[]const u8, dest_path: ?[]const u8) ![]u8 {
    if (dest_path) |path| return resolveEndpointPath(ctx, dest_endpoint, path);
    const name = dest_name orelse agent_file_copy.basename(source_path);
    if (!agent_file_copy.isSafeDestinationName(name)) return error.UnsafeDestinationName;
    return switch (dest_endpoint) {
        .local => |surface| if (surface == null) blk: {
            const wd = ctx.settings.working_dir orelse return error.MissingWorkingDir;
            const plan = try agent_file_copy.planDestination(ctx.allocator, wd, source_path, dest_name);
            break :blk plan.dest_path;
        } else blk: {
            const cwd = endpointCwd(ctx, dest_endpoint) orelse return error.MissingWorkingDir;
            break :blk std.fs.path.join(ctx.allocator, &.{ cwd, name });
        },
        .wsl, .ssh => blk: {
            const cwd = endpointCwd(ctx, dest_endpoint) orelse return error.MissingWorkingDir;
            break :blk posixJoin(ctx.allocator, cwd, name);
        },
        .err => unreachable,
    };
}

fn wslGuestPathToLocalAlloc(allocator: std.mem.Allocator, guest_path: []const u8) ![]u8 {
    var native_buf: platform_pty_command.CwdBuffer = undefined;
    var utf8_buf: [4096]u8 = undefined;
    const local = platform_wsl.guestPathToLocalPathUtf8(guest_path, &native_buf, &utf8_buf) orelse return error.WslPathUnavailable;
    return allocator.dupe(u8, local);
}

fn localPathForEndpoint(ctx: *ToolContext, endpoint: CopyEndpoint, path: []const u8) ![]u8 {
    return switch (endpoint) {
        .local => ctx.allocator.dupe(u8, path),
        .wsl => wslGuestPathToLocalAlloc(ctx.allocator, path),
        .ssh, .err => unreachable,
    };
}

fn ensureLocalParent(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.fs.cwd().makePath(parent);
    }
}

fn openLocalReadFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, .{});
    return std.fs.cwd().openFile(path, .{});
}

fn createLocalWriteFile(path: []const u8) !std.fs.File {
    try ensureLocalParent(path);
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, .{ .truncate = true });
    return std.fs.cwd().createFile(path, .{ .truncate = true });
}

fn copyLocalFileStreaming(source_path: []const u8, dest_path: []const u8) !u64 {
    var src = try openLocalReadFile(source_path);
    defer src.close();
    var dst = try createLocalWriteFile(dest_path);
    defer dst.close();

    var total: u64 = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dst.writeAll(buf[0..n]);
        total += n;
    }
    return total;
}

fn remoteSpecChecked(buf: *[512]u8, conn: *const ToolSshConnection, remote_path: []const u8) ![]const u8 {
    const needed = conn.user().len + 1 + conn.host().len + 1 + remote_path.len;
    if (needed > buf.len) return error.PathTooLong;
    return scp.remoteSpec(buf, conn, remote_path);
}

fn copyFileTool(
    ctx: *ToolContext,
    source_path_in: []const u8,
    source_surface_id: ?[]const u8,
    dest_surface_id: ?[]const u8,
    dest_path_in: ?[]const u8,
    dest_name: ?[]const u8,
) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const source_endpoint = try resolveCopyEndpoint(ctx, source_surface_id);
    if (source_endpoint == .err) return source_endpoint.err;
    const dest_endpoint = try resolveCopyEndpoint(ctx, dest_surface_id);
    if (dest_endpoint == .err) return dest_endpoint.err;

    const source_path = resolveEndpointPath(ctx, source_endpoint, source_path_in) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to resolve source path {s}: {s}", .{ source_path_in, @errorName(err) });
    };
    defer ctx.allocator.free(source_path);

    const dest_path = defaultDestinationPath(ctx, dest_endpoint, source_path, dest_name, dest_path_in) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to resolve destination path: {s}", .{@errorName(err)});
    };
    defer ctx.allocator.free(dest_path);

    switch (source_endpoint) {
        .ssh => |src_remote| {
            if (dest_endpoint == .ssh) return ctx.allocator.dupe(u8, "copy_file does not support SSH-to-SSH copies yet. Pull to local wispterm-files first, then push to the destination SSH surface.");
            const local_dest = localPathForEndpoint(ctx, dest_endpoint, dest_path) catch |err| {
                return std.fmt.allocPrint(ctx.allocator, "Failed to map destination path {s}: {s}", .{ dest_path, @errorName(err) });
            };
            defer ctx.allocator.free(local_dest);
            try ensureLocalParent(local_dest);
            var remote_buf: [512]u8 = undefined;
            const remote_src = remoteSpecChecked(&remote_buf, &src_remote.conn, source_path) catch |err| {
                return std.fmt.allocPrint(ctx.allocator, "Failed to build SSH source path: {s}", .{@errorName(err)});
            };
            const result = scp.transfer(ctx.allocator, &src_remote.conn, remote_src, local_dest);
            if (result != .ok) return std.fmt.allocPrint(ctx.allocator, "Failed to copy SSH file {s} to {s}: {s}", .{ source_path, local_dest, @tagName(result) });
            return std.fmt.allocPrint(ctx.allocator, "copied source=ssh:{s} local_path={s}", .{ source_path, local_dest });
        },
        .local, .wsl => {
            const local_source = localPathForEndpoint(ctx, source_endpoint, source_path) catch |err| {
                return std.fmt.allocPrint(ctx.allocator, "Failed to map source path {s}: {s}", .{ source_path, @errorName(err) });
            };
            defer ctx.allocator.free(local_source);

            switch (dest_endpoint) {
                .ssh => |dst_remote| {
                    var remote_buf: [512]u8 = undefined;
                    const remote_dst = remoteSpecChecked(&remote_buf, &dst_remote.conn, dest_path) catch |err| {
                        return std.fmt.allocPrint(ctx.allocator, "Failed to build SSH destination path: {s}", .{@errorName(err)});
                    };
                    const result = scp.transfer(ctx.allocator, &dst_remote.conn, local_source, remote_dst);
                    if (result != .ok) return std.fmt.allocPrint(ctx.allocator, "Failed to copy local file {s} to SSH {s}: {s}", .{ local_source, dest_path, @tagName(result) });
                    return std.fmt.allocPrint(ctx.allocator, "copied source={s} remote_path={s}", .{ local_source, dest_path });
                },
                .local, .wsl => {
                    const local_dest = localPathForEndpoint(ctx, dest_endpoint, dest_path) catch |err| {
                        return std.fmt.allocPrint(ctx.allocator, "Failed to map destination path {s}: {s}", .{ dest_path, @errorName(err) });
                    };
                    defer ctx.allocator.free(local_dest);
                    const bytes = copyLocalFileStreaming(local_source, local_dest) catch |err| {
                        return std.fmt.allocPrint(ctx.allocator, "Failed to copy {s} to {s}: {s}", .{ local_source, local_dest, @errorName(err) });
                    };
                    return switch (dest_endpoint) {
                        .wsl => std.fmt.allocPrint(ctx.allocator, "copied bytes={d} wsl_path={s} local_path={s}", .{ bytes, dest_path, local_dest }),
                        else => std.fmt.allocPrint(ctx.allocator, "copied bytes={d} local_path={s}", .{ bytes, local_dest }),
                    };
                },
                .err => unreachable,
            }
        },
        .err => unreachable,
    }
}

// ---------------------------------------------------------------------------
// read_file tool
// ---------------------------------------------------------------------------

fn readFileTool(ctx: *ToolContext, path: []const u8, surface_id: ?[]const u8, offset: usize, limit: usize) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const target = try resolveFileTarget(ctx, surface_id);
    const remote_conn: ?ToolSshConnection = switch (target) {
        .err => |msg| return msg,
        .remote => |conn| conn,
        .local => null,
    };
    if (remote_conn) |conn| {
        const gate = remoteFileGate(false);
        if (approvalRequiredForGate(ctx.settings.permission, gate)) {
            if (!ctx.requestApproval("read_file", path, "Read remote file")) {
                return deniedResult(ctx.allocator, path, "operator rejected remote read");
            }
        }
        const bytes = scp.sshReadFile(ctx.allocator, &conn, path, agent_file_edit.MAX_FILE_BYTES) orelse
            return std.fmt.allocPrint(ctx.allocator, "Failed to read remote file {s}", .{path});
        defer ctx.allocator.free(bytes);
        return renderReadResult(ctx, path, bytes, offset, limit);
    }
    const gate = fileAccessGate(ctx, path, false);
    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        const reason = if (gate.blacklisted) "Reads a protected path - confirm to allow" else "Read file";
        if (!ctx.requestApproval("read_file", path, reason)) {
            return deniedResult(ctx.allocator, path, "operator rejected file read");
        }
    }
    const resolved = try resolveLocalPath(ctx.allocator, path, ctx.settings.working_dir);
    defer ctx.allocator.free(resolved);
    const bytes = std.fs.cwd().readFileAlloc(ctx.allocator, resolved, agent_file_edit.MAX_FILE_BYTES) catch |err| {
        if (err == error.FileTooBig) {
            return std.fmt.allocPrint(ctx.allocator, "File {s} is too large (>= {d} bytes). Use offset/limit to read a range.", .{ path, agent_file_edit.MAX_FILE_BYTES });
        }
        return std.fmt.allocPrint(ctx.allocator, "Failed to read {s}: {s}", .{ path, @errorName(err) });
    };
    defer ctx.allocator.free(bytes);
    return renderReadResult(ctx, path, bytes, offset, limit);
}

// ---------------------------------------------------------------------------
// write_file tool
// ---------------------------------------------------------------------------

fn writeFileTool(ctx: *ToolContext, path: []const u8, content: []const u8, surface_id: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const target = try resolveFileTarget(ctx, surface_id);
    const remote_conn: ?ToolSshConnection = switch (target) {
        .err => |msg| return msg,
        .remote => |conn| conn,
        .local => null,
    };
    const gate = if (remote_conn != null) remoteFileGate(true) else fileAccessGate(ctx, path, true);

    // Do not disclose a protected file's existing content in the diff.
    var old_content: []u8 = &[_]u8{};
    var owns_old = false;
    defer if (owns_old) ctx.allocator.free(old_content);
    if (!gate.blacklisted) {
        if (remote_conn) |conn| {
            if (scp.sshReadFile(ctx.allocator, &conn, path, agent_file_edit.MAX_FILE_BYTES)) |bytes| {
                old_content = bytes;
                owns_old = true;
            }
        } else {
            const resolved = try resolveLocalPath(ctx.allocator, path, ctx.settings.working_dir);
            defer ctx.allocator.free(resolved);
            if (std.fs.cwd().readFileAlloc(ctx.allocator, resolved, agent_file_edit.MAX_FILE_BYTES)) |bytes| {
                old_content = bytes;
                owns_old = true;
            } else |_| {}
        }
    }

    const diff = try agent_file_edit.unifiedDiffAlloc(ctx.allocator, path, old_content, content);
    defer ctx.allocator.free(diff);
    ctx.emitNote(diff);

    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        const reason = try std.fmt.allocPrint(ctx.allocator, "Write {s}", .{path});
        defer ctx.allocator.free(reason);
        if (!ctx.requestApproval("write_file", path, reason)) {
            return deniedResult(ctx.allocator, path, "operator rejected file write");
        }
    }

    if (remote_conn) |conn| {
        if (!scp.sshWriteFile(ctx.allocator, &conn, path, content)) {
            return std.fmt.allocPrint(ctx.allocator, "Failed to write remote file {s}", .{path});
        }
    } else {
        const resolved = try resolveLocalPath(ctx.allocator, path, ctx.settings.working_dir);
        defer ctx.allocator.free(resolved);
        writeLocalFileAtomic(ctx.allocator, resolved, content) catch |err| {
            return std.fmt.allocPrint(ctx.allocator, "Failed to write {s}: {s}", .{ path, @errorName(err) });
        };
    }
    return std.fmt.allocPrint(ctx.allocator, "Wrote {d} bytes to {s}", .{ content.len, path });
}

// ---------------------------------------------------------------------------
// edit_file tool
// ---------------------------------------------------------------------------

fn editFileTool(ctx: *ToolContext, path: []const u8, old_string: []const u8, new_string: []const u8, replace_all: bool, surface_id: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const target = try resolveFileTarget(ctx, surface_id);
    const remote_conn: ?ToolSshConnection = switch (target) {
        .err => |msg| return msg,
        .remote => |conn| conn,
        .local => null,
    };

    var old_content: []u8 = undefined;
    if (remote_conn) |conn| {
        old_content = scp.sshReadFile(ctx.allocator, &conn, path, agent_file_edit.MAX_FILE_BYTES) orelse
            return std.fmt.allocPrint(ctx.allocator, "Failed to read remote file {s} for editing", .{path});
    } else {
        const resolved = try resolveLocalPath(ctx.allocator, path, ctx.settings.working_dir);
        defer ctx.allocator.free(resolved);
        old_content = std.fs.cwd().readFileAlloc(ctx.allocator, resolved, agent_file_edit.MAX_FILE_BYTES) catch |err|
            return std.fmt.allocPrint(ctx.allocator, "Failed to read {s}: {s}", .{ path, @errorName(err) });
    }
    defer ctx.allocator.free(old_content);

    const outcome = agent_file_edit.applyEdit(ctx.allocator, old_content, old_string, new_string, replace_all) catch |err| {
        return switch (err) {
            error.EmptyOld => ctx.allocator.dupe(u8, "old_string must not be empty."),
            error.NotFound => std.fmt.allocPrint(ctx.allocator, "old_string not found in {s}.", .{path}),
            error.NotUnique => std.fmt.allocPrint(ctx.allocator, "old_string is not unique in {s}; pass replace_all=true or add more context.", .{path}),
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    defer ctx.allocator.free(outcome.new_content);

    const gate = if (remote_conn != null) remoteFileGate(true) else fileAccessGate(ctx, path, true);

    // Do not disclose a protected file's content in the diff; show a redacted note.
    if (gate.blacklisted) {
        const note = try std.fmt.allocPrint(ctx.allocator, "edit_file {s}: protected path - diff hidden ({d} change(s))", .{ path, outcome.occurrences });
        defer ctx.allocator.free(note);
        ctx.emitNote(note);
    } else {
        const diff = try agent_file_edit.unifiedDiffAlloc(ctx.allocator, path, old_content, outcome.new_content);
        defer ctx.allocator.free(diff);
        ctx.emitNote(diff);
    }

    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        const reason = try std.fmt.allocPrint(ctx.allocator, "Edit {s} ({d} change(s))", .{ path, outcome.occurrences });
        defer ctx.allocator.free(reason);
        if (!ctx.requestApproval("edit_file", path, reason)) {
            return deniedResult(ctx.allocator, path, "operator rejected file edit");
        }
    }

    if (remote_conn) |conn| {
        if (!scp.sshWriteFile(ctx.allocator, &conn, path, outcome.new_content)) {
            return std.fmt.allocPrint(ctx.allocator, "Failed to write remote file {s}", .{path});
        }
    } else {
        const resolved = try resolveLocalPath(ctx.allocator, path, ctx.settings.working_dir);
        defer ctx.allocator.free(resolved);
        writeLocalFileAtomic(ctx.allocator, resolved, outcome.new_content) catch |err|
            return std.fmt.allocPrint(ctx.allocator, "Failed to write {s}: {s}", .{ path, @errorName(err) });
    }
    return std.fmt.allocPrint(ctx.allocator, "Edited {s} ({d} change(s)).", .{ path, outcome.occurrences });
}

fn deniedResult(allocator: std.mem.Allocator, command: []const u8, reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "DENIED by operator (reason: {s})\ncommand: {s}", .{ reason, command });
}

pub fn truncateOwned(allocator: std.mem.Allocator, settings: AgentSettings, text: []u8) ![]u8 {
    const limit = settings.output_limit;
    if (text.len <= limit) return text;
    errdefer allocator.free(text); // owned: must not leak when allocPrint fails
    const truncated = try std.fmt.allocPrint(allocator, "{s}\n...[truncated to {d} bytes]", .{ text[0..limit], limit });
    allocator.free(text);
    return truncated;
}

/// Like truncateOwned, but keeps the LAST `limit` bytes (the most recent
/// output) and marks the dropped head. Use for terminal-snapshot-bearing
/// results, where the live interactive screen is at the tail — keeping the head
/// would hide the current prompt.
fn truncateTailOwned(allocator: std.mem.Allocator, settings: AgentSettings, text: []u8) ![]u8 {
    const limit: usize = settings.output_limit;
    if (text.len <= limit) return text;
    errdefer allocator.free(text); // owned: must not leak when allocPrint fails
    const tail = text[text.len - limit ..];
    const truncated = try std.fmt.allocPrint(allocator, "...[older output truncated to {d} bytes]\n{s}", .{ limit, tail });
    allocator.free(text);
    return truncated;
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

test "terminal_snapshot reads the live surface screen for a targeted surface" {
    const allocator = std.testing.allocator;
    var host_ctx = ReplWaitTestHost.Ctx{ .busy_until = 0, .settled_text = "LIVE-SCREEN-9999" };
    var surfaces = try allocator.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "s1"),
        .title = try allocator.dupe(u8, "Local Shell"),
        .cwd = try allocator.dupe(u8, "/home/user"),
        // The request-start pre-capture is stale; the live read must win.
        .snapshot = try allocator.dupe(u8, "STALE-PRECAPTURE-0000"),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    const cached = ToolSnapshot{ .surfaces = surfaces, .active_tab = 0 };
    defer cached.deinit(allocator);

    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = ReplWaitTestHost.host(&host_ctx),
        .tool_snapshot = cached,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const result = try terminalSnapshotTool(&ctx, "s1");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "LIVE-SCREEN-9999") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "STALE-PRECAPTURE") == null);
    try std.testing.expectEqual(@as(usize, 1), host_ctx.snap_calls);
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
    setWriteContext(&ctx, "aaa");
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
    setWriteContext(&ctx, "closed-surface");
    const call = ToolCall{ .id = @constCast("c1"), .name = @constCast("terminal_context"), .arguments = @constCast("{}") };

    const out = try executeToolCall(&ctx, call);
    defer allocator.free(out);

    try std.testing.expectEqualStrings("Selected terminal context surface_id=closed-surface is no longer open.", out);
    try std.testing.expectEqualStrings("closed-surface", ctx.write_context_surface_id[0..ctx.write_context_surface_id_len]);
}

test "terminal_select resolves the focused-surface alias to the focused surface" {
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
    for ([_][]const u8{ "focused", "active", "current", "" }) |alias| {
        const result = try terminalSelectTool(&ctx, alias);
        defer allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "surface_id=bbb") != null);
    }
    // An exact id still resolves directly.
    const exact = try terminalSelectTool(&ctx, "aaa");
    defer allocator.free(exact);
    try std.testing.expect(std.mem.indexOf(u8, exact, "surface_id=aaa") != null);
}

test "terminal_select focused alias honors selected write context before UI focus" {
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
    setWriteContext(&ctx, "aaa");

    const result = try terminalSelectTool(&ctx, "focused");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "surface_id=aaa") != null);
    try std.testing.expectEqualStrings("aaa", ctx.write_context_surface_id[0..ctx.write_context_surface_id_len]);
}

test "terminal_select focused alias falls back when selected write context is stale" {
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
    setWriteContext(&ctx, "closed-surface");

    const result = try terminalSelectTool(&ctx, "focused");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "surface_id=bbb") != null);
    try std.testing.expectEqualStrings("bbb", ctx.write_context_surface_id[0..ctx.write_context_surface_id_len]);
}

test "terminal_select lists available surfaces when the id does not match" {
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
    const result = try terminalSelectTool(&ctx, "zzz");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "zzz") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "aaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "bbb") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, msg, "code=<ctrl-c>") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Cloning into 'x'...") != null);
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
    try std.testing.expect(approvalRequiredForGate(.auto, denied));
    try std.testing.expect(!approvalRequiredForGate(.full, denied));

    const dangerous = accessGate(&ctx, "rm /work/ok/readme.md", null);
    try std.testing.expect(approvalRequiredForGate(.auto, dangerous));
    try std.testing.expect(!approvalRequiredForGate(.full, dangerous));

    const neutral = accessGate(&ctx, "cat /work/other.txt", null);
    try std.testing.expect(approvalRequiredForGate(.confirm, neutral));
    try std.testing.expect(!approvalRequiredForGate(.auto, neutral));

    const allowed_read = accessGate(&ctx, "cat /work/ok/readme.md", null);
    try std.testing.expect(!approvalRequiredForGate(.confirm, allowed_read));
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
    try std.testing.expect(!approvalRequiredForGate(.confirm, g1)); // confirm now auto-runs inside the dir
    try std.testing.expect(!approvalRequiredForGate(.auto, g1));
    // confined dangerous -> still forced
    const g2 = accessGate(&ctx, "rm -rf build", "/home/u/proj");
    try std.testing.expect(!g2.skip);
    try std.testing.expect(g2.force);
    try std.testing.expect(approvalRequiredForGate(.confirm, g2));
    try std.testing.expect(approvalRequiredForGate(.auto, g2));
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

test "remoteFileGate: writes force approval, reads do not" {
    try std.testing.expect(remoteFileGate(true).force);
    try std.testing.expect(!remoteFileGate(false).force);
    try std.testing.expect(remoteFileGate(false).skip);
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
    const gate = fileAccessGate(&ctx, "/work/readme.txt", false);
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
    const gate = fileAccessGate(&ctx, "/etc/hosts", true);
    try std.testing.expect(gate.force); // risky: absolute path outside working dir
    try std.testing.expect(!gate.skip);
}

test "read_file returns numbered lines for a local file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "r.txt", .data = "one\ntwo\n" });
    const abs = try tmp.dir.realpathAlloc(a, "r.txt");
    defer a.free(abs);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try readFileTool(&ctx, abs, null, 0, 0);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "     1\tone\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "     2\ttwo\n") != null);
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

test "file tool resolution uses ssh connection carried by the request snapshot" {
    const a = std.testing.allocator;
    const conn = ToolSshConnection.fromParts(.{
        .user = "alice",
        .host = "example.test",
        .port = "2222",
        .proxy_jump = "jump.example.test",
    });
    var surfaces = try a.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = try a.dupe(u8, "ssh-surface"),
        .title = try a.dupe(u8, "SSH"),
        .cwd = try a.dupe(u8, "/home/alice"),
        .snapshot = try a.dupe(u8, "$ "),
        .tab_index = 0,
        .focused = true,
        .is_ssh = true,
        .is_wsl = false,
        .ssh_connection = conn,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    const snapshot = ToolSnapshot{ .surfaces = surfaces, .active_tab = 0 };
    defer snapshot.deinit(a);

    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = snapshot,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const target = try resolveFileTarget(&ctx, "ssh-surface");
    switch (target) {
        .remote => |remote| {
            try std.testing.expectEqualStrings("alice", remote.user());
            try std.testing.expectEqualStrings("example.test", remote.host());
            try std.testing.expectEqualStrings("2222", remote.port());
            try std.testing.expectEqualStrings("jump.example.test", remote.proxyJump());
        },
        .err => |msg| {
            defer a.free(msg);
            return error.TestExpectedEqual;
        },
        .local => return error.TestExpectedEqual,
    }

    const endpoint = try resolveCopyEndpoint(&ctx, "ssh-surface");
    switch (endpoint) {
        .ssh => |remote| {
            try std.testing.expectEqualStrings("ssh-surface", remote.surface.id);
            try std.testing.expectEqualStrings("alice", remote.conn.user());
            try std.testing.expectEqualStrings("example.test", remote.conn.host());
        },
        .err => |msg| {
            defer a.free(msg);
            return error.TestExpectedEqual;
        },
        else => return error.TestExpectedEqual,
    }
}

test "write_file creates a local file in full permission mode" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_abs);
    const file_abs = try std.fs.path.join(a, &.{ dir_abs, "w.txt" });
    defer a.free(file_abs);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try writeFileTool(&ctx, file_abs, "hello\n", null);
    defer a.free(out);
    const written = try tmp.dir.readFileAlloc(a, "w.txt", 1024);
    defer a.free(written);
    try std.testing.expectEqualStrings("hello\n", written);
}

test "write_file can truncate to an empty file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.txt", .data = "old content" });
    const abs = try tmp.dir.realpathAlloc(a, "t.txt");
    defer a.free(abs);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try writeFileTool(&ctx, abs, "", null);
    defer a.free(out);
    const after = try tmp.dir.readFileAlloc(a, "t.txt", 1024);
    defer a.free(after);
    try std.testing.expectEqualStrings("", after);
}

test "edit_file applies a unique replacement to a local file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "e.txt", .data = "alpha\nbeta\ngamma\n" });
    const abs = try tmp.dir.realpathAlloc(a, "e.txt");
    defer a.free(abs);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try editFileTool(&ctx, abs, "beta", "BETA", false, null);
    defer a.free(out);
    const after = try tmp.dir.readFileAlloc(a, "e.txt", 1024);
    defer a.free(after);
    try std.testing.expectEqualStrings("alpha\nBETA\ngamma\n", after);
}

test "read_file with an unknown surface_id returns a no-surface error" {
    const a = std.testing.allocator;
    const snapshot = try twoSurfaceSnapshotForTest(a);
    defer snapshot.deinit(a);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = snapshot,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try readFileTool(&ctx, "/tmp/whatever.txt", "no-such-surface", 0, 0);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "No terminal surface matches") != null);
}

test "executeToolCall handles memory_save and memory_recall" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const dirs_mod = @import("platform/dirs.zig");
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

test "truncateTailOwned keeps the tail and marks the dropped head" {
    const a = std.testing.allocator;
    const settings = AgentSettings{ .output_limit = 8 };
    const text = try a.dupe(u8, "ABCDEFGHIJKLMNOP"); // 16 bytes, limit 8
    const out = try truncateTailOwned(a, settings, text);
    defer a.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, "IJKLMNOP"));
    try std.testing.expect(std.mem.indexOf(u8, out, "older output truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ABCD") == null);
}

test "truncateTailOwned returns short text unchanged" {
    const a = std.testing.allocator;
    const settings = AgentSettings{ .output_limit = 1024 };
    const text = try a.dupe(u8, "small");
    const out = try truncateTailOwned(a, settings, text);
    defer a.free(out);
    try std.testing.expectEqualStrings("small", out);
}

test "truncate helpers free the owned input when the truncation alloc fails" {
    // Both helpers take ownership of `text`; if the replacement allocPrint
    // hits OOM they must free it. std.testing.allocator's leak check is the
    // assertion here (allocation #0 = the input dupe, #1 = the failing
    // allocPrint).
    const settings = AgentSettings{ .output_limit = 4 };

    var failing_tail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const tail_alloc = failing_tail.allocator();
    const tail_text = try tail_alloc.dupe(u8, "0123456789");
    try std.testing.expectError(error.OutOfMemory, truncateTailOwned(tail_alloc, settings, tail_text));

    var failing_head = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const head_alloc = failing_head.allocator();
    const head_text = try head_alloc.dupe(u8, "0123456789");
    try std.testing.expectError(error.OutOfMemory, truncateOwned(head_alloc, settings, head_text));
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

    const result = try terminalSnapshotTool(&ctx, @as(?[]const u8, "surface-claude"));
    defer a.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "PROMPT_AT_BOTTOM") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "older output truncated") != null);
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

    const result = try terminalAnswerPromptTool(&ctx, @as(?[]const u8, "surface-claude"), "approve");
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

    const result = try terminalAnswerPromptTool(&ctx, @as(?[]const u8, "surface-claude"), "approve");
    defer a.free(result);

    try std.testing.expectEqual(@as(usize, 0), host_ctx.all_len);
    try std.testing.expect(std.mem.indexOf(u8, result, "awaiting an answer") != null);
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
