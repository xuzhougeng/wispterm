//! Platform PDF rasterizer: one page of an in-memory PDF document → PNG bytes.
//! Used by the preview pane's job threads; each call is self-contained (no
//! cross-call state), so backends may init/teardown per call.
const std = @import("std");
const builtin = @import("builtin");

pub const RenderError = error{
    Unsupported,
    ToolMissing,
    InvalidPdf,
    PasswordProtected,
    RenderFailed,
    OutOfMemory,
};

pub const RenderResult = struct {
    /// PNG-encoded page raster, owned by the caller's allocator.
    png: []u8,
    /// Total pages in the document.
    page_count: u32,
};

const impl = switch (builtin.os.tag) {
    .windows => @import("pdf_render_windows.zig"),
    .macos => @import("pdf_render_macos.zig"),
    .linux => @import("pdf_render_linux.zig"),
    else => @import("pdf_render_unsupported.zig"),
};

/// Rasterize 0-based `page_index` at `target_width_px` wide (aspect kept).
pub const renderPage = impl.renderPage;
