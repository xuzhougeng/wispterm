//! Pure xterm mouse *button* report encoding.
//!
//! Encodes mouse button presses, releases and drag-motion into the escape
//! sequences a PTY application (nvim, tmux, htop, …) expects when it has
//! enabled mouse tracking via DECSET `?1000h` (normal) / `?1002h` (button) /
//! `?1003h` (any), in any of the X10 / UTF-8 (1005) / SGR (1006) / urxvt
//! (1015) / SGR-pixels (1016) report formats.
//!
//! This mirrors ghostty's `src/input/mouse_encode.zig` (shouldReport /
//! buttonCode / encode) so behaviour matches the reference terminal. It is
//! intentionally dependency-free — it does NOT import `ghostty-vt` — so it
//! compiles and runs in the fast unit-test suite (`zig build test`). The
//! caller (`input.zig`) maps `ghostty_vt.MouseEvent`/`MouseFormat` onto the
//! local `Event`/`Format` enums.
//!
//! The codebase already encodes the mouse *wheel* in `input.zig`
//! (`appendMouseWheelReport`); this module covers the button events that path
//! never handled, which is why clicks did nothing inside mouse-aware TUIs.

const std = @import("std");

/// Mouse tracking mode the application requested (mutually exclusive).
pub const Event = enum { none, x10, normal, button, any };

/// Report wire format the application requested (mutually exclusive).
pub const Format = enum { x10, utf8, sgr, urxvt, sgr_pixels };

/// The button involved in an event. Wheel buttons are handled separately by
/// the existing wheel path, so only the three physical buttons appear here.
pub const Button = enum { left, middle, right };

/// The kind of event being reported.
pub const Action = enum { press, release, motion };

/// Keyboard modifiers held during the event.
pub const Mods = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

/// Returns true if an event should be reported under the active tracking
/// mode. `button` is null only for a motion event with no button held.
pub fn shouldReport(event: Event, action: Action, button: ?Button) bool {
    return switch (event) {
        .none => false,
        // X10 only reports presses of a physical button.
        .x10 => action == .press and button != null,
        // Normal mode reports presses and releases but no motion.
        .normal => action != .motion,
        // Button mode adds motion, but only while a button is held.
        .button => button != null,
        // Any mode reports everything, including button-less motion.
        .any => true,
    };
}

/// Low 7-bit button code before format framing. Mirrors ghostty buttonCode().
fn buttonCode(event: Event, format: Format, action: Action, button: ?Button, mods: Mods) u8 {
    var acc: u8 = code: {
        // Motion with no held button is reported as button 3.
        if (button == null) break :code 3;
        // Legacy (non-SGR) releases collapse to button 3 because the wire
        // format can't distinguish which button was released.
        if (action == .release and format != .sgr and format != .sgr_pixels) break :code 3;
        break :code switch (button.?) {
            .left => 0,
            .middle => 1,
            .right => 2,
        };
    };

    // X10 predates modifier reporting.
    if (event != .x10) {
        if (mods.shift) acc += 4;
        if (mods.alt) acc += 8;
        if (mods.ctrl) acc += 16;
    }

    // Motion sets the extra "drag" bit.
    if (action == .motion) acc += 32;

    return acc;
}

fn appendBytes(out: []u8, len: *usize, bytes: []const u8) bool {
    if (len.* + bytes.len > out.len) return false;
    @memcpy(out[len.* .. len.* + bytes.len], bytes);
    len.* += bytes.len;
    return true;
}

fn appendByte(out: []u8, len: *usize, byte: u8) bool {
    if (len.* >= out.len) return false;
    out[len.*] = byte;
    len.* += 1;
    return true;
}

fn appendFmt(out: []u8, len: *usize, comptime fmt: []const u8, args: anytype) bool {
    const written = std.fmt.bufPrint(out[len.*..], fmt, args) catch return false;
    len.* += written.len;
    return true;
}

/// Legacy single-/multi-byte coordinate encoding shared by X10 and UTF-8.
fn encodeLegacy(code: u8, col: usize, row: usize, out: []u8, len: *usize, utf8: bool) bool {
    if (!appendBytes(out, len, "\x1b[M")) return false;
    if (!appendByte(out, len, 32 +| code)) return false;
    if (utf8) {
        // 1005: coordinates are UTF-8 codepoints offset by 33 (32 + 1-based).
        var buf: [4]u8 = undefined;
        const x_cp: u21 = @intCast(col + 33);
        const y_cp: u21 = @intCast(row + 33);
        const xl = std.unicode.utf8Encode(x_cp, &buf) catch return false;
        if (!appendBytes(out, len, buf[0..xl])) return false;
        const yl = std.unicode.utf8Encode(y_cp, &buf) catch return false;
        if (!appendBytes(out, len, buf[0..yl])) return false;
        return true;
    }
    // X10: one byte per coordinate, 1-based, capped at column/row 223.
    if (col > 222 or row > 222) return false;
    if (!appendByte(out, len, 32 + @as(u8, @intCast(col)) + 1)) return false;
    if (!appendByte(out, len, 32 + @as(u8, @intCast(row)) + 1)) return false;
    return true;
}

