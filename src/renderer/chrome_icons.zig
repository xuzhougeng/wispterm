//! Axis-aligned chrome icon geometry for the app-drawn titlebar.
//!
//! Linux (and Windows when Segoe MDL2 is missing) paints these quads instead
//! of an icon font. Hit-test and layout widths stay in `titlebar_layout`; this
//! module only decides what is drawn inside those rects.

const std = @import("std");

pub const Quad = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Kind = enum {
    menu,
    add,
    close,
    settings,
    help,
    copilot,
    command_palette,
    minimize,
    maximize,
    restore,
    /// Right-dock "Files" tab.
    folder,
    /// Right-dock open/close toggle: a window with its right pane marked.
    panel_right,
};

pub const max_quads: usize = 64;

const stroke: f32 = 1.75;

fn glyphSize(w: f32, h: f32) f32 {
    _ = h;
    // Width-only: titlebar height is often 34px while the hit target stays 46px
    // wide. Scaling by min(w,h) made the gear look undersized next to the old
    // fixed 12px fallbacks.
    return @min(12.0, w * 0.28);
}

fn append(out: []Quad, i: *usize, q: Quad) void {
    if (i.* >= out.len) return;
    if (q.w <= 0 or q.h <= 0) return;
    out[i.*] = q;
    i.* += 1;
}

fn appendLine(out: []Quad, i: *usize, x0: f32, y0: f32, x1: f32, y1: f32, t: f32) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.01) return;
    const steps = @max(2, @as(usize, @intFromFloat(@ceil(len / (t * 0.55)))));
    const last = steps - 1;
    var s: usize = 0;
    while (s < steps) : (s += 1) {
        const frac = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(last));
        const px = x0 + dx * frac;
        const py = y0 + dy * frac;
        append(out, i, .{ .x = px - t / 2, .y = py - t / 2, .w = t, .h = t });
    }
}

fn appendHBar(out: []Quad, i: *usize, cx: f32, cy: f32, width: f32, t: f32) void {
    append(out, i, .{ .x = cx - width / 2, .y = cy - t / 2, .w = width, .h = t });
}

fn appendVBar(out: []Quad, i: *usize, cx: f32, cy: f32, height: f32, t: f32) void {
    append(out, i, .{ .x = cx - t / 2, .y = cy - height / 2, .w = t, .h = height });
}

fn appendRectStroke(out: []Quad, i: *usize, x: f32, y: f32, w: f32, h: f32, t: f32) void {
    append(out, i, .{ .x = x, .y = y + h - t, .w = w, .h = t }); // top (GL y-up)
    append(out, i, .{ .x = x, .y = y, .w = w, .h = t }); // bottom
    append(out, i, .{ .x = x, .y = y, .w = t, .h = h }); // left
    append(out, i, .{ .x = x + w - t, .y = y, .w = t, .h = h }); // right
}

fn appendOctagonRing(out: []Quad, i: *usize, cx: f32, cy: f32, r: f32, t: f32) void {
    const cut = r * 0.42;
    const inner = r - t;
    // Cardinal sides.
    append(out, i, .{ .x = cx - r + cut, .y = cy + inner, .w = (r - cut) * 2, .h = t });
    append(out, i, .{ .x = cx - r + cut, .y = cy - r, .w = (r - cut) * 2, .h = t });
    append(out, i, .{ .x = cx - r, .y = cy - r + cut, .w = t, .h = (r - cut) * 2 });
    append(out, i, .{ .x = cx + inner, .y = cy - r + cut, .w = t, .h = (r - cut) * 2 });
    // Diagonal corners as short bars.
    appendLine(out, i, cx - r + cut, cy + r, cx - r, cy + r - cut, t);
    appendLine(out, i, cx + r - cut, cy + r, cx + r, cy + r - cut, t);
    appendLine(out, i, cx - r + cut, cy - r, cx - r, cy - r + cut, t);
    appendLine(out, i, cx + r - cut, cy - r, cx + r, cy - r + cut, t);
}

fn fillMenu(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    const width = g + 2.0;
    const gap = 3.5;
    appendHBar(out, i, cx, cy + gap, width, stroke);
    appendHBar(out, i, cx, cy, width, stroke);
    appendHBar(out, i, cx, cy - gap, width, stroke);
}

fn fillAdd(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    appendHBar(out, i, cx, cy, g, stroke);
    appendVBar(out, i, cx, cy, g, stroke);
}

fn fillClose(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    const arm = g * 0.42;
    appendLine(out, i, cx - arm, cy - arm, cx + arm, cy + arm, stroke);
    appendLine(out, i, cx - arm, cy + arm, cx + arm, cy - arm, stroke);
}

