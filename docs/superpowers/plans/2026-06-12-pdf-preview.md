# PDF Native Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ctrl+click (or File Explorer double-click) on a `.pdf` opens it in the existing preview pane like a PNG, rasterized per page by OS-native facilities, with PageUp/PageDown page navigation.

**Architecture:** Rasterize "page N → PNG bytes" on the existing preview job thread, then reuse the image pipeline untouched (`source` holds PNG → render thread stb-decodes → GL texture → zoom/pan). Platform split lives in one new `src/platform/pdf_render.zig` dispatch (Windows WinRT `Windows.Data.Pdf` via a C bridge, macOS CGPDF+ImageIO via an Objective-C bridge, Linux poppler-utils subprocesses). Spec: `docs/superpowers/specs/2026-06-12-pdf-preview-design.md`.

**Ghostty comparison (AGENTS.md):** Ghostty has no file-preview pane at all (images render in-terminal via kitty graphics, which WispTerm also supports separately). The preview pane is a WispTerm-specific feature; there is no Ghostty implementation to mirror, same as the existing markdown/image preview.

**Tech Stack:** Zig 0.15.2, stb_image (already vendored via ghostty dep), WinRT Windows.Data.Pdf (Win10+ system), CoreGraphics/ImageIO (macOS system), poppler-utils (Linux, runtime optional).

**Verification commands:** `zig build test` (fast suite), `zig build test-full` (pre-merge gate, includes posix tests + windows-gnu app compile), `zig build` (windows app build). Commit after every green task.

---

### Task 1: `.pdf` kind in markdown_preview

**Files:**
- Modify: `src/markdown_preview.zig`

- [ ] **Step 1.1: Write failing tests** — extend the existing `test "detect preview kind"` block in `src/markdown_preview.zig` and add a raster-helper test:

```zig
// inside test "detect preview kind", after the image expectations:
    try std.testing.expectEqual(Kind.pdf, detectKind("paper.pdf").?);
    try std.testing.expectEqual(Kind.pdf, detectKind("REPORT.PDF").?);
    try std.testing.expectEqual(MAX_PDF_SOURCE_BYTES, sourceLimit(.pdf));

// new test at file end:
test "raster kinds are image and pdf" {
    try std.testing.expect(Kind.image.isRaster());
    try std.testing.expect(Kind.pdf.isRaster());
    try std.testing.expect(!Kind.markdown.isRaster());
    try std.testing.expect(!Kind.text.isRaster());
}
```

- [ ] **Step 1.2: Run to verify failure** — `zig test src/markdown_preview.zig` → compile error (`Kind.pdf` undefined).

- [ ] **Step 1.3: Implement** in `src/markdown_preview.zig`:

```zig
pub const MAX_PDF_SOURCE_BYTES: usize = 64 * 1024 * 1024;

pub const Kind = enum {
    markdown,
    text,
    csv,
    tsv,
    image,
    pdf,

    /// Kinds displayed as a rasterized texture (zoom/pan instead of scroll).
    pub fn isRaster(self: Kind) bool {
        return self == .image or self == .pdf;
    }
};
```

In `detectKind`, before the image loop: `if (endsWithIgnoreCase(path, ".pdf")) return .pdf;`
In `sourceLimit`: `.pdf => MAX_PDF_SOURCE_BYTES,`
In `render`: `.image, .pdf => allocator.dupe(u8, source),`

- [ ] **Step 1.4: Run** — `zig test src/markdown_preview.zig` → PASS. Also `zig build test` (preview_path pulls this module into the fast suite).

- [ ] **Step 1.5: Commit** — `git add -A && git commit -m "feat(preview): add .pdf preview kind with raster-kind helper"`

---

### Task 2: pure helpers `src/pdf_preview.zig`

**Files:**
- Create: `src/pdf_preview.zig`
- Modify: `src/test_fast.zig` (register module)

- [ ] **Step 2.1: Write the module with tests (TDD per function; the file is small enough to write tests first, watch them fail to compile, then fill in implementations):**

