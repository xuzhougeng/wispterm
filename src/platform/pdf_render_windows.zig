//! Windows PDF rasterizer: system WinRT Windows.Data.Pdf via
//! pdf_render_windows_bridge.c (no bundled library, Win10+).
const std = @import("std");
const pdf_render = @import("pdf_render.zig");

extern fn wisp_pdf_render_page(
    pdf: [*]const u8,
    pdf_len: usize,
    page_index: c_uint,
    target_width: c_uint,
    out_png: *?[*]u8,
    out_png_len: *usize,
    out_page_count: *c_uint,
) c_int;
extern fn wisp_pdf_free(p: ?*anyopaque) void;

pub fn renderPage(
    alloc: std.mem.Allocator,
    pdf: []const u8,
    page_index: u32,
    target_width_px: u32,
) pdf_render.RenderError!pdf_render.RenderResult {
    var png_ptr: ?[*]u8 = null;
    var png_len: usize = 0;
    var page_count: c_uint = 0;
    const rc = wisp_pdf_render_page(pdf.ptr, pdf.len, page_index, target_width_px, &png_ptr, &png_len, &page_count);
    if (rc != 0) {
        return switch (rc) {
            2 => error.InvalidPdf,
            3 => error.PasswordProtected,
            4, 5 => error.RenderFailed,
            else => error.RenderFailed,
        };
    }
    const src = png_ptr orelse return error.RenderFailed;
    defer wisp_pdf_free(src);
    if (png_len == 0) return error.RenderFailed;
    const png = try alloc.dupe(u8, src[0..png_len]);
    return .{ .png = png, .page_count = page_count };
}
