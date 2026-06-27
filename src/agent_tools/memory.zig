//! Agent memory tool-call adapters.
const std = @import("std");
const types = @import("../ai_chat_types.zig");
const tool_args = @import("args.zig");
const agent_memory = @import("../agent_memory.zig");

const ToolContext = types.ToolContext;

pub fn save(ctx: *ToolContext, root: std.json.Value) ![]u8 {
    const name = tool_args.string(root, "name") orelse return ctx.allocator.dupe(u8, "Missing name");
    const description = tool_args.string(root, "description") orelse return ctx.allocator.dupe(u8, "Missing description");
    const body = blk: {
        if (root != .object) break :blk null;
        const v = root.object.get("body") orelse break :blk null;
        break :blk if (v == .string) v.string else null;
    } orelse return ctx.allocator.dupe(u8, "Missing body");
    const tier_text = tool_args.string(root, "tier") orelse "global";
    const tier: agent_memory.Tier = if (std.mem.eql(u8, tier_text, "project")) .project else .global;
    const type_ = agent_memory.MemoryType.fromString(tool_args.string(root, "type") orelse "user");
    return agent_memory.saveMemory(ctx.allocator, tier, ctx.settings.working_dir, name, description, type_, body);
}

pub fn recall(ctx: *ToolContext, root: std.json.Value) ![]u8 {
    const name = tool_args.string(root, "name") orelse return ctx.allocator.dupe(u8, "Missing name");
    return agent_memory.recallMemory(ctx.allocator, ctx.settings.working_dir orelse "", name);
}

pub fn delete(ctx: *ToolContext, root: std.json.Value) ![]u8 {
    const name = tool_args.string(root, "name") orelse return ctx.allocator.dupe(u8, "Missing name");
    const tier_opt: ?agent_memory.Tier = if (tool_args.string(root, "tier")) |t|
        (if (std.mem.eql(u8, t, "project")) .project else if (std.mem.eql(u8, t, "global")) .global else null)
    else
        null;
    return agent_memory.deleteMemory(ctx.allocator, ctx.settings.working_dir orelse "", name, tier_opt);
}