/// Encode one mouse button event, appending the bytes to `out` starting at
/// `len.*` and advancing `len`. Returns true if any bytes were written.
///
/// `col`/`row` are zero-based cell coordinates; `pixel_x`/`pixel_y` are
/// terminal-space pixels used only by the SGR-pixels format.
pub fn encode(
    event: Event,
    format: Format,
    action: Action,
    button: ?Button,
    mods: Mods,
    col: usize,
    row: usize,
    pixel_x: i32,
    pixel_y: i32,
    out: []u8,
    len: *usize,
) bool {
    if (!shouldReport(event, action, button)) return false;
    const code = buttonCode(event, format, action, button, mods);
    const release = action == .release;
    return switch (format) {
        .sgr => appendFmt(out, len, "\x1b[<{d};{d};{d}{c}", .{
            code, col + 1, row + 1, @as(u8, if (release) 'm' else 'M'),
        }),
        .urxvt => appendFmt(out, len, "\x1b[{d};{d};{d}M", .{
            32 + @as(u16, code), col + 1, row + 1,
        }),
        .sgr_pixels => appendFmt(out, len, "\x1b[<{d};{d};{d}{c}", .{
            code, @max(0, pixel_x), @max(0, pixel_y), @as(u8, if (release) 'm' else 'M'),
        }),
        .x10 => encodeLegacy(code, col, row, out, len, false),
        .utf8 => encodeLegacy(code, col, row, out, len, true),
    };
}

