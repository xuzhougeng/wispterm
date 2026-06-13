//! Lightweight Markdown/text preview rendering for File Explorer.
//!
//! The output is plain UTF-8 text with a small amount of ANSI styling. This
//! keeps preview rendering independent from external tools such as glow/mdcat.

const std = @import("std");

pub const MAX_SOURCE_BYTES: usize = 1024 * 1024;
pub const MAX_IMAGE_SOURCE_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_PDF_SOURCE_BYTES: usize = 64 * 1024 * 1024;

pub const Kind = enum {
    markdown,
    text,
    csv,
    tsv,
    image,
    pdf,

    /// Kinds displayed as a rasterized texture (zoom/pan instead of scroll).
    pub fn isRaster(self: Kind) bool {
        return self == .image or self == .pdf;
    }
};

pub const MAX_TABLE_COLS: usize = 32;
pub const MAX_TABLE_CELL_BYTES: usize = 512;

pub const TableRow = struct {
    cells: [MAX_TABLE_COLS][]const u8 = undefined,
    count: usize = 0,
    truncated_cols: bool = false,
};

const Link = struct {
    label: []const u8,
    url: []const u8,
    end: usize,
    image: bool = false,
};

pub fn detectKind(path: []const u8) ?Kind {
    if (endsWithIgnoreCase(path, ".md") or endsWithIgnoreCase(path, ".markdown")) return .markdown;
    if (endsWithIgnoreCase(path, ".csv")) return .csv;
    if (endsWithIgnoreCase(path, ".tsv")) return .tsv;
    if (endsWithIgnoreCase(path, ".pdf")) return .pdf;
    inline for (image_file_suffixes) |suffix| {
        if (endsWithIgnoreCase(path, suffix)) return .image;
    }
    inline for (text_file_suffixes) |suffix| {
        if (endsWithIgnoreCase(path, suffix)) return .text;
    }
    return null;
}

pub fn sourceLimit(kind: Kind) usize {
    return switch (kind) {
        .markdown, .text, .csv, .tsv => MAX_SOURCE_BYTES,
        .image => MAX_IMAGE_SOURCE_BYTES,
        .pdf => MAX_PDF_SOURCE_BYTES,
    };
}

/// Whether an over-limit file of this kind should be shown as a truncated head
/// window (the first `sourceLimit` bytes) rather than refused outright. Text-like
/// kinds stream fine, so a huge log is previewable as a scrollable head; raster
/// kinds (image/pdf) can't be partially decoded, so they still fail as too-large.
pub fn allowsTruncatedHead(kind: Kind) bool {
    return !kind.isRaster();
}

pub fn isImagePath(path: []const u8) bool {
    return detectKind(path) == .image;
}

const text_file_suffixes = &.{
    ".txt",
    ".text",
    ".rs",
    ".c",
    ".h",
    ".cpp",
    ".zig",
    ".py",
    ".js",
    ".ts",
    ".json",
    ".yaml",
    ".toml",
    ".sh",
    ".r",
};

const image_file_suffixes = &.{
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".bmp",
    ".webp",
};

pub fn render(allocator: std.mem.Allocator, kind: Kind, title: []const u8, source: []const u8) ![]u8 {
    return switch (kind) {
        .markdown => renderMarkdown(allocator, title, source),
        .text, .csv, .tsv => renderText(allocator, source),
        .image, .pdf => allocator.dupe(u8, source),
    };
}

pub fn delimiterForKind(kind: Kind) ?u8 {
    return switch (kind) {
        .csv => ',',
        .tsv => '\t',
        else => null,
    };
}

pub fn parseDelimitedRow(raw_line: []const u8, delimiter: u8, buffers: *[MAX_TABLE_COLS][MAX_TABLE_CELL_BYTES]u8) TableRow {
    const line = std.mem.trimRight(u8, raw_line, "\r");
    var row: TableRow = .{};
    var i: usize = 0;

    while (i <= line.len) {
        if (row.count >= MAX_TABLE_COLS) {
            row.truncated_cols = true;
            break;
        }

        var out_len: usize = 0;
        var quoted = false;
        var was_quoted = false;
        var field_started = false;

        if (i < line.len and line[i] == '"') {
            quoted = true;
            was_quoted = true;
            field_started = true;
            i += 1;
        }

        while (i < line.len) {
            const ch = line[i];
            if (quoted) {
                if (ch == '"') {
                    if (i + 1 < line.len and line[i + 1] == '"') {
                        appendTableCellByte(&buffers[row.count], &out_len, '"');
                        i += 2;
                    } else {
                        quoted = false;
                        i += 1;
                    }
                    continue;
                }
                appendTableCellByte(&buffers[row.count], &out_len, ch);
                i += 1;
                continue;
            }

            if (ch == delimiter) break;
            if (!field_started and ch == '"') {
                quoted = true;
                was_quoted = true;
                field_started = true;
                i += 1;
                continue;
            }

            appendTableCellByte(&buffers[row.count], &out_len, ch);
            field_started = true;
            i += 1;
        }

        const raw_cell = buffers[row.count][0..out_len];
        row.cells[row.count] = if (was_quoted) raw_cell else std.mem.trim(u8, raw_cell, " \t");
        row.count += 1;

        if (i >= line.len) break;
        if (line[i] == delimiter) i += 1;
    }

    return row;
}

