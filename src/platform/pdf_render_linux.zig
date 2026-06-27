//! Linux PDF rasterizer: poppler-utils subprocesses (pdfinfo for the page
//! count, pdftoppm for a single-page PNG on stdout). The document arrives as
//! bytes (local/WSL/SSH sources), so it is staged in a private temp file.
const std = @import("std");
const pdf_render = @import("pdf_render.zig");
const pdf_preview = @import("../preview/pdf.zig");

const MAX_PNG_BYTES: usize = 64 * 1024 * 1024;

pub fn renderPage(
    alloc: std.mem.Allocator,
    pdf: []const u8,
    page_index: u32,
    target_width_px: u32,
) pdf_render.RenderError!pdf_render.RenderResult {
    var path_buf: [256]u8 = undefined;
    const path = writeTempPdf(&path_buf, pdf) catch return error.RenderFailed;
    defer std.fs.deleteFileAbsolute(path) catch {};

    const page_count = try pdfInfoPageCount(alloc, path);
    if (page_index >= page_count) return error.RenderFailed;
    const png = try renderPagePng(alloc, path, page_index, target_width_px);
    return .{ .png = png, .page_count = page_count };
}

fn writeTempPdf(buf: *[256]u8, pdf: []const u8) ![]const u8 {
    var rand_bytes: [12]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var hex: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{rand_bytes}) catch unreachable;
    const tmp_dir = std.posix.getenv("TMPDIR") orelse "/tmp";
    const path = try std.fmt.bufPrint(buf, "{s}/wispterm-pdf-{s}.pdf", .{ tmp_dir, hex });
    const file = try std.fs.createFileAbsolute(path, .{ .exclusive = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(pdf);
    return path;
}

const RunResult = struct { stdout: []u8, stderr: []u8, ok: bool };

fn runTool(alloc: std.mem.Allocator, argv: []const []const u8) pdf_render.RenderError!RunResult {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .max_output_bytes = MAX_PNG_BYTES,
    }) catch |err| return switch (err) {
        error.FileNotFound => error.ToolMissing,
        error.OutOfMemory => error.OutOfMemory,
        else => error.RenderFailed,
    };
    const ok = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .ok = ok };
}

fn pdfInfoPageCount(alloc: std.mem.Allocator, path: []const u8) pdf_render.RenderError!u32 {
    const run = try runTool(alloc, &.{ "pdfinfo", path });
    defer alloc.free(run.stdout);
    defer alloc.free(run.stderr);
    if (!run.ok) return classifyFailure(run.stderr);
    return pdf_preview.parsePdfInfoPages(run.stdout) orelse error.InvalidPdf;
}

fn renderPagePng(
    alloc: std.mem.Allocator,
    path: []const u8,
    page_index: u32,
    target_width_px: u32,
) pdf_render.RenderError![]u8 {
    var num_buf: [32]u8 = undefined;
    const argv = pdf_preview.pdftoppmArgv(&num_buf, path, page_index, target_width_px);
    const run = try runTool(alloc, &argv);
    defer alloc.free(run.stderr);
    if (!run.ok or run.stdout.len == 0) {
        alloc.free(run.stdout);
        if (!run.ok) return classifyFailure(run.stderr);
        return error.RenderFailed;
    }
    return run.stdout;
}

fn classifyFailure(stderr: []const u8) pdf_render.RenderError {
    if (pdf_preview.stderrIndicatesPassword(stderr)) return error.PasswordProtected;
    return error.InvalidPdf;
}
