//! A file/markdown/image preview as a split-tree leaf. Refcounted because
//! SplitTree is immutable: every edit clones the tree and refs each leaf so
//! versions share payloads. State here was previously the threadlocal globals
//! in preview panes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const markdown_preview = @import("markdown_preview.zig");
const preview_source = @import("input/preview_source.zig");
const preview_diagnostics = @import("preview_diagnostics.zig");
const pdf_preview = @import("pdf_preview.zig");
const pdf_render = @import("platform/pdf_render.zig");
const gpu = @import("renderer/gpu/gpu.zig");

const PreviewPane = @This();

pub const DEFAULT_WIDTH: f32 = 440; // used to derive the initial right-edge split ratio
pub const LoadStatus = enum { idle, loading, ready, failed, too_large };
pub const PreviewSourceKind = preview_source.SourceKind;
pub const PreviewReadResult = union(enum) { ok: []u8, ok_truncated: []u8, failed, too_large };
const PreviewReadFn = *const fn (Allocator, PreviewSourceKind, markdown_preview.Kind, []const u8) PreviewReadResult;
pub const PdfRenderFn = *const fn (Allocator, []const u8, u32, u32) pdf_render.RenderError!pdf_render.RenderResult;

const LOADING_SOURCE = "Loading preview...";
const FAILED_SOURCE = "Preview failed";
const TOO_LARGE_SOURCE = "Preview too large";
const IMAGE_ZOOM_MIN: f32 = 0.25;
const IMAGE_ZOOM_MAX: f32 = 16.0;
const IMAGE_ZOOM_STEP: f32 = 1.2;
// Wheel-zoom sensitivity. One classic mouse-wheel notch reports |delta| == 120;
// REF_UNITS maps that to a single IMAGE_ZOOM_STEP (1.2x). macOS precise/trackpad
// scrolling instead reports large, magnified deltas across a torrent of events
// (window_macos_bridge.m scales precise scrollingDeltaY by 10), so the wheel
// delta is fed through a continuous exponential rate and PER_EVENT_MAX caps a
// single event — a big precise delta can no longer jump straight to the clamp.
const IMAGE_ZOOM_WHEEL_REF_UNITS: f32 = 120.0;
const IMAGE_ZOOM_WHEEL_PER_EVENT_MAX: f32 = 1.25;
threadlocal var g_usize_field_buf: [32]u8 = undefined;

const PreviewJob = struct {
    request_id: u64 = 0,
    kind: markdown_preview.Kind = .markdown,
    source_kind: PreviewSourceKind = .local,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    status: LoadStatus = .failed,
    source: ?[]u8 = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    read_fn: PreviewReadFn = defaultPreviewRead,
    owner: *PreviewPane = undefined,
    pdf_input: ?[]u8 = null, // flip jobs: job-owned copy of the document
    pdf_page: u32 = 0,
    is_pdf_flip: bool = false,
    pdf_out_data: ?[]u8 = null, // on success: document bytes for the pane
    pdf_page_count: u32 = 0,
    fail_msg: ?[]const u8 = null, // static strings only
    truncated: bool = false, // text-like head was clipped to the size limit
    render_fn: PdfRenderFn = pdf_render.renderPage,
};

refcount: usize = 1,
kind: markdown_preview.Kind = .markdown,
source_kind: PreviewSourceKind = .local,
load_status: LoadStatus = .idle,
title_buf: [256]u8 = undefined,
title_len: usize = 0,
path_buf: [512]u8 = undefined,
path_len: usize = 0,
source: ?[]u8 = null,
scroll_offset: f32 = 0,
// Max vertical scroll for text/markdown/csv content, set by the renderer each
// pass from the actual height it laid out (so scrolling stops exactly at the
// last rendered line instead of falling into blank space past it).
max_scroll: f32 = 0,
// True when the source is only the head of a file that exceeded the size limit
// (text-like kinds); drives the "truncated" banner. See preview_source.PreviewRead.
content_truncated: bool = false,
image_zoom: f32 = 1.0,
image_pan_x: f32 = 0,
image_pan_y: f32 = 0,
content_generation: u64 = 0,
request_id: u64 = 0,
jobs: std.ArrayListUnmanaged(*PreviewJob) = .empty,
pdf_data: ?[]u8 = null, // page_allocator-owned original document bytes
pdf_page: u32 = 0,
pdf_page_count: u32 = 0,
pdf_pending_page: ?u32 = null, // optimistic flip target while a job runs
pdf_render_fn: PdfRenderFn = pdf_render.renderPage,
// GL image-texture cache (migrated from markdown_preview_renderer.zig). Touched
// only on the render thread.
image_texture: gpu.c.GLuint = 0,
image_width: c_int = 0,
image_height: c_int = 0,
image_generation: u64 = std.math.maxInt(u64),
image_failed: bool = false,