fn appendTableCellByte(buffer: *[MAX_TABLE_CELL_BYTES]u8, len: *usize, byte: u8) void {
    if (len.* >= buffer.len) return;
    switch (byte) {
        0x1b, '\r', '\n' => {},
        '\t' => {
            buffer[len.*] = ' ';
            len.* += 1;
        },
        0x20...0x7e, 0x80...0xff => {
            buffer[len.*] = byte;
            len.* += 1;
        },
        else => {},
    }
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn renderText(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendSanitizedText(&out, allocator, source);
    return out.toOwnedSlice(allocator);
}

fn renderMarkdown(allocator: std.mem.Allocator, title: []const u8, source: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (title.len > 0) {
        try out.appendSlice(allocator, "\x1b[1m");
        try appendSanitizedInline(&out, allocator, title);
        try out.appendSlice(allocator, "\x1b[0m\r\n");
        try appendSeparator(&out, allocator, @min(title.len, 72));
        try out.appendSlice(allocator, "\r\n");
    }

    var in_code = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        try renderMarkdownLine(&out, allocator, line, &in_code);
    }
    if (in_code) try out.appendSlice(allocator, "\x1b[0m");

    return out.toOwnedSlice(allocator);
}

fn renderMarkdownLine(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    line: []const u8,
    in_code: *bool,
) !void {
    const trimmed_left = std.mem.trimLeft(u8, line, " \t");

    if (isFence(trimmed_left)) {
        in_code.* = !in_code.*;
        if (in_code.*) {
            try out.appendSlice(allocator, "\x1b[2m----- code -----\x1b[0m\r\n");
        } else {
            try out.appendSlice(allocator, "\x1b[2m---------------\x1b[0m\r\n");
        }
        return;
    }

    if (in_code.*) {
        try out.appendSlice(allocator, "\x1b[36m");
        try appendSanitizedInline(out, allocator, line);
        try out.appendSlice(allocator, "\x1b[0m\r\n");
        return;
    }

    if (trimmed_left.len == 0) {
        try out.appendSlice(allocator, "\r\n");
        return;
    }

    if (headingBody(trimmed_left)) |heading| {
        try out.appendSlice(allocator, "\x1b[1m");
        if (heading.level <= 2) try out.appendSlice(allocator, "\x1b[4m");
        try appendSanitizedInline(out, allocator, heading.body);
        try out.appendSlice(allocator, "\x1b[0m\r\n");
        if (heading.level <= 2) try out.appendSlice(allocator, "\r\n");
        return;
    }

    if (isHorizontalRule(trimmed_left)) {
        try appendSeparator(out, allocator, 48);
        try out.appendSlice(allocator, "\r\n");
        return;
    }

    const indent_len = line.len - trimmed_left.len;
    if (std.mem.startsWith(u8, trimmed_left, ">")) {
        try appendIndent(out, allocator, indent_len);
        try out.appendSlice(allocator, "\x1b[2m| ");
        const body = std.mem.trimLeft(u8, trimmed_left[1..], " \t");
        try writeMarkdownInline(out, allocator, body);
        try out.appendSlice(allocator, "\x1b[0m\r\n");
        return;
    }

    if (listBody(trimmed_left)) |list| {
        try appendIndent(out, allocator, indent_len);
        try out.appendSlice(allocator, "\x1b[36m");
        try out.appendSlice(allocator, list.marker);
        try out.appendSlice(allocator, "\x1b[0m");
        try writeMarkdownInline(out, allocator, list.body);
        try out.appendSlice(allocator, "\r\n");
        return;
    }

    try appendIndent(out, allocator, indent_len);
    try writeMarkdownInline(out, allocator, trimmed_left);
    try out.appendSlice(allocator, "\r\n");
}

fn appendSeparator(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, desired: usize) !void {
    const count = @max(@as(usize, 12), desired);
    try out.appendSlice(allocator, "\x1b[2m");
    for (0..count) |_| try out.append(allocator, '-');
    try out.appendSlice(allocator, "\x1b[0m");
}

fn appendIndent(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, count: usize) !void {
    const capped = @min(count, 24);
    for (0..capped) |_| try out.append(allocator, ' ');
}

fn appendSanitizedText(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '\r' => {},
            '\n' => try out.appendSlice(allocator, "\r\n"),
            else => try appendSanitizedByte(out, allocator, byte),
        }
    }
}

