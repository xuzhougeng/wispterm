//! Opt-in D3D11 future-auto selector dry-run smoke.
//!
//! Enable with `WISPTERM_D3D11_AUTO_DRY_RUN_SMOKE=1`. This logs selector
//! decisions for the current Windows auto default and the future Windows auto
//! policy without changing the active backend or writing fallback markers.

const std = @import("std");
const build_options = @import("build_options");

const gpu = @import("gpu/gpu.zig");
const Backend = @import("gpu/backend.zig").Backend;
const fallback_marker = @import("gpu/d3d11/fallback_marker.zig");
const render_diagnostics = @import("../render_diagnostics.zig");

const ENV_NAME = "WISPTERM_D3D11_AUTO_DRY_RUN_SMOKE";

threadlocal var checked_env = false;
threadlocal var enabled_cache = false;
threadlocal var fired = false;

const SmokeDecision = struct {
    current_auto_opengl: bool,
    future_auto_d3d11: bool,
    future_auto_marker_opengl: bool,
    explicit_d3d11_ignored_marker: bool,
    explicit_opengl: bool,
    stale_marker_ignored: bool,
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

fn evaluateDecisions(version: []const u8, adapter_id: []const u8, marker_text: []const u8, stale_marker_text: []const u8) SmokeDecision {
    const current_auto = fallback_marker.decide(.windows, "auto", "", version, adapter_id, .current_default);
    const future_auto = fallback_marker.decide(.windows, "auto", "", version, adapter_id, .future_windows_auto);
    const future_auto_marker = fallback_marker.decide(.windows, "auto", marker_text, version, adapter_id, .future_windows_auto);
    const explicit_d3d11 = fallback_marker.decide(.windows, "d3d11", marker_text, version, adapter_id, .future_windows_auto);
    const explicit_opengl = fallback_marker.decide(.windows, "opengl", marker_text, version, adapter_id, .future_windows_auto);
    const stale_marker = fallback_marker.decide(.windows, "auto", stale_marker_text, version, adapter_id, .future_windows_auto);

    return .{
        .current_auto_opengl = current_auto.backend == Backend.opengl and
            current_auto.effect == .current_auto_default_unchanged,
        .future_auto_d3d11 = future_auto.backend == Backend.d3d11 and
            future_auto.effect == .future_auto_d3d11,
        .future_auto_marker_opengl = future_auto_marker.backend == Backend.opengl and
            future_auto_marker.effect == .future_auto_opengl_marker,
        .explicit_d3d11_ignored_marker = explicit_d3d11.backend == Backend.d3d11 and
            explicit_d3d11.effect == .explicit_d3d11_ignores_marker and
            explicit_d3d11.warning,
        .explicit_opengl = explicit_opengl.backend == Backend.opengl and
            explicit_opengl.effect == .explicit_opengl,
        .stale_marker_ignored = stale_marker.backend == Backend.d3d11 and
            stale_marker.effect == .stale_marker,
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
        render_diagnostics.log("d3d11-auto-dry-run-smoke marker format failed: {s}", .{@errorName(err)});
        return;
    };

    var stale_marker_buf: [fallback_marker.marker_max_len]u8 = undefined;
    const stale_marker = fallback_marker.format(
        &stale_marker_buf,
        .fallback_candidate,
        "0.0.0-stale",
        adapter_id,
        .environment_blocked,
    ) catch |err| {
        render_diagnostics.log("d3d11-auto-dry-run-smoke stale marker format failed: {s}", .{@errorName(err)});
        return;
    };

    const decision = evaluateDecisions(build_options.app_version, adapter_id, marker, stale_marker);
    render_diagnostics.log(
        "d3d11-auto-dry-run-smoke adapter={s} current_auto_opengl={} future_auto_d3d11={} future_auto_marker_opengl={} explicit_d3d11_ignored_marker={} explicit_opengl={} stale_marker_ignored={} automatic_fallback=false default_unchanged=true",
        .{
            adapter_id,
            decision.current_auto_opengl,
            decision.future_auto_d3d11,
            decision.future_auto_marker_opengl,
            decision.explicit_d3d11_ignored_marker,
            decision.explicit_opengl,
            decision.stale_marker_ignored,
        },
    );
}

test "D3D11 auto dry-run smoke env parser accepts truthy values" {
    try std.testing.expect(parseEnabledValue("1"));
    try std.testing.expect(parseEnabledValue("true"));
    try std.testing.expect(parseEnabledValue("YES"));
    try std.testing.expect(parseEnabledValue("on"));
}

test "D3D11 auto dry-run smoke env parser rejects falsey values" {
    try std.testing.expect(!parseEnabledValue(""));
    try std.testing.expect(!parseEnabledValue("0"));
    try std.testing.expect(!parseEnabledValue("false"));
    try std.testing.expect(!parseEnabledValue("off"));
}

test "D3D11 auto dry-run smoke validates selector decisions" {
    var marker_buf: [fallback_marker.marker_max_len]u8 = undefined;
    const marker = try fallback_marker.format(
        &marker_buf,
        .fallback_candidate,
        "1.20.0",
        "adapter-a",
        .environment_blocked,
    );
    var stale_marker_buf: [fallback_marker.marker_max_len]u8 = undefined;
    const stale_marker = try fallback_marker.format(
        &stale_marker_buf,
        .fallback_candidate,
        "1.19.0",
        "adapter-a",
        .environment_blocked,
    );

    const decision = evaluateDecisions("1.20.0", "adapter-a", marker, stale_marker);
    try std.testing.expect(decision.current_auto_opengl);
    try std.testing.expect(decision.future_auto_d3d11);
    try std.testing.expect(decision.future_auto_marker_opengl);
    try std.testing.expect(decision.explicit_d3d11_ignored_marker);
    try std.testing.expect(decision.explicit_opengl);
    try std.testing.expect(decision.stale_marker_ignored);
}
