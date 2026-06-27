//! Shared agent tool approval-gate helpers.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const ai_agent_access = @import("../ai_agent_access.zig");

const ToolContext = types.ToolContext;
const AgentPermission = types.AgentPermission;

pub const Gate = struct {
    dangerous: bool,
    blacklisted: bool,
    force: bool,
    skip: bool,
    matched: []const u8,
};

pub fn approvalRequired(permission: AgentPermission, gate: Gate) bool {
    return switch (permission) {
        .confirm => !gate.skip,
        .auto => gate.force,
        .full => false,
    };
}

/// Gate a local file path. Reads only check the deny-list; writes additionally
/// flag paths outside the working dir as risky (force). `working_dir` is the
/// effective cwd for resolving relatives.
pub fn fileGate(ctx: *const ToolContext, path: []const u8, is_write: bool) Gate {
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
pub fn remoteFileGate(is_write: bool) Gate {
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
pub fn allocBlacklistReason(allocator: std.mem.Allocator, matched: []const u8) ?[]u8 {
    return std.fmt.allocPrint(allocator, "Reads protected path \"{s}\" — confirm to allow", .{matched}) catch null;
}
