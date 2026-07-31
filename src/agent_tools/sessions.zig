//! Agent session, SSH profile, and tab tool adapters.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const terminal_lease = @import("../agent/terminal_lease.zig");
const platform_pty_command = @import("../platform/pty_command.zig");
const terminal_tools = @import("terminal.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;
const SshProfileSaveArgs = types.SshProfileSaveArgs;

pub fn sshProfileSaveApprovalText(allocator: std.mem.Allocator, args: SshProfileSaveArgs) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Save SSH profile name=\"{s}\" host=\"{s}\" user=\"{s}\" port=\"{s}\" proxy_jump=\"{s}\" auth_method=\"{s}\" identity_file=\"{s}\" password=\"{s}\"",
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

pub fn sshProfileSave(ctx: *ToolContext, args: SshProfileSaveArgs) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const approval_text = try sshProfileSaveApprovalText(ctx.allocator, args);
    defer ctx.allocator.free(approval_text);
    if (ctx.settings.permission == .confirm) {
        if (!ctx.requestApproval("ssh_profile_save", approval_text, "Save SSH server profile")) {
            return tool_output.deniedResult(ctx.allocator, approval_text, "operator rejected saved SSH profile update");
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
    return tool_output.truncateOwned(ctx.allocator, ctx.settings, out);
}

pub fn sshProfileConnect(ctx: *ToolContext, profile_name: []const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    if (ctx.settings.permission == .confirm) {
        if (!ctx.requestApproval("ssh_profile_connect", profile_name, "Open saved SSH server in a new tab")) {
            return tool_output.deniedResult(ctx.allocator, profile_name, "operator rejected saved SSH profile connection");
        }
    }

    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    var surface = host.connectSshProfile(host.ctx, ctx.allocator, profile_name) catch |err| switch (err) {
        error.ProfileNotFound => return std.fmt.allocPrint(ctx.allocator, "No saved SSH profile matched \"{s}\".", .{profile_name}),
        else => return std.fmt.allocPrint(ctx.allocator, "Failed to connect saved SSH profile \"{s}\": {}", .{ profile_name, err }),
    };
    var surface_owned = true;
    errdefer if (surface_owned) surface.deinit(ctx.allocator);
    if (ctx.agent_instance_id != 0 and !terminal_lease.active().claim(ctx.agent_instance_id, surface.id)) {
        return ctx.allocator.dupe(u8, "Failed to reserve the newly created SSH terminal for this Agent.");
    }
    surface.terminal_access = .owned;

    const out = try std.fmt.allocPrint(
        ctx.allocator,
        "connected profile=\"{s}\" surface_id={s} tab={d} focused={} kind={s} title=\"{s}\" cwd=\"{s}\"",
        .{
            profile_name,
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            terminal_tools.surfaceKind(surface),
            surface.title,
            surface.cwd,
        },
    );
    errdefer ctx.allocator.free(out);

    try terminal_tools.rememberConnectedSurface(ctx, surface);
    surface_owned = false;
    return tool_output.truncateOwned(ctx.allocator, ctx.settings, out);
}

pub fn tabNew(ctx: *ToolContext, kind: []const u8, command: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const trimmed_kind = std.mem.trim(u8, kind, " \t\r\n");
    const command_for_approval = command orelse trimmed_kind;
    if (ctx.settings.permission == .confirm) {
        if (!ctx.requestApproval("tab_new", command_for_approval, "Open a new local terminal tab")) {
            return tool_output.deniedResult(ctx.allocator, command_for_approval, "operator rejected new tab creation");
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
    if (ctx.agent_instance_id != 0 and !terminal_lease.active().claim(ctx.agent_instance_id, surface.id)) {
        return ctx.allocator.dupe(u8, "Failed to reserve the newly created terminal for this Agent.");
    }
    surface.terminal_access = .owned;

    const out = try std.fmt.allocPrint(
        ctx.allocator,
        "created tab kind={s} surface_id={s} tab={d} focused={} surface_kind={s} title=\"{s}\" cwd=\"{s}\". Close this temporary tab with tab_close when the task finishes.",
        .{
            if (trimmed_kind.len > 0) trimmed_kind else "default",
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            terminal_tools.surfaceKind(surface),
            surface.title,
            surface.cwd,
        },
    );
    errdefer ctx.allocator.free(out);

    try terminal_tools.rememberConnectedSurface(ctx, surface);
    surface_owned = false;
    return tool_output.truncateOwned(ctx.allocator, ctx.settings, out);
}

pub fn tabClose(ctx: *ToolContext, tab_index: ?usize, surface_id: ?[]const u8, title: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const snapshot = terminal_tools.collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const target_tab = resolveCloseTab(snapshot, tab_index, surface_id, title) orelse
        return ctx.allocator.dupe(u8, "No matching terminal tab was found.");
    if (try ensureTabWriteAccess(ctx, snapshot, target_tab)) |message| return message;

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
            return tool_output.deniedResult(ctx.allocator, selector, "operator rejected tab close");
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

    try terminal_tools.rememberClosedTab(ctx, closed);

    const out = try std.fmt.allocPrint(
        ctx.allocator,
        "closed tab={d} title=\"{s}\" active_tab={d}",
        .{ closed.tab_index + 1, closed.title, closed.active_tab + 1 },
    );
    return tool_output.truncateOwned(ctx.allocator, ctx.settings, out);
}

fn resolveCloseTab(snapshot: types.ToolSnapshot, tab_index: ?usize, surface_id: ?[]const u8, title: ?[]const u8) ?usize {
    if (tab_index) |index| return index;
    if (surface_id) |id| return (terminal_tools.findSurface(snapshot, id) orelse return null).tab_index;
    if (title) |raw| {
        const needle = std.mem.trim(u8, raw, " \t\r\n");
        if (needle.len == 0) return null;
        for (snapshot.surfaces) |surface| {
            if (std.ascii.eqlIgnoreCase(surface.title, needle)) return surface.tab_index;
        }
        var partial: ?usize = null;
        for (snapshot.surfaces) |surface| {
            if (std.ascii.indexOfIgnoreCase(surface.title, needle) == null) continue;
            if (partial != null and partial.? != surface.tab_index) return null;
            partial = surface.tab_index;
        }
        return partial;
    }
    return snapshot.active_tab;
}

fn ensureTabWriteAccess(ctx: *ToolContext, snapshot: types.ToolSnapshot, tab_index: usize) !?[]u8 {
    var found = false;
    for (snapshot.surfaces) |surface| {
        if (surface.tab_index != tab_index) continue;
        found = true;
        if (try terminal_tools.ensureWriteAccess(ctx, surface)) |message| return message;
    }
    if (!found) return @as(?[]u8, try ctx.allocator.dupe(u8, "No matching terminal tab was found."));
    return null;
}

test "ssh profile save approval text redacts password" {
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