pub fn create(gpa: Allocator) Allocator.Error!*PreviewPane {
    const self = try gpa.create(PreviewPane);
    self.* = .{};
    return self;
}

pub fn ref(self: *PreviewPane) *PreviewPane {
    self.refcount += 1;
    return self;
}

pub fn unref(self: *PreviewPane, gpa: Allocator) void {
    std.debug.assert(self.refcount > 0);
    self.refcount -= 1;
    if (self.refcount == 0) {
        self.resetJobs();
        self.freeSource();
        self.clearPdfDocument();
        self.unloadImageTexture(); // render-thread; see GL threading assumption
        gpa.destroy(self);
    }
}

pub fn title(self: *const PreviewPane) []const u8 { return self.title_buf[0..self.title_len]; }
pub fn path(self: *const PreviewPane) []const u8 { return self.path_buf[0..self.path_len]; }
pub fn sourceText(self: *const PreviewPane) []const u8 { return self.source orelse ""; }
pub fn contentGeneration(self: *const PreviewPane) u64 { return self.content_generation; }
pub fn currentSourceKind(self: *const PreviewPane) PreviewSourceKind { return self.source_kind; }
pub fn imageZoom(self: *const PreviewPane) f32 { return self.image_zoom; }
pub fn imagePanX(self: *const PreviewPane) f32 { return self.image_pan_x; }
pub fn imagePanY(self: *const PreviewPane) f32 { return self.image_pan_y; }

fn setTitlePath(self: *PreviewPane, t: []const u8, p: []const u8) void {
    self.title_len = @min(t.len, self.title_buf.len);
    @memcpy(self.title_buf[0..self.title_len], t[0..self.title_len]);
    self.path_len = @min(p.len, self.path_buf.len);
    @memcpy(self.path_buf[0..self.path_len], p[0..self.path_len]);
}

pub fn open(self: *PreviewPane, kind: markdown_preview.Kind, t: []const u8, p: []const u8, source_text: []const u8) void {
    self.request_id +%= 1;
    self.source_kind = .local;
    self.applyOwned(kind, t, p, std.heap.page_allocator.dupe(u8, source_text) catch null, .ready);
}

fn applyOwned(self: *PreviewPane, kind: markdown_preview.Kind, t: []const u8, p: []const u8, owned: ?[]u8, status: LoadStatus) void {
    self.clearPdfDocument();
    self.kind = kind;
    self.load_status = if (owned == null and status == .ready) .failed else status;
    self.scroll_offset = 0;
    self.max_scroll = 0;
    self.content_truncated = false;
    self.image_zoom = 1.0;
    self.image_pan_x = 0;
    self.image_pan_y = 0;
    self.content_generation +%= 1;
    self.setTitlePath(t, p);
    self.freeSource();
    self.source = owned;
}

pub fn scrollBy(self: *PreviewPane, delta: f32) void {
    // Raster panes (image/pdf) use zoom/pan, not scroll. Text/markdown/csv clamp
    // to the renderer-reported content height so scrolling can't run past the
    // last rendered line into blank space (the old line-count estimate let a big
    // file scroll into a void well below its rendered content).
    if (self.kind.isRaster()) return;
    self.scroll_offset = @max(0, @min(self.max_scroll, self.scroll_offset + delta));
}

pub fn isContentTruncated(self: *const PreviewPane) bool { return self.content_truncated; }

pub fn zoomImageBySteps(self: *PreviewPane, steps: usize, zoom_in: bool) bool {
    if (!self.kind.isRaster()) return false;
    var next = self.image_zoom;
    var remaining = @max(@as(usize, 1), steps);
    while (remaining > 0) : (remaining -= 1) next = if (zoom_in) next * IMAGE_ZOOM_STEP else next / IMAGE_ZOOM_STEP;
    next = @max(IMAGE_ZOOM_MIN, @min(IMAGE_ZOOM_MAX, next));
    if (@abs(next - self.image_zoom) < 0.001) return false;
    self.image_zoom = next;
    return true;
}

