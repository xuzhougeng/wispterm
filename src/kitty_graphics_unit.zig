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
