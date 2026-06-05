# `webread` local-file → markdown cache Design

## Goal

When `webread` reads a **local file** (PDF / Office), it uploads the bytes to Jina Reader
and waits for the conversion (~60 s for a paper). When the model re-reads the same file
moments later (e.g. "now list all the authors"), it pays that cost again. This feature
caches the converted markdown on disk, keyed by file content, so a repeat read of an
unchanged file returns instantly with no network call.

Scope: **local file uploads only**. Web URLs are never cached (reading a URL should stay
live). Office formats ride the same path as PDF (already MIME-sniffed by Reader).

## Architecture

A new pure module **`src/web_read_cache.zig`** owns the cache's path/key/IO logic. It has no
network or Jina knowledge — just "given a working dir, a resolved file path, and the file
bytes, where is the cache file, and read/write it". `web_read.executeRead` orchestrates:
hash the bytes, look up the cache, return on hit, or upload-then-store on miss. The two
entry points (`$webread` user command, `webread` agent tool) each pass their working
directory into `web_read.Options.cache_dir`.

```
webReadTool (agent)      ─┐                         ┌─ web_read_cache.lookup ─► <cache>.md (HIT, no network)
                          ├─► web_read.executeRead ─┤
webReadThreadMain (user) ─┘   (file mode only)      └─ Jina upload ─► web_read_cache.store (MISS)
```

## Cache key, location, naming

- **Key:** `SHA-256` of the file bytes (hex). Content-addressed, so an edited file produces a
  different key and re-converts automatically — invalidation is free, no mtime/size guessing.
  A changed file can never hit a stale entry (different bytes → different filename).
- **Cache root:**
  - working dir set & non-empty → `<working_dir>/.webread_cache/`
  - otherwise → `<dirname(resolved_file)>/.webread_cache/` (sidecar fallback next to the file)
- **Filename:** `<basename>.<sha16>.md`, where `<sha16>` is the first 16 hex chars (64 bits) of
  the SHA-256. Basename keeps it human-readable (`Gosai_Nature_24.pdf.5f3a1c…​.md`); the hash
  suffix makes it content-addressed and collision-safe for a personal cache.

## `src/web_read_cache.zig` (pure, unit-tested)

```zig
/// Hex SHA-256 of `bytes` written into `out` (out.len must be 64). Returns out[0..64].
pub fn sha256Hex(bytes: []const u8, out: *[64]u8) []const u8;

/// Cache root dir: `<cache_dir>/.webread_cache` when cache_dir is non-empty, else
/// `<dirname(resolved_path)>/.webread_cache`. Caller frees.
pub fn cacheRoot(allocator, cache_dir: ?[]const u8, resolved_path: []const u8) ![]u8;

/// Cache file name: `<basename>.<sha16>.md` (sha16 = hash_hex[0..16]). Caller frees.
pub fn cacheFileName(allocator, basename: []const u8, hash_hex: []const u8) ![]u8;

/// Full cache path = join(cacheRoot(...), cacheFileName(...)). Caller frees.
pub fn cachePath(allocator, cache_dir: ?[]const u8, resolved_path: []const u8, hash_hex: []const u8) ![]u8;

/// Read a cache file. Returns owned content, or null on any error / empty file
/// (miss-or-unreadable both mean "no cache"). Caller frees the returned slice.
pub fn read(allocator, cache_path: []const u8) ?[]u8;

/// Best-effort write: mkdir -p the parent, then atomically write `content`. Errors are
/// swallowed (caching must never fail the read). Returns void.
pub fn store(allocator, cache_path: []const u8, content: []const u8) void;
```

`store` reuses the atomic-write idiom already in the codebase (write to a temp file in the
same dir, then rename) so a crashed write never leaves a truncated `.md`.

## Changes to `src/web_read.zig`