/// Zoom from a raw mouse-wheel delta. Unlike zoomImageBySteps (keyboard +/-,
/// a fixed 1.2x per press), this maps the wheel delta through a continuous
/// exponential rate so macOS precise/trackpad scrolling zooms smoothly instead
/// of exploding to the clamp on a tiny scroll. A single event is bounded by
/// IMAGE_ZOOM_WHEEL_PER_EVENT_MAX.
pub fn zoomImageByWheel(self: *PreviewPane, delta: i16) bool {
    if (!self.kind.isRaster()) return false;
    if (delta == 0) return false;
    const rate: f32 = @log(IMAGE_ZOOM_STEP) / IMAGE_ZOOM_WHEEL_REF_UNITS;
    var factor: f32 = @exp(rate * @as(f32, @floatFromInt(delta)));
    // Cap a single event so a large precise/trackpad delta cannot jump the zoom.
    factor = @max(1.0 / IMAGE_ZOOM_WHEEL_PER_EVENT_MAX, @min(IMAGE_ZOOM_WHEEL_PER_EVENT_MAX, factor));
    const next = @max(IMAGE_ZOOM_MIN, @min(IMAGE_ZOOM_MAX, self.image_zoom * factor));
    if (@abs(next - self.image_zoom) < 0.0001) return false;
    self.image_zoom = next;
    return true;
}

pub fn panImageBy(self: *PreviewPane, dx: f32, dy: f32) bool {
    if (!self.kind.isRaster() or self.load_status != .ready) return false;
    if (dx == 0 and dy == 0) return false;
    self.image_pan_x += dx;
    self.image_pan_y += dy;
    return true;
}

pub fn clampImagePan(self: *PreviewPane, view_w: f32, view_h: f32, draw_w: f32, draw_h: f32) void {
    const max_x = if (draw_w > view_w) (draw_w - view_w) / 2 else 0;
    const max_y = if (draw_h > view_h) (draw_h - view_h) / 2 else 0;
    self.image_pan_x = @max(-max_x, @min(max_x, self.image_pan_x));
    self.image_pan_y = @max(-max_y, @min(max_y, self.image_pan_y));
}

pub fn beginAsyncLoad(self: *PreviewPane, kind: markdown_preview.Kind, t: []const u8, p: []const u8, source_kind: PreviewSourceKind) bool {
    return self.beginAsyncLoadWith(kind, t, p, source_kind, defaultPreviewRead);
}

fn beginAsyncLoadWith(self: *PreviewPane, kind: markdown_preview.Kind, t: []const u8, p: []const u8, source_kind: PreviewSourceKind, read_fn: PreviewReadFn) bool {
    self.request_id +%= 1;
    self.source_kind = source_kind;
    if (p.len > 512) { self.applyOwned(kind, t, p, std.heap.page_allocator.dupe(u8, FAILED_SOURCE) catch null, .failed); return false; }
    self.applyOwned(kind, t, p, std.heap.page_allocator.dupe(u8, LOADING_SOURCE) catch null, .loading);
    const alloc = std.heap.page_allocator;
    const job = alloc.create(PreviewJob) catch return false;
    job.* = .{ .request_id = self.request_id, .kind = kind, .source_kind = source_kind, .path_len = p.len, .title_len = @min(t.len, 256), .read_fn = read_fn, .render_fn = self.pdf_render_fn, .owner = self };
    @memcpy(job.path_buf[0..p.len], p);
    @memcpy(job.title_buf[0..job.title_len], t[0..job.title_len]);
    self.jobs.append(alloc, job) catch { alloc.destroy(job); return false; };
    job.thread = std.Thread.spawn(.{}, jobThread, .{job}) catch { _ = self.jobs.pop(); alloc.destroy(job); return false; };
    return true;
}

