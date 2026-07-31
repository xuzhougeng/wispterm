//! Left-drag pan state machine for raster preview panes. Extracted from
//! input.zig threadlocals so the drag wiring is testable: the right-dock →
//! pane migration (PR #185) silently dropped drag-to-pan because the logic
//! lived only in untested UI glue. input.zig owns one threadlocal instance
//! and routes mouse press/move/release through it; everything stateful and
//! lifetime-sensitive (the pane ref held across the drag) lives here.
const std = @import("std");
const Allocator = std.mem.Allocator;
const PreviewPane = @import("../preview/pane.zig");

const PreviewImageDrag = @This();

pane: ?*PreviewPane = null,
last_x: f64 = 0,
last_y: f64 = 0,

pub fn active(self: *const PreviewImageDrag) bool {
    return self.pane != null;
}

/// Start a pan drag on `p` if it is a ready image/PDF preview. Replaces any stale
/// drag. The pane is ref'd for the drag's lifetime so a mid-drag tree edit
/// (e.g. a keyboard close) cannot free it under the cursor. Returns whether
/// the drag engaged (caller sets the pan cursor).
pub fn begin(self: *PreviewImageDrag, gpa: Allocator, p: *PreviewPane, x: f64, y: f64) bool {
    if (!p.kind.isRaster() or p.load_status != .ready) return false;
    self.release(gpa);
    self.pane = p.ref();
    self.last_x = x;
    self.last_y = y;
    return true;
}

/// Pan the dragged pane by the mouse delta since the last call. Returns true
/// when the pan actually changed (caller sets rebuild flags).
pub fn move(self: *PreviewImageDrag, x: f64, y: f64) bool {
    const p = self.pane orelse return false;
    const dx: f32 = @floatCast(x - self.last_x);
    const dy: f32 = @floatCast(y - self.last_y);
    self.last_x = x;
    self.last_y = y;
    return p.panImageBy(dx, dy);
}

/// End the drag, dropping the drag's pane reference. No-op when inactive.
pub fn release(self: *PreviewImageDrag, gpa: Allocator) void {
    const p = self.pane orelse return;
    self.pane = null;
    p.unref(gpa);
}

fn readyImagePaneForTest(gpa: Allocator) !*PreviewPane {
    const p = try PreviewPane.create(gpa);
    p.kind = .image;
    p.load_status = .ready;
    return p;
}

test "PreviewImageDrag: begin refuses non-image and non-ready panes" {
    const gpa = std.testing.allocator;
    var drag: PreviewImageDrag = .{};

    const md = try PreviewPane.create(gpa);
    defer md.unref(gpa);
    md.kind = .markdown;
    md.load_status = .ready;
    try std.testing.expect(!drag.begin(gpa, md, 10, 10));
    try std.testing.expect(!drag.active());
    try std.testing.expectEqual(@as(usize, 1), md.refcount);

    const loading = try PreviewPane.create(gpa);
    defer loading.unref(gpa);
    loading.kind = .image;
    loading.load_status = .loading;
    try std.testing.expect(!drag.begin(gpa, loading, 10, 10));
    try std.testing.expect(!drag.active());
    try std.testing.expectEqual(@as(usize, 1), loading.refcount);
}

test "PreviewImageDrag: begin refs the pane and engages the drag" {
    const gpa = std.testing.allocator;
    var drag: PreviewImageDrag = .{};

    const p = try readyImagePaneForTest(gpa);
    defer p.unref(gpa);

    try std.testing.expect(drag.begin(gpa, p, 100, 100));
    try std.testing.expect(drag.active());
    try std.testing.expectEqual(@as(usize, 2), p.refcount);

    drag.release(gpa);
}

test "PreviewImageDrag: begin replaces a stale drag, dropping the old ref" {
    const gpa = std.testing.allocator;
    var drag: PreviewImageDrag = .{};

    const a = try readyImagePaneForTest(gpa);
    defer a.unref(gpa);
    const b = try readyImagePaneForTest(gpa);
    defer b.unref(gpa);

    try std.testing.expect(drag.begin(gpa, a, 0, 0));
    try std.testing.expect(drag.begin(gpa, b, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), a.refcount);
    try std.testing.expectEqual(@as(usize, 2), b.refcount);
    try std.testing.expectEqual(b, drag.pane.?);

    drag.release(gpa);
}

test "PreviewImageDrag: move pans by the mouse delta and updates the anchor" {
    const gpa = std.testing.allocator;
    var drag: PreviewImageDrag = .{};

    const p = try readyImagePaneForTest(gpa);
    defer p.unref(gpa);

    try std.testing.expect(drag.begin(gpa, p, 100, 100));
    try std.testing.expect(drag.move(110, 90));
    try std.testing.expectEqual(@as(f32, 10), p.imagePanX());
    try std.testing.expectEqual(@as(f32, -10), p.imagePanY());

    // Same position again: zero delta, no pan change.
    try std.testing.expect(!drag.move(110, 90));
    try std.testing.expectEqual(@as(f32, 10), p.imagePanX());

    drag.release(gpa);
}

test "PreviewImageDrag: ready PDF panes can be dragged like images" {
    const gpa = std.testing.allocator;
    var drag: PreviewImageDrag = .{};

    const p = try PreviewPane.create(gpa);
    defer p.unref(gpa);
    p.kind = .pdf;
    p.load_status = .ready;

    try std.testing.expect(drag.begin(gpa, p, 20, 30));
    try std.testing.expect(drag.move(12, 44));
    try std.testing.expectEqual(@as(f32, -8), p.imagePanX());
    try std.testing.expectEqual(@as(f32, 14), p.imagePanY());

    drag.release(gpa);
}

test "PreviewImageDrag: move without an active drag is a no-op" {
    var drag: PreviewImageDrag = .{};
    try std.testing.expect(!drag.move(50, 50));
}

test "PreviewImageDrag: release drops the drag ref and is idempotent" {
    const gpa = std.testing.allocator;
    var drag: PreviewImageDrag = .{};

    const p = try readyImagePaneForTest(gpa);
    defer p.unref(gpa);

    try std.testing.expect(drag.begin(gpa, p, 0, 0));
    drag.release(gpa);
    try std.testing.expect(!drag.active());
    try std.testing.expectEqual(@as(usize, 1), p.refcount);
    drag.release(gpa); // second release must be a safe no-op
    try std.testing.expectEqual(@as(usize, 1), p.refcount);
}

test "PreviewImageDrag: drag keeps the pane alive after it leaves the tree" {
    const gpa = std.testing.allocator;
    var drag: PreviewImageDrag = .{};

    const p = try readyImagePaneForTest(gpa);
    try std.testing.expect(drag.begin(gpa, p, 0, 0));

    // Simulate the tree dropping its (only other) ref mid-drag, e.g. a
    // keyboard close while the button is held. The drag's ref keeps the pane
    // alive, so continued moves are safe.
    p.unref(gpa);
    try std.testing.expectEqual(@as(usize, 1), p.refcount);
    try std.testing.expect(drag.move(5, 7));

    // Release frees the pane (testing allocator flags leaks/double-frees).
    drag.release(gpa);
    try std.testing.expect(!drag.active());
}