```zig
//! Pure PDF-preview helpers: page-flip targeting, poppler output parsing,
//! and footer label formatting. Platform-independent; fast suite.
const std = @import("std");

/// Rasterization width in pixels. Zoom operates on the resulting texture.
pub const TARGET_RENDER_WIDTH: u32 = 1600;

/// 0-based page after a flip, clamped to [0, count). Null when the flip
/// would not change the page (already at an edge, or empty document).
pub fn flipTarget(current: u32, count: u32, forward: bool) ?u32 {
    if (count == 0) return null;
    const last = count - 1;
    const cur = @min(current, last);
    if (forward) {
        if (cur >= last) return null;
        return cur + 1;
    }
    if (cur == 0) return null;
    return cur - 1;
}

/// Parse the "Pages: N" line of `pdfinfo` output.
pub fn parsePdfInfoPages(text: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Pages:")) continue;
        const value = std.mem.trim(u8, line["Pages:".len..], " \t\r");
        return std.fmt.parseInt(u32, value, 10) catch null;
    }
    return null;
}

/// True when poppler stderr indicates an encrypted document.
pub fn stderrIndicatesPassword(stderr: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(stderr, "password") != null or
        std.ascii.indexOfIgnoreCase(stderr, "encrypted") != null;
}

/// "N/M" footer indicator (1-based page display).
pub fn formatPageIndicator(buf: []u8, page_index: u32, page_count: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}/{d}", .{ page_index + 1, page_count }) catch buf[0..0];
}

/// argv for rendering a single 0-based page as PNG on stdout. Slices in the
/// result point into `num_buf` (page/width digits) and `pdf_path`.
pub const PDFTOPPM_ARGC = 11;
pub fn pdftoppmArgv(
    num_buf: *[32]u8,
    pdf_path: []const u8,
    page_index: u32,
    target_width: u32,
) [PDFTOPPM_ARGC][]const u8 {
    var fbs = std.io.fixedBufferStream(num_buf);
    const w = fbs.writer();
    const page_start = fbs.pos;
    w.print("{d}", .{page_index + 1}) catch unreachable;
    const page = num_buf[page_start..fbs.pos];
    const width_start = fbs.pos;
    w.print("{d}", .{target_width}) catch unreachable;
    const width = num_buf[width_start..fbs.pos];
    return .{
        "pdftoppm", "-png",
        "-f",       page,
        "-l",       page,
        "-scale-to-x", width,
        "-scale-to-y", "-1",
        pdf_path,
    };
}

test "flipTarget clamps to document bounds" {
    try std.testing.expectEqual(@as(?u32, 1), flipTarget(0, 3, true));
    try std.testing.expectEqual(@as(?u32, 2), flipTarget(1, 3, true));
    try std.testing.expectEqual(@as(?u32, null), flipTarget(2, 3, true));
    try std.testing.expectEqual(@as(?u32, null), flipTarget(0, 3, false));
    try std.testing.expectEqual(@as(?u32, 1), flipTarget(2, 3, false));
    try std.testing.expectEqual(@as(?u32, null), flipTarget(0, 0, true));
    // out-of-range current clamps first
    try std.testing.expectEqual(@as(?u32, 1), flipTarget(99, 3, false));
}

test "parsePdfInfoPages reads the Pages line" {
    const out = "Title:          x\nPages:          12\nEncrypted:      no\n";
    try std.testing.expectEqual(@as(?u32, 12), parsePdfInfoPages(out));
    try std.testing.expectEqual(@as(?u32, null), parsePdfInfoPages("no pages here"));
    try std.testing.expectEqual(@as(?u32, null), parsePdfInfoPages("Pages: abc"));
}

test "stderr password detection" {
    try std.testing.expect(stderrIndicatesPassword("Command Line Error: Incorrect password"));
    try std.testing.expect(stderrIndicatesPassword("Document is Encrypted"));
    try std.testing.expect(!stderrIndicatesPassword("Syntax Error: bad xref"));
}

test "page indicator formats 1-based" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("3/12", formatPageIndicator(&buf, 2, 12));
    try std.testing.expectEqualStrings("1/1", formatPageIndicator(&buf, 0, 1));
}

test "pdftoppm argv renders one page to stdout" {
    var nums: [32]u8 = undefined;
    const argv = pdftoppmArgv(&nums, "/tmp/a.pdf", 2, 1600);
    try std.testing.expectEqualStrings("pdftoppm", argv[0]);
    try std.testing.expectEqualStrings("-f", argv[2]);
    try std.testing.expectEqualStrings("3", argv[3]);
    try std.testing.expectEqualStrings("3", argv[5]);
    try std.testing.expectEqualStrings("1600", argv[7]);
    try std.testing.expectEqualStrings("/tmp/a.pdf", argv[10]);
}
```

Note: if `std.ascii.indexOfIgnoreCase` does not exist in Zig 0.15.2, implement a small local helper instead (lowercase scan); check `std.ascii` first.

- [ ] **Step 2.2: Run** — `zig test src/pdf_preview.zig` → PASS.

- [ ] **Step 2.3: Register in fast suite** — in `src/test_fast.zig`, inside the `test { ... }` import block, add alphabetically near other root modules: `_ = @import("pdf_preview.zig");` Run `zig build test` → PASS.

- [ ] **Step 2.4: Commit** — `git commit -am "feat(pdf): pure pdf-preview helpers (flip, pdfinfo parse, argv)"`

---

### Task 3: platform rasterizer dispatch + Linux backend

**Files:**
- Create: `src/platform/pdf_render.zig`
- Create: `src/platform/pdf_render_linux.zig`
- Create: `src/platform/pdf_render_windows.zig` (stub this task; real impl Task 7)
- Create: `src/platform/pdf_render_macos.zig` (stub this task; real impl Task 8)
- Create: `src/platform/pdf_render_unsupported.zig`
- Modify: `src/test_posix.zig` (integration test)

- [ ] **Step 3.1: Dispatch module** `src/platform/pdf_render.zig`:

```zig
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
```

- [ ] **Step 3.2: Stubs** — `pdf_render_unsupported.zig` (and, for now, identical bodies in `pdf_render_windows.zig` / `pdf_render_macos.zig` so every target compiles until Tasks 7/8):

```zig
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
```

- [ ] **Step 3.3: Linux backend** `src/platform/pdf_render_linux.zig`:

```zig
//! Linux PDF rasterizer: poppler-utils subprocesses (pdfinfo for the page
//! count, pdftoppm for a single-page PNG on stdout). The document arrives as
//! bytes (local/WSL/SSH sources), so it is staged in a private temp file.
const std = @import("std");
const pdf_render = @import("pdf_render.zig");
const pdf_preview = @import("../pdf_preview.zig");

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
```

Note `pdftoppmArgv` must end with the pdf path and rely on pdftoppm's
stdout default for single-page PNG. **Verify on this machine** (Step 3.5's
integration test does this): if `pdftoppm -png -f 1 -l 1 x.pdf` does NOT write
to stdout without an explicit `-` root argument, append `"-"` as a final argv
element in `pdf_preview.pdftoppmArgv` (bump `PDFTOPPM_ARGC` to 12 and fix its
unit test).

