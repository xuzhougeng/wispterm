//! Pure PDF-preview helpers: page-flip targeting, poppler output parsing,
//! and footer label formatting. Platform-independent; fast suite.
const std = @import("std");

/// Rasterization width in pixels. Zoom operates on the resulting texture.
pub const TARGET_RENDER_WIDTH: u32 = 1600;

/// 0-based page after a flip, clamped to [0, count). Null when the flip
/// would not change the page (already at an edge, or empty document).
pub fn flipTarget(current: u32, count: u32, forward: bool) ?u32 {
    if (count == 0) return null;
    const last = count - 1;
    const cur = @min(current, last);
    if (forward) {
        if (cur >= last) return null;
        return cur + 1;
    }
    if (cur == 0) return null;
    return cur - 1;
}

/// Parse the "Pages: N" line of `pdfinfo` output.
pub fn parsePdfInfoPages(text: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Pages:")) continue;
        const value = std.mem.trim(u8, line["Pages:".len..], " \t\r");
        return std.fmt.parseInt(u32, value, 10) catch null;
    }
    return null;
}

/// True when poppler stderr indicates an encrypted document.
pub fn stderrIndicatesPassword(stderr: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(stderr, "password") != null or
        std.ascii.indexOfIgnoreCase(stderr, "encrypted") != null;
}

/// "N/M" footer indicator (1-based page display).
pub fn formatPageIndicator(buf: []u8, page_index: u32, page_count: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}/{d}", .{ page_index + 1, page_count }) catch buf[0..0];
}

/// argv for rendering a single 0-based page as PNG on stdout. Slices in the
/// result point into `num_buf` (page/width digits) and `pdf_path`.
pub const PDFTOPPM_ARGC = 11;
pub fn pdftoppmArgv(
    num_buf: *[32]u8,
    pdf_path: []const u8,
    page_index: u32,
    target_width: u32,
) [PDFTOPPM_ARGC][]const u8 {
    var fbs = std.io.fixedBufferStream(num_buf);
    const w = fbs.writer();
    const page_start = fbs.pos;
    w.print("{d}", .{page_index + 1}) catch unreachable;
    const page = num_buf[page_start..fbs.pos];
    const width_start = fbs.pos;
    w.print("{d}", .{target_width}) catch unreachable;
    const width = num_buf[width_start..fbs.pos];
    return .{
        "pdftoppm",    "-png",
        "-f",          page,
        "-l",          page,
        "-scale-to-x", width,
        "-scale-to-y", "-1",
        pdf_path,
    };
}

test "flipTarget clamps to document bounds" {
    try std.testing.expectEqual(@as(?u32, 1), flipTarget(0, 3, true));
    try std.testing.expectEqual(@as(?u32, 2), flipTarget(1, 3, true));
    try std.testing.expectEqual(@as(?u32, null), flipTarget(2, 3, true));
    try std.testing.expectEqual(@as(?u32, null), flipTarget(0, 3, false));
    try std.testing.expectEqual(@as(?u32, 1), flipTarget(2, 3, false));
    try std.testing.expectEqual(@as(?u32, null), flipTarget(0, 0, true));
    try std.testing.expectEqual(@as(?u32, null), flipTarget(0, 1, true));
    // out-of-range current clamps first
    try std.testing.expectEqual(@as(?u32, 1), flipTarget(99, 3, false));
}

test "parsePdfInfoPages reads the Pages line" {
    const out = "Title:          x\nPages:          12\nEncrypted:      no\n";
    try std.testing.expectEqual(@as(?u32, 12), parsePdfInfoPages(out));
    try std.testing.expectEqual(@as(?u32, null), parsePdfInfoPages("no pages here"));
    try std.testing.expectEqual(@as(?u32, null), parsePdfInfoPages("Pages: abc"));
}

test "stderr password detection" {
    try std.testing.expect(stderrIndicatesPassword("Command Line Error: Incorrect password"));
    try std.testing.expect(stderrIndicatesPassword("Document is Encrypted"));
    try std.testing.expect(!stderrIndicatesPassword("Syntax Error: bad xref"));
}

test "page indicator formats 1-based" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("3/12", formatPageIndicator(&buf, 2, 12));
    try std.testing.expectEqualStrings("1/1", formatPageIndicator(&buf, 0, 1));
}

test "pdftoppm argv renders one page to stdout" {
    var nums: [32]u8 = undefined;
    const argv = pdftoppmArgv(&nums, "/tmp/a.pdf", 2, 1600);
    try std.testing.expectEqualStrings("pdftoppm", argv[0]);
    try std.testing.expectEqualStrings("-png", argv[1]);
    try std.testing.expectEqualStrings("-f", argv[2]);
    try std.testing.expectEqualStrings("3", argv[3]);
    try std.testing.expectEqualStrings("-l", argv[4]);
    try std.testing.expectEqualStrings("3", argv[5]);
    try std.testing.expectEqualStrings("-scale-to-x", argv[6]);
    try std.testing.expectEqualStrings("1600", argv[7]);
    try std.testing.expectEqualStrings("-scale-to-y", argv[8]);
    try std.testing.expectEqualStrings("-1", argv[9]);
    try std.testing.expectEqualStrings("/tmp/a.pdf", argv[10]);
}
