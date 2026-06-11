# Preview Panel as a First-Class Tiling Pane — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Markdown/text/image preview a normal split-tree pane — created by Ctrl+click, focusable/navigable/swappable/resizable/zoomable like a terminal — by turning the split-tree leaf into a `Pane` sum type and converting the preview *singleton* into a per-instance `PreviewPane`.

**Architecture:** The split-tree leaf changes from `*Surface` (terminal-only) to `Pane = union { terminal: *Surface, preview: *PreviewPane }` (`copilot`/`webview` arms are left for later). `PreviewPane` is a refcounted object holding the state that is today a pile of threadlocal globals in `markdown_preview_panel.zig` (kind, title, path, source, scroll, image zoom/pan, async jobs, GL image-texture cache). Two iterators contain churn: `surfaces()` (terminal-only) for PTY/snapshot/layout work, `panes()` (all leaves) for render/focus/persistence. The right-dock is removed at the end; newly created previews default to the tab's right edge.

**Tech Stack:** Zig; the project's own `SplitTree`, `Surface`, GPU renderer (`src/renderer/*`, `ui_pipeline`, `stb_image`), async preview loader (`markdown_preview_panel.zig`), session persistence (`session_persist.zig`, `std.json`).

**Spec:** `docs/superpowers/specs/2026-06-09-preview-tiling-panel-design.md`

---

## Orientation (read once before starting)

**Build / test commands**
- Fast suite (pure logic, native): `zig build test`
- Full suite (app graph): `zig build test-full`
- `split_tree.zig`, `session_persist.zig`, `appwindow/tab.zig`, renderer modules run under **test-full**.
- **Test wiring gotcha:** a Zig test only runs if its file is `_ = @import`ed in `src/test_fast.zig` (fast) or `src/test_main.zig` (full). A NEW file MUST be added there or its tests silently never run. `markdown_preview_panel.zig` is already registered (its tests run under test-full).

**The compiler is your worklist.** `SplitTree.Node.leaf` is currently `*Surface`. Changing it to `Pane` makes Zig flag *every* `.leaf => |surface|` destructure and `tree.iterator()` payload use. Build after the type change and walk the errors — that is the authoritative list of sites. Grep counts below are a guide, not the source of truth.

**Known `.leaf` footprint** (files that destructure `.leaf` today): `src/split_tree.zig`, `src/appwindow/tab.zig`, `src/appwindow/split_layout.zig`, `src/session_persist.zig`, `src/renderer/overlays.zig`. Plus ~38 `tree.iterator()` callers across `AppWindow.zig`, `appwindow/tab.zig`, `appwindow/split_layout.zig`, and several `renderer/*` files.

**Key facts discovered during planning (rely on these):**
- `markdown_preview_panel.zig` is a **singleton**: all state is `pub threadlocal var g_*` (`g_visible`, `g_owner_tab`, `g_width`, `g_kind`, `g_scroll_offset`, `g_load_status`, `g_title_buf/len`, `g_path_buf/len`, `g_source`, `g_content_generation`, `g_image_zoom/pan_x/pan_y`, `g_preview_request_id`, `g_preview_jobs`). Public API: `width()`, `isVisibleForActiveTab()`, `open(kind,title,path,source)`, `beginAsyncLoad(kind,title,path,source_kind)`, `tickAsync()`, `close()`, `title()`, `path()`, `source()`, `contentGeneration()`, `scrollBy(delta)`, `zoomImageBySteps(steps,in)`, `panImageBy(dx,dy)`, `clampImagePan(...)`, `imageZoom()/imagePanX()/imagePanY()`, `setWidth(w,winw)`, `maxWidthForWindow(w)`, `onTabClosed(i)`, `onTabReordered(a,b)`, `deinit()`. Async jobs use `std.heap.page_allocator`.
- `markdown_preview_renderer.zig` reads those globals directly (`panel.g_kind`, `panel.g_scroll_offset`, `panel.g_load_status`, `panel.title()`, `panel.path()`, `panel.source()`, `panel.width()`, `panel.isVisibleForActiveTab()`, `panel.contentGeneration()`, `panel.imageZoom/imagePanX/imagePanY/clampImagePan`). Entry: `render(window_width, window_height, titlebar_h, right_offset)` → computes `panel_x = window_width - right_offset - panel_w` and draws header/footer/document. Its **own** threadlocal image-texture cache: `g_image_texture/width/height/generation/failed`, `ensureImageTexture()` (keyed on `panel.contentGeneration()`), `unloadImageTexture()`, `deinit()`. All GL calls run on the render thread.
- `SplitTree` (`split_tree.zig`): `Node = union(enum){ leaf: *Surface, split: Split }` (46); `init(gpa, *Surface)` (83) does `nodes[0] = .{ .leaf = surface.ref() }`; `deinit` (98) unrefs each leaf; `clone`/`refNodes` ref each leaf; `iterator()` (154) yields `SurfaceEntry{handle, surface:*Surface}` skipping splits; `swapLeaves` (426) swaps two leaf payloads, asserting leaf-ness; `readingOrder`/`spatial`/`deepest`/`previous`/`nextHandle`/`nearest` switch on `.leaf`/`.split` and **ignore the payload**; `fromSnapshot` (~1093) rebuilds via a `*const fn(*SurfaceSnap, Allocator) ?*Surface` factory. `Surface.ref()` / `Surface.unref(gpa)` exist.
- `split_layout.zig`: `SplitRect{ x,y,width,height,cols,rows, surface:*Surface, handle }` (23); `computeSplitLayout` (142) iterates `tree.iterator()`, computes a pixel rect per leaf, calls `surface.setScreenSizeWithPolicy(...)`, stores `g_split_rects[...]`. `surfaceAtPoint(x,y) ?*Surface` (61) + `cachedRectIsLive(rect)` (50) compare `surface == rect.surface`. `hitTestDivider` (76) is payload-agnostic.
- Right-dock width is reserved in `AppWindow.zig` `rightPanelsWidth*` (~2369–2379: `markdown_preview_panel.width() + browser_panel.width() + copilot_w`). Async tick is pumped at `AppWindow.zig:6138` (`markdown_preview_panel.tickAsync()`). In-memory previews (SKILL.md) open via `markdown_preview_panel.open(...)` at `AppWindow.zig:1565` and `:3548`.
- `input.zig` preview sites: `markdown_preview_panel.close()` (677); visibility/width hit-tests for resize (2006–2199, incl. `g_markdown_preview_resize_dragging`); `openPreviewAsync(kind,title,path,source_kind)` (2968) + `terminalPreviewSourceKind`/`fileExplorerPreviewSourceKind` (2983–2991); image pan (4152), image cursor (3471/3857/4279), wheel scroll/zoom (4610–4614).
- `session_persist.zig`: `SurfaceSnap` (16), `NodeSnap{leaf:LeafSnap, split:SplitSnap}` (39), `LeafSnap{surface:SurfaceSnap}` (43), `TabSnap{focused_leaf, zoomed_leaf, tree}` (61), `SCHEMA_VERSION = 1` (12), JSON via `std.json` tagged-union default encoding. `markdown_preview.Kind = enum{ markdown, text, csv, tsv, image }`.