- [ ] **Step 3.4: Compile checks** — `zig build test` (fast suite unaffected) and `zig build` (windows target compiles the windows stub).

- [ ] **Step 3.5: posix integration test** — in `src/test_posix.zig` add to the `comptime` import block `_ = @import("platform/pdf_render_linux.zig");` and add:

```zig
test "pdf_render_linux rasterizes a generated two-page PDF via poppler" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    // Skip cleanly on hosts without poppler-utils.
    const probe = std.process.Child.run(.{ .allocator = alloc, .argv = &.{ "pdftoppm", "-v" } }) catch return error.SkipZigTest;
    alloc.free(probe.stdout);
    alloc.free(probe.stderr);

    const pdf = try buildMinimalTwoPagePdf(alloc);
    defer alloc.free(pdf);

    const pdf_render = @import("platform/pdf_render.zig");
    const page0 = try pdf_render.renderPage(alloc, pdf, 0, 320);
    defer alloc.free(page0.png);
    try std.testing.expectEqual(@as(u32, 2), page0.page_count);
    // PNG magic
    try std.testing.expect(page0.png.len > 8);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G' }, page0.png[0..4]);

    const page1 = try pdf_render.renderPage(alloc, pdf, 1, 320);
    defer alloc.free(page1.png);
    try std.testing.expectEqual(@as(u32, 2), page1.page_count);

    // Out-of-range page fails, invalid bytes fail.
    try std.testing.expectError(error.RenderFailed, pdf_render.renderPage(alloc, pdf, 2, 320));
    try std.testing.expectError(error.InvalidPdf, pdf_render.renderPage(alloc, "not a pdf", 0, 320));
}

/// Assemble a minimal valid 2-page PDF, computing xref offsets at runtime so
/// the fixture never drifts out of sync with its body.
fn buildMinimalTwoPagePdf(alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var offsets: [6]usize = undefined; // objects 1..5; index 0 unused

    try out.appendSlice(alloc, "%PDF-1.4\n");
    const objects = [_][]const u8{
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>\nendobj\n",
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>\nendobj\n",
        "4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>\nendobj\n",
        "5 0 obj\n<< >>\nendobj\n",
    };
    for (objects, 1..) |obj, num| {
        offsets[num] = out.items.len;
        try out.appendSlice(alloc, obj);
    }
    const xref_at = out.items.len;
    try out.appendSlice(alloc, "xref\n0 6\n0000000000 65535 f \n");
    for (offsets[1..6]) |off| {
        try out.writer(alloc).print("{d:0>10} 00000 n \n", .{off});
    }
    try out.writer(alloc).print(
        "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n",
        .{xref_at},
    );
    return out.toOwnedSlice(alloc);
}
```

- [ ] **Step 3.6: Run** — `zig build test-full` (runs posix tests natively) → the new test PASSES (fix the stdout-`-` argv question here if it fails; see Step 3.3 note).

- [ ] **Step 3.7: Commit** — `git commit -am "feat(pdf): platform rasterizer dispatch with poppler Linux backend"`

---

### Task 4: PreviewPane PDF document state, load + page-flip jobs

**Files:**
- Modify: `src/preview_pane.zig`

- [ ] **Step 4.1: Write failing tests** (append to `src/preview_pane.zig`; they exercise the seams with fake fns, no real rasterizer):

```zig
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
```

- [ ] **Step 4.2: Run to verify failure** — `zig test src/preview_pane.zig` will not link (gpu import); instead compile via the app graph: `zig build test-full -Dtarget=x86_64-linux-gnu` (test_main runs natively on Linux) or rely on compile errors from `zig build`. Expected: compile errors (`pdf_render_fn` undefined).

- [ ] **Step 4.3: Implement in `src/preview_pane.zig`:**

Imports: add `const pdf_render = @import("platform/pdf_render.zig");` and `const pdf_preview = @import("pdf_preview.zig");`

New declarations:

```zig
pub const PdfRenderFn = *const fn (Allocator, []const u8, u32, u32) pdf_render.RenderError!pdf_render.RenderResult;
```

New `PreviewJob` fields:

```zig
    pdf_input: ?[]u8 = null, // flip jobs: job-owned copy of the document
    pdf_page: u32 = 0,
    is_pdf_flip: bool = false,
    pdf_out_data: ?[]u8 = null, // on success: document bytes for the pane
    pdf_page_count: u32 = 0,
    fail_msg: ?[]const u8 = null, // static strings only
    render_fn: PdfRenderFn = pdf_render.renderPage,
```

New `PreviewPane` fields:

```zig
pdf_data: ?[]u8 = null, // page_allocator-owned original document bytes
pdf_page: u32 = 0,
pdf_page_count: u32 = 0,
pdf_pending_page: ?u32 = null, // optimistic flip target while a job runs
pdf_render_fn: PdfRenderFn = pdf_render.renderPage,
```

`applyOwned` additionally clears the document state (start of fn):

```zig
    self.clearPdfDocument();
```

with:

```zig
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
```

`unref` calls `self.clearPdfDocument();` next to `freeSource()`.

`beginAsyncLoadWith` copies the seam into the job: in the `job.* = .{ ... }` init add `.render_fn = self.pdf_render_fn`.

`jobThread` routes PDFs:

```zig
fn jobThread(job: *PreviewJob) void {
    if (job.kind == .pdf) {
        pdfJobThread(job);
        job.done.store(true, .release);
        return;
    }
    // ... existing body unchanged ...
}

fn pdfJobThread(job: *PreviewJob) void {
    const alloc = std.heap.page_allocator;
    const data: []u8 = blk: {
        if (job.pdf_input) |d| {
            job.pdf_input = null;
            break :blk d;
        }
        switch (job.read_fn(alloc, job.source_kind, job.kind, job.path_buf[0..job.path_len])) {
            .ok => |s| break :blk s,
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

fn pdfFailMessage(err: pdf_render.RenderError) []const u8 {
    return switch (err) {
        error.Unsupported => "PDF preview is not supported on this platform yet",
        error.ToolMissing => "PDF preview requires poppler-utils (pdftoppm/pdfinfo)",
        error.PasswordProtected => "Encrypted PDF is not supported",
        error.InvalidPdf => "Not a valid PDF",
        error.RenderFailed, error.OutOfMemory => FAILED_SOURCE,
    };
}
```

`tickAsync` result application becomes:

```zig
        if (job.request_id != self.request_id) continue;
        if (job.status == .ready and job.source != null) {
            const s = job.source.?;
            job.source = null;
            const keep_zoom: ?f32 = if (job.is_pdf_flip) self.image_zoom else null;
            self.applyOwned(job.kind, job.title_buf[0..job.title_len], job.path_buf[0..job.path_len], s, .ready);
            if (job.kind == .pdf) {
                if (job.pdf_out_data) |doc| {
                    job.pdf_out_data = null;
                    self.setPdfDocument(doc, job.pdf_page, job.pdf_page_count);
                }
                if (keep_zoom) |z| self.image_zoom = z;
            }
        } else {
            const msg = job.fail_msg orelse if (job.status == .too_large) TOO_LARGE_SOURCE else FAILED_SOURCE;
            self.applyOwned(job.kind, job.title_buf[0..job.title_len], job.path_buf[0..job.path_len], std.heap.page_allocator.dupe(u8, msg) catch null, job.status);
        }
        changed = true;
```

`destroyJob` frees the new buffers:

```zig
fn destroyJob(job: *PreviewJob) void {
    if (job.source) |s| std.heap.page_allocator.free(s);
    if (job.pdf_input) |d| std.heap.page_allocator.free(d);
    if (job.pdf_out_data) |d| std.heap.page_allocator.free(d);
    std.heap.page_allocator.destroy(job);
}
```

Page flip API (keeps showing the current page while rendering — no loading
blank):

```zig
/// Start rendering the previous/next page. Returns false when not a ready
/// PDF, at the document edge, or when the job could not start.
pub fn flipPdfPage(self: *PreviewPane, forward: bool) bool {
    if (self.kind != .pdf or self.load_status != .ready) return false;
    const data = self.pdf_data orelse return false;
    const base = self.pdf_pending_page orelse self.pdf_page;
    const target = pdf_preview.flipTarget(base, self.pdf_page_count, forward) orelse return false;

    const alloc = std.heap.page_allocator;
    const copy = alloc.dupe(u8, data) catch return false;
    self.request_id +%= 1;
    const job = alloc.create(PreviewJob) catch {
        alloc.free(copy);
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
        return false;
    };
    job.thread = std.Thread.spawn(.{}, jobThread, .{job}) catch {
        _ = self.jobs.pop();
        destroyJob(job);
        return false;
    };
    self.pdf_pending_page = target;
    return true;
}
```

Also generalize the raster gates in this file:
- `zoomImageBySteps`: `if (self.kind != .image)` → `if (!self.kind.isRaster())`
- `panImageBy`: `if (self.kind != .image or ...)` → `if (!self.kind.isRaster() or ...)`
- `estimatedMaxScroll`: `if (self.kind == .image)` → `if (self.kind.isRaster())`

- [ ] **Step 4.4: Run** — `zig build test-full` (windows-gnu compile of the app graph + posix) and `zig build test-full -Dtarget=x86_64-linux-gnu` (actually RUNS the preview_pane tests natively; if this target hits unrelated build issues, note it and rely on the windows-gnu compile + a temporary `zig test` harness — but try the linux target first). Expected: new tests PASS.

- [ ] **Step 4.5: Commit** — `git commit -am "feat(pdf): preview pane pdf document state with async page-flip jobs"`

---### Task 5: renderer wiring (badge, page indicator, raster route, failure text)

**Files:**
- Modify: `src/renderer/markdown_preview_renderer.zig`

No new unit tests here (GL-coupled); behavior covered by Task 4 pane tests +
compile checks. Changes:

- [ ] **Step 5.1:** Import `const pdf_preview = @import("../pdf_preview.zig");`

- [ ] **Step 5.2:** Footer badge switch (`renderFooter`, ~line 111): add `.pdf => "PDF",`. Below it, make `badge_end` a `var` and append the page indicator for PDFs:

```zig
    var badge_end = titlebar.renderTextLimited(badge, panel_x + PAD_X, text_y, accent, 40);
    if (pane.kind == .pdf and pane.pdf_page_count > 0) {
        var page_buf: [24]u8 = undefined;
        const label = pdf_preview.formatPageIndicator(&page_buf, pane.pdf_page, pane.pdf_page_count);
        badge_end = titlebar.renderTextLimited(label, badge_end + 8, text_y, muted, 64);
    }
```