/// Returns true if a completed job changed this pane's content.
pub fn tickAsync(self: *PreviewPane) bool {
    var changed = false;
    var i: usize = 0;
    while (i < self.jobs.items.len) {
        const job = self.jobs.items[i];
        if (!job.done.load(.acquire)) { i += 1; continue; }
        if (job.thread) |th| th.join();
        _ = self.jobs.orderedRemove(i);
        defer destroyJob(job);
        if (job.request_id != self.request_id) continue;
        if (job.status == .ready and job.source != null) {
            const s = job.source.?; job.source = null;
            const keep_zoom: ?f32 = if (job.is_pdf_flip) self.image_zoom else null;
            self.applyOwned(job.kind, job.title_buf[0..job.title_len], job.path_buf[0..job.path_len], s, .ready);
            self.content_truncated = job.truncated;
            if (job.kind == .pdf) {
                if (job.pdf_out_data) |doc| {
                    job.pdf_out_data = null;
                    self.setPdfDocument(doc, job.pdf_page, job.pdf_page_count);
                }
                if (keep_zoom) |z| self.image_zoom = z;
            }
        } else if (job.is_pdf_flip) {
            // A failed flip keeps the currently displayed page; only the
            // optimistic pending target is rolled back.
            self.pdf_pending_page = null;
            continue;
        } else {
            const msg = job.fail_msg orelse if (job.status == .too_large) TOO_LARGE_SOURCE else FAILED_SOURCE;
            self.applyOwned(job.kind, job.title_buf[0..job.title_len], job.path_buf[0..job.path_len], std.heap.page_allocator.dupe(u8, msg) catch null, job.status);
        }
        changed = true;
    }
    return changed;
}

fn jobThread(job: *PreviewJob) void {
    if (job.kind == .pdf) {
        pdfJobThread(job);
        job.done.store(true, .release);
        return;
    }
    switch (job.read_fn(std.heap.page_allocator, job.source_kind, job.kind, job.path_buf[0..job.path_len])) {
        .ok => |s| {
            preview_diagnostics.debug("preview-read", &.{
                .{ .key = "stage", .value = "ok" },
                .{ .key = "kind", .value = @tagName(job.kind) },
                .{ .key = "source", .value = previewSourceKindName(job.source_kind) },
                .{ .key = "path", .value = job.path_buf[0..job.path_len] },
                .{ .key = "bytes", .value = usizeField(s.len) },
            });
            job.source = s;
            job.status = .ready;
        },
        .ok_truncated => |s| {
            preview_diagnostics.debug("preview-read", &.{
                .{ .key = "stage", .value = "ok-truncated" },
                .{ .key = "kind", .value = @tagName(job.kind) },
                .{ .key = "source", .value = previewSourceKindName(job.source_kind) },
                .{ .key = "path", .value = job.path_buf[0..job.path_len] },
                .{ .key = "bytes", .value = usizeField(s.len) },
            });
            job.source = s;
            job.status = .ready;
            job.truncated = true;
        },
        .too_large => {
            preview_diagnostics.debug("preview-read", &.{
                .{ .key = "stage", .value = "too-large" },
                .{ .key = "kind", .value = @tagName(job.kind) },
                .{ .key = "source", .value = previewSourceKindName(job.source_kind) },
                .{ .key = "path", .value = job.path_buf[0..job.path_len] },
            });
            job.status = .too_large;
        },
        .failed => {
            preview_diagnostics.debug("preview-read", &.{
                .{ .key = "stage", .value = "failed" },
                .{ .key = "kind", .value = @tagName(job.kind) },
                .{ .key = "source", .value = previewSourceKindName(job.source_kind) },
                .{ .key = "path", .value = job.path_buf[0..job.path_len] },
            });
            job.status = .failed;
        },
    }
    job.done.store(true, .release);
}

fn pdfJobThread(job: *PreviewJob) void {
    const alloc = std.heap.page_allocator;
    const data: []u8 = blk: {
        if (job.pdf_input) |d| {
            job.pdf_input = null;
            break :blk d;
        }
        switch (job.read_fn(alloc, job.source_kind, job.kind, job.path_buf[0..job.path_len])) {
            // PDFs are raster (allowsTruncatedHead == false), so a real read never
            // truncates; handle the variant defensively as a full read regardless.
            .ok, .ok_truncated => |s| break :blk s,
            .too_large => {
                job.status = .too_large;
                return;
            },
            .failed => {
                job.status = .failed;
                return;
            },
        }
    };
    const rendered = job.render_fn(alloc, data, job.pdf_page, pdf_preview.TARGET_RENDER_WIDTH) catch |err| {
        alloc.free(data);
        job.status = .failed;
        job.fail_msg = pdfFailMessage(err);
        return;
    };
    job.source = rendered.png;
    job.pdf_out_data = data;
    job.pdf_page_count = rendered.page_count;
    job.status = .ready;
}

fn previewSourceKindName(kind: PreviewSourceKind) []const u8 {
    return switch (kind) {
        .local => "local",
        .wsl => "wsl",
        .remote => "ssh",
    };
}