**GL threading assumption (verify during GUI test):** split-tree edits and tab/pane teardown run on the UI thread, which owns the GL context (same thread the renderer runs on). Therefore `PreviewPane.deinit` may delete its GL texture directly. Async preview *loads* run on worker threads but only set a `done` flag and never free a pane. If a future change frees panes off the render thread, switch texture deletion to a render-thread-drained orphan list.

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/preview_pane.zig` | **New.** Refcounted `PreviewPane`: kind/title/path/source/scroll/image-zoom-pan, async jobs, GL image-texture cache, `create/ref/unref/deinit` + all the per-instance methods migrated from the panel singleton. | Create |
| `src/markdown_preview_panel.zig` | Becomes a thin **dock shim** around one `PreviewPane` instance (Phase 1), then is deleted/reduced once the dock is removed (Phase 5). | Modify → shrink |
| `src/split_tree.zig` | `Pane` union, `Node.leaf: Pane`, `ref/unref` dispatch, `initPane`, `surfaces()`+`panes()` iterators; update internal leaf sites + tests; `fromSnapshot` builds preview leaves. | Modify |
| `src/renderer/markdown_preview_renderer.zig` | Rect+pane core `renderInto(pane, panel_x, panel_top, panel_w, panel_h, ...)`; image-texture cache moves into the pane. | Modify |
| `src/appwindow/split_layout.zig` | `SplitRect` carries a `Pane`; layout iterates `panes()` and skips surface-resize for preview; `paneAtPoint`/`handleAtPoint`. | Modify |
| `src/appwindow/tab.zig` | `splitIntoPreview`, reuse-target + right-edge placement helpers; pane-aware focusedSurface/snapshot/restore; drop owner tracking. | Modify |
| `src/AppWindow.zig` | Per-leaf draw dispatch, focused-preview input routing, remove right-dock width reservation, per-pane async tick, "Split → Preview" command, reroute SKILL.md opens. | Modify |
| `src/input.zig` | Ctrl+click reuse-else-create; Ctrl+Shift+click new; focused-preview scroll/zoom/pan; remove dock resize hit-test. | Modify |
| `src/session_persist.zig` | `LeafSnap` gains `kind` + `preview: ?PreviewSnap`; `SCHEMA_VERSION` bump; round-trip. | Modify |
| `src/command_center_state.zig` / command registry | "Split → Preview" entry. | Modify |

---

# Phase 1 — Extract `PreviewPane` (right-dock keeps working, now instance-backed)

This phase introduces the per-instance type and re-backs the existing right-dock with a single instance. No tree changes yet; the app looks and behaves identically.

### Task 1: `PreviewPane` type + ported instance tests

**Files:**
- Create: `src/preview_pane.zig`
- Test: same file (already discoverable once `markdown_preview_panel.zig` imports it; also register in `src/test_main.zig` — Step 5)

- [ ] **Step 1: Write the new file with migrated state + a refcount test**

Create `src/preview_pane.zig`. Move the singleton's state into fields and its pure logic into methods. Keep using `std.heap.page_allocator` for `source`/jobs exactly as the singleton does today; use the passed `gpa` only for the struct + refcount.

```zig
//! A file/markdown/image preview as a split-tree leaf. Refcounted because
//! SplitTree is immutable: every edit clones the tree and refs each leaf so
//! versions share payloads. State here was previously the threadlocal globals
//! in markdown_preview_panel.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;
const markdown_preview = @import("markdown_preview.zig");
const preview_source = @import("input/preview_source.zig");
const gpu = @import("AppWindow.zig").gpu;

const PreviewPane = @This();

pub const DEFAULT_WIDTH: f32 = 440; // used to derive the initial right-edge split ratio
pub const LoadStatus = enum { idle, loading, ready, failed, too_large };
pub const PreviewSourceKind = preview_source.SourceKind;
pub const PreviewReadResult = union(enum) { ok: []u8, failed, too_large };
const PreviewReadFn = *const fn (Allocator, PreviewSourceKind, markdown_preview.Kind, []const u8) PreviewReadResult;

const LOADING_SOURCE = "Loading preview...";
const FAILED_SOURCE = "Preview failed";
const TOO_LARGE_SOURCE = "Preview too large";
const IMAGE_ZOOM_MIN: f32 = 0.25;
const IMAGE_ZOOM_MAX: f32 = 16.0;
const IMAGE_ZOOM_STEP: f32 = 1.2;

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
};

refcount: usize = 1,
kind: markdown_preview.Kind = .markdown,
load_status: LoadStatus = .idle,
title_buf: [256]u8 = undefined,
title_len: usize = 0,
path_buf: [512]u8 = undefined,
path_len: usize = 0,
source: ?[]u8 = null,
scroll_offset: f32 = 0,
image_zoom: f32 = 1.0,
image_pan_x: f32 = 0,
image_pan_y: f32 = 0,
content_generation: u64 = 0,
request_id: u64 = 0,
jobs: std.ArrayListUnmanaged(*PreviewJob) = .empty,
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
        self.unloadImageTexture(); // render-thread; see GL threading assumption
        gpa.destroy(self);
    }
}

pub fn title(self: *const PreviewPane) []const u8 { return self.title_buf[0..self.title_len]; }
pub fn path(self: *const PreviewPane) []const u8 { return self.path_buf[0..self.path_len]; }
pub fn sourceText(self: *const PreviewPane) []const u8 { return self.source orelse ""; }
pub fn contentGeneration(self: *const PreviewPane) u64 { return self.content_generation; }
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
    self.applyOwned(kind, t, p, std.heap.page_allocator.dupe(u8, source_text) catch null, .ready);
}

fn applyOwned(self: *PreviewPane, kind: markdown_preview.Kind, t: []const u8, p: []const u8, owned: ?[]u8, status: LoadStatus) void {
    self.kind = kind;
    self.load_status = if (owned == null and status == .ready) .failed else status;
    self.scroll_offset = 0;
    self.image_zoom = 1.0;
    self.image_pan_x = 0;
    self.image_pan_y = 0;
    self.content_generation +%= 1;
    self.setTitlePath(t, p);
    self.freeSource();
    self.source = owned;
}

pub fn scrollBy(self: *PreviewPane, delta: f32) void {
    const max_scroll = self.estimatedMaxScroll();
    self.scroll_offset = @max(0, @min(max_scroll, self.scroll_offset + delta));
}

fn estimatedMaxScroll(self: *const PreviewPane) f32 {
    if (self.kind == .image) return 0;
    const line_count = @max(@as(usize, 1), std.mem.count(u8, self.sourceText(), "\n") + 1);
    return @max(0, @as(f32, @floatFromInt(line_count)) * 28 - 360);
}

pub fn zoomImageBySteps(self: *PreviewPane, steps: usize, zoom_in: bool) bool {
    if (self.kind != .image) return false;
    var next = self.image_zoom;
    var remaining = @max(@as(usize, 1), steps);
    while (remaining > 0) : (remaining -= 1) next = if (zoom_in) next * IMAGE_ZOOM_STEP else next / IMAGE_ZOOM_STEP;
    next = @max(IMAGE_ZOOM_MIN, @min(IMAGE_ZOOM_MAX, next));
    if (@abs(next - self.image_zoom) < 0.001) return false;
    self.image_zoom = next;
    return true;
}