- [ ] **Step 5.3:** Document routing (`renderDocument`, ~line 158): `if (pane.kind == .image)` → `if (pane.kind.isRaster())`.

- [ ] **Step 5.4:** PDF-specific failure text in `renderImageDocument` (~line 598): the pane's `source` already holds the precise message for PDFs, so:

```zig
        .failed => {
            const msg = if (pane.kind == .pdf and pane.sourceText().len > 0) pane.sourceText() else "Image preview failed";
            renderStatusMessage(content_x, content_w, window_height, body_top, body_h, msg, normal);
            return;
        },
```

- [ ] **Step 5.5:** Search for other exhaustive `Kind` switches the compiler flags: `zig build && zig build test-full` — fix any remaining `switch` exhaustiveness errors the same way (`.pdf` joins `.image` arms unless text-specific). Expected: builds green.

- [ ] **Step 5.6: Commit** — `git commit -am "feat(pdf): render pdf preview pages with page indicator badge"`

---

### Task 6: input wiring (page flip keys, raster zoom/pan/wheel)

**Files:**
- Modify: `src/input.zig`
- Modify: `README.md` (keyboard shortcuts / features), `docs/file-explorer.md` is Task 9

Per AGENTS.md: every consumed event below already routes through the existing
preview blocks that set `AppWindow.g_force_rebuild`/`g_cells_valid` — keep the
new arms inside those same blocks.

- [ ] **Step 6.1:** Char zoom gate (~line 1430): `if (p.kind == .image and !ev.ctrl and !ev.alt)` → `if (p.kind.isRaster() and !ev.ctrl and !ev.alt)`. (Comment above it mentions "image preview" — update to "raster (image/PDF) preview".)

- [ ] **Step 6.2:** Key block (~line 2065):

```zig
                platform_input.key_page_up => if (p.kind == .pdf) {
                    _ = p.flipPdfPage(false);
                } else p.scrollBy(-360),
                platform_input.key_page_down => if (p.kind == .pdf) {
                    _ = p.flipPdfPage(true);
                } else p.scrollBy(360),
                platform_input.key_up => if (p.kind.isRaster()) {
                    _ = p.panImageBy(0, 40);
                } else p.scrollBy(-60),
                platform_input.key_down => if (p.kind.isRaster()) {
                    _ = p.panImageBy(0, -40);
                } else p.scrollBy(60),
                platform_input.key_left => if (p.kind.isRaster()) {
                    _ = p.panImageBy(40, 0);
                } else {
                    consumed = false;
                },
                platform_input.key_right => if (p.kind.isRaster()) {
                    _ = p.panImageBy(-40, 0);
                } else {
                    consumed = false;
                },
```

- [ ] **Step 6.3:** Wheel (~line 5056): `if (p.kind == .image)` → `if (p.kind.isRaster())`.

- [ ] **Step 6.4:** README: extend the features line 20 (`preview Markdown/text/tables/images` → `preview Markdown/text/tables/images/PDFs`) and line ~215 similarly; in the Keyboard shortcuts section, find the preview-pane rows (search for "preview") and add: `PageUp / PageDown — previous / next PDF page (PDF preview focused)`. Check `src/renderer/overlays.zig` for user-visible preview shortcut strings (`grep -n "PageUp\|preview" src/renderer/overlays.zig`) and update if any describe these keys.

- [ ] **Step 6.5:** Run `zig build test-full` → green.

- [ ] **Step 6.6: Commit** — `git commit -am "feat(pdf): PageUp/PageDown page navigation and raster zoom/pan for pdf previews"`

---

### Task 7: Windows backend (WinRT Windows.Data.Pdf via C bridge)

**Files:**
- Create: `src/platform/pdf_render_windows_bridge.c`
- Rewrite: `src/platform/pdf_render_windows.zig`
- Modify: `build.zig` (compile the bridge for windows targets)

- [ ] **Step 7.1: Verify interface IIDs/vtable orders.** The bridge hand-declares WinRT interfaces (mingw has `roapi.h`/`winstring.h`/`asyncinfo.h`/`shcore.h` but no `windows.data.pdf.h`). Before coding, confirm against the Windows SDK header (`windows.data.pdf.h`, available in the `microsoft/win32metadata` repo or SDK mirrors on GitHub) these values used below:
  - `IID_IPdfDocumentStatics = {433A0B5F-C007-4788-90F2-08143D922599}`
  - `IID_IPdfPageRenderOptions = {3C98056F-B7CF-4C29-9A04-52D90267F425}`
  - vtable orders: `IPdfDocumentStatics`: LoadFromFileAsync, LoadFromFileWithPasswordAsync, LoadFromStreamAsync, LoadFromStreamWithPasswordAsync. `IPdfDocument`: GetPage, get_PageCount, get_IsPasswordProtected. `IPdfPage`: RenderToStreamAsync, RenderWithOptionsToStreamAsync, PreparePageAsync, get_Index, get_Size, get_Dimensions, get_Rotation, get_PreferredZoom. `IPdfPageRenderOptions`: get/put_SourceRect, get/put_DestinationWidth, get/put_DestinationHeight, get/put_BackgroundColor, get/put_IsIgnoringHighContrast, get/put_BitmapEncoderId. `IAsyncOperation<T>`/`IAsyncAction`: IInspectable(6 slots) + put_Completed, get_Completed, GetResults.
  Use WebSearch/WebFetch; record the verified values in the bridge comments.

- [ ] **Step 7.2: Write the C bridge** `src/platform/pdf_render_windows_bridge.c`. Contract and structure (full file; adjust only if Step 7.1 contradicts):

