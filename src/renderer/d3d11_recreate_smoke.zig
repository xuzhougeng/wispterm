//! Opt-in D3D11 device-recreate recovery smoke.
//!
//! Enable with `WISPTERM_D3D11_RECREATE_SMOKE=1`. The normal render loop asks
//! the D3D11 backend to latch a recreate-class recovery request exactly once;
//! AppWindow then exercises the same recovery path used after device-loss
//! diagnostics.

const std = @import("std");

const fallback_marker_smoke = @import("d3d11_fallback_marker_smoke.zig");
const gpu = @import("gpu/gpu.zig");
const render_diagnostics = @import("../render_diagnostics.zig");

const ENV_NAME = "WISPTERM_D3D11_RECREATE_SMOKE";

threadlocal var checked_env = false;
threadlocal var enabled_cache = false;
threadlocal var fired = false;

fn parseEnabledValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.mem.eql(u8, trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

fn enabled() bool {
    if (comptime gpu.active != .d3d11) return false;
    if (checked_env) return enabled_cache;
    checked_env = true;

    const value = std.process.getEnvVarOwned(std.heap.page_allocator, ENV_NAME) catch {
        enabled_cache = false;
        return enabled_cache;
    };
    defer std.heap.page_allocator.free(value);

    enabled_cache = parseEnabledValue(value);
    return enabled_cache;
}

pub fn maybeRequest() void {
    if (comptime gpu.active != .d3d11) return;
    fallback_marker_smoke.maybeRun();
    if (!enabled() or fired) return;
    fired = true;
    if (gpu.Context.requestDeviceRecreateForSmoke()) {
        render_diagnostics.log("d3d11-recreate-smoke requested device recreate", .{});
    } else {
        render_diagnostics.log("d3d11-recreate-smoke request skipped backend_unavailable=true", .{});
    }
}

test "D3D11 recreate smoke env parser accepts truthy values" {
    try std.testing.expect(parseEnabledValue("1"));
    try std.testing.expect(parseEnabledValue("true"));
    try std.testing.expect(parseEnabledValue("YES"));
    try std.testing.expect(parseEnabledValue("on"));
}

test "D3D11 recreate smoke env parser rejects falsey values" {
    try std.testing.expect(!parseEnabledValue(""));
    try std.testing.expect(!parseEnabledValue("0"));
    try std.testing.expect(!parseEnabledValue("false"));
    try std.testing.expect(!parseEnabledValue("off"));
}
