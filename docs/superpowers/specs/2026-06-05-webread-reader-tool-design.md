# `$webread` (Jina Reader: web page + local file) Design

## Goal

Add a "read this into clean markdown" capability to the AI chat, mirroring the existing
`$websearch` feature, exposed two ways:

1. **`$webread <target>` user command** — typed in the chat composer. WispTerm fetches the
   content itself and renders it into the transcript. No AI turn.
2. **`webread` agent tool** — the AI model calls it on its own when it needs the full
   content of a specific page or local document. Returns the content to the model.

`<target>` is either:

- a **web URL** (`http://` / `https://`) → read via `r.jina.ai` → clean markdown, or
- a **local file path** (anything else) → uploaded to `r.jina.ai` → clean markdown.
  Reader sniffs the MIME from the bytes, so PDF **and** Word/Excel/PowerPoint all work
  through the same path.

The Reader backend is Jina (`r.jina.ai`), the counterpart of the search engine
(`s.jina.ai`) already wired for `$websearch`. The **same `jina-api-key` serves both**
read and search — no new config key. Reader allows anonymous use, so the key is
**optional**: sent as `Bearer` when configured (higher rate limit), omitted otherwise.

## Architecture

A new module `src/web_read.zig` owns everything reader-specific: the result type, the pure
request-building / response-parsing / formatting logic, and the single impure HTTP
function. Both entry points (the `$webread` command and the agent tool) call into this
module. The module is **pure of config**: it does not read the global key — callers pass
`api_key` in `Options` (reusing the existing `web_search.jinaApiKeyAlloc()` global), so
`web_read` does not depend on `web_search`.

The `$webread` command runs on a background thread that reuses the existing AI-request
lifecycle (re-checks `session.closing` under the session lock before touching the
transcript), exactly like `$websearch`. The agent tool runs synchronously inside the
existing tool worker thread, like every other tool.

```
ai_chat_composer.parseWebCommand ──► ai_chat (spawn bg job) ─┐
                                                             ├─► web_read.executeRead ─► Jina r.jina.ai HTTP
ai_chat_protocol.forEachToolSpec ──► ai_chat_tools.executeToolCall ─┘
```

## `src/web_read.zig`

### Types

```zig
pub const ReadResult = struct {       // owns its backing memory via an arena
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    url: []const u8,                  // source URL/path echoed by Reader (may be "")
    content: []const u8,              // markdown
    pub fn deinit(self: *ReadResult) void;
};

pub const Options = struct {
    api_key: []const u8 = "",         // "" = anonymous (no Authorization header)
    max_file_bytes: usize = 25 * 1024 * 1024,  // reject larger local files (OOM guard)
};
```

### Pure functions (no network / no disk — unit tested)

- `isHttpUrl(target) bool` → true when target starts with `http://` or `https://`
  (case-insensitive).
- `buildUrlRequestBody(allocator, url) ![]u8` → `{"url":"<url>"}` (URL JSON-escaped, reuses
  the same `appendJsonString` escaping as `web_search`).
- `buildMultipartBody(allocator, filename, bytes) !struct { body: []u8, content_type: []u8 }`
  → a `multipart/form-data` body with one `file` field (`Content-Disposition: form-data;
  name="file"; filename="<basename>"`) plus the raw bytes, and the matching
  `multipart/form-data; boundary=<...>` content-type string. Boundary is a fixed unique
  token unlikely to collide (binary-safe; we do not scan the payload).
- `parseReaderResponse(arena, json_bytes) !ReadResult-fields` → reads
  `{"code":200,"data":{"title","url","content"}}`. Tolerates missing `title`/`url`
  (default `""`); a missing/empty `content` with no usable data → `error.ParseFailed`.
  Uses `parseFromSlice` with `.allocate = .alloc_always` (source buffer freed before use —
  see the parseFromSlice alias UAF note).
- `formatForUser(allocator, target, result) ![]u8` → transcript block:
  header echoing the target, then `# <title>`, the source URL line, and the content —
  **truncated to ~8000 chars** with a `…(truncated, N chars total)` note so a huge page
  does not flood the transcript.
- `formatForAgent(allocator, target, result) ![]u8` → `title` / `URL:` / full `content`
  for the model (no truncation; the model asked for it).

### Impure function

- `executeRead(gpa, target, opts) !ReadResult`
  - `isHttpUrl(target)` → **web mode**: `POST https://r.jina.ai/` with body
    `buildUrlRequestBody(target)`, headers `Content-Type: application/json`,
    `Accept: application/json`, and `Authorization: Bearer <api_key>` **only when
    `api_key.len > 0`**.
  - else → **file mode**: `std.fs.cwd().openFile(target)`; `error.FileNotFound` /
    other open errors map to `error.FileNotFound`. Stat; if size > `max_file_bytes` →
    `error.FileTooLarge`. Read bytes, `buildMultipartBody(basename, bytes)`,
    `POST https://r.jina.ai/` with that body + content-type, `Accept: application/json`,
    optional `Authorization`.
  - Non-200 → `error.HttpStatus` (trimmed body excerpt captured for the message, like
    `web_search`). Transport failure → `error.Network`. Then `parseReaderResponse`.
- HTTP goes through `platform/http_client.zig` (`fetch`) so desktop builds keep system
  proxies. Reuses the same threadlocal error-detail buffer pattern as `web_search`
  (`network` / `http_status` / `parse_failed`).

