const std = @import("std");
const build_options = @import("build_options");

const log = std.log.scoped(.preview_diagnostics);

pub const Field = struct {
    key: []const u8,
    value: []const u8,
};

pub fn formatCopyLine(buf: []u8, scope: []const u8, fields: []const Field) []const u8 {
    var len: usize = 0;
    appendSlice(buf, &len, "preview-diagnostic scope=");
    appendToken(buf, &len, scope);
    for (fields) |field| {
        appendSlice(buf, &len, " ");
        appendToken(buf, &len, field.key);
        appendSlice(buf, &len, "=\"");
        appendEscapedValue(buf, &len, field.value);
        appendSlice(buf, &len, "\"");
    }
    return buf[0..len];
}

pub fn debug(scope: []const u8, fields: []const Field) void {
    if (!build_options.debug_console) return;
    var buf: [1400]u8 = undefined;
    const line = formatCopyLine(&buf, scope, fields);
    log.debug("{s}", .{line});
}

fn appendSlice(buf: []u8, len: *usize, text: []const u8) void {
    if (len.* >= buf.len) return;
    const n = @min(buf.len - len.*, text.len);
    @memcpy(buf[len.*..][0..n], text[0..n]);
    len.* += n;
}

fn appendToken(buf: []u8, len: *usize, text: []const u8) void {
    for (text) |ch| {
        appendByte(buf, len, if (isTokenByte(ch)) ch else '_');
    }
}

fn appendEscapedValue(buf: []u8, len: *usize, text: []const u8) void {
    for (text) |ch| {
        const out = if (ch == '\r' or ch == '\n' or ch == '\t')
            ' '
        else if (ch == '"')
            '\''
        else if (ch < 0x20 or ch == 0x7f)
            '?'
        else
            ch;
        appendByte(buf, len, out);
    }
}

fn appendByte(buf: []u8, len: *usize, byte: u8) void {
    if (len.* >= buf.len) return;
    buf[len.*] = byte;
    len.* += 1;
}

fn isTokenByte(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_' or
        ch == '-' or
        ch == '.';
}

test "preview_diagnostics: formats a single-line copyable record" {
    var buf: [256]u8 = undefined;
    const line = formatCopyLine(&buf, "html", &.{
        .{ .key = "stage", .value = "open" },
        .{ .key = "path", .value = "a\"b\nc.htm" },
    });

    try std.testing.expectEqualStrings(
        "preview-diagnostic scope=html stage=\"open\" path=\"a'b c.htm\"",
        line,
    );
}

test "preview_diagnostics: truncates without creating multiline output" {
    var buf: [32]u8 = undefined;
    const line = formatCopyLine(&buf, "image", &.{
        .{ .key = "path", .value = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png" },
    });

    try std.testing.expect(line.len <= buf.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
}