fn usizeField(value: usize) []const u8 {
    return std.fmt.bufPrint(&g_usize_field_buf, "{d}", .{value}) catch "";
}

fn pdfFailMessage(err: pdf_render.RenderError) []const u8 {
    return switch (err) {
        error.Unsupported => "PDF preview is not supported on this platform yet",
        error.ToolMissing => "PDF preview requires poppler-utils (pdftoppm/pdfinfo)",
        error.PasswordProtected => "Encrypted PDF is not supported",
        error.InvalidPdf => "Not a valid PDF",
        error.RenderFailed, error.OutOfMemory => FAILED_SOURCE,
    };
}

/// Start rendering the previous/next page. Returns false when not a ready
/// PDF, at the document edge, or when the job could not start. The current
/// page keeps displaying until the new raster arrives.
pub fn flipPdfPage(self: *PreviewPane, forward: bool) bool {
    if (self.kind != .pdf or self.load_status != .ready) return false;
    const data = self.pdf_data orelse return false;
    const base = self.pdf_pending_page orelse self.pdf_page;
    const target = pdf_preview.flipTarget(base, self.pdf_page_count, forward) orelse return false;

    const alloc = std.heap.page_allocator;
    const copy = alloc.dupe(u8, data) catch return false;
    // The request_id bump below invalidates any in-flight flip, so failed
    // spawn paths must also roll back the optimistic pending page.
    self.request_id +%= 1;
    const job = alloc.create(PreviewJob) catch {
        alloc.free(copy);
        self.pdf_pending_page = null;
        return false;
    };
    job.* = .{
        .request_id = self.request_id,
        .kind = .pdf,
        .source_kind = .local,
        .path_len = self.path_len,
        .title_len = self.title_len,
        .pdf_input = copy,
        .pdf_page = target,
        .is_pdf_flip = true,
        .render_fn = self.pdf_render_fn,
        .owner = self,
    };
    @memcpy(job.path_buf[0..self.path_len], self.path());
    @memcpy(job.title_buf[0..job.title_len], self.title());
    self.jobs.append(alloc, job) catch {
        destroyJob(job);
        self.pdf_pending_page = null;
        return false;
    };
    job.thread = std.Thread.spawn(.{}, jobThread, .{job}) catch {
        _ = self.jobs.pop();
        destroyJob(job);
        self.pdf_pending_page = null;
        return false;
    };
    self.pdf_pending_page = target;
    return true;
}

fn clearPdfDocument(self: *PreviewPane) void {
    if (self.pdf_data) |d| std.heap.page_allocator.free(d);
    self.pdf_data = null;
    self.pdf_page = 0;
    self.pdf_page_count = 0;
    self.pdf_pending_page = null;
}

fn setPdfDocument(self: *PreviewPane, data: []u8, page: u32, count: u32) void {
    self.clearPdfDocument();
    self.pdf_data = data;
    self.pdf_page = page;
    self.pdf_page_count = count;
}

fn defaultPreviewRead(alloc: Allocator, source_kind: PreviewSourceKind, kind: markdown_preview.Kind, p: []const u8) PreviewReadResult {
    const r = preview_source.readPreviewSourceForKind(alloc, source_kind, p, kind) catch |err|
        return if (err == error.PreviewTooLarge) .too_large else .failed;
    return if (r.truncated) .{ .ok_truncated = r.bytes } else .{ .ok = r.bytes };
}

fn freeSource(self: *PreviewPane) void {
    if (self.source) |s| std.heap.page_allocator.free(s);
    self.source = null;
}

fn resetJobs(self: *PreviewPane) void {
    for (self.jobs.items) |job| { if (job.thread) |th| th.join(); destroyJob(job); }
    self.jobs.clearAndFree(std.heap.page_allocator);
}

fn destroyJob(job: *PreviewJob) void {
    if (job.source) |s| std.heap.page_allocator.free(s);
    if (job.pdf_input) |d| std.heap.page_allocator.free(d);
    if (job.pdf_out_data) |d| std.heap.page_allocator.free(d);
    std.heap.page_allocator.destroy(job);
}

pub fn unloadImageTexture(self: *PreviewPane) void {
    if (self.image_texture != 0) { var t = gpu.Texture.fromHandle(self.image_texture); t.destroy(); self.image_texture = 0; }
    self.image_width = 0;
    self.image_height = 0;
    self.image_generation = std.math.maxInt(u64);
    self.image_failed = false;
}