```c
// WinRT Windows.Data.Pdf rasterizer bridge (Win10+ system component).
// All WinRT/COM entry points are loaded dynamically (combase/shlwapi/shcore)
// so no new import libraries are required; async operations are observed by
// polling IAsyncInfo::get_Status from the (non-UI) caller thread.
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <roapi.h>
#include <winstring.h>
#include <asyncinfo.h>
#include <shcore.h>
#include <stdint.h>
#include <stddef.h>

#define WISP_PDF_OK 0
#define WISP_PDF_ERR_OS 1
#define WISP_PDF_ERR_INVALID 2
#define WISP_PDF_ERR_PASSWORD 3
#define WISP_PDF_ERR_RENDER 4
#define WISP_PDF_ERR_PAGE_RANGE 5

// ---- dynamic entry points -------------------------------------------------
typedef HRESULT(WINAPI *RoInitializeFn)(RO_INIT_TYPE);
typedef void(WINAPI *RoUninitializeFn)(void);
typedef HRESULT(WINAPI *RoGetActivationFactoryFn)(HSTRING, REFIID, void **);
typedef HRESULT(WINAPI *RoActivateInstanceFn)(HSTRING, IInspectable **);
typedef HRESULT(WINAPI *WindowsCreateStringFn)(PCWSTR, UINT32, HSTRING *);
typedef HRESULT(WINAPI *WindowsDeleteStringFn)(HSTRING);
typedef IStream *(WINAPI *SHCreateMemStreamFn)(const BYTE *, UINT);
typedef HRESULT(WINAPI *CreateRandomAccessStreamOverStreamFn)(IStream *, BSOS_OPTIONS, REFIID, void **);

// ---- minimal WinRT interface declarations (verified per plan Step 7.1) ----
// IInspectable base: QueryInterface, AddRef, Release, GetIids,
// GetRuntimeClassName, GetTrustLevel == 6 leading slots.
typedef struct WinRtObj WinRtObj; // generic IInspectable-derived handle

typedef struct AsyncVtbl {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(WinRtObj *, REFIID, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(WinRtObj *);
    ULONG(STDMETHODCALLTYPE *Release)(WinRtObj *);
    HRESULT(STDMETHODCALLTYPE *GetIids)(WinRtObj *, ULONG *, IID **);
    HRESULT(STDMETHODCALLTYPE *GetRuntimeClassName)(WinRtObj *, HSTRING *);
    HRESULT(STDMETHODCALLTYPE *GetTrustLevel)(WinRtObj *, int *);
    HRESULT(STDMETHODCALLTYPE *put_Completed)(WinRtObj *, void *);
    HRESULT(STDMETHODCALLTYPE *get_Completed)(WinRtObj *, void **);
    HRESULT(STDMETHODCALLTYPE *GetResults)(WinRtObj *, void **); // for IAsyncAction: no out param
} AsyncVtbl;
typedef struct WinRtObj { const AsyncVtbl *lpVtbl; } WinRtAsync;

// ... analogous explicit vtable structs for IPdfDocumentStatics, IPdfDocument,
// IPdfPage, IPdfPageRenderOptions, declared with the exact slot orders from
// Step 7.1 (full declarations in the file; elided in this plan excerpt) ...

// Poll an async operation to completion. Returns WISP_PDF_OK / error code.
static int wisp_wait_async(IUnknown *op) {
    IAsyncInfo *info = NULL;
    if (FAILED(IUnknown_QueryInterface(op, &IID_IAsyncInfo, (void **)&info)))
        return WISP_PDF_ERR_OS;
    for (;;) {
        AsyncStatus st = Started;
        if (FAILED(IAsyncInfo_get_Status(info, &st))) { IAsyncInfo_Release(info); return WISP_PDF_ERR_OS; }
        if (st == Completed) { IAsyncInfo_Release(info); return WISP_PDF_OK; }
        if (st != Started) { // Canceled or Error
            HRESULT code = E_FAIL;
            IAsyncInfo_get_ErrorCode(info, &code);
            IAsyncInfo_Release(info);
            return code == (HRESULT)0x8007052B /* wrong password */ ? WISP_PDF_ERR_PASSWORD : WISP_PDF_ERR_INVALID;
        }
        Sleep(2);
    }
}

// Renders one 0-based page to PNG. *out_png is HeapAlloc'd; free with
// wisp_pdf_free. Returns WISP_PDF_* code.
int wisp_pdf_render_page(const unsigned char *pdf, size_t pdf_len,
                         unsigned int page_index, unsigned int target_width,
                         unsigned char **out_png, size_t *out_png_len,
                         unsigned int *out_page_count);
void wisp_pdf_free(void *p);
```

