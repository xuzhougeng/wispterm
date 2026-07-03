//! Opt-in D3D11 fallback marker smoke.
//!
//! Enable with `WISPTERM_D3D11_FALLBACK_MARKER_SMOKE=1`. This writes a
//! synthetic next-launch fallback marker into the isolated state file used by
//! the smoke harness, then verifies the current/future selector decisions. It
//! does not change the current Windows `auto` default and does not trigger
//! automatic fallback.

const std = @import("std");
const build_options = @import("build_options");

const gpu = @import("gpu/gpu.zig");
const Backend = @import("gpu/backend.zig").Backend;
const fallback_marker = @import("gpu/d3d11/fallback_marker.zig");
const platform_window_state = @import("../platform/window_state.zig");
const render_diagnostics = @import("../render_diagnostics.zig");

const ENV_NAME = "WISPTERM_D3D11_FALLBACK_MARKER_SMOKE";

threadlocal var checked_env = false;
threadlocal var enabled_cache = false;
threadlocal var fired = false;

const SmokeDecision = struct {
    readback_ok: bool,
    explicit_d3d11_ignored: bool,
    current_auto_default_unchanged: bool,
    future_auto_opengl_marker: bool,
};

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

fn evaluateDecisions(marker_text: []const u8, version: []const u8, adapter_id: []const u8) SmokeDecision {
    const explicit_d3d11 = fallback_marker.decide(
        .windows,
        "d3d11",
        marker_text,
        version,
        adapter_id,
        .future_windows_auto,
    );
    const current_auto = fallback_marker.decide(
        .windows,
        "auto",
        marker_text,
        version,
        adapter_id,
        .current_default,
    );
    const future_auto = fallback_marker.decide(
        .windows,
        "auto",
        marker_text,
        version,
        adapter_id,
        .future_windows_auto,
    );

    return .{
        .readback_ok = fallback_marker.parse(marker_text) != null,
        .explicit_d3d11_ignored = explicit_d3d11.backend == .d3d11 and
            explicit_d3d11.effect == .explicit_d3d11_ignores_marker and
            explicit_d3d11.warning,
        .current_auto_default_unchanged = current_auto.backend == Backend.opengl and
            current_auto.effect == .current_auto_default_unchanged,
        .future_auto_opengl_marker = future_auto.backend == Backend.opengl and
            future_auto.effect == .future_auto_opengl_marker,
    };
}

pub fn maybeRun() void {
    if (comptime gpu.active != .d3d11) return;
    if (!enabled() or fired) return;
    fired = true;

    var adapter_buf: [64]u8 = undefined;
    const adapter_id = gpu.Context.adapterFallbackIdentity(&adapter_buf) orelse "unknown-adapter";

    var marker_buf: [fallback_marker.marker_max_len]u8 = undefined;
    const marker = fallback_marker.format(
        &marker_buf,
        .fallback_candidate,
        build_options.app_version,
        adapter_id,
        .environment_blocked,
    ) catch |err| {
        render_diagnostics.log("d3d11-fallback-marker-smoke marker format failed: {s}", .{@errorName(err)});
        return;
    };

    const allocator = std.heap.page_allocator;
    platform_window_state.recordD3d11Fallback(allocator, marker);

    var readback_buf: [fallback_marker.marker_max_len]u8 = undefined;
    const readback = platform_window_state.d3d11Fallback(allocator, &readback_buf);
    const decision = evaluateDecisions(readback, build_options.app_version, adapter_id);
    const readback_matches = std.mem.eql(u8, marker, readback);

    render_diagnostics.log(
        "d3d11-fallback-marker-smoke marker={s} adapter={s} readback_ok={} readback_matches={} explicit_d3d11_ignored={} current_auto_default_unchanged={} future_auto_opengl_marker={} automatic_fallback=false default_unchanged=true",
        .{
            marker,
            adapter_id,
            decision.readback_ok,
            readback_matches,
            decision.explicit_d3d11_ignored,
            decision.current_auto_default_unchanged,
            decision.future_auto_opengl_marker,
        },
    );
}

test "D3D11 fallback marker smoke env parser accepts truthy values" {
    try std.testing.expect(parseEnabledValue("1"));
    try std.testing.expect(parseEnabledValue("true"));
    try std.testing.expect(parseEnabledValue("YES"));
    try std.testing.expect(parseEnabledValue("on"));
}

test "D3D11 fallback marker smoke env parser rejects falsey values" {
    try std.testing.expect(!parseEnabledValue(""));
    try std.testing.expect(!parseEnabledValue("0"));
    try std.testing.expect(!parseEnabledValue("false"));
    try std.testing.expect(!parseEnabledValue("off"));
}

test "D3D11 fallback marker smoke validates selector decisions" {
    var marker_buf: [fallback_marker.marker_max_len]u8 = undefined;
    const marker = try fallback_marker.format(
        &marker_buf,
        .fallback_candidate,
        "1.20.0",
        "adapter-a",
        .environment_blocked,
    );
    const decision = evaluateDecisions(marker, "1.20.0", "adapter-a");

    try std.testing.expect(decision.readback_ok);
    try std.testing.expect(decision.explicit_d3d11_ignored);
    try std.testing.expect(decision.current_auto_default_unchanged);
    try std.testing.expect(decision.future_auto_opengl_marker);
}
