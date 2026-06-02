//! Pure (std-only) serialization + validation for the window/UI state file.
//! Kept dependency-light so it unit-tests in the fast suite without pulling in
//! platform display/dirs code. `window_state.zig` is the I/O layer over this.
const std = @import("std");

/// Reject restored sizes smaller than this (treat as "no saved size").
pub const MIN_WIDTH: i32 = 200;
pub const MIN_HEIGHT: i32 = 150;
/// Reject restored sizes larger than this — no real single-window framebuffer
/// reaches it, so anything bigger is a corrupted value.
pub const MAX_DIMENSION: i32 = 32_767;

pub const PersistedState = struct {
    x: ?i32 = null,
    y: ?i32 = null,
    width: ?i32 = null,
    height: ?i32 = null,
    // Quake-mode drop-down outer frame (screen coords). Distinct from the
    // windowed geometry above because quake persists an *outer* frame while the
    // windowed path stores outer-position + framebuffer-size; mixing them would
    // corrupt geometry when the user toggles `quake-mode` between launches.
    quake_x: ?i32 = null,
    quake_y: ?i32 = null,
    quake_width: ?i32 = null,
    quake_height: ?i32 = null,
    ai_setup_prompted: bool = false,
};

/// True only when both dimensions are within the plausible range for a real
/// window: [MIN_WIDTH..MAX_DIMENSION] × [MIN_HEIGHT..MAX_DIMENSION].
pub fn sizeIsValid(width: i32, height: i32) bool {
    return width >= MIN_WIDTH and width <= MAX_DIMENSION and
        height >= MIN_HEIGHT and height <= MAX_DIMENSION;
}

/// Parse `key = value` lines. Unknown keys and malformed numbers are ignored;
/// missing keys keep their PersistedState defaults.
pub fn parse(data: []const u8) PersistedState {
    var state = PersistedState{};
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r' });
        if (trimmed.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], &[_]u8{ ' ', '\t' });
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], &[_]u8{ ' ', '\t' });
        if (std.mem.eql(u8, key, "window-x")) {
            state.x = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "window-y")) {
            state.y = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "window-width")) {
            state.width = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "window-height")) {
            state.height = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "quake-x")) {
            state.quake_x = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "quake-y")) {
            state.quake_y = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "quake-width")) {
            state.quake_width = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "quake-height")) {
            state.quake_height = std.fmt.parseInt(i32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "ai-setup-prompted")) {
            state.ai_setup_prompted = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
        }
    }
    return state;
}

/// Format `state` as `key = value` lines into `buf`. Optional geometry fields are
/// written only when non-null; the flag is always written.
pub fn format(buf: []u8, state: PersistedState) ![]const u8 {
    var len: usize = 0;
    if (state.x) |x| len += (try std.fmt.bufPrint(buf[len..], "window-x = {d}\n", .{x})).len;
    if (state.y) |y| len += (try std.fmt.bufPrint(buf[len..], "window-y = {d}\n", .{y})).len;
    if (state.width) |w| len += (try std.fmt.bufPrint(buf[len..], "window-width = {d}\n", .{w})).len;
    if (state.height) |h| len += (try std.fmt.bufPrint(buf[len..], "window-height = {d}\n", .{h})).len;
    if (state.quake_x) |x| len += (try std.fmt.bufPrint(buf[len..], "quake-x = {d}\n", .{x})).len;
    if (state.quake_y) |y| len += (try std.fmt.bufPrint(buf[len..], "quake-y = {d}\n", .{y})).len;
    if (state.quake_width) |w| len += (try std.fmt.bufPrint(buf[len..], "quake-width = {d}\n", .{w})).len;
    if (state.quake_height) |h| len += (try std.fmt.bufPrint(buf[len..], "quake-height = {d}\n", .{h})).len;
    len += (try std.fmt.bufPrint(buf[len..], "ai-setup-prompted = {d}\n", .{@intFromBool(state.ai_setup_prompted)})).len;
    return buf[0..len];
}

/// Copy of `state` with position overwritten; size fields replaced only when the
/// argument is non-null (so a maximized save updates position but preserves the
/// last windowed size).
pub fn mergeGeometry(state: PersistedState, x: i32, y: i32, width: ?i32, height: ?i32) PersistedState {
    var next = state;
    next.x = x;
    next.y = y;
    if (width) |val| next.width = val;
    if (height) |val| next.height = val;
    return next;
}

/// Copy of `state` with the quake drop-down outer frame overwritten. Leaves the
/// windowed geometry and the onboarding flag untouched.
pub fn mergeQuakeFrame(state: PersistedState, x: i32, y: i32, width: i32, height: i32) PersistedState {
    var next = state;
    next.quake_x = x;
    next.quake_y = y;
    next.quake_width = width;
    next.quake_height = height;
    return next;
}

test "parse reads an old position-only state file" {
    const s = parse("window-x = 100\nwindow-y = 200\n");
    try std.testing.expectEqual(@as(?i32, 100), s.x);
    try std.testing.expectEqual(@as(?i32, 200), s.y);
    try std.testing.expectEqual(@as(?i32, null), s.width);
    try std.testing.expectEqual(@as(?i32, null), s.height);
    try std.testing.expectEqual(false, s.ai_setup_prompted);
}