pub fn panImageBy(self: *PreviewPane, dx: f32, dy: f32) bool {
    if (self.kind != .image or self.load_status != .ready) return false;
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
    if (p.len > 512) { self.applyOwned(kind, t, p, std.heap.page_allocator.dupe(u8, FAILED_SOURCE) catch null, .failed); return false; }
    self.applyOwned(kind, t, p, std.heap.page_allocator.dupe(u8, LOADING_SOURCE) catch null, .loading);
    const alloc = std.heap.page_allocator;
    const job = alloc.create(PreviewJob) catch return false;
    job.* = .{ .request_id = self.request_id, .kind = kind, .source_kind = source_kind, .path_len = p.len, .title_len = @min(t.len, 256), .read_fn = read_fn, .owner = self };
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
            self.applyOwned(job.kind, job.title_buf[0..job.title_len], job.path_buf[0..job.path_len], s, .ready);
        } else {
            const msg = if (job.status == .too_large) TOO_LARGE_SOURCE else FAILED_SOURCE;
            self.applyOwned(job.kind, job.title_buf[0..job.title_len], job.path_buf[0..job.path_len], std.heap.page_allocator.dupe(u8, msg) catch null, job.status);
        }
        changed = true;
    }
    return changed;
}

fn jobThread(job: *PreviewJob) void {
    switch (job.read_fn(std.heap.page_allocator, job.source_kind, job.kind, job.path_buf[0..job.path_len])) {
        .ok => |s| { job.source = s; job.status = .ready; },
        .too_large => job.status = .too_large,
        .failed => job.status = .failed,
    }
    job.done.store(true, .release);
}

fn defaultPreviewRead(alloc: Allocator, source_kind: PreviewSourceKind, kind: markdown_preview.Kind, p: []const u8) PreviewReadResult {
    const s = preview_source.readPreviewSourceForKind(alloc, source_kind, p, kind) catch |err|
        return if (err == error.PreviewTooLarge) .too_large else .failed;
    return .{ .ok = s };
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
    std.heap.page_allocator.destroy(job);
}