- `Options` gains `cache_dir: ?[]const u8 = null` (the working directory; null = use the
  file's own directory for the cache root). `null`/absent preserves today's behavior except
  the cache root falls back to the file's directory.
- `ReadResult` gains `cached: bool = false`.
- **Relative file paths** are resolved against `cache_dir` before reading: a non-URL target
  that is not absolute is joined onto `cache_dir` (mirrors `ai_chat_tools.resolveLocalPath`).
  This also fixes a latent gap where `webread` resolved relative paths against the process
  cwd, not the agent working dir.
- `executeRead` file branch becomes:
  1. resolve the target path against `cache_dir` (absolute wins).
  2. `readLocalFileForUpload(resolved)` → bytes + basename (unchanged size guard).
  3. `sha256Hex(bytes)`.
  4. `cachePath(...)`; `web_read_cache.read(path)` → if non-null, return
     `ReadResult{ .title = "", .url = <resolved>, .content = <cached>, .cached = true }`
     **without any network call**.
  5. miss → existing multipart upload + parse. On success, `web_read_cache.store(path, content)`
     (best-effort), then return the result (`cached = false`).
- URL mode is unchanged and never consults the cache.

## Changes to the entry points

- **Agent tool** (`ai_chat_tools.webReadTool`): take `working_dir: ?[]const u8` (from
  `ctx.settings.working_dir`) and pass it as `Options.cache_dir`. The dispatch branch passes
  `ctx.settings.working_dir`.
- **User command**: `WebReadRequest` gains an owned `working_dir` string. `startWebReadRequest`
  reads `self.effectiveWorkingDirLocked()` while it still holds the lock and passes that value
  to `WebReadRequest.create`, which dupes it (mirroring how `target` is duped; an empty/null
  dir becomes ""). `webReadThreadMain` passes it as `Options.cache_dir` (treating "" as null).
- **Display:** `formatForUser` prepends a small `(cached)` marker to its header when
  `result.cached` is true, so the user can see when the upload was skipped. `formatForAgent`
  is unchanged (the model just gets the content; a marker would only add noise).

## Error handling

Caching is strictly best-effort and must never change the *outcome* of a read:

- Cache read error / missing / empty file → treated as a miss → normal upload.
- `mkdir` or write error when storing → swallowed → the read still returns the fresh result.
- A hash or path-build allocation failure propagates as a normal error (same as today's OOM).

No key, file bytes, or path is logged beyond existing diagnostics.

## Testing

Pure tests in `web_read_cache.zig` (registered in the fast suite via `test_fast.zig`):

- `sha256Hex` against a known vector (e.g. `""` → `e3b0c442…`).
- `cacheRoot`: with a non-empty `cache_dir` → `<cache_dir>/.webread_cache`; with null →
  `<dirname(path)>/.webread_cache`.
- `cacheFileName` → `<basename>.<first16>.md`.
- `read`/`store` round-trip via `std.testing.tmpDir`: store then read returns the content;
  read of a non-existent path returns null; read of an empty file returns null.

Integration test in `web_read.zig` (no network — exercises the HIT path end to end):

- Create a temp file with known bytes; compute its SHA-256; pre-seed the cache file at the
  computed `cachePath` (cache_dir = the tmp dir); call `executeRead(target, .{ .cache_dir })`
  → returns `cached == true` and the seeded content, with **no HTTP call**.
URL mode never touches the cache by construction: the cache code lives entirely inside the
file branch of `executeRead`, structurally unreachable for an `http(s)://` target (verified by
reading the code, not a unit test — the URL path can't be exercised offline anyway). The
miss→store path's network half stays untested (no live network in tests); `store` itself is
covered by the round-trip test, and the read-and-return-on-hit half by the integration test.

Implement with TDD. Run `zig build test`; run `zig build test-full` before finishing.

## Scope guards (YAGNI)

- Local file mode only; URLs never cached.
- No cache size limit, no eviction, no pruning of stale (old-hash) entries — content
  addressing means stale entries are simply never read; a human can delete `.webread_cache/`.
- No config on/off toggle (caching is always on for file reads; it is best-effort and cheap).
- No change to the 25 MB upload cap or any Reader request options.
```