test "parse reads a full state file with size and flag" {
    const s = parse("window-x = -5\nwindow-y = 0\nwindow-width = 1280\nwindow-height = 800\nai-setup-prompted = 1\n");
    try std.testing.expectEqual(@as(?i32, -5), s.x);
    try std.testing.expectEqual(@as(?i32, 1280), s.width);
    try std.testing.expectEqual(@as(?i32, 800), s.height);
    try std.testing.expectEqual(true, s.ai_setup_prompted);
}

test "parse ignores unknown keys and malformed numbers" {
    const s = parse("garbage\nwindow-x = notanumber\ncolor = red\nwindow-y = 50\nai-setup-prompted = true\n");
    try std.testing.expectEqual(@as(?i32, null), s.x);
    try std.testing.expectEqual(@as(?i32, 50), s.y);
    try std.testing.expectEqual(true, s.ai_setup_prompted);
}

test "format round-trips through parse" {
    const original = PersistedState{ .x = 12, .y = 34, .width = 1024, .height = 768, .ai_setup_prompted = true };
    var buf: [256]u8 = undefined;
    const text = try format(&buf, original);
    const reparsed = parse(text);
    try std.testing.expectEqual(original.x, reparsed.x);
    try std.testing.expectEqual(original.y, reparsed.y);
    try std.testing.expectEqual(original.width, reparsed.width);
    try std.testing.expectEqual(original.height, reparsed.height);
    try std.testing.expectEqual(original.ai_setup_prompted, reparsed.ai_setup_prompted);
}

test "format omits null geometry but always writes the flag" {
    var buf: [256]u8 = undefined;
    const text = try format(&buf, .{ .ai_setup_prompted = false });
    try std.testing.expectEqualStrings("ai-setup-prompted = 0\n", text);
}

test "sizeIsValid rejects degenerate sizes" {
    try std.testing.expect(sizeIsValid(800, 600));
    try std.testing.expect(sizeIsValid(MIN_WIDTH, MIN_HEIGHT));
    try std.testing.expect(!sizeIsValid(10, 600));
    try std.testing.expect(!sizeIsValid(800, 10));
    try std.testing.expect(!sizeIsValid(40_000, 600));
    try std.testing.expect(!sizeIsValid(800, 40_000));
}

test "mergeGeometry preserves size when width/height are null" {
    const base = PersistedState{ .x = 1, .y = 2, .width = 1000, .height = 700, .ai_setup_prompted = true };
    const merged = mergeGeometry(base, 9, 8, null, null);
    try std.testing.expectEqual(@as(?i32, 9), merged.x);
    try std.testing.expectEqual(@as(?i32, 8), merged.y);
    try std.testing.expectEqual(@as(?i32, 1000), merged.width);
    try std.testing.expectEqual(@as(?i32, 700), merged.height);
    try std.testing.expectEqual(true, merged.ai_setup_prompted);
}

test "mergeGeometry overwrites size when provided" {
    const merged = mergeGeometry(.{}, 0, 0, 1280, 720);
    try std.testing.expectEqual(@as(?i32, 1280), merged.width);
    try std.testing.expectEqual(@as(?i32, 720), merged.height);
}

test "parse reads the quake drop-down frame" {
    const s = parse("quake-x = 100\nquake-y = 0\nquake-width = 1920\nquake-height = 540\n");
    try std.testing.expectEqual(@as(?i32, 100), s.quake_x);
    try std.testing.expectEqual(@as(?i32, 0), s.quake_y);
    try std.testing.expectEqual(@as(?i32, 1920), s.quake_width);
    try std.testing.expectEqual(@as(?i32, 540), s.quake_height);
}

test "an old state file without quake keys leaves the quake frame null" {
    const s = parse("window-x = 10\nwindow-y = 20\nai-setup-prompted = 1\n");
    try std.testing.expectEqual(@as(?i32, null), s.quake_x);
    try std.testing.expectEqual(@as(?i32, null), s.quake_y);
    try std.testing.expectEqual(@as(?i32, null), s.quake_width);
    try std.testing.expectEqual(@as(?i32, null), s.quake_height);
}

test "quake frame round-trips through format and parse" {
    const original = PersistedState{ .quake_x = -7, .quake_y = 0, .quake_width = 2560, .quake_height = 720, .ai_setup_prompted = true };
    var buf: [256]u8 = undefined;
    const text = try format(&buf, original);
    const reparsed = parse(text);
    try std.testing.expectEqual(original.quake_x, reparsed.quake_x);
    try std.testing.expectEqual(original.quake_y, reparsed.quake_y);
    try std.testing.expectEqual(original.quake_width, reparsed.quake_width);
    try std.testing.expectEqual(original.quake_height, reparsed.quake_height);
}

test "mergeQuakeFrame sets the quake frame without touching windowed geometry" {
    const base = PersistedState{ .x = 1, .y = 2, .width = 1000, .height = 700, .ai_setup_prompted = true };
    const merged = mergeQuakeFrame(base, 50, 0, 1920, 600);
    // quake frame written
    try std.testing.expectEqual(@as(?i32, 50), merged.quake_x);
    try std.testing.expectEqual(@as(?i32, 0), merged.quake_y);
    try std.testing.expectEqual(@as(?i32, 1920), merged.quake_width);
    try std.testing.expectEqual(@as(?i32, 600), merged.quake_height);
    // windowed geometry + flag preserved
    try std.testing.expectEqual(@as(?i32, 1), merged.x);
    try std.testing.expectEqual(@as(?i32, 1000), merged.width);
    try std.testing.expectEqual(true, merged.ai_setup_prompted);
}