fn fillSettings(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    const r = g * 0.38;
    appendOctagonRing(out, i, cx, cy, r, stroke);
    const tooth = g * 0.22;
    const hub = r + 0.15;
    appendVBar(out, i, cx, cy + hub + tooth / 2, tooth, stroke);
    appendVBar(out, i, cx, cy - hub - tooth / 2, tooth, stroke);
    appendHBar(out, i, cx + hub + tooth / 2, cy, tooth, stroke);
    appendHBar(out, i, cx - hub - tooth / 2, cy, tooth, stroke);
    const diag = (hub + tooth * 0.35) * 0.72;
    appendLine(out, i, cx + diag, cy + diag, cx + diag + 1.6, cy + diag + 1.6, stroke);
    appendLine(out, i, cx - diag, cy + diag, cx - diag - 1.6, cy + diag + 1.6, stroke);
    appendLine(out, i, cx + diag, cy - diag, cx + diag + 1.6, cy - diag - 1.6, stroke);
    appendLine(out, i, cx - diag, cy - diag, cx - diag - 1.6, cy - diag - 1.6, stroke);
}

fn fillHelp(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    appendOctagonRing(out, i, cx, cy, g * 0.52, stroke);
    // Question mark, optically centered in the ring.
    const q = g * 0.22;
    appendHBar(out, i, cx + 0.2, cy + q * 1.15, q * 1.35, stroke);
    appendVBar(out, i, cx + q * 0.72, cy + q * 0.55, q * 1.15, stroke);
    appendHBar(out, i, cx + 0.15, cy + q * 0.05, q * 0.7, stroke);
    append(out, i, .{ .x = cx - 0.85, .y = cy - q * 1.15, .w = 1.7, .h = 1.7 });
}

fn fillCopilot(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    const bw = g + 3.0;
    const bh = g * 0.78;
    const rad = 2.0;
    const bx = cx - bw / 2;
    const by = cy - bh / 2 + 0.6;
    // Sides inset by the corner radius so the outline reads rounded.
    append(out, i, .{ .x = bx + rad, .y = by + bh - stroke, .w = bw - rad * 2, .h = stroke });
    append(out, i, .{ .x = bx + rad, .y = by, .w = bw - rad * 2, .h = stroke });
    append(out, i, .{ .x = bx, .y = by + rad, .w = stroke, .h = bh - rad * 2 });
    append(out, i, .{ .x = bx + bw - stroke, .y = by + rad, .w = stroke, .h = bh - rad * 2 });
    // Corner caps.
    append(out, i, .{ .x = bx, .y = by + bh - rad, .w = stroke, .h = rad - 0.2 });
    append(out, i, .{ .x = bx, .y = by + bh - stroke, .w = rad, .h = stroke });
    append(out, i, .{ .x = bx + bw - rad, .y = by + bh - stroke, .w = rad, .h = stroke });
    append(out, i, .{ .x = bx + bw - stroke, .y = by + bh - rad, .w = stroke, .h = rad - 0.2 });
    append(out, i, .{ .x = bx, .y = by, .w = rad, .h = stroke });
    append(out, i, .{ .x = bx, .y = by, .w = stroke, .h = rad });
    append(out, i, .{ .x = bx + bw - rad, .y = by, .w = rad, .h = stroke });
    append(out, i, .{ .x = bx + bw - stroke, .y = by, .w = stroke, .h = rad });
    // Tail (bottom-left), matching the wisp / speech-bubble mark.
    append(out, i, .{ .x = bx + 2.0, .y = by - 2.4, .w = stroke, .h = 2.6 });
    append(out, i, .{ .x = bx + 2.0, .y = by - 2.4, .w = 3.2, .h = stroke });
}

fn fillCommandPalette(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    // Magnifier: the command center is find-and-run, like VS Code's.
    const r = g * 0.34;
    const lx = cx - g * 0.12;
    const ly = cy + g * 0.12;
    appendOctagonRing(out, i, lx, ly, r, stroke);
    const h0 = r * 0.72;
    appendLine(out, i, lx + h0, ly - h0, cx + g * 0.42, cy - g * 0.42, stroke);
}

fn fillMinimize(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    appendHBar(out, i, cx, cy, g, stroke);
}

fn fillMaximize(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    const s = g * 0.86;
    appendRectStroke(out, i, cx - s / 2, cy - s / 2, s, s, stroke);
}

fn fillRestore(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    const s = g * 0.68;
    const off = 2.6;
    // Back square: top + right only.
    append(out, i, .{ .x = cx - s / 2 + off, .y = cy + s / 2 + off - stroke, .w = s, .h = stroke });
    append(out, i, .{ .x = cx + s / 2 + off - stroke, .y = cy - s / 2 + off, .w = stroke, .h = s });
    // Front square: full stroke.
    appendRectStroke(out, i, cx - s / 2 - off * 0.35, cy - s / 2 - off * 0.15, s, s, stroke);
}

