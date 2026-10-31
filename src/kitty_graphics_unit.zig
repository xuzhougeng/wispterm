const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Surface = @import("Surface.zig");
const termio = @import("termio.zig");

test "kitty graphics APC transmit and display creates image placement" {
    const allocator = std.testing.allocator;

    var terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 5,
        .kitty_image_storage_limit = 1024 * 1024,
        .kitty_image_loading_limits = .all,
    });
    defer terminal.deinit(allocator);

    var handler = terminal.vtHandler();
    defer handler.deinit();

    var stream = ghostty_vt.Stream(@TypeOf(handler)).initAlloc(
        terminal.screens.active.alloc,
        handler,
    );
    defer stream.deinit();

    stream.nextSlice("\x1b_Ga=T,f=32,t=d,i=1,p=1,s=1,v=1,c=1,r=1;/////w==\x1b\\");

    const storage = &terminal.screens.active.kitty_images;
    try std.testing.expect(storage.imageById(1) != null);
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    try std.testing.expect(storage.dirty);
}

test "kitty graphics APC chunked transmit creates image placement" {
    const allocator = std.testing.allocator;

    var terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 5,
        .kitty_image_storage_limit = 1024 * 1024,
        .kitty_image_loading_limits = .all,
    });
    defer terminal.deinit(allocator);

    var handler = terminal.vtHandler();
    defer handler.deinit();

    var stream = ghostty_vt.Stream(@TypeOf(handler)).initAlloc(
        terminal.screens.active.alloc,
        handler,
    );
    defer stream.deinit();

    stream.nextSlice("\x1b_Ga=T,f=32,t=d,i=2,p=2,s=1,v=1,c=1,r=1,m=1;////\x1b\\");
    stream.nextSlice("\x1b_Gm=0;/w==\x1b\\");

    const storage = &terminal.screens.active.kitty_images;
    try std.testing.expect(storage.imageById(2) != null);
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    try std.testing.expect(storage.dirty);
}

test "wispterm image OSC fallback translates to kitty graphics APC" {
    const allocator = std.testing.allocator;

    var surface: Surface = undefined;
    surface.allocator = allocator;
    surface.terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 5,
        .kitty_image_storage_limit = 1024 * 1024,
        .kitty_image_loading_limits = .all,
    });
    defer surface.terminal.deinit(allocator);

    surface.wispterm_image_osc_state = .ground;
    surface.wispterm_image_osc_buf = .empty;
    defer surface.wispterm_image_osc_buf.deinit(allocator);

    // The terminal now answers queries/transmissions back to the PTY (issue
    // #302), and a kitty graphics transmit emits an "OK" reply, so the surface
    // needs a real mailbox to receive it instead of writing through garbage.
    surface.mailbox = try termio.Mailbox.init();
    defer surface.mailbox.deinit();
    surface.io_state_mutex = .{};
    surface.io_state = .running;
    surface.exited = std.atomic.Value(bool).init(false);

    surface.vt_stream = Surface.VtStream.initAlloc(
        surface.terminal.screens.active.alloc,
        Surface.VtHandler.init(&surface.terminal, &surface),
    );
    defer surface.vt_stream.deinit();

    surface.feedVtWithWispTermImageFallback("x\x1b]7747;WispTermImage=a=T,f=32,");
    surface.feedVtWithWispTermImageFallback("t=d,i=3,p=3,s=1,v=1,c=1,r=1;/////w==\x07y");

    const storage = &surface.terminal.screens.active.kitty_images;
    try std.testing.expect(storage.imageById(3) != null);
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    try std.testing.expect(storage.dirty);
}

// ---------------------------------------------------------------------------
// Kitty unicode placeholders (virtual placements, `a=T,U=1`).
//
// yazi picks this driver whenever TERM_PROGRAM says "ghostty" (issue #704). The
// stream below is byte-for-byte what `yazi-adapter/src/drivers/kgp.rs` emits:
// a chunked `a=T,C=1,U=1` transmit with no `c=`/`r=`, then one `CSI H` per row
// followed by U+10EEEE + row diacritic + column diacritic per cell, with the
// image id carried in the foreground colour. ghostty-vt stores the image and
// flags the rows; `image_renderer.snapshot` must turn each row's run into a
// placement covering exactly that row's slice of the picture (Ghostty:
// renderer/image.zig `prepKittyVirtualPlacement`).
// ---------------------------------------------------------------------------

const Renderer = @import("renderer/Renderer.zig");
const cell_renderer = @import("renderer/cell_renderer.zig");
const font = @import("font/manager.zig");

/// Leading entries of the kitty row/column diacritic table (shared by yazi).
const placeholder_diacritics = [_]u21{ 0x0305, 0x030D, 0x030E, 0x0310 };

fn appendCodepoint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    try list.appendSlice(allocator, buf[0..n]);
}

fn appendFmt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [192]u8 = undefined;
    try list.appendSlice(allocator, try std.fmt.bufPrint(&buf, fmt, args));
}

fn placementForRow(rend: *const Renderer, grid_row: i32) ?Renderer.KittyPlacement {
    for (rend.kitty_placements.items) |p| {
        if (p.grid_row == grid_row) return p;
    }
    return null;
}