fn appendSanitizedInline(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '\r', '\n' => {},
            else => try appendSanitizedByte(out, allocator, byte),
        }
    }
}

fn appendSanitizedByte(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, byte: u8) !void {
    switch (byte) {
        0x1b => {}, // Do not allow file content to inject terminal escapes.
        '\t' => try out.append(allocator, '\t'),
        0x20...0x7e, 0x80...0xff => try out.append(allocator, byte),
        else => {},
    }
}

const Heading = struct {
    level: usize,
    body: []const u8,
};

fn headingBody(line: []const u8) ?Heading {
    var level: usize = 0;
    while (level < line.len and line[level] == '#' and level < 6) : (level += 1) {}
    if (level == 0 or level >= line.len or line[level] != ' ') return null;
    return .{ .level = level, .body = std.mem.trimLeft(u8, line[level + 1 ..], " \t") };
}

fn isFence(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~");
}

fn isHorizontalRule(line: []const u8) bool {
    var marker: u8 = 0;
    var count: usize = 0;
    for (line) |ch| {
        if (ch == ' ' or ch == '\t') continue;
        if (ch != '-' and ch != '*' and ch != '_') return false;
        if (marker == 0) marker = ch;
        if (ch != marker) return false;
        count += 1;
    }
    return count >= 3;
}

const List = struct {
    marker: []const u8,
    body: []const u8,
};

fn listBody(line: []const u8) ?List {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and isSpace(line[1])) {
        const body = std.mem.trimLeft(u8, line[2..], " \t");
        if (std.mem.startsWith(u8, body, "[ ] ")) return .{ .marker = "[ ] ", .body = body[4..] };
        if (body.len >= 4 and body[0] == '[' and (body[1] == 'x' or body[1] == 'X') and body[2] == ']' and isSpace(body[3])) {
            return .{ .marker = "[x] ", .body = body[4..] };
        }
        return .{ .marker = "- ", .body = body };
    }

    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i > 0 and i + 1 < line.len and (line[i] == '.' or line[i] == ')') and isSpace(line[i + 1])) {
        return .{ .marker = line[0 .. i + 2], .body = std.mem.trimLeft(u8, line[i + 2 ..], " \t") };
    }
    return null;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn writeMarkdownInline(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    var bold = false;
    var code = false;
    while (i < text.len) {
        if (text[i] == '`') {
            code = !code;
            try out.appendSlice(allocator, if (code) "\x1b[33m" else "\x1b[0m");
            i += 1;
            continue;
        }
        if (i + 1 < text.len and ((text[i] == '*' and text[i + 1] == '*') or (text[i] == '_' and text[i + 1] == '_'))) {
            bold = !bold;
            try out.appendSlice(allocator, if (bold) "\x1b[1m" else "\x1b[0m");
            i += 2;
            continue;
        }
        if (parseLink(text, i)) |link| {
            if (link.image) try out.appendSlice(allocator, "image: ");
            try out.appendSlice(allocator, "\x1b[36;4m");
            try appendSanitizedInline(out, allocator, link.label);
            try out.appendSlice(allocator, "\x1b[0m");
            if (link.url.len > 0) {
                try out.appendSlice(allocator, " \x1b[2m(");
                try appendSanitizedInline(out, allocator, link.url);
                try out.appendSlice(allocator, ")\x1b[0m");
            }
            i = link.end;
            continue;
        }

        if (text[i] == '*' or text[i] == '_') {
            i += 1;
            continue;
        }
        try appendSanitizedByte(out, allocator, text[i]);
        i += 1;
    }
    if (bold or code) try out.appendSlice(allocator, "\x1b[0m");
}

fn parseLink(text: []const u8, start: usize) ?Link {
    var image = false;
    var bracket = start;
    if (text[start] == '!') {
        if (start + 1 >= text.len or text[start + 1] != '[') return null;
        image = true;
        bracket = start + 1;
    } else if (text[start] != '[') {
        return null;
    }

    const close_rel = std.mem.indexOfScalar(u8, text[bracket + 1 ..], ']') orelse return null;
    const close = bracket + 1 + close_rel;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    const url_start = close + 2;
    const url_rel = std.mem.indexOfScalar(u8, text[url_start..], ')') orelse return null;
    const url_end = url_start + url_rel;

    return .{
        .label = text[bracket + 1 .. close],
        .url = text[url_start..url_end],
        .end = url_end + 1,
        .image = image,
    };
}

