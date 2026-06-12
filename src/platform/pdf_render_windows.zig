//! Windows PDF rasterizer stub; the WinRT Windows.Data.Pdf implementation
//! lands with the bridge in a later task.
const std = @import("std");
const pdf_render = @import("pdf_render.zig");

pub fn renderPage(
    alloc: std.mem.Allocator,
    pdf: []const u8,
    page_index: u32,
    target_width_px: u32,
) pdf_render.RenderError!pdf_render.RenderResult {
    _ = alloc;
    _ = pdf;
    _ = page_index;
    _ = target_width_px;
    return error.Unsupported;
}