fn previewReadOkForTest(alloc: Allocator, _: PreviewSourceKind, _: markdown_preview.Kind, _: []const u8) PreviewReadResult {
    return .{ .ok = alloc.dupe(u8, "# Loaded\n") catch return .failed };
}

test "PreviewPane: ref/unref balances" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    try std.testing.expectEqual(@as(usize, 1), p.refcount);
    _ = p.ref();
    try std.testing.expectEqual(@as(usize, 2), p.refcount);
    p.unref(gpa); // 1
    p.unref(gpa); // 0 -> freed (no leak reported by testing allocator)
}

test "PreviewPane: open sets content and bumps generation" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);
    const g0 = p.contentGeneration();
    p.open(.markdown, "README.md", "README.md", "# Title\n");
    try std.testing.expectEqual(LoadStatus.ready, p.load_status);
    try std.testing.expectEqualStrings("# Title\n", p.sourceText());
    try std.testing.expect(p.contentGeneration() != g0);
}

test "PreviewPane: async load stores current source kind" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);

    try std.testing.expect(switch (p.currentSourceKind()) {
        .local => true,
        else => false,
    });
    try std.testing.expect(p.beginAsyncLoadWith(.image, "a.png", "/tmp/a.png", .wsl, previewReadOkForTest));
    try std.testing.expect(switch (p.currentSourceKind()) {
        .wsl => true,
        else => false,
    });
    drainJobs(p);
    try std.testing.expectEqual(@as(usize, 0), p.jobs.items.len);
    try std.testing.expectEqual(LoadStatus.ready, p.load_status);
    try std.testing.expect(switch (p.currentSourceKind()) {
        .wsl => true,
        else => false,
    });

    p.open(.markdown, "b.md", "b.md", "# Reset\n");
    try std.testing.expect(switch (p.currentSourceKind()) {
        .local => true,
        else => false,
    });
}

test "PreviewPane: image zoom/pan are image-only and clamped" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);
    p.kind = .text;
    try std.testing.expect(!p.zoomImageBySteps(1, true));
    p.kind = .image;
    p.load_status = .ready;
    try std.testing.expect(p.zoomImageBySteps(100, true));
    try std.testing.expectEqual(@as(f32, 16.0), p.imageZoom());
    try std.testing.expect(p.panImageBy(200, -80));
    p.clampImagePan(100, 100, 300, 160);
    try std.testing.expectEqual(@as(f32, 100), p.imagePanX());
}

test "PreviewPane: wheel zoom is gentle and bounded per event (no precise-scroll explosion)" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);

    // Non-raster panes ignore wheel zoom entirely.
    p.kind = .text;
    try std.testing.expect(!p.zoomImageByWheel(600));

    p.kind = .image;
    p.load_status = .ready;

    // A single huge precise-scroll delta must NOT explode: the old path fed
    // delta=600 through mouseWheelUnits -> ~15 steps of 1.2x (>16x). One event
    // is now capped at IMAGE_ZOOM_WHEEL_PER_EVENT_MAX.
    p.image_zoom = 1.0;
    try std.testing.expect(p.zoomImageByWheel(600));
    try std.testing.expect(p.imageZoom() > 1.0);
    try std.testing.expect(p.imageZoom() <= IMAGE_ZOOM_WHEEL_PER_EVENT_MAX + 0.01);

    // A small scroll nudges the zoom only slightly.
    p.image_zoom = 1.0;
    try std.testing.expect(p.zoomImageByWheel(12));
    try std.testing.expect(p.imageZoom() < 1.05);

    // One classic wheel notch (|delta| == 120) is ~1.2x.
    p.image_zoom = 1.0;
    try std.testing.expect(p.zoomImageByWheel(120));
    try std.testing.expect(@abs(p.imageZoom() - IMAGE_ZOOM_STEP) < 0.02);

    // Negative delta zooms out, also bounded per event.
    p.image_zoom = 1.0;
    try std.testing.expect(p.zoomImageByWheel(-600));
    try std.testing.expect(p.imageZoom() < 1.0);
    try std.testing.expect(p.imageZoom() >= 1.0 / IMAGE_ZOOM_WHEEL_PER_EVENT_MAX - 0.01);

    // Repeated events still reach the max clamp, then report "no change".
    p.image_zoom = 1.0;
    var i: usize = 0;
    while (i < 400) : (i += 1) _ = p.zoomImageByWheel(600);
    try std.testing.expectEqual(IMAGE_ZOOM_MAX, p.imageZoom());
    try std.testing.expect(!p.zoomImageByWheel(600));

    // delta == 0 is a no-op.
    p.image_zoom = 2.0;
    try std.testing.expect(!p.zoomImageByWheel(0));
}