test "yazi unicode placeholders (a=T,U=1) resolve to one virtual placement per row" {
    const allocator = std.testing.allocator;

    var surface: Surface = undefined;
    surface.allocator = allocator;
    surface.terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 20,
        .rows = 6,
        .kitty_image_storage_limit = 1024 * 1024,
        .kitty_image_loading_limits = .all,
    });
    defer surface.terminal.deinit(allocator);
    surface.selection = .{};

    var rend = Renderer.init(&surface);
    defer rend.deinit();
    cell_renderer.g_current_render_surface = &surface;
    defer cell_renderer.g_current_render_surface = null;

    var handler = surface.terminal.vtHandler();
    defer handler.deinit();
    var stream = ghostty_vt.Stream(@TypeOf(handler)).initAlloc(
        surface.terminal.screens.active.alloc,
        handler,
    );
    defer stream.deinit();

    // yazi downscales the picture to the preview area first, so the pixel size
    // is a whole number of cells: 3 columns x 2 rows placed at column 4, row 1.
    const cell_w: u32 = @intFromFloat(font.cell_width);
    const cell_h: u32 = @intFromFloat(font.cell_height);
    const area_cols: u32 = 3;
    const area_rows: u32 = 2;
    const area_x: u32 = 4;
    const area_y: u32 = 1;
    const img_w = area_cols * cell_w;
    const img_h = area_rows * cell_h;
    const image_id: u32 = 0x010203; // yazi: process id modulo 2^24

    const raw = try allocator.alloc(u8, img_w * img_h * 3);
    defer allocator.free(raw);
    @memset(raw, 0x7f);
    const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, raw);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    // Transmit + virtual display, chunked at 4096 bytes like yazi's output_b64.
    var off: usize = 0;
    while (off < b64.len) {
        const end = @min(off + 4096, b64.len);
        const more: u8 = if (end < b64.len) 1 else 0;
        if (off == 0) {
            try appendFmt(&payload, allocator, "\x1b_Gq=2,a=T,C=1,U=1,f=24,s={d},v={d},i={d},m={d};", .{ img_w, img_h, image_id, more });
        } else {
            try appendFmt(&payload, allocator, "\x1b_Gm={d};", .{more});
        }
        try payload.appendSlice(allocator, b64[off..end]);
        try payload.appendSlice(allocator, "\x1b\\");
        off = end;
    }

    // Placement text (yazi `Kgp::place`): the image id rides in the fg colour,
    // then per row one cursor move and one placeholder cell per column.
    try appendFmt(&payload, allocator, "\x1b[38;2;{d};{d};{d}m", .{
        (image_id >> 16) & 0xff,
        (image_id >> 8) & 0xff,
        image_id & 0xff,
    });
    for (0..area_rows) |y| {
        try appendFmt(&payload, allocator, "\x1b[{d};{d}H", .{ area_y + y + 1, area_x + 1 });
        for (0..area_cols) |x| {
            try appendCodepoint(&payload, allocator, ghostty_vt.kitty.graphics.unicode.placeholder);
            try appendCodepoint(&payload, allocator, placeholder_diacritics[y]);
            try appendCodepoint(&payload, allocator, placeholder_diacritics[x]);
        }
    }
    try payload.appendSlice(allocator, "\x1b[0m");

    stream.nextSlice(payload.items);

    const storage = &surface.terminal.screens.active.kitty_images;
    try std.testing.expect(storage.imageById(image_id) != null);
    // The transmit created a *virtual* placement; it must not draw by itself.
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());

    try std.testing.expect(cell_renderer.updateTerminalCellsForSurface(&rend, &surface.terminal, true));

    try std.testing.expectEqual(@as(usize, area_rows), rend.kitty_placements.items.len);
    for (0..area_rows) |y| {
        const grid_row: i32 = @intCast(area_y + y);
        const p = placementForRow(&rend, grid_row) orelse return error.MissingRowPlacement;
        const row_f: f32 = @floatFromInt(y);
        const rows_f: f32 = @floatFromInt(area_rows);
        try std.testing.expectEqual(image_id, p.image_id);
        try std.testing.expectEqual(@as(i32, @intCast(area_x)), p.grid_col);
        // Each row paints the full width of the area and one cell of height,
        // sampling exactly that row's horizontal band of the texture.
        try std.testing.expectEqual(@as(f32, @floatFromInt(img_w)), p.width);
        try std.testing.expectEqual(@as(f32, @floatFromInt(cell_h)), p.height);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), p.offset_x, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), p.offset_y, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), p.uv_left, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), p.uv_right, 0.001);
        try std.testing.expectApproxEqAbs(row_f / rows_f, p.uv_top, 0.001);
        try std.testing.expectApproxEqAbs((row_f + 1) / rows_f, p.uv_bottom, 0.001);
        try std.testing.expectEqual(Renderer.KittyLayer.below_text, p.layer);
    }
    // The picture itself is queued for one GPU upload.
    try std.testing.expectEqual(@as(usize, 1), rend.kitty_pending_uploads.items.len);
    try std.testing.expectEqual(image_id, rend.kitty_pending_uploads.items[0].image_id);

    // yazi `Kgp::image_erase`: overwrite the area with spaces, then `a=d,d=A`.
    // Nothing may remain to draw. The virtual placement itself survives in
    // storage: ghostty-vt (like kitty) skips `.virtual` placements for the
    // delete-all forms, so the image stays resident until it is deleted by id
    // or evicted; with no placeholder cells left it is simply never drawn.
    payload.clearRetainingCapacity();
    for (0..area_rows) |y| {
        try appendFmt(&payload, allocator, "\x1b[{d};{d}H", .{ area_y + y + 1, area_x + 1 });
        for (0..area_cols) |_| try payload.appendSlice(allocator, " ");
    }
    try payload.appendSlice(allocator, "\x1b[0m\x1b_Gq=2,a=d,d=A\x1b\\");
    stream.nextSlice(payload.items);

    try std.testing.expect(cell_renderer.updateTerminalCellsForSurface(&rend, &surface.terminal, true));
    try std.testing.expectEqual(@as(usize, 0), rend.kitty_placements.items.len);
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    try std.testing.expect(storage.imageById(image_id) != null);
}