Body of `wisp_pdf_render_page` (sequence; each step releases on failure):
1. Load combase/shlwapi/shcore fns once (static + `InterlockedCompareExchange` guard or simple static init under a critical section; failure → `WISP_PDF_ERR_OS`).
2. `RoInitialize(RO_INIT_MULTITHREADED)`; accept `S_OK`/`S_FALSE`/`RPC_E_CHANGED_MODE` (only pair `RoUninitialize` for the first two).
3. `WindowsCreateString(L"Windows.Data.Pdf.PdfDocument")` → `RoGetActivationFactory(IID_IPdfDocumentStatics)`.
4. `SHCreateMemStream(pdf, pdf_len)` → `CreateRandomAccessStreamOverStream(..., BSOS_DEFAULT, IID_IRandomAccessStream)` (declare `IID_IRandomAccessStream = {905A0FE1-BC53-11DF-8C49-001E4FC686DA}`).
5. `LoadFromStreamAsync` → `wisp_wait_async` → `GetResults` → `IPdfDocument`. A wrong-password failure surfaces here (`0x8007052B`); also call `get_IsPasswordProtected` and return `WISP_PDF_ERR_PASSWORD` if true.
6. `get_PageCount` → `*out_page_count`; bounds-check `page_index` (→ `WISP_PDF_ERR_PAGE_RANGE`).
7. `GetPage(page_index)` → `IPdfPage`.
8. `RoActivateInstance(L"Windows.Data.Pdf.PdfPageRenderOptions")` → QI `IID_IPdfPageRenderOptions` → `put_DestinationWidth(target_width)` (height unset preserves aspect).
9. Output stream: `SHCreateMemStream(NULL, 0)` (keep the `IStream*`!) → wrap via `CreateRandomAccessStreamOverStream` → `RenderWithOptionsToStreamAsync(wrapped, options)` → `wisp_wait_async` (render failure → `WISP_PDF_ERR_RENDER`).
10. Read back from the kept `IStream`: `IStream_Seek(0, STREAM_SEEK_END)` for size, seek 0, `IStream_Read` into a `HeapAlloc(GetProcessHeap(), 0, size)` buffer → `*out_png/*out_png_len`.
11. Release everything; `RoUninitialize` when owed; return `WISP_PDF_OK`.

`wisp_pdf_free`: `HeapFree(GetProcessHeap(), 0, p);`

- [ ] **Step 7.3: Zig wrapper** — replace the stub `src/platform/pdf_render_windows.zig`:

```zig
//! Windows PDF rasterizer: WinRT Windows.Data.Pdf via pdf_render_windows_bridge.c.
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
            3 => error.PasswordProtected,
            2 => error.InvalidPdf,
            5 => error.RenderFailed, // page out of range
            else => error.RenderFailed,
        };
    }
    const src = png_ptr orelse return error.RenderFailed;
    defer wisp_pdf_free(src);
    const png = try alloc.dupe(u8, src[0..png_len]);
    return .{ .png = png, .page_count = page_count };
}
```

- [ ] **Step 7.4: build.zig** — in `createAppModule`, next to the glad block (`if (target.result.os.tag == .windows or ...)`, ~line 1014), add:

```zig
    // System WinRT PDF rasterizer bridge (preview pane PDF support).
    if (target.result.os.tag == .windows) {
        app_mod.addCSourceFile(.{
            .file = b.path("src/platform/pdf_render_windows_bridge.c"),
            .flags = &.{},
        });
    }
```

(`createAppModuleWithRoot` shares this code path, so `test_main` links the bridge too. The comptime `build_guards.firstLeak` check runs on every build — if it rejects the added lines, follow its message; existing per-OS conditionals at line 1014 show the accepted pattern.)

- [ ] **Step 7.5: Compile checks** — `zig build` (windows app links bridge) and `zig build test-full` → green. Note in the PR that Windows runtime behavior needs GUI verification on a real Windows machine.

- [ ] **Step 7.6: Commit** — `git commit -am "feat(pdf): Windows rasterizer via system WinRT Windows.Data.Pdf"`

---

### Task 8: macOS backend (CGPDF + ImageIO bridge)

**Files:**
- Create: `src/platform/pdf_render_macos_bridge.m`
- Rewrite: `src/platform/pdf_render_macos.zig`
- Modify: `build.zig` (`macos_objective_c_sources`, `macos_app_frameworks` + their tests)

- [ ] **Step 8.1: Objective-C bridge** `src/platform/pdf_render_macos_bridge.m`:

