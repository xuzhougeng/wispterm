# PDF Native Preview — Design

Date: 2026-06-12
Status: approved

## Goal

Ctrl+click on a `.pdf` path previews the PDF in the existing preview pane, the
same way `.png`/`.jpg` images preview today, with multi-page navigation. No
bundled third-party PDF library (MIT-incompatible AGPL MuPDF and heavyweight
PDFium are both rejected); each OS rasterizes with what it ships.

## Approach

Rasterize "PDF page N" into PNG bytes on the preview job thread, then reuse the
existing image preview pipeline untouched: `PreviewPane.source` holds encoded
PNG → render thread decodes via stb_image → GL texture → zoom/pan. Only the
"PDF bytes → PNG bytes" step is platform-specific.

## Components

### 1. Platform rasterizer: `src/platform/pdf_render.zig`

Dispatch module following the `clipboard.zig` pattern
(`pdf_render_windows.zig` / `pdf_render_macos.zig` / `pdf_render_linux.zig` /
`pdf_render_unsupported.zig`).

Unified interface (bytes in, bytes out, so WSL/remote-SSH sources work
unchanged):

```zig
pub const RenderResult = struct { png: []u8, page_count: u32 };
pub const RenderError = error{ Unsupported, ToolMissing, InvalidPdf,
    PasswordProtected, RenderFailed, OutOfMemory };
/// page_index is 0-based. target_width_px is the rasterization width.
pub fn renderPage(alloc: Allocator, pdf_bytes: []const u8, page_index: u32,
    target_width_px: u32) RenderError!RenderResult;
```

- **Windows**: system WinRT `Windows.Data.Pdf.PdfDocument` (built into
  Win10+). Hand-declared COM vtables. PDF bytes wrapped via `SHCreateMemStream`
  + `CreateRandomAccessStreamOverStream`; `LoadFromStreamAsync` /
  `RenderToStreamAsync` completion observed by polling `IAsyncInfo.Status`
  (no COM callback objects). Output stream is already PNG-encoded. Each call
  runs on a fresh preview job thread; `RoInitialize(MULTITHREADED)` /
  `RoUninitialize` inside the call.
- **macOS**: `pdf_render_macos_bridge.m` using CGPDFDocument
  (`CGDataProviderCreateWithData` → `CGPDFDocumentCreateWithProvider`) drawn
  into a CGBitmapContext, encoded to PNG with ImageIO
  (`CGImageDestinationCreateWithData`, UTType PNG). System frameworks only;
  stb_image_write is not vendored so ImageIO does the encoding.
- **Linux**: temp file + poppler-utils subprocesses: `pdfinfo` parses
  `Pages: N`; `pdftoppm -png -f P -l P -scale-to-x W -scale-to-y -1 file`
  writes a single PNG to stdout. Missing tools → `error.ToolMissing` with a
  pane message telling the user to install poppler-utils.
- Encrypted PDFs map to `error.PasswordProtected` (best effort per backend).

### 2. Kind and pane state

- `markdown_preview.Kind` gains `.pdf`; `detectKind` maps the `.pdf` suffix
  (case-insensitive). `sourceLimit(.pdf)` = `MAX_PDF_SOURCE_BYTES` = 64 MiB.
- `PreviewPane` gains: `pdf_data: ?[]u8` (original PDF bytes, cached so page
  flips never re-read local/WSL/SSH sources), `pdf_page: u32` (0-based),
  `pdf_page_count: u32`.
- PDF load job = existing read fn (local/WSL/remote) → `renderPage` → PNG into
  `source`, PDF bytes moved into `pane.pdf_data`, page count recorded.
- Page-flip job = rasterize-only using cached `pdf_data`; guarded by the
  existing `request_id` staleness check. Page flips preserve zoom, reset pan.

### 3. Input

When the focused preview pane kind is `.pdf`:

- PageUp / PageDown = previous / next page, clamped to `[0, page_count)`.
  (Harmless repurposing: scroll is a no-op for raster kinds.)
- `+`/`-`, mouse wheel = zoom; arrow keys = pan — same as images, via an
  `isRasterKind()` helper replacing `kind == .image` checks where behavior is
  shared.

### 4. Renderer

`markdown_preview_renderer.zig`: `.pdf` takes the image draw path (decode
`source` PNG → texture, zoom/pan/clip identical). Header badge shows `PDF`
plus a `N/M` page indicator. Fixed rasterization width 1600 px (zoom works on
the texture; re-rasterizing per zoom level is out of scope for v1).

### 5. Failure handling

Pane-level status text, consistent with existing `FAILED_SOURCE` style:
encrypted ("Encrypted PDF is not supported"), invalid/corrupt ("Preview
failed"), Linux missing tools ("PDF preview requires poppler-utils
(pdftoppm/pdfinfo)"). Errors never crash the pane; `load_status = .failed`.

### 6. Testing

- Pure unit tests (fast suite): `.pdf` kind detection + source limit; page
  clamp/flip transitions; pdftoppm/pdfinfo argv building; `pdfinfo` output
  parsing; pane title/page-indicator formatting.
- `preview_pane` async tests with an injected fake rasterizer (existing
  `read_fn` seam pattern) covering: load populates `pdf_data`/page count;
  flip preserves zoom and bumps generation; stale flip results dropped.
- `test_posix.zig`: real-pdftoppm integration test with a minimal hand-written
  PDF fixture embedded in the test; skips when poppler-utils is absent.
- Windows/macOS backends: cross-compile checks (`zig build windows`, macOS
  targets); runtime GUI verification deferred as usual.

### 7. Docs

Update the file-preview topic in `docs/` and `wiki/` (EN + zh-CN, kept in
sync — docs/*.md are @embedFile'd for the in-app `wispterm_docs` tool).

## Out of scope (v1)

- Re-rasterizing at higher resolution on zoom-in.
- Text selection/search inside the PDF, outlines, links.
- HTML server (web remote) PDF preview.
- Configurable render width.
