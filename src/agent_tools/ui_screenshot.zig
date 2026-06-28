//! Agent UI screenshot tool.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");

const ToolContext = types.ToolContext;
const UiScreenshotTarget = types.UiScreenshotTarget;

fn parseTarget(text: ?[]const u8) ?UiScreenshotTarget {
    const raw = std.mem.trim(u8, text orelse "focused_panel", " \t\r\n");
    if (raw.len == 0 or std.ascii.eqlIgnoreCase(raw, "focused_panel") or std.ascii.eqlIgnoreCase(raw, "focused")) return .focused_panel;
    if (std.ascii.eqlIgnoreCase(raw, "active_tab") or std.ascii.eqlIgnoreCase(raw, "tab")) return .active_tab;
    return null;
}

pub fn run(ctx: *ToolContext, target_text: ?[]const u8, surface_id: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const target = parseTarget(target_text) orelse return ctx.allocator.dupe(u8, "Invalid target; expected focused_panel or active_tab.");
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No UI screenshot host is available.");
    const callback = host.uiScreenshot orelse return ctx.allocator.dupe(u8, "No UI screenshot host is available.");
    const result = callback(host.ctx, ctx.allocator, target, surface_id, ctx.settings.working_dir) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "ui_screenshot failed: {s}", .{@errorName(err)});
    };
    defer result.deinit(ctx.allocator);
    if (result.surface_id) |result_surface_id| {
        return std.fmt.allocPrint(
            ctx.allocator,
            "screenshot path={s} mime={s} width={d} height={d} target={s} surface_id={s}",
            .{ result.path, result.mime, result.width, result.height, result.target.label(), result_surface_id },
        );
    }
    return std.fmt.allocPrint(
        ctx.allocator,
        "screenshot path={s} mime={s} width={d} height={d} target={s}",
        .{ result.path, result.mime, result.width, result.height, result.target.label() },
    );
}

test "ui_screenshot target parser accepts defaults and aliases" {
    try std.testing.expectEqual(UiScreenshotTarget.focused_panel, parseTarget(null).?);
    try std.testing.expectEqual(UiScreenshotTarget.focused_panel, parseTarget("focused").?);
    try std.testing.expectEqual(UiScreenshotTarget.active_tab, parseTarget("tab").?);
    try std.testing.expect(parseTarget("pane") == null);
}