test "PreviewPane: async load applies content then clears job" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);
    try std.testing.expect(p.beginAsyncLoadWith(.markdown, "a.md", "a.md", .local, previewReadOkForTest));
    try std.testing.expectEqual(LoadStatus.loading, p.load_status);
    var attempts: usize = 0;
    while (p.jobs.items.len > 0 and attempts < 200) : (attempts += 1) { _ = p.tickAsync(); if (p.jobs.items.len > 0) std.Thread.sleep(std.time.ns_per_ms); }
    try std.testing.expectEqual(LoadStatus.ready, p.load_status);
    try std.testing.expectEqualStrings("# Loaded\n", p.sourceText());
}

fn fakePdfReadOk(alloc: Allocator, _: PreviewSourceKind, _: markdown_preview.Kind, _: []const u8) PreviewReadResult {
    return .{ .ok = alloc.dupe(u8, "%PDF-fake") catch return .failed };
}

fn fakePdfRenderOk(alloc: Allocator, pdf: []const u8, page_index: u32, _: u32) pdf_render.RenderError!pdf_render.RenderResult {
    std.debug.assert(std.mem.startsWith(u8, pdf, "%PDF-fake"));
    const png = try std.fmt.allocPrint(alloc, "PNG-page-{d}", .{page_index});
    return .{ .png = png, .page_count = 3 };
}

fn fakePdfRenderFail(_: Allocator, _: []const u8, _: u32, _: u32) pdf_render.RenderError!pdf_render.RenderResult {
    return error.ToolMissing;
}

fn drainJobs(p: *PreviewPane) void {
    var attempts: usize = 0;
    while (p.jobs.items.len > 0 and attempts < 500) : (attempts += 1) {
        _ = p.tickAsync();
        if (p.jobs.items.len > 0) std.Thread.sleep(std.time.ns_per_ms);
    }
}

test "PreviewPane: pdf load renders page 0 and caches the document" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);
    p.pdf_render_fn = fakePdfRenderOk;
    try std.testing.expect(p.beginAsyncLoadWith(.pdf, "a.pdf", "a.pdf", .local, fakePdfReadOk));
    drainJobs(p);
    try std.testing.expectEqual(LoadStatus.ready, p.load_status);
    try std.testing.expectEqualStrings("PNG-page-0", p.sourceText());
    try std.testing.expect(p.pdf_data != null);
    try std.testing.expectEqual(@as(u32, 0), p.pdf_page);
    try std.testing.expectEqual(@as(u32, 3), p.pdf_page_count);
}

test "PreviewPane: pdf page flip preserves zoom, resets pan, bumps generation" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);
    p.pdf_render_fn = fakePdfRenderOk;
    try std.testing.expect(p.beginAsyncLoadWith(.pdf, "a.pdf", "a.pdf", .local, fakePdfReadOk));
    drainJobs(p);
    p.image_zoom = 2.0;
    p.image_pan_x = 50;
    const g0 = p.contentGeneration();

    try std.testing.expect(p.flipPdfPage(true));
    drainJobs(p);
    try std.testing.expectEqualStrings("PNG-page-1", p.sourceText());
    try std.testing.expectEqual(@as(u32, 1), p.pdf_page);
    try std.testing.expectEqual(@as(f32, 2.0), p.image_zoom);
    try std.testing.expectEqual(@as(f32, 0), p.image_pan_x);
    try std.testing.expect(p.contentGeneration() != g0);

    // backward to 0; then backward again is a no-op
    try std.testing.expect(p.flipPdfPage(false));
    drainJobs(p);
    try std.testing.expectEqual(@as(u32, 0), p.pdf_page);
    try std.testing.expect(!p.flipPdfPage(false));
}