/// Encode one wheel notch (xterm buttons 4/5, codes 64/65). Callers decide
/// whether the terminal's mouse mode reports wheel events at all.
pub fn encodeWheel(
    format: Format,
    up: bool,
    mods: Mods,
    col: usize,
    row: usize,
    pixel_x: i32,
    pixel_y: i32,
    out: []u8,
    len: *usize,
) bool {
    var code: u8 = if (up) 64 else 65;
    if (mods.shift) code += 4;
    if (mods.alt) code += 8;
    if (mods.ctrl) code += 16;
    return switch (format) {
        .sgr => appendFmt(out, len, "\x1b[<{d};{d};{d}M", .{ code, col + 1, row + 1 }),
        .urxvt => appendFmt(out, len, "\x1b[{d};{d};{d}M", .{ 32 + @as(u16, code), col + 1, row + 1 }),
        .sgr_pixels => appendFmt(out, len, "\x1b[<{d};{d};{d}M", .{ code, @max(0, pixel_x), @max(0, pixel_y) }),
        .x10 => encodeLegacy(code, col, row, out, len, false),
        .utf8 => encodeLegacy(code, col, row, out, len, true),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectEncode(
    expected: []const u8,
    event: Event,
    format: Format,
    action: Action,
    button: ?Button,
    mods: Mods,
    col: usize,
    row: usize,
    pixel_x: i32,
    pixel_y: i32,
) !void {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const wrote = encode(event, format, action, button, mods, col, row, pixel_x, pixel_y, &buf, &len);
    try testing.expect(wrote);
    try testing.expectEqualSlices(u8, expected, buf[0..len]);
}

fn expectNoEncode(
    event: Event,
    format: Format,
    action: Action,
    button: ?Button,
    mods: Mods,
) !void {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const wrote = encode(event, format, action, button, mods, 0, 0, 0, 0, &buf, &len);
    try testing.expect(!wrote);
    try testing.expectEqual(@as(usize, 0), len);
}

test "shouldReport gates by tracking mode" {
    // none: never reports
    try testing.expect(!shouldReport(.none, .press, .left));
    // x10: only button presses
    try testing.expect(shouldReport(.x10, .press, .left));
    try testing.expect(!shouldReport(.x10, .release, .left));
    try testing.expect(!shouldReport(.x10, .motion, .left));
    // normal: presses and releases, but not motion
    try testing.expect(shouldReport(.normal, .press, .left));
    try testing.expect(shouldReport(.normal, .release, .left));
    try testing.expect(!shouldReport(.normal, .motion, .left));
    // button: motion only with a held button
    try testing.expect(shouldReport(.button, .motion, .left));
    try testing.expect(!shouldReport(.button, .motion, null));
    // any: everything, including button-less motion
    try testing.expect(shouldReport(.any, .motion, null));
}

test "SGR encodes press and release with M/m and 1-based coords" {
    try expectEncode("\x1b[<0;1;1M", .normal, .sgr, .press, .left, .{}, 0, 0, 0, 0);
    try expectEncode("\x1b[<0;1;1m", .normal, .sgr, .release, .left, .{}, 0, 0, 0, 0);
    try expectEncode("\x1b[<2;5;3M", .normal, .sgr, .press, .right, .{}, 4, 2, 0, 0);
    try expectEncode("\x1b[<1;1;1M", .normal, .sgr, .press, .middle, .{}, 0, 0, 0, 0);
}

test "SGR encodes modifier bits (shift=4 alt=8 ctrl=16)" {
    try expectEncode("\x1b[<4;1;1M", .normal, .sgr, .press, .left, .{ .shift = true }, 0, 0, 0, 0);
    try expectEncode("\x1b[<8;1;1M", .normal, .sgr, .press, .left, .{ .alt = true }, 0, 0, 0, 0);
    try expectEncode("\x1b[<16;1;1M", .normal, .sgr, .press, .left, .{ .ctrl = true }, 0, 0, 0, 0);
}

test "SGR encodes motion with the +32 motion bit" {
    try expectEncode("\x1b[<32;4;2M", .button, .sgr, .motion, .left, .{}, 3, 1, 0, 0);
    // any-mode button-less motion: code 3 + 32 = 35
    try expectEncode("\x1b[<35;1;1M", .any, .sgr, .motion, null, .{}, 0, 0, 0, 0);
}

test "SGR-pixels uses pixel coordinates" {
    try expectEncode("\x1b[<0;100;50M", .normal, .sgr_pixels, .press, .left, .{}, 0, 0, 100, 50);
}

test "legacy X10 encodes single-byte coords offset by 32, release as button 3" {
    // press left @ (0,0): ESC [ M, (32+0), (32+0+1), (32+0+1)
    try expectEncode(&[_]u8{ 0x1b, '[', 'M', 32, 33, 33 }, .normal, .x10, .press, .left, .{}, 0, 0, 0, 0);
    // legacy release collapses to button 3 (32+3 = 35)
    try expectEncode(&[_]u8{ 0x1b, '[', 'M', 35, 33, 33 }, .normal, .x10, .release, .left, .{}, 0, 0, 0, 0);
}

test "UTF-8 format encodes coordinates as UTF-8 codepoints" {
    // small coord (<95) is identical to single byte
    try expectEncode(&[_]u8{ 0x1b, '[', 'M', 32, 33, 33 }, .normal, .utf8, .press, .left, .{}, 0, 0, 0, 0);
    // col 200 -> codepoint 233 (U+00E9) -> 0xC3 0xA9 multibyte; row 0 -> 33
    try expectEncode(&[_]u8{ 0x1b, '[', 'M', 32, 0xC3, 0xA9, 33 }, .normal, .utf8, .press, .left, .{}, 200, 0, 0, 0);
}

test "urxvt format frames code as 32+code with decimal coords" {
    try expectEncode("\x1b[32;1;1M", .normal, .urxvt, .press, .left, .{}, 0, 0, 0, 0);
}

test "no output when mode is none or event not reportable" {
    try expectNoEncode(.none, .sgr, .press, .left, .{});
    try expectNoEncode(.normal, .sgr, .motion, .left, .{}); // normal never reports motion
    try expectNoEncode(.x10, .sgr, .release, .left, .{}); // x10 never reports release
}

test "wheel reports use UTF-8 coordinates in 1005 mode past column 95" {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    // Column 200 -> codepoint 233, which must be the two-byte UTF-8 form, not
    // a raw 0xE9 byte (invalid UTF-8) and not a dropped event.
    try testing.expect(encodeWheel(.utf8, true, .{}, 200, 2, 0, 0, &buf, &len));
    try testing.expectEqualSlices(u8, "\x1b[M\x60\xc3\xa9\x23", buf[0..len]);

    len = 0;
    try testing.expect(encodeWheel(.utf8, false, .{}, 300, 0, 0, 0, &buf, &len));
    try testing.expect(std.unicode.utf8ValidateSlice(buf[3..len]));
}

test "wheel reports keep the SGR and X10 encodings" {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    try testing.expect(encodeWheel(.sgr, false, .{ .shift = true }, 4, 9, 0, 0, &buf, &len));
    try testing.expectEqualSlices(u8, "\x1b[<69;5;10M", buf[0..len]);

    len = 0;
    try testing.expect(encodeWheel(.x10, true, .{}, 0, 0, 0, 0, &buf, &len));
    try testing.expectEqualSlices(u8, "\x1b[M\x60\x21\x21", buf[0..len]);

    len = 0;
    try testing.expect(!encodeWheel(.x10, true, .{}, 223, 0, 0, 0, &buf, &len));
}