fn fillFolder(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    const bw = g + 3.0;
    const bh = g * 0.72;
    const bx = cx - bw / 2;
    const by = cy - bh / 2 - 0.8;
    appendRectStroke(out, i, bx, by, bw, bh, stroke);
    // Tab on the top-left edge (GL y-up: above the body).
    const tab_w = bw * 0.42;
    const tab_h: f32 = 2.2;
    append(out, i, .{ .x = bx, .y = by + bh - stroke, .w = stroke, .h = tab_h + stroke });
    append(out, i, .{ .x = bx, .y = by + bh + tab_h - stroke, .w = tab_w, .h = stroke });
    append(out, i, .{ .x = bx + tab_w - stroke, .y = by + bh - stroke, .w = stroke, .h = tab_h });
}

fn fillPanelRight(out: []Quad, i: *usize, cx: f32, cy: f32, g: f32) void {
    const bw = g + 3.0;
    const bh = g * 0.86;
    const bx = cx - bw / 2;
    const by = cy - bh / 2;
    appendRectStroke(out, i, bx, by, bw, bh, stroke);
    // Divider marking the right-hand pane.
    const split_x = bx + bw * 0.62;
    append(out, i, .{ .x = split_x, .y = by, .w = stroke, .h = bh });
}

/// Write icon quads for `kind` into `out`. Returns the number of quads written.
pub fn fill(out: []Quad, kind: Kind, x: f32, y: f32, w: f32, h: f32) usize {
    var i: usize = 0;
    if (w <= 0 or h <= 0 or out.len == 0) return 0;
    const cx = x + w / 2;
    const cy = y + h / 2;
    const g = glyphSize(w, h);
    switch (kind) {
        .menu => fillMenu(out, &i, cx, cy, g),
        .add => fillAdd(out, &i, cx, cy, g),
        .close => fillClose(out, &i, cx, cy, g),
        .settings => fillSettings(out, &i, cx, cy, g),
        .help => fillHelp(out, &i, cx, cy, g),
        .copilot => fillCopilot(out, &i, cx, cy, g),
        .command_palette => fillCommandPalette(out, &i, cx, cy, g),
        .minimize => fillMinimize(out, &i, cx, cy, g),
        .maximize => fillMaximize(out, &i, cx, cy, g),
        .restore => fillRestore(out, &i, cx, cy, g),
        .folder => fillFolder(out, &i, cx, cy, g),
        .panel_right => fillPanelRight(out, &i, cx, cy, g),
    }
    return i;
}

fn quadsInsideRect(kind: Kind, x: f32, y: f32, w: f32, h: f32) !void {
    var buf: [max_quads]Quad = undefined;
    const n = fill(&buf, kind, x, y, w, h);
    try std.testing.expect(n > 0);
    try std.testing.expect(n <= max_quads);
    const pad: f32 = 2.0;
    for (buf[0..n]) |q| {
        try std.testing.expect(q.x + 0.01 >= x - pad);
        try std.testing.expect(q.y + 0.01 >= y - pad);
        try std.testing.expect(q.x + q.w <= x + w + pad + 0.01);
        try std.testing.expect(q.y + q.h <= y + h + pad + 0.01);
    }
}

test "chrome icons stay inside the button rect" {
    const kinds = std.meta.tags(Kind);
    for (kinds) |kind| {
        try quadsInsideRect(kind, 100, 200, 46, 34);
        try quadsInsideRect(kind, 0, 0, 46, 46);
    }
}

test "chrome icons collapse on a zero-width caption slot" {
    var buf: [max_quads]Quad = undefined;
    try std.testing.expectEqual(@as(usize, 0), fill(&buf, .close, 0, 0, 0, 34));
}

test "chrome icons share one optical size in a 46px titlebar button" {
    try std.testing.expectEqual(@as(f32, 12), glyphSize(46, 34));
    try std.testing.expectEqual(@as(f32, 12), glyphSize(46, 46));
    try std.testing.expectEqual(@as(f32, 0), glyphSize(0, 34));
}

test "caption restore is not the same quad set as maximize" {
    var max_buf: [max_quads]Quad = undefined;
    var rest_buf: [max_quads]Quad = undefined;
    const max_n = fill(&max_buf, .maximize, 0, 0, 46, 34);
    const rest_n = fill(&rest_buf, .restore, 0, 0, 46, 34);
    try std.testing.expect(rest_n > max_n);
}
