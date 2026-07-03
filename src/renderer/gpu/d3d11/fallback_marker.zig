//! D3D11 next-launch fallback marker policy.
//!
//! WispTerm resolves the active renderer backend at comptime, Ghostty-style, so
//! D3D11 cannot safely switch to OpenGL in-process. This module defines the
//! state-file marker and dry-run selection rules used by later Phase V/VI work;
//! it does not change the current Windows `auto` default or trigger fallback.

const std = @import("std");
const Backend = @import("../backend.zig").Backend;

pub const marker_max_len: usize = 160;
pub const schema = "d3d11:v1";

pub const Kind = enum {
    blocked,
    fallback_candidate,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .blocked => "blocked",
            .fallback_candidate => "fallback_candidate",
        };
    }

    pub fn parse(value: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const Reason = enum {
    device_lost,
    recreate_failed,
    init_failed,
    invalid_call,
    render_target_failed,
    present_failed,
    resize_failed,
    environment_blocked,
    unknown,

    pub fn name(self: Reason) []const u8 {
        return switch (self) {
            .device_lost => "device_lost",
            .recreate_failed => "recreate_failed",
            .init_failed => "init_failed",
            .invalid_call => "invalid_call",
            .render_target_failed => "render_target_failed",
            .present_failed => "present_failed",
            .resize_failed => "resize_failed",
            .environment_blocked => "environment_blocked",
            .unknown => "unknown",
        };
    }

    pub fn parse(value: []const u8) ?Reason {
        inline for (@typeInfo(Reason).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const Marker = struct {
    kind: Kind,
    version: []const u8,
    adapter_id: []const u8,
    reason: Reason,

    pub fn appliesTo(self: Marker, version: []const u8, adapter_id: []const u8) bool {
        return std.mem.eql(u8, self.version, version) and
            std.mem.eql(u8, self.adapter_id, adapter_id);
    }
};

pub const Phase = enum {
    current_default,
    future_windows_auto,
};

pub const MarkerEffect = enum {
    none,
    stale_marker,
    explicit_opengl,
    explicit_d3d11_ignores_marker,
    current_auto_default_unchanged,
    future_auto_d3d11,
    future_auto_opengl_marker,
};

pub const SelectionDecision = struct {
    backend: Backend,
    effect: MarkerEffect = .none,
    marker_reason: ?Reason = null,
    warning: bool = false,
};

pub fn adapterIdentity(
    buf: []u8,
    vendor_id: u32,
    device_id: u32,
    luid_low: u32,
    luid_high: i32,
) ![]const u8 {
    const luid_high_bits: u32 = @bitCast(luid_high);
    return std.fmt.bufPrint(
        buf,
        "v{x:0>4}d{x:0>4}l{x:0>8}{x:0>8}",
        .{ vendor_id, device_id, luid_low, luid_high_bits },
    );
}

pub fn format(
    buf: []u8,
    kind: Kind,
    version: []const u8,
    adapter_id: []const u8,
    reason: Reason,
) ![]const u8 {
    if (!fieldSafe(version) or !fieldSafe(adapter_id)) return error.InvalidMarkerField;
    return std.fmt.bufPrint(
        buf,
        schema ++ ";kind={s};version={s};adapter={s};reason={s}",
        .{ kind.name(), version, adapter_id, reason.name() },
    );
}

pub fn parse(marker: []const u8) ?Marker {
    const prefix = schema ++ ";";
    if (!std.mem.startsWith(u8, marker, prefix)) return null;

    var kind: ?Kind = null;
    var version: ?[]const u8 = null;
    var adapter_id: ?[]const u8 = null;
    var reason: ?Reason = null;

    var it = std.mem.splitScalar(u8, marker[prefix.len..], ';');
    while (it.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..eq];
        const value = part[eq + 1 ..];
        if (std.mem.eql(u8, key, "kind")) {
            kind = Kind.parse(value);
        } else if (std.mem.eql(u8, key, "version")) {
            version = value;
        } else if (std.mem.eql(u8, key, "adapter")) {
            adapter_id = value;
        } else if (std.mem.eql(u8, key, "reason")) {
            reason = Reason.parse(value);
        }
    }

    return .{
        .kind = kind orelse return null,
        .version = version orelse return null,
        .adapter_id = adapter_id orelse return null,
        .reason = reason orelse return null,
    };
}

pub fn decide(
    os_tag: std.Target.Os.Tag,
    build_option: []const u8,
    marker_text: []const u8,
    version: []const u8,
    adapter_id: []const u8,
    phase: Phase,
) SelectionDecision {
    const marker = parse(marker_text);
    const marker_applies = if (marker) |m| m.appliesTo(version, adapter_id) else false;
    const stale_marker = marker != null and !marker_applies;

    if (std.mem.eql(u8, build_option, "d3d11")) {
        return .{
            .backend = .d3d11,
            .effect = if (marker_applies) .explicit_d3d11_ignores_marker else if (stale_marker) .stale_marker else .none,
            .marker_reason = if (marker_applies) marker.?.reason else null,
            .warning = marker_applies,
        };
    }

    if (std.mem.eql(u8, build_option, "opengl")) {
        return .{
            .backend = .opengl,
            .effect = .explicit_opengl,
            .marker_reason = if (marker_applies) marker.?.reason else null,
        };
    }

    if (!std.mem.eql(u8, build_option, "auto")) {
        return .{ .backend = Backend.resolve(os_tag, build_option) };
    }

    if (phase == .future_windows_auto and os_tag == .windows) {
        if (marker_applies) {
            return .{
                .backend = .opengl,
                .effect = .future_auto_opengl_marker,
                .marker_reason = marker.?.reason,
            };
        }
        return .{
            .backend = .d3d11,
            .effect = if (stale_marker) .stale_marker else .future_auto_d3d11,
        };
    }

    return .{
        .backend = Backend.default(os_tag),
        .effect = if (stale_marker) .stale_marker else .current_auto_default_unchanged,
    };
}

fn fieldSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| switch (c) {
        ';', '\r', '\n' => return false,
        else => {},
    };
    return true;
}

test "D3D11 fallback marker formats and parses version adapter reason" {
    var adapter_buf: [48]u8 = undefined;
    const adapter = try adapterIdentity(&adapter_buf, 0x10de, 0x2684, 0x1234abcd, -1);
    var marker_buf: [marker_max_len]u8 = undefined;
    const text = try format(&marker_buf, .blocked, "1.20.0", adapter, .device_lost);
    const parsed = parse(text) orelse return error.MissingMarker;

    try std.testing.expectEqual(Kind.blocked, parsed.kind);
    try std.testing.expectEqual(Reason.device_lost, parsed.reason);
    try std.testing.expectEqualStrings("1.20.0", parsed.version);
    try std.testing.expectEqualStrings(adapter, parsed.adapter_id);
    try std.testing.expect(parsed.appliesTo("1.20.0", adapter));
}

test "D3D11 fallback marker rejects unsafe fields and unknown schema" {
    var buf: [marker_max_len]u8 = undefined;
    try std.testing.expectError(error.InvalidMarkerField, format(&buf, .blocked, "1.0\nbad", "adapter", .unknown));
    try std.testing.expect(parse("blocked:1.20.0") == null);
    try std.testing.expect(parse(schema ++ ";kind=blocked;version=1;adapter=a;reason=nope") == null);
}

test "D3D11 fallback marker ignores stale version and adapter" {
    var buf: [marker_max_len]u8 = undefined;
    const text = try format(&buf, .blocked, "1.20.0", "adapter-a", .recreate_failed);

    try std.testing.expect(!(parse(text) orelse return error.MissingMarker).appliesTo("1.21.0", "adapter-a"));
    try std.testing.expect(!(parse(text) orelse return error.MissingMarker).appliesTo("1.20.0", "adapter-b"));
}

test "D3D11 fallback policy keeps current Windows auto default unchanged" {
    var buf: [marker_max_len]u8 = undefined;
    const text = try format(&buf, .blocked, "1.20.0", "adapter-a", .device_lost);
    const decision = decide(.windows, "auto", text, "1.20.0", "adapter-a", .current_default);

    try std.testing.expectEqual(Backend.opengl, decision.backend);
    try std.testing.expectEqual(MarkerEffect.current_auto_default_unchanged, decision.effect);
    try std.testing.expect(!decision.warning);
}

test "D3D11 fallback policy explicit d3d11 ignores marker with warning" {
    var buf: [marker_max_len]u8 = undefined;
    const text = try format(&buf, .blocked, "1.20.0", "adapter-a", .device_lost);
    const decision = decide(.windows, "d3d11", text, "1.20.0", "adapter-a", .future_windows_auto);

    try std.testing.expectEqual(Backend.d3d11, decision.backend);
    try std.testing.expectEqual(MarkerEffect.explicit_d3d11_ignores_marker, decision.effect);
    try std.testing.expectEqual(Reason.device_lost, decision.marker_reason.?);
    try std.testing.expect(decision.warning);
}

test "D3D11 fallback policy future auto consumes matching marker" {
    var buf: [marker_max_len]u8 = undefined;
    const text = try format(&buf, .fallback_candidate, "1.20.0", "adapter-a", .render_target_failed);
    const decision = decide(.windows, "auto", text, "1.20.0", "adapter-a", .future_windows_auto);

    try std.testing.expectEqual(Backend.opengl, decision.backend);
    try std.testing.expectEqual(MarkerEffect.future_auto_opengl_marker, decision.effect);
    try std.testing.expectEqual(Reason.render_target_failed, decision.marker_reason.?);
}

test "D3D11 fallback policy future auto selects d3d11 without matching marker" {
    var buf: [marker_max_len]u8 = undefined;
    const text = try format(&buf, .blocked, "1.20.0", "adapter-a", .device_lost);
    const decision = decide(.windows, "auto", text, "1.21.0", "adapter-a", .future_windows_auto);

    try std.testing.expectEqual(Backend.d3d11, decision.backend);
    try std.testing.expectEqual(MarkerEffect.stale_marker, decision.effect);
}