test "detect preview kind" {
    try std.testing.expectEqual(Kind.markdown, detectKind("README.md").?);
    try std.testing.expectEqual(Kind.markdown, detectKind("notes.MARKDOWN").?);
    try std.testing.expectEqual(Kind.csv, detectKind("sample.CSV").?);
    try std.testing.expectEqual(Kind.tsv, detectKind("matrix.tsv").?);
    try std.testing.expectEqual(Kind.text, detectKind("log.TXT").?);
    try std.testing.expectEqual(Kind.text, detectKind("main.rs").?);
    try std.testing.expectEqual(Kind.text, detectKind("main.c").?);
    try std.testing.expectEqual(Kind.text, detectKind("main.h").?);
    try std.testing.expectEqual(Kind.text, detectKind("main.cpp").?);
    try std.testing.expectEqual(Kind.text, detectKind("main.zig").?);
    try std.testing.expectEqual(Kind.text, detectKind("script.py").?);
    try std.testing.expectEqual(Kind.text, detectKind("app.js").?);
    try std.testing.expectEqual(Kind.text, detectKind("app.ts").?);
    try std.testing.expectEqual(Kind.text, detectKind("package.json").?);
    try std.testing.expectEqual(Kind.text, detectKind("config.yaml").?);
    try std.testing.expectEqual(Kind.text, detectKind("Cargo.toml").?);
    try std.testing.expectEqual(Kind.text, detectKind("deploy.sh").?);
    try std.testing.expectEqual(Kind.text, detectKind("plot.r").?);
    try std.testing.expectEqual(Kind.text, detectKind("model.R").?);
    try std.testing.expectEqual(Kind.image, detectKind("image.png").?);
    try std.testing.expectEqual(Kind.image, detectKind("photo.JPEG").?);
    try std.testing.expectEqual(Kind.pdf, detectKind("paper.pdf").?);
    try std.testing.expectEqual(Kind.pdf, detectKind("REPORT.PDF").?);
    try std.testing.expectEqual(MAX_PDF_SOURCE_BYTES, sourceLimit(.pdf));
    try std.testing.expectEqual(MAX_SOURCE_BYTES, sourceLimit(.markdown));
    try std.testing.expectEqual(MAX_SOURCE_BYTES, sourceLimit(.text));
    try std.testing.expectEqual(MAX_SOURCE_BYTES, sourceLimit(.csv));
    try std.testing.expectEqual(MAX_SOURCE_BYTES, sourceLimit(.tsv));
    try std.testing.expectEqual(MAX_IMAGE_SOURCE_BYTES, sourceLimit(.image));
}

test "raster kinds are image and pdf" {
    try std.testing.expect(Kind.image.isRaster());
    try std.testing.expect(Kind.pdf.isRaster());
    try std.testing.expect(!Kind.markdown.isRaster());
    try std.testing.expect(!Kind.text.isRaster());
    try std.testing.expect(!Kind.csv.isRaster());
    try std.testing.expect(!Kind.tsv.isRaster());
}

test "text-like kinds allow a truncated head; raster kinds do not" {
    // A huge log/markdown/csv shows its head and scrolls; image/pdf can't be
    // partially decoded, so they still fail as too-large.
    try std.testing.expect(allowsTruncatedHead(.text));
    try std.testing.expect(allowsTruncatedHead(.markdown));
    try std.testing.expect(allowsTruncatedHead(.csv));
    try std.testing.expect(allowsTruncatedHead(.tsv));
    try std.testing.expect(!allowsTruncatedHead(.image));
    try std.testing.expect(!allowsTruncatedHead(.pdf));
}

test "delimited row parser handles csv quotes and tsv" {
    var buffers: [MAX_TABLE_COLS][MAX_TABLE_CELL_BYTES]u8 = undefined;

    const csv = parseDelimitedRow("name,\"hello, world\",\"a\"\"b\", 42 ", ',', &buffers);
    try std.testing.expectEqual(@as(usize, 4), csv.count);
    try std.testing.expectEqualStrings("name", csv.cells[0]);
    try std.testing.expectEqualStrings("hello, world", csv.cells[1]);
    try std.testing.expectEqualStrings("a\"b", csv.cells[2]);
    try std.testing.expectEqualStrings("42", csv.cells[3]);

    const tsv = parseDelimitedRow("gene\tcount\tvalue", '\t', &buffers);
    try std.testing.expectEqual(@as(usize, 3), tsv.count);
    try std.testing.expectEqualStrings("gene", tsv.cells[0]);
    try std.testing.expectEqualStrings("count", tsv.cells[1]);
    try std.testing.expectEqualStrings("value", tsv.cells[2]);
}

test "markdown render strips structural markers" {
    const rendered = try render(std.testing.allocator, .markdown, "doc.md", "# Title\n\n- **item**\n```zig\nconst x = 1;\n```\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "# Title") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "- ") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "item") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "const x = 1;") != null);
}

test "text render sanitizes escapes and normalizes newlines" {
    const rendered = try render(std.testing.allocator, .text, "plain.txt", "safe\x1b[31m\nnext");
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[31m") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "safe[31m\r\nnext") != null);
}