### Errors → text

`errorText(err)` / `formatErrorText(allocator, err)` mirror `web_search`, mapping:

- `error.FileNotFound` → "Web read failed: no such local file: `<…>` (use an http(s):// URL
  or an existing file path)." *(target echoed by the caller, not the key)*
- `error.FileTooLarge` → "Web read failed: file exceeds the 25 MB upload limit."
- `error.Network` / `error.HttpStatus` / `error.ParseFailed` → same shape as search.

Note: **no `MissingApiKey`** — Reader works anonymously.

## Config

No new config key. Both entry points obtain the key from the existing
`web_search.jinaApiKeyAlloc(allocator)` (set from `jina-api-key`) and pass it into
`Options.api_key`; `null`/unset → `""` → anonymous. The `--help` line for `jina-api-key`
is updated to mention it powers **both** `$websearch` and `$webread`.

## `$webread` user command

### Composer (`src/ai_chat_composer.zig`)

- Extend `WebCommand` to `enum { websearch, webread }`.
- Add `.{ .name = "webread", .description = "read a web page or local file (Jina)" }` to
  `reserved_web_commands` (so typing `$` surfaces it alongside `$websearch`).
- Extend `parseWebCommand(token)` to also match `$webread` (exact token; rejects
  `$webreadx`, `/webread`, bare `webread`).

### Dispatch (`src/ai_chat.zig`)

- In the submit path where `parseWebCommand` is checked, branch on the returned variant.
  `webread`: extract the target = text after `$webread`, trimmed.
  - Empty → append `Usage: $webread <url | file path>`; no network.
  - Otherwise: set status "Reading…", clear the input, spawn a background read job with an
    owned copy of the target.
- New `WebReadRequest` struct + `startWebReadRequest`, siblings of `WebSearchRequest` /
  `startWebSearchRequest`. The worker calls `web_read.executeRead` (key from
  `web_search.jinaApiKeyAlloc`), then lands the result via the existing
  `appendWebSearchResult(session, text)` (it is a generic "append local tool message" — no
  need for a second function). On error it appends `formatErrorText`.

### Worker (`src/ai_chat_request.zig`)

- `webReadThreadMain(req)` mirrors `webSearchThreadMain`: owns `req`, frees on exit,
  re-checks `session.closing`, formats with `web_read.formatForUser`.

## Agent `webread` tool

### Schema (`src/ai_chat_protocol.zig`)

One new `emit(...)` in `forEachToolSpec` (single source of truth → all three protocols):

- name: `webread`
- description: "Read a web page or local file into clean markdown via Jina Reader. Pass an
  http(s):// URL to fetch a page, or a local file path (PDF, Word, Excel, PowerPoint) to
  upload and convert it. Use when you need the full content of one source, not a search."
- properties: `{"url":{"type":"string"}}` (required) — name kept `url` for model clarity
  though it also accepts a local path.

### Dispatch (`src/ai_chat_tools.zig`)

- New `"webread"` branch in `executeToolCall`: parse `url` (required); key from
  `web_search.jinaApiKeyAlloc`; `web_read.executeRead`; return `web_read.formatForAgent`.
  Missing arg / file error / HTTP error → return a clear message string (tools return error
  text, they do not throw).
- **No approval gate** — consistent with `websearch`. Reading a URL is a read-only fetch;
  uploading a local file is the user's own explicit choice of file. Runs unprompted at
  every permission level.

## Testing

Pure tests in `web_read.zig`, registered in the fast suite (imported in
`test_fast.zig` / `test_main.zig` so they actually run):

- `isHttpUrl`: http/https (any case) true; paths / `ftp://` / `"file.pdf"` false.
- `buildUrlRequestBody` escapes a URL containing a quote/`&`.
- `buildMultipartBody`: body contains the boundary, the `file` field disposition with the
  basename, the raw bytes, and a closing boundary; content-type carries the same boundary.
- `parseReaderResponse` on captured sample JSON: extracts title/url/content; tolerates
  missing title/url; empty `data` → `error.ParseFailed`.
- `formatForUser` truncates past the cap and notes total length; `formatForAgent` keeps
  full content.
- `errorText` maps `FileNotFound` / `FileTooLarge` / `Network` / `HttpStatus`.

Composer test in test-full: `parseWebCommand` accepts `$webread https://x`, extracts the
target, still accepts `$websearch …`, and rejects `$webreadx` / `/webread` / plain text.

No live network or disk in the pure tests — the HTTP path is exercised only against
captured JSON; multipart is tested on in-memory bytes. (A file-mode `executeRead` smoke
test may read a tiny temp file but must not hit the network.)

Implement with TDD. Run `zig build test`; run `zig build test-full` before finishing.

## Scope guards (YAGNI)

- Only `r.jina.ai`; `Accept: application/json`; default markdown output.
- No advanced Reader headers (screenshot/pageshot, `x-markdown-chunking`, `x-preset`,
  per-page `page=N`, target selectors, image captioning).
- Local files are **local to the machine running WispTerm** — no SSH-surface remote-file
  read (the agent file-edit tools' `surface_id` path is out of scope here).
- Key is config-file `jina-api-key`, shared with search; no env var, no per-profile key.
- User command shows the content (truncated) — no AI summarization turn.
- No caching, no recursive site crawl, no follow-links.
```