fn unloadImageTexture(self: *PreviewPane) void {
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
```

- [ ] **Step 2: Register the file for the full suite**

In `src/test_main.zig`, near the other `_ = @import(...)` lines, add:

```zig
    _ = @import("preview_pane.zig");
```

- [ ] **Step 3: Run to verify the new tests pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS (4 PreviewPane tests green; no leaks from the testing allocator).

- [ ] **Step 4: Commit**

```bash
git add src/preview_pane.zig src/test_main.zig
git commit -m "feat(preview-pane): refcounted PreviewPane with migrated state + async loader"
```

### Task 2: Back the dock singleton with one `PreviewPane`; convert var reads to accessors

**Files:** Modify `src/markdown_preview_panel.zig`, `src/renderer/markdown_preview_renderer.zig` (read sites), `src/input.zig` (read sites)

- [ ] **Step 1:** In `markdown_preview_panel.zig`, replace the pile of content globals with a single instance plus the dock-only globals that stay (visibility/width/owner). Keep the **same public function names** so callers compile:

```zig
const PreviewPane = @import("preview_pane.zig");

pub threadlocal var g_visible: bool = false;
pub threadlocal var g_owner_tab: ?usize = null;
pub threadlocal var g_width: f32 = PreviewPane.DEFAULT_WIDTH;

threadlocal var g_dock: ?*PreviewPane = null;

fn dock() *PreviewPane {
    if (g_dock == null) g_dock = PreviewPane.create(std.heap.page_allocator) catch @panic("preview dock alloc");
    return g_dock.?;
}

// Accessors that the renderer/input now call instead of touching raw vars:
pub fn kind() markdown_preview.Kind { return dock().kind; }
pub fn loadStatus() PreviewPane.LoadStatus { return dock().load_status; }
pub fn scrollOffset() f32 { return dock().scroll_offset; }
pub fn title() []const u8 { return dock().title(); }
pub fn path() []const u8 { return dock().path(); }
pub fn source() []const u8 { return dock().sourceText(); }
pub fn contentGeneration() u64 { return dock().contentGeneration(); }
pub fn imageZoom() f32 { return dock().imageZoom(); }
pub fn imagePanX() f32 { return dock().imagePanX(); }
pub fn imagePanY() f32 { return dock().imagePanY(); }
pub fn clampImagePan(vw: f32, vh: f32, dw: f32, dh: f32) void { dock().clampImagePan(vw, vh, dw, dh); }

pub fn open(k: markdown_preview.Kind, t: []const u8, p: []const u8, s: []const u8) void { g_visible = true; g_owner_tab = active_tab_state.g_active_tab; dock().open(k, t, p, s); }
pub fn beginAsyncLoad(k: markdown_preview.Kind, t: []const u8, p: []const u8, sk: PreviewPane.PreviewSourceKind) bool { g_visible = true; g_owner_tab = active_tab_state.g_active_tab; return dock().beginAsyncLoad(k, t, p, sk); }
pub fn tickAsync() bool { return if (g_dock) |d| d.tickAsync() else false; }
pub fn scrollBy(delta: f32) void { dock().scrollBy(delta); }
pub fn zoomImageBySteps(n: usize, in_: bool) bool { return dock().zoomImageBySteps(n, in_); }
pub fn panImageBy(dx: f32, dy: f32) bool { return dock().panImageBy(dx, dy); }
pub fn close() void { g_visible = false; g_owner_tab = null; if (g_dock) |d| d.open(.markdown, "", "", ""); }
pub fn deinit() void { if (g_dock) |d| { d.unref(std.heap.page_allocator); g_dock = null; } }
```

Keep `width()`, `isVisibleForActiveTab()`, `setWidth`, `maxWidthForWindow`, `onTabClosed`, `onTabReordered`, and the width constants unchanged (they are dock geometry, removed in Phase 5). Delete the old `g_kind`/`g_scroll_offset`/`g_load_status`/`g_title_*`/`g_path_*`/`g_source`/`g_image_*`/`g_preview_*` globals and the now-duplicated job code (it lives in `PreviewPane`). Move the panel's existing unit tests to `preview_pane.zig` (done in Task 1) or delete them here.

- [ ] **Step 2:** In `markdown_preview_renderer.zig`, replace direct var reads with the accessors: `panel.g_kind` → `panel.kind()`, `panel.g_scroll_offset` → `panel.scrollOffset()`, `panel.g_load_status` → `panel.loadStatus()`. (≈7 sites: lines 138, 176, 180, 186, 251, 325, 607, 777.) The `panel.title()/path()/source()/width()/contentGeneration()/imageZoom()/...` calls are unchanged.

- [ ] **Step 3:** In `input.zig`, replace any `markdown_preview_panel.g_kind`/`g_load_status` reads (e.g. 3471, 3857, 4279, 4610) with `markdown_preview_panel.kind()` / `.loadStatus()`.

- [ ] **Step 4: Run**

Run: `zig build test-full 2>&1 | tail -20` → PASS
Run: `zig build 2>&1 | tail -5` → builds clean

- [ ] **Step 5: Commit**

```bash
git add src/markdown_preview_panel.zig src/renderer/markdown_preview_renderer.zig src/input.zig
git commit -m "refactor(preview): back the dock with one PreviewPane instance via accessors"
```

### Task 3: Renderer rect+pane core `renderInto`; migrate image-texture cache into the pane

**Files:** Modify `src/renderer/markdown_preview_renderer.zig`

- [ ] **Step 1:** Change `render(window_width, window_height, titlebar_h, right_offset)` to compute the dock rect and delegate to a new core that takes an explicit pane + rect. Signature:

```zig
pub fn renderInto(
    pane: *PreviewPane,
    panel_x: f32,
    panel_top: f32,   // distance from the window TOP to the pane's top edge
    panel_w: f32,
    panel_h: f32,
    window_height: f32,
    show_chrome: bool, // dock draws header/footer + resize edge; a tree leaf may skip the resize edge
) void { ... }
```

Move the body of `render`/`renderHeader`/`renderFooter`/`renderDocument`/`renderImageDocument`/`renderDelimitedDocument` to read from `pane` (`pane.kind`, `pane.scroll_offset`, `pane.load_status`, `pane.sourceText()`, `pane.title()`, `pane.path()`, `pane.imageZoom()`, `pane.clampImagePan(...)`) instead of the `panel.*` accessors, and to use `panel_top`/`panel_h` instead of `window_height - titlebar_h`. Keep the existing GL-y convention (`window_height - top - h`).

Then make the dock entry a thin wrapper:

```zig
pub fn render(window_width: f32, window_height: f32, titlebar_h: f32, right_offset: f32) void {
    if (!panel.isVisibleForActiveTab()) { if (panel.dockPane()) |p| p.unloadImageTextureIfIdle(); return; }
    const panel_w = panel.width();
    if (panel_w <= 0) return;
    const panel_x = window_width - right_offset - panel_w;
    renderInto(panel.dockPane(), panel_x, titlebar_h, panel_w, window_height - titlebar_h, window_height, true);
}
```

Add `pub fn dockPane() *PreviewPane { return dock(); }` to `markdown_preview_panel.zig`.

- [ ] **Step 2:** Move the texture cache into `PreviewPane`. Delete the renderer's `g_image_texture/width/height/generation/failed` and make `ensureImageTexture`/`drawImageTexture`/`unloadImageTexture` take `pane: *PreviewPane` and read/write `pane.image_*`. `ensureImageTexture(pane)` keys on `pane.contentGeneration()` vs `pane.image_generation`. The renderer's `deinit()` no longer owns a texture — instead the dock pane's texture is freed when the dock pane is unref'd (`PreviewPane.unloadImageTexture`, Task 1). Add `pub fn unloadImageTextureIfIdle(self: *PreviewPane) void { self.unloadImageTexture(); }` for the not-visible branch (or inline). Expose `unloadImageTexture` as `pub` on `PreviewPane`.

- [ ] **Step 3: Test** — full-suite smoke that `renderInto` reads the pane (no GL needed): a pure helper extracted from the header is overkill; instead assert the dock pane is reachable and image-cache fields default correctly.

```zig
test "preview renderer: dock pane exposes image cache defaults" {
    const panel = @import("../markdown_preview_panel.zig");
    const p = panel.dockPane();
    try std.testing.expectEqual(@as(c_int, 0), p.image_width);
}
```

(Register `markdown_preview_renderer.zig` in `src/test_main.zig` if it is not already; if registering pulls GL symbols that the test binary lacks, skip this test and rely on the Task 1 PreviewPane tests + the build.)

- [ ] **Step 4: Run**

Run: `zig build test-full 2>&1 | tail -20` → PASS
Run: `zig build 2>&1 | tail -5` → clean (right-dock renders exactly as before)

- [ ] **Step 5: Commit**

```bash
git add src/renderer/markdown_preview_renderer.zig src/markdown_preview_panel.zig
git commit -m "refactor(preview): rect+pane renderInto core; per-pane GL image-texture cache"
```

**Phase 1 checkpoint:** Right-dock preview works identically, now driven by a single `PreviewPane` instance with a rect-based renderer. No tree changes yet. Both suites green.

---

# Phase 2 — `Pane` leaf foundation (terminals work; preview arm dormant)

Mirrors the approved copilot-tiling Phase 1. The dock singleton is independent of the tree and keeps working through this phase.

### Task 4: `Pane` union + `Node.leaf` change + iterators + `initPane`

**Files:** Modify `src/split_tree.zig` (Node 46–70, init 83–96, deinit 98–112, clone/refNodes ~115/682, Iterator 154–181, swapLeaves 426–442, removeNode ~586, fromSnapshot ~1119, tests 1206+)

- [ ] **Step 1: Write the failing test** (drives `Pane`, `initPane`, `surfaces()`/`panes()`):

```zig
test "SplitTree: surfaces() yields terminals, panes() yields all leaves" {
    const gpa = std.testing.allocator;
    var s0: Surface = undefined; // identity-only; we never deref in this test
    var tree = try initPane(gpa, .{ .terminal = surfaceStubInit(&s0) });
    defer tree.deinit();
    var n_surf: usize = 0; var sit = tree.surfaces();
    while (sit.next()) |_| n_surf += 1;
    var n_pane: usize = 0; var pit = tree.panes();
    while (pit.next()) |e| { n_pane += 1; try std.testing.expect(e.pane == .terminal); }
    try std.testing.expectEqual(@as(usize, 1), n_surf);
    try std.testing.expectEqual(@as(usize, 1), n_pane);
}
```

If a `Surface` stub is impractical (it has a real `ref/unref`), instead build the tree through the existing `fromSnapshot` test helper used by the current `swapLeaves`/`fromSnapshot` tests and assert `panes()`/`surfaces()` counts on it. Use whichever the existing tests already use.

- [ ] **Step 2:** Run → FAIL (`initPane`/`surfaces`/`panes`/`e.pane` undefined).

- [ ] **Step 3: Implement** the `Pane` union and `Node` change (replace lines 46–70):

```zig
const PreviewPane = @import("preview_pane.zig");

pub const Pane = union(enum) {
    terminal: *Surface,
    preview: *PreviewPane,
    // copilot / webview: future arms (one each)

    pub fn ref(self: Pane) Pane {
        return switch (self) {
            .terminal => |s| .{ .terminal = s.ref() },
            .preview => |p| .{ .preview = p.ref() },
        };
    }
    pub fn unref(self: Pane, gpa: Allocator) void {
        switch (self) {
            .terminal => |s| s.unref(gpa),
            .preview => |p| p.unref(gpa),
        }
    }
    pub fn surface(self: Pane) ?*Surface {
        return switch (self) { .terminal => |s| s, else => null };
    }
};

pub const Node = union(enum) {
    leaf: Pane,
    split: Split,
    pub const Handle = enum(Backing) {
        root = 0, _,
        pub const Backing = u16;
        pub inline fn idx(self: Handle) usize { return @intFromEnum(self); }
        pub fn offset(self: Handle, v: usize) Handle {
            const u: usize = @intCast(@intFromEnum(self));
            const final = u + v; assert(final < std.math.maxInt(Backing));
            return @enumFromInt(final);
        }
    };
};
```

Add `initPane` and refactor `init`:

```zig
pub fn initPane(gpa: Allocator, pane: Pane) Allocator.Error!SplitTree {
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const nodes = try arena.allocator().alloc(Node, 1);
    nodes[0] = .{ .leaf = pane.ref() };
    return .{ .arena = arena, .nodes = nodes, .zoomed = null };
}
pub fn init(gpa: Allocator, surface: *Surface) Allocator.Error!SplitTree {
    return initPane(gpa, .{ .terminal = surface });
}
```

- [ ] **Step 4: Update internal leaf sites (compiler worklist)** — build `zig build test-full 2>&1 | head -60` and fix each:
  - `deinit` (104–107): `.leaf => |pane| pane.unref(gpa),`
  - `refNodes` (~688): `.leaf => |pane| nodes[i] = .{ .leaf = pane.ref() },`
  - `swapLeaves` (432–441): bind `|p|`, swap two `Pane` values.
  - `removeNode` (~590): `.leaf => |pane| { new_nodes[off] = .{ .leaf = pane }; return 1; }`
  - `fromSnapshot` factory write (~1124): `self.nodes[h.idx()] = .{ .leaf = .{ .terminal = surface } };`
  - `clone`/`equalize`/`deepest`/`previous*`/`next*`/`nearest`/`spatial`/`fillSpatialSlots`/`findParentSplit`: match `.leaf` without binding the payload (or bind-and-ignore) — fix only what the compiler flags.

- [ ] **Step 5: Replace `Iterator` with `surfaces()` + `panes()`** (replace 158–181):

```zig
pub const SurfaceEntry = struct { handle: Node.Handle, surface: *Surface };
pub const PaneEntry = struct { handle: Node.Handle, pane: Pane };

pub const SurfaceIterator = struct {
    i: Node.Handle = .root, nodes: []const Node,
    pub fn next(self: *SurfaceIterator) ?SurfaceEntry {
        while (@intFromEnum(self.i) < self.nodes.len) {
            const h = self.i; self.i = @enumFromInt(h.idx() + 1);
            switch (self.nodes[h.idx()]) {
                .leaf => |pane| if (pane.surface()) |s| return .{ .handle = h, .surface = s },
                .split => {},
            }
        }
        return null;
    }
};
pub const PaneIterator = struct {
    i: Node.Handle = .root, nodes: []const Node,
    pub fn next(self: *PaneIterator) ?PaneEntry {
        while (@intFromEnum(self.i) < self.nodes.len) {
            const h = self.i; self.i = @enumFromInt(h.idx() + 1);
            switch (self.nodes[h.idx()]) {
                .leaf => |pane| return .{ .handle = h, .pane = pane },
                .split => {},
            }
        }
        return null;
    }
};
pub fn surfaces(self: *const SplitTree) SurfaceIterator { return .{ .nodes = self.nodes }; }
pub fn panes(self: *const SplitTree) PaneIterator { return .{ .nodes = self.nodes }; }
/// DEPRECATED: temporary alias == surfaces(); removed in Task 6.
pub fn iterator(self: *const SplitTree) SurfaceIterator { return self.surfaces(); }
```

- [ ] **Step 6:** `readingOrder` (~926) must walk all panes (so preview leaves get number-focus): change `self.iterator()` → `self.panes()`. In the existing split_tree tests, `tree.nodes[i].leaf` (as `*Surface`) becomes `tree.nodes[i].leaf.terminal`.

- [ ] **Step 7: Run** → `zig build test-full 2>&1 | tail -20` PASS.

- [ ] **Step 8: Commit**

```bash
git add src/split_tree.zig
git commit -m "feat(split-tree): leaf becomes Pane{terminal,preview}; surfaces()/panes() iterators"
```

### Task 5: Migrate external leaf/iterator consumers

**Files:** Modify `src/appwindow/tab.zig`, `src/AppWindow.zig`, `src/appwindow/split_layout.zig`, `src/renderer/overlays.zig`

- [ ] **Step 1:** Build to list sites: `zig build test-full 2>&1 | head -80`.

- [ ] **Step 2:** `tab.zig` — `focusedSurface`: `.leaf => |pane| pane.surface()` (null if focused leaf is a preview). `snapshotTab` leaf: terminals only for now (preview persistence is Phase 5) — temporary placeholder so a preview leaf round-trips as an empty shell until Task 14/15 replaces it:

```zig
.leaf => |pane| switch (pane) {
    .terminal => |s| .{ .leaf = .{ .surface = try snapshotSurface(arena, s) } },
    .preview => .{ .leaf = .{ .surface = .{ .local_shell = .{} } } }, // placeholder until Phase 5
},
```

`restoreTab`/dump-helper: bind `.terminal => |s|` where a `*Surface` is required. `swapPanels` divider guard: payload-agnostic, unchanged.

- [ ] **Step 3:** Classify each `tree.iterator()` caller in `AppWindow.zig`, `tab.zig`, and `renderer/*` as `surfaces()` (terminal-specific: PTY resize, `terminal_snapshot`, bell, remote-id match — most of them) or `panes()` (renders/focuses every pane). Leaving them on the deprecated `iterator()` alias compiles and behaves identically today (no preview leaves yet), but classify now.

- [ ] **Step 4:** `split_layout.zig:170` `computeSplitLayout` stays on `iterator()`/`surfaces()` for now (preview leaves are added in Phase 3 Task 7). `cachedRectIsLive` (53): `.leaf => |pane| pane.surface() == rect.surface`. `overlays.zig` divider loop: payload-agnostic.

- [ ] **Step 5: Run** → `zig build test-full 2>&1 | tail -20` PASS; `zig build 2>&1 | tail -5` clean.

- [ ] **Step 6: Commit**

```bash
git add src/appwindow/tab.zig src/AppWindow.zig src/appwindow/split_layout.zig src/renderer/overlays.zig
git commit -m "refactor(splits): migrate leaf consumers to Pane/surfaces()/panes()"
```

### Task 6: Remove the deprecated `iterator()` alias

**Files:** Modify `src/split_tree.zig` (+ stragglers)

- [ ] **Step 1:** Delete the `iterator()` alias. **Step 2:** `zig build test-full 2>&1 | head -40` — repoint any straggler to `surfaces()` or `panes()`. **Step 3:** `tail -20` PASS. **Step 4:** Commit:

```bash
git add src/split_tree.zig src/appwindow src/AppWindow.zig src/renderer
git commit -m "refactor(split-tree): drop deprecated iterator() alias"
```

**Phase 2 checkpoint:** App compiles and behaves exactly as before (terminals + right-dock preview); the `preview` leaf arm exists but is never constructed. Both suites green.

---

# Phase 3 — Render & input dispatch for preview leaves

### Task 7: `SplitRect` carries a `Pane`; layout includes preview leaves

**Files:** Modify `src/appwindow/split_layout.zig`

- [ ] **Step 1: Write the failing test** (full-suite) for a pure helper that decides per-leaf whether to resize a surface:

```zig
test "split_layout: preview leaf produces a rect without a surface" {
    // paneIsTerminal(pane) is the pure predicate used to gate surface.setScreenSize.
    const SplitTree = @import("../split_tree.zig");
    var dummy: SplitTree.Surface = undefined; _ = &dummy;
    try std.testing.expect(!paneIsTerminal(.{ .preview = undefined }));
    try std.testing.expect(paneIsTerminal(.{ .terminal = &dummy }));
}
```

- [ ] **Step 2:** Run → FAIL (`paneIsTerminal` undefined / `SplitRect.pane` undefined).

- [ ] **Step 3: Implement.** Change `SplitRect` (23): replace `surface: *Surface` with `pane: SplitTree.Pane`; add `pub fn surface(self: SplitRect) ?*Surface { return self.pane.surface(); }`. Add `fn paneIsTerminal(p: SplitTree.Pane) bool { return p.surface() != null; }`. In `computeSplitLayout` (142): iterate `active_tab.tree.panes()`; compute the pixel rect as today; **only** call `surface.setScreenSizeWithPolicy(...)` + resize-overlay logic when `entry.pane.surface()` is non-null; always store the rect:

```zig
g_split_rects[count] = .{
    .x = px, .y = py, .width = pw, .height = ph,
    .cols = if (entry.pane.surface()) |s| s.size.grid.cols else 0,
    .rows = if (entry.pane.surface()) |s| s.size.grid.rows else 0,
    .pane = entry.pane,
    .handle = entry.handle,
};
```

Update `cachedRectIsLive` (50) to compare by handle identity:

```zig
return switch (active_tab.tree.nodes[rect.handle.idx()]) {
    .leaf => |pane| std.meta.eql(pane, rect.pane),
    .split => false,
};
```

`surfaceAtPoint` (61): return `rect.pane.surface()` (skips preview leaves — terminal-only callers unaffected). Add a pane-aware lookup for focus:

```zig
pub const PaneHit = struct { pane: SplitTree.Pane, handle: SplitTree.Node.Handle };
pub fn paneAtPoint(x: i32, y: i32) ?PaneHit {
    for (0..g_split_rect_count) |i| {
        const r = g_split_rects[i];
        if (!cachedRectIsLive(r)) continue;
        if (x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height) return .{ .pane = r.pane, .handle = r.handle };
    }
    return null;
}
```

- [ ] **Step 4:** Run → `zig build test-full 2>&1 | tail -20` PASS; `zig build` clean.

- [ ] **Step 5: Commit**

```bash
git add src/appwindow/split_layout.zig
git commit -m "feat(layout): SplitRect carries a Pane; preview leaves get rects; paneAtPoint"
```

### Task 8: Per-leaf draw dispatch (terminal cells vs preview)

**Files:** Modify `src/AppWindow.zig` (the render loop consuming `g_split_rects`) and/or `src/renderer/overlays.zig`

- [ ] **Step 1:** Find the loop that iterates `g_split_rects`/`g_split_rect_count` to draw each terminal (cells + scrollbar + focus ring). It currently assumes every rect is a terminal (`rect.surface`).

- [ ] **Step 2:** Dispatch on the pane kind for each rect:

```zig
for (0..split_layout.g_split_rect_count) |i| {
    const rect = split_layout.g_split_rects[i];
    switch (rect.pane) {
        .terminal => |s| drawTerminalRect(s, rect, ...),   // existing path (cells/scrollbar)
        .preview => |p| markdown_preview_renderer.renderInto(
            p,
            @floatFromInt(rect.x),
            @floatFromInt(currentTitlebarHeight()), // panel_top: pane top from window top — use rect.y mapped to "from-top"
            @floatFromInt(rect.width),
            @floatFromInt(rect.height),
            @floatFromInt(fb.height),
            false, // no dock resize edge inside the tree
        ),
    }
}
```

Match the existing draw loop's coordinate inputs; `panel_top` is the pane's top measured from the window top (`rect.y` is already window-top-relative in `computeSplitLayout`). Draw the focus ring around a focused preview leaf the same way terminals do, keyed on `active_tab.focused == rect.handle`.

- [ ] **Step 3: Test** (full-suite, no GL): assert the dispatch is total — `panes()` over a tree containing a preview leaf yields a `.preview` entry, and `paneAtPoint` inside that leaf's rect returns it. (A pure check; GL draw is verified manually.)

- [ ] **Step 4:** Run → `zig build test-full 2>&1 | tail -20` PASS; `zig build` clean.

- [ ] **Step 5: Commit**

```bash
git add src/AppWindow.zig src/renderer/overlays.zig
git commit -m "feat(render): dispatch split-tree leaves to terminal vs preview draw"
```

### Task 9: Route input to a focused preview leaf

**Files:** Modify `src/input.zig`, `src/AppWindow.zig`

- [ ] **Step 1:** Add `AppWindow.focusedPreviewPane() ?*PreviewPane`:

```zig
pub fn focusedPreviewPane() ?*preview_pane = blk: { ... };
// implementation:
pub fn focusedPreviewPane() ?*PreviewPane {
    const t = tab.activeTab() orelse return null;
    if (t.focused.idx() >= t.tree.nodes.len) return null;
    return switch (t.tree.nodes[t.focused.idx()]) {
        .leaf => |pane| switch (pane) { .preview => |p| p, else => null },
        .split => null,
    };
}
```

- [ ] **Step 2:** In `input.zig`, when `AppWindow.focusedPreviewPane()` is non-null, handle keys on that pane and consume them: `PageUp/PageDown/Home/End/Up/Down` → `p.scrollBy(±step)`; for `p.kind == .image`: `+`/`=` → `p.zoomImageBySteps(1, true)`, `-` → `(1, false)`, arrows → `p.panImageBy(...)`. Mouse: on click, set `t.focused` to `paneAtPoint(...).handle`; route wheel to `p.scrollBy` (or zoom when image), and drag to `p.panImageBy` — keyed on the **focused preview pane** and that leaf's rect (from `g_split_rects`), replacing the old single-dock-rect hit-tests.

- [ ] **Step 3: Test** (full-suite): build a tab whose focused leaf is a preview; assert `focusedPreviewPane()` returns it and returns null when the focused leaf is a terminal; assert `scrollBy` moves `scroll_offset`.

- [ ] **Step 4:** Run → `zig build test-full 2>&1 | tail -20` PASS.

- [ ] **Step 5: Commit**

```bash
git add src/input.zig src/AppWindow.zig
git commit -m "feat(input): focus + scroll/zoom/pan routing for preview panes"
```

**Phase 3 checkpoint:** A preview leaf (when present) renders in its slot, takes focus, and scrolls/zooms. Swap/number-focus/resize/zoom already work (leaf-agnostic tree). Both suites green. The dock still exists in parallel.

---

# Phase 4 — Open flow (create preview leaves at the right edge)

### Task 10: `splitIntoPreview` + reuse-target + right-edge placement helpers

**Files:** Modify `src/appwindow/tab.zig`, `src/split_tree.zig`

- [ ] **Step 1: Write failing tests** (full-suite for the tab op; the pure helpers can be fast-suite if placed in `split_tree.zig`):

```zig
// split_tree.zig (fast/full): the right-edge insert wraps the whole tree left.
test "SplitTree: insert preview at right edge splits the root" {
    // build a 1-terminal tree, splitAtRoot(.right, ratio, previewLeafTree),
    // assert nodes.len == 3 and the rightmost leaf in reading order is the preview.
}
// tab.zig (full): reuse target selection
test "tab: firstPreviewForReuse picks focused-preview else first in reading order" { ... }
```

- [ ] **Step 2:** Run → FAIL.

- [ ] **Step 3: Implement.**
  - In `split_tree.zig`, add `pub fn splitAtRoot(self, gpa, direction, ratio, insert) !SplitTree` that calls the existing `split` with `at = .root` (the whole current tree becomes one side, `insert` the other). If `split` already supports `at = .root`, just call it from the tab op and skip this wrapper.
  - In `tab.zig`, add the pure reuse selector:

```zig
/// Handle of the preview pane to reuse: the focused leaf if it is a preview,
/// else the first preview in reading order, else null.
pub fn firstPreviewForReuse(t: *const TabState) ?SplitTree.Node.Handle {
    if (t.focused.idx() < t.tree.nodes.len) switch (t.tree.nodes[t.focused.idx()]) {
        .leaf => |pane| switch (pane) { .preview => return t.focused, else => {} },
        .split => {},
    };
    const order = t.tree.readingOrder(g_alloc) catch return null; // or reuse an existing arena
    defer g_alloc.free(order);
    for (order) |h| switch (t.tree.nodes[h.idx()]) {
        .leaf => |pane| switch (pane) { .preview => return h, else => {} },
        .split => {},
    };
    return null;
}
```

  - Add `splitIntoPreview` that creates a `PreviewPane`, wraps it in a one-leaf tree (`SplitTree.initPane(gpa, .{ .preview = p })`), inserts at the **root** to the right at a ratio derived from `PreviewPane.DEFAULT_WIDTH` vs the window width, and returns the new preview leaf's handle (do **not** change `t.focused` — opening does not steal focus):

```zig
pub fn splitIntoPreview(gpa: std.mem.Allocator) ?*PreviewPane {
    const t = activeTab() orelse return null;
    const p = PreviewPane.create(gpa) catch return null;
    var insert = SplitTree.initPane(gpa, .{ .preview = p }) catch { p.unref(gpa); return null; };
    defer insert.deinit();
    const ratio = rightEdgeRatio(); // DEFAULT_WIDTH / window_width, clamped to [0.2,0.6]
    const new_tree = t.tree.split(gpa, .root, .right, ratio, &insert) catch return null;
    replaceTree(t, new_tree); // existing helper that deinits the old tree + invalidates rects
    return p; // caller loads content into it
}
```

- [ ] **Step 4:** Run → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/appwindow/tab.zig src/split_tree.zig
git commit -m "feat(tab): splitIntoPreview (right-edge) + reuse-target selector"
```

### Task 11: Rewire Ctrl+click to reuse-else-create a preview leaf; Split→Preview command

**Files:** Modify `src/input.zig` (`openPreviewAsync` 2968 + its Ctrl+click caller), `src/AppWindow.zig` (SKILL.md opens 1565/3548; command entry), command registry

- [ ] **Step 1:** Replace the body of `openPreviewAsync(kind, title, path, source_kind)` (input.zig:2968) so it targets a preview **leaf** instead of the dock:

```zig
fn openPreviewAsync(kind: markdown_preview.Kind, title: []const u8, path: []const u8, source_kind) bool {
    const t = AppWindow.tab.activeTab() orelse return false;
    const gpa = AppWindow.g_allocator orelse return false;
    const pane: *PreviewPane = if (AppWindow.tab.firstPreviewForReuse(t)) |h|
        t.tree.nodes[h.idx()].leaf.preview
    else
        (AppWindow.tab.splitIntoPreview(gpa) orelse return false);
    return pane.beginAsyncLoad(kind, title, path, source_kind);
}
```

- [ ] **Step 2:** Add a forced-new variant for Ctrl+Shift+click: `openPreviewNew(...)` that always calls `splitIntoPreview` then `beginAsyncLoad`. Wire the modifier check at the Ctrl+click call site (where `openPreviewAsync` is invoked): Shift held → `openPreviewNew`, else `openPreviewAsync`.

- [ ] **Step 3:** Reroute the in-memory SKILL.md opens (`AppWindow.zig:1565`, `:3548`) from `markdown_preview_panel.open(...)` to: reuse-or-create a preview leaf then `pane.open(.markdown, title, "SKILL.md", content)`:

```zig
const t = tab.activeTab() orelse return;
const pane = if (tab.firstPreviewForReuse(t)) |h| t.tree.nodes[h.idx()].leaf.preview else (tab.splitIntoPreview(g_allocator.?) orelse return);
pane.open(.markdown, name, "SKILL.md", content);
```

- [ ] **Step 4:** Add a command-center entry "Split → Preview" → `tab.splitIntoPreview(g_allocator.?)` (creates an empty preview leaf to load into). Register the action in `command_center_state.zig`/the command registry next to the existing split actions.

- [ ] **Step 5:** Pump the async tick over **all** preview panes. Replace `AppWindow.zig:6138` (`markdown_preview_panel.tickAsync()`) with a walk of every tab's tree `panes()`, calling `p.tickAsync()` on each `.preview`, OR-ing the changed flag; keep the dock tick too until Phase 5.

- [ ] **Step 6:** Run → `zig build test-full 2>&1 | tail -20` PASS; `zig build` clean.

- [ ] **Step 7: Commit**

```bash
git add src/input.zig src/AppWindow.zig src/command_center_state.zig
git commit -m "feat(preview): Ctrl+click reuses-else-creates a preview pane; Split→Preview command"
```

**Phase 4 checkpoint:** Ctrl+click opens/updates a preview **pane** (right edge by default); Ctrl+Shift+click and the command make new ones; multiple previews coexist; swap/resize/zoom/focus all work. Both suites green. (The old dock is now redundant — removed next.)

---

# Phase 5 — Remove the right-dock; persistence

### Task 12: Remove the right-dock geometry + singleton

**Files:** Modify `src/markdown_preview_panel.zig` (reduce/remove), `src/renderer/markdown_preview_renderer.zig` (drop dock `render`), `src/AppWindow.zig` (`rightPanelsWidth*` ~2369–2379; SKILL.md already rerouted; remove dock tick), `src/input.zig` (resize hit-test 2006–2199, `g_markdown_preview_resize_dragging`)

- [ ] **Step 1:** Delete the dock geometry from `markdown_preview_panel.zig`: `g_visible`, `g_owner_tab`, `g_width`, `width()`, `setWidth`, `maxWidthForWindow`, `RESIZE_HIT_WIDTH`/MIN/MAX/`DEFAULT_WIDTH` (keep `PreviewPane.DEFAULT_WIDTH`), `isVisibleForActiveTab`, `onTabClosed`, `onTabReordered`, `dockPane`, `dock`, `tickAsync`, the accessor shims, and `close()`. The file is now either empty or just a thin `pub const PreviewPane = @import("preview_pane.zig");` re-export — if nothing imports it anymore, `git rm` it and drop its `test_main.zig` import.
- [ ] **Step 2:** In `markdown_preview_renderer.zig`, delete the dock `render(window_width, window_height, titlebar_h, right_offset)` wrapper and its `panel.*` import; keep only `renderInto(pane, ...)` (called from Task 8). Remove the renderer's `deinit()` if it only freed the old global texture.
- [ ] **Step 3:** In `AppWindow.zig`, drop `markdown_preview_panel.width()` from `rightPanelsWidth*` (preview width now lives in the tree), remove the dock render call from the main render path, and remove the dock `tickAsync` (Task 11 Step 5 already ticks panes). Remove `markdown_preview_panel.deinit()` calls (or repoint to nothing).
- [ ] **Step 4:** In `input.zig`, delete the dock resize hit-test block (2006–2199) and `g_markdown_preview_resize_dragging`, plus the old single-dock-rect mouse routing replaced in Task 9.
- [ ] **Step 5:** `zig build test-full 2>&1 | head -40` — fix flagged callers (compiler worklist). Then `tail -20` PASS; `zig build` clean.
- [ ] **Step 6: Commit**

```bash
git add -A src/markdown_preview_panel.zig src/renderer/markdown_preview_renderer.zig src/AppWindow.zig src/input.zig src/test_main.zig
git commit -m "refactor(preview): remove the right-dock (preview is now a tiling pane)"
```

### Task 13: Persistence codec — leaf kind + `PreviewSnap`

**Files:** Modify `src/session_persist.zig`

- [ ] **Step 1: Write the failing test** (full-suite, mirrors existing JSON round-trip tests): a `LeafSnap` with `kind = .preview` and a `PreviewSnap{ kind = .markdown, path = "README.md" }` serializes and parses back intact; an old-format leaf (no `kind`/`preview` fields) still parses as `.terminal`.

- [ ] **Step 2:** Run → FAIL.

- [ ] **Step 3: Implement** (replace `LeafSnap` at 43–45; bump version at 12):

```zig
pub const SCHEMA_VERSION: u32 = 2; // was 1: added LeafSnap.kind + preview

pub const PreviewSnap = struct {
    kind: @import("markdown_preview.zig").Kind = .markdown,
    path: []const u8 = "",
};

pub const LeafSnap = struct {
    kind: Kind = .terminal,
    surface: SurfaceSnap = .{ .local_shell = .{} }, // valid only when kind == .terminal
    preview: ?PreviewSnap = null,                    // present when kind == .preview
    pub const Kind = enum { terminal, preview };
};
```

Defaults keep old JSON loading (missing `kind` → terminal; missing `preview` → null) and `ignore_unknown_fields = true` means new files load on old binaries (degrading a preview leaf to its placeholder shell). `countLeaves`/`leafByIndex`/`indexOfLeaf`/`clampRatios` switch on `.leaf`/`.split` already and are unaffected.

- [ ] **Step 4:** Run → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/session_persist.zig
git commit -m "feat(persist): leaf snapshot carries pane kind + PreviewSnap (path); schema v2"
```

### Task 14: Save preview leaves (`snapshotTab`)

**Files:** Modify `src/appwindow/tab.zig` (`snapshotTab` leaf — replace the Phase-2 placeholder)

- [ ] **Step 1: Write the failing test** (full-suite): `snapshotTab` of a tab with a preview leaf (path "README.md", kind markdown) emits a `.preview` leaf with that path + kind.

- [ ] **Step 2:** Run → FAIL.

- [ ] **Step 3: Implement** — replace the Phase-2 placeholder:

```zig
.leaf => |pane| switch (pane) {
    .terminal => |s| .{ .leaf = .{ .kind = .terminal, .surface = try snapshotSurface(arena, s) } },
    .preview => |p| .{ .leaf = .{ .kind = .preview, .preview = .{ .kind = p.kind, .path = try arena.dupe(u8, p.path()) } } },
},
```

- [ ] **Step 4:** Run → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/appwindow/tab.zig
git commit -m "feat(persist): save preview panes (kind + path)"
```

### Task 15: Restore preview leaves (rebuild + async reload)

**Files:** Modify `src/split_tree.zig` (`fromSnapshot` ~1093), `src/appwindow/tab.zig` (`restoreTab`)

- [ ] **Step 1: Write the failing test** (full-suite): save→load a tab with terminal + preview(path "README.md"); after restore the tree has a `.preview` leaf whose `path()` == "README.md" and whose load was kicked (status `loading` or `ready`).

- [ ] **Step 2:** Run → FAIL.

- [ ] **Step 3: Implement** — `fromSnapshot` branches on `LeafSnap.kind`. Since a preview needs no surface factory, build it inline:

```zig
.leaf => |leaf| switch (leaf.kind) {
    .terminal => self.nodes[h] = .{ .leaf = .{ .terminal = factory(&leaf.surface, gpa) orelse return error.SurfaceCreationFailed } },
    .preview => {
        const p = PreviewPane.create(gpa) catch return error.SurfaceCreationFailed;
        if (leaf.preview) |snap| p.beginAsyncLoad(snap.kind, std.fs.path.basename(snap.path), snap.path, .local) ; // best-effort
        self.nodes[h] = .{ .leaf = .{ .preview = p } };
    },
},
```

`beginAsyncLoad` resolves relative paths the same way Ctrl+click does (the existing `preview_source` reader). If `fromSnapshot` cannot easily call `beginAsyncLoad` (e.g. it must stay allocation-pure), instead create the pane empty here and kick the reload from `restoreTab` after the tree is assembled (walk `panes()`, for each `.preview` call `beginAsyncLoad` from the stored snapshot). Keep the reload in whichever layer already has the snapshot + tree together.

- [ ] **Step 4:** Run → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/split_tree.zig src/appwindow/tab.zig
git commit -m "feat(persist): restore preview panes and async-reload their file"
```

**Phase 5 checkpoint:** No right-dock remains; preview exists only as a tiling pane; layouts with preview panes survive restart (file re-loaded best-effort). Both suites green.

---

## Final verification (before declaring done)

- [ ] `zig build test` → fast suite green.
- [ ] `zig build test-full` → full suite green (0 failed).
- [ ] `zig build` → default target builds clean.
- [ ] `git grep -n "g_markdown_preview_resize_dragging\|markdown_preview_panel.width\|isVisibleForActiveTab" src/` → no stragglers (dock fully gone).
- [ ] **GUI verify (manual, macOS + Windows — no Linux GUI backend; WSLg cannot screenshot GL):**
  - Ctrl+click a file path → preview opens on the right edge; terminal keeps focus.
  - Ctrl+click another file → same preview updates in place.
  - Ctrl+Shift+click (or "Split → Preview") → a second preview pane; both visible.
  - Focus a preview (Ctrl+N / click) → PageUp/Down scroll; for an image, +/- zoom and drag pans.
  - **Alt+drag a preview onto a terminal → they swap positions.** Drag the divider → resize. Ctrl+1-9 → focus by position. Zoom (zoom keybind) → fills the tab.
  - Close the preview pane (close-split keybind) → gone; tab survives.
  - Restart → preview pane returns at its slot with the file re-loaded.
  - **Confirm the GL threading assumption:** open/close many preview panes (incl. image previews) and watch for GL texture leaks/crashes; if any, switch `PreviewPane.unloadImageTexture` to a render-thread orphan queue.

## Self-Review (completed during planning)

- **Spec coverage:** `Pane` sum type + `preview` arm (T4); `PreviewPane` per-instance + refcount (T1); singleton→instance via dock shim then removal (T2/T12); two iterators (T4); render dispatch + per-pane image texture (T3/T7/T8); focused-leaf input scroll/zoom/pan + mouse (T9); reuse-else-create + right-edge placement + Split→Preview + Ctrl+Shift+click (T10/T11); swap/number-focus/resize/zoom (free from T4, verified in Final GUI); persist slot + reload, schema bump (T13–T15); right-dock removal incl. width reservation/resize-drag/owner tracking (T12); copilot-branch coexistence (the `Pane` arms list + `surfaces()`/`panes()` match the copilot spec so it rebases cleanly). All spec sections map to tasks.
- **Placeholder scan:** New types, the async loader, the persistence codec, and all tests have complete code. `AppWindow.zig`/`input.zig` integration steps give exact anchors (line numbers from Orientation) + change shape + representative code rather than full final source, because those 4–6k-line files are edited compiler-in-the-loop (Zig's exhaustive union switch enumerates every site — stated in Orientation). No "TBD"/"handle edge cases"/"similar to Task N".
- **Type consistency:** `PreviewPane` API (`create/ref/unref`, `open`, `beginAsyncLoad`, `tickAsync`, `scrollBy`, `zoomImageBySteps`, `panImageBy`, `clampImagePan`, `kind`, `load_status`, `sourceText`, `title`, `path`, `contentGeneration`, `image_*`, `unloadImageTexture`), `Pane{terminal,preview}`+`ref/unref/surface`, `SurfaceEntry`/`PaneEntry`, `surfaces()`/`panes()`, `initPane`, `SplitRect.pane`+`surface()`, `paneIsTerminal`, `paneAtPoint`/`PaneHit`, `firstPreviewForReuse`, `splitIntoPreview`, `focusedPreviewPane`, `LeafSnap{kind,surface,preview}`+`PreviewSnap{kind,path}` are used consistently across tasks. `renderInto(pane, panel_x, panel_top, panel_w, panel_h, window_height, show_chrome)` matches between T3 (definition) and T8 (call).
