//! Dynamic binary agent tool adapter.
const std = @import("std");
const types = @import("../ai_chat_types.zig");
const agent_exec = @import("exec.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;

pub fn find(tools: []const types.DynamicBinaryTool, name: []const u8) ?types.DynamicBinaryTool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.function_name, name)) return tool;
    }
    return null;
}

pub fn run(ctx: *ToolContext, tool: types.DynamicBinaryTool, args: []const []const u8, cwd: ?[]const u8, timeout_ms: u32) ![]u8 {
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
                return tool_output.deniedResult(ctx.allocator, approval_text.items, "operator denied binary tool execution");
            }
        },
        .full => {},
    }

    const argv = try ctx.allocator.alloc([]const u8, args.len + 1);
    defer ctx.allocator.free(argv);
    argv[0] = tool.executable_abs;
    for (args, 0..) |arg, i| argv[i + 1] = arg;

    const result = agent_exec.runArgv(ctx.allocator, argv, cwd, ctx.settings.output_limit, timeout_ms, ctx) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Binary tool {s} failed: {}", .{ tool.function_name, err });
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    if (result.timed_out) try out.appendSlice(ctx.allocator, "timed_out=true\n");
    try out.print(ctx.allocator, "exit_code={d}\nstdout:\n{s}\nstderr:\n{s}", .{ result.exit_code, result.stdout, result.stderr });
    return tool_output.truncateOwned(ctx.allocator, ctx.settings, try out.toOwnedSlice(ctx.allocator));
}

test "find returns the matching dynamic binary tool" {
    const tools = [_]types.DynamicBinaryTool{
        .{
            .function_name = "one",
            .executable_abs = "/bin/one",
            .description = "one",
        },
        .{
            .function_name = "two",
            .executable_abs = "/bin/two",
            .description = "two",
        },
    };
    try std.testing.expectEqualStrings("/bin/two", find(tools[0..], "two").?.executable_abs);
    try std.testing.expect(find(tools[0..], "missing") == null);
}