```objc
// macOS PDF rasterizer: CGPDFDocument draw into a bitmap context, PNG-encoded
// with ImageIO. System frameworks only (CoreGraphics, ImageIO).
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define WISP_PDF_OK 0
#define WISP_PDF_ERR_OS 1
#define WISP_PDF_ERR_INVALID 2
#define WISP_PDF_ERR_PASSWORD 3
#define WISP_PDF_ERR_RENDER 4
#define WISP_PDF_ERR_PAGE_RANGE 5

int wisp_pdf_render_page_macos(const uint8_t *pdf, size_t pdf_len,
                               uint32_t page_index, uint32_t target_width,
                               uint8_t **out_png, size_t *out_png_len,
                               uint32_t *out_page_count) {
    *out_png = NULL;
    *out_png_len = 0;
    *out_page_count = 0;
    if (target_width == 0 || pdf_len == 0) return WISP_PDF_ERR_INVALID;

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pdf, pdf_len, NULL);
    if (!provider) return WISP_PDF_ERR_OS;
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithProvider(provider);
    CGDataProviderRelease(provider);
    if (!doc) return WISP_PDF_ERR_INVALID;

    int rc = WISP_PDF_ERR_RENDER;
    CGContextRef ctx = NULL;
    CGColorSpaceRef space = NULL;
    CGImageRef image = NULL;
    CFMutableDataRef data = NULL;
    CGImageDestinationRef dest = NULL;

    if (CGPDFDocumentIsEncrypted(doc) && !CGPDFDocumentUnlockWithPassword(doc, "")) {
        rc = WISP_PDF_ERR_PASSWORD;
        goto done;
    }
    size_t count = CGPDFDocumentGetNumberOfPages(doc);
    *out_page_count = (uint32_t)count;
    if (page_index >= count) {
        rc = WISP_PDF_ERR_PAGE_RANGE;
        goto done;
    }
    CGPDFPageRef page = CGPDFDocumentGetPage(doc, page_index + 1); // 1-based
    if (!page) goto done;

    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
    if (box.size.width <= 0 || box.size.height <= 0) goto done;
    size_t px_w = target_width;
    size_t px_h = (size_t)((double)target_width * box.size.height / box.size.width + 0.5);
    if (px_h == 0 || px_h > 8192 * 4) goto done;

    space = CGColorSpaceCreateDeviceRGB();
    ctx = CGBitmapContextCreate(NULL, px_w, px_h, 8, 0, space,
                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) goto done;
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, px_w, px_h));
    CGContextSaveGState(ctx);
    CGContextScaleCTM(ctx, (CGFloat)px_w / box.size.width, (CGFloat)px_h / box.size.height);
    CGContextTranslateCTM(ctx, -box.origin.x, -box.origin.y);
    CGContextDrawPDFPage(ctx, page);
    CGContextRestoreGState(ctx);

    image = CGBitmapContextCreateImage(ctx);
    if (!image) goto done;
    data = CFDataCreateMutable(NULL, 0);
    dest = CGImageDestinationCreateWithData(data, CFSTR("public.png"), 1, NULL);
    if (!dest) goto done;
    CGImageDestinationAddImage(dest, image, NULL);
    if (!CGImageDestinationFinalize(dest)) goto done;

    size_t len = (size_t)CFDataGetLength(data);
    uint8_t *buf = malloc(len);
    if (!buf) { rc = WISP_PDF_ERR_OS; goto done; }
    memcpy(buf, CFDataGetBytePtr(data), len);
    *out_png = buf;
    *out_png_len = len;
    rc = WISP_PDF_OK;

done:
    if (dest) CFRelease(dest);
    if (data) CFRelease(data);
    if (image) CGImageRelease(image);
    if (ctx) CGContextRelease(ctx);
    if (space) CGColorSpaceRelease(space);
    CGPDFDocumentRelease(doc);
    return rc;
}

void wisp_pdf_free_macos(void *p) { free(p); }
```

Note: the caller (preview job thread) outlives the call and the provider copy
is not retained past `renderPage`, so passing `pdf` without a copy is safe.

- [ ] **Step 8.2: Zig wrapper** `src/platform/pdf_render_macos.zig` — mirror of the Windows wrapper with `wisp_pdf_render_page_macos` / `wisp_pdf_free_macos` extern names and the same error-code mapping.

- [ ] **Step 8.3: build.zig** — append `"src/platform/pdf_render_macos_bridge.m"` to `macos_objective_c_sources` and `"ImageIO"` to `macos_app_frameworks`. Update the build tests: framework count `10` → `11` plus `try expectContainsString(frameworks, "ImageIO");` (test "macOS platform advertises required app frameworks"); check for any test asserting the objective-c source list/count and update it.

- [ ] **Step 8.4: Compile checks** — `zig build test-full` (build.zig tests run in test_main; shared compile checks). Attempt `zig build test-shared -Dtarget=aarch64-macos` for a macOS cross-compile check; if the apple-sdk/zlib sysroot blocks it (known issue), record that in the PR and rely on review + macOS CI/GUI verification later.

- [ ] **Step 8.5: Commit** — `git commit -am "feat(pdf): macOS rasterizer via CGPDF + ImageIO"`

---

### Task 9: docs and wiki sync

**Files:**
- Modify: `docs/file-explorer.md` (embedded in-app doc — keep in sync with wiki)
- Modify: `wiki/File-Explorer.md`, `wiki/File-Explorer-zh.md`
- Modify: `wiki/Keyboard-Shortcuts.md` (+ its zh twin if present)
- Modify: `README.md` / `README.zh-CN.md` feature lines if not already done in Task 6

- [ ] **Step 9.1:** `docs/file-explorer.md`: extend the preview description (~line 12-17): PDFs preview as rasterized pages; PageUp/PageDown turn pages; wheel zooms, drag pans; on Linux requires poppler-utils (`sudo apt install poppler-utils`); encrypted PDFs unsupported. Mention the footer `N/M` page indicator.

- [ ] **Step 9.2:** Mirror the same content in `wiki/File-Explorer.md` (EN) and `wiki/File-Explorer-zh.md` (zh-CN), and the PageUp/PageDown binding in `wiki/Keyboard-Shortcuts.md` (+ zh twin). Run `python3 wiki/check_wiki.py` if present (link/parity validator).

- [ ] **Step 9.3:** Run `zig build test` (docs are @embedFile'd — confirm nothing breaks) and commit: `git commit -am "docs(pdf): document PDF preview in embedded docs and wiki"`

---

### Task 10: full verification + PR

- [ ] **Step 10.1:** `zig build test` → green. `zig build test-full` → green. `zig build` → green. If available, `zig build test-full -Dtarget=x86_64-linux-gnu` → green (runs pane tests natively).
- [ ] **Step 10.2:** Manual smoke on this Linux box if the app runs under WSLg: open a terminal, `ls` a PDF, ctrl+click it; verify page render + PageUp/PageDown + zoom. (Best-effort; GL screenshots under WSLg are known-broken.)
- [ ] **Step 10.3:** Use superpowers:requesting-code-review, fix findings.
- [ ] **Step 10.4:** Push branch, open PR (note: Windows/macOS GUI verification pending; Linux integration-tested). Check live proxy port before push (memory: probe :6789 and :1990).