test "PreviewPane: rapid pdf flips advance from the pending page" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);
    p.pdf_render_fn = fakePdfRenderOk;
    try std.testing.expect(p.beginAsyncLoadWith(.pdf, "a.pdf", "a.pdf", .local, fakePdfReadOk));
    drainJobs(p);
    try std.testing.expect(p.flipPdfPage(true));
    try std.testing.expect(p.flipPdfPage(true));
    try std.testing.expect(!p.flipPdfPage(true)); // pending already at last page (2)
    drainJobs(p);
    try std.testing.expectEqual(@as(u32, 2), p.pdf_page);
    try std.testing.expectEqualStrings("PNG-page-2", p.sourceText());
}

test "PreviewPane: pdf render failure surfaces a specific message" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);
    p.pdf_render_fn = fakePdfRenderFail;
    try std.testing.expect(p.beginAsyncLoadWith(.pdf, "a.pdf", "a.pdf", .local, fakePdfReadOk));
    drainJobs(p);
    try std.testing.expectEqual(LoadStatus.failed, p.load_status);
    try std.testing.expect(std.mem.indexOf(u8, p.sourceText(), "poppler-utils") != null);
    try std.testing.expect(!p.flipPdfPage(true));
}

test "PreviewPane: failed pdf flip keeps the current page" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);
    p.pdf_render_fn = fakePdfRenderOk;
    try std.testing.expect(p.beginAsyncLoadWith(.pdf, "a.pdf", "a.pdf", .local, fakePdfReadOk));
    drainJobs(p);

    p.pdf_render_fn = fakePdfRenderFail;
    try std.testing.expect(p.flipPdfPage(true));
    drainJobs(p);
    try std.testing.expectEqual(LoadStatus.ready, p.load_status);
    try std.testing.expectEqualStrings("PNG-page-0", p.sourceText());
    try std.testing.expect(p.pdf_data != null);
    try std.testing.expectEqual(@as(u32, 0), p.pdf_page);
    try std.testing.expectEqual(@as(?u32, null), p.pdf_pending_page);

    // The pane stays usable: a later flip with a working rasterizer succeeds.
    p.pdf_render_fn = fakePdfRenderOk;
    try std.testing.expect(p.flipPdfPage(true));
    drainJobs(p);
    try std.testing.expectEqual(@as(u32, 1), p.pdf_page);
    try std.testing.expectEqualStrings("PNG-page-1", p.sourceText());
}

test "PreviewPane: non-pdf open clears pdf document state" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);
    p.pdf_render_fn = fakePdfRenderOk;
    try std.testing.expect(p.beginAsyncLoadWith(.pdf, "a.pdf", "a.pdf", .local, fakePdfReadOk));
    drainJobs(p);
    p.open(.markdown, "b.md", "b.md", "# hi");
    try std.testing.expect(p.pdf_data == null);
    try std.testing.expectEqual(@as(u32, 0), p.pdf_page_count);
}

fn fakeTruncatedReadOk(alloc: Allocator, _: PreviewSourceKind, _: markdown_preview.Kind, _: []const u8) PreviewReadResult {
    return .{ .ok_truncated = alloc.dupe(u8, "line1\nline2\n") catch return .failed };
}

test "PreviewPane: truncated text read is ready and flags content as truncated" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);
    try std.testing.expect(p.beginAsyncLoadWith(.text, "big.log", "big.log", .local, fakeTruncatedReadOk));
    drainJobs(p);
    try std.testing.expectEqual(LoadStatus.ready, p.load_status);
    try std.testing.expect(p.isContentTruncated());
    try std.testing.expectEqualStrings("line1\nline2\n", p.sourceText());

    // Loading new content clears the truncated flag.
    p.open(.markdown, "b.md", "b.md", "# hi");
    try std.testing.expect(!p.isContentTruncated());
}

test "PreviewPane: scrollBy clamps to the renderer-reported max_scroll" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);
    p.kind = .text;
    p.load_status = .ready;

    // No content height reported yet -> cannot scroll into a void.
    p.scrollBy(500);
    try std.testing.expectEqual(@as(f32, 0), p.scroll_offset);

    // The renderer reports the laid-out height; scroll clamps to it.
    p.max_scroll = 200;
    p.scrollBy(500);
    try std.testing.expectEqual(@as(f32, 200), p.scroll_offset);
    p.scrollBy(-1000);
    try std.testing.expectEqual(@as(f32, 0), p.scroll_offset);

    // Raster panes ignore scroll entirely (they zoom/pan instead).
    p.kind = .image;
    p.max_scroll = 200;
    p.scroll_offset = 0;
    p.scrollBy(500);
    try std.testing.expectEqual(@as(f32, 0), p.scroll_offset);
}
