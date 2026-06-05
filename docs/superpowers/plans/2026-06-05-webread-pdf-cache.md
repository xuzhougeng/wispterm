# `webread` local-file → markdown cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cache the markdown that Jina Reader produces for a local file (PDF/Office), keyed by file content (SHA-256), so a repeat `webread` of an unchanged file returns instantly with no network call.

**Architecture:** New pure module `src/web_read_cache.zig` (path/key/IO). `web_read.executeRead` gains a `cache_dir` option; in **file mode** it hashes the bytes, returns a cache hit with no network, or uploads-then-stores on a miss. Both entry points (`$webread` user command, `webread` agent tool) pass their working directory. URLs are never cached. Caching is best-effort — it never makes a read fail.

**Tech Stack:** Zig, `std.crypto.hash.sha2.Sha256`, `std.fs` (atomicFile), building on the just-merged `src/web_read.zig`.

**Spec:** `docs/superpowers/specs/2026-06-05-webread-pdf-cache-design.md`

**Branch:** `feat/webread-pdf-cache` (already created; spec committed there).

---

## File Structure

- **Create** `src/web_read_cache.zig` — pure cache helpers: `sha256Hex`, `cacheRoot`, `cacheFileName`, `cachePath`, `read`, `store`.
- **Modify** `src/test_fast.zig` — register the new module.
- **Modify** `src/web_read.zig` — `Options.cache_dir`, `ReadResult.cached`, `resolveFilePath`, refactor (`parseResponseInto`, `uploadFile`), cache hit/miss in `executeRead`, `(cached)` marker in `formatForUser`.
- **Modify** `src/ai_chat_tools.zig` — `webReadTool` takes `working_dir`; dispatch passes `ctx.settings.working_dir`.
- **Modify** `src/ai_chat.zig` — `WebReadRequest.working_dir`; `startWebReadRequest` captures `effectiveWorkingDirLocked()`.
- **Modify** `src/ai_chat_request.zig` — `webReadThreadMain` passes `cache_dir`.

Constants: cache dir name `.webread_cache`, filename `<basename>.<sha16>.md`, cache-file read cap `64 * 1024 * 1024`.

---

## Task 1: `web_read_cache.zig` — pure cache helpers

**Files:**
- Create: `src/web_read_cache.zig`
- Modify: `src/test_fast.zig:57` (add import)

- [ ] **Step 1: Write the module + failing tests** — create `src/web_read_cache.zig`:

```zig
//! Pure on-disk cache for `web_read` local-file conversions. Given a working dir,
//! a resolved file path, and the file bytes' hash, it computes where the cached
//! markdown lives and reads/writes it. No network, no Jina knowledge. Best-effort:
//! `read` returns null on any problem; `store` swallows all errors.
const std = @import("std");

const cache_dir_name = ".webread_cache";
const max_cache_file_bytes: usize = 64 * 1024 * 1024;

/// Lowercase hex SHA-256 of `bytes`, written into `out` (must be 64 bytes). Returns out.
pub fn sha256Hex(bytes: []const u8, out: *[64]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out[0..64];
}

/// Cache root: `<cache_dir>/.webread_cache` when cache_dir is non-empty, else
/// `<dirname(resolved_path)>/.webread_cache`. Caller frees.
pub fn cacheRoot(allocator: std.mem.Allocator, cache_dir: ?[]const u8, resolved_path: []const u8) ![]u8 {
    if (cache_dir) |cd| if (cd.len > 0) return std.fs.path.join(allocator, &.{ cd, cache_dir_name });
    const dir = std.fs.path.dirname(resolved_path) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, cache_dir_name });
}

/// Cache file name: `<basename>.<sha16>.md` (sha16 = first 16 hex chars). Caller frees.
pub fn cacheFileName(allocator: std.mem.Allocator, basename: []const u8, hash_hex: []const u8) ![]u8 {
    const sha16 = hash_hex[0..@min(hash_hex.len, 16)];
    return std.fmt.allocPrint(allocator, "{s}.{s}.md", .{ basename, sha16 });
}

/// Full cache path = join(cacheRoot, cacheFileName(basename(resolved_path), hash)). Caller frees.
pub fn cachePath(allocator: std.mem.Allocator, cache_dir: ?[]const u8, resolved_path: []const u8, hash_hex: []const u8) ![]u8 {
    const root = try cacheRoot(allocator, cache_dir, resolved_path);
    defer allocator.free(root);
    const name = try cacheFileName(allocator, std.fs.path.basename(resolved_path), hash_hex);
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ root, name });
}

/// Read a cache file. Returns owned content, or null on any error / empty file
/// (miss-or-unreadable both mean "no cache"). Caller frees the returned slice.
pub fn read(allocator: std.mem.Allocator, cache_path: []const u8) ?[]u8 {
    const file = std.fs.cwd().openFile(cache_path, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(allocator, max_cache_file_bytes) catch return null;
    if (content.len == 0) {
        allocator.free(content);
        return null;
    }
    return content;
}

/// Best-effort: mkdir -p the parent dir, then atomically write `content`. All errors
/// are swallowed — caching must never fail the read.
pub fn store(_: std.mem.Allocator, cache_path: []const u8, content: []const u8) void {
    if (std.fs.path.dirname(cache_path)) |dir| std.fs.cwd().makePath(dir) catch return;
    var write_buffer: [0]u8 = .{};
    var atomic = std.fs.cwd().atomicFile(cache_path, .{ .write_buffer = &write_buffer }) catch return;
    defer atomic.deinit();
    atomic.file_writer.file.writeAll(content) catch return;
    atomic.finish() catch return;
}

test "sha256Hex matches the known empty-input vector" {
    var out: [64]u8 = undefined;
    const hex = sha256Hex("", &out);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hex);
}

test "cacheRoot uses cache_dir when set, else the file's directory" {
    const a = std.testing.allocator;
    const with = try cacheRoot(a, "/work/proj", "/dl/x.pdf");
    defer a.free(with);
    try std.testing.expectEqualStrings("/work/proj/.webread_cache", with);
    const without = try cacheRoot(a, null, "/dl/x.pdf");
    defer a.free(without);
    try std.testing.expectEqualStrings("/dl/.webread_cache", without);
    const empty = try cacheRoot(a, "", "/dl/x.pdf");
    defer a.free(empty);
    try std.testing.expectEqualStrings("/dl/.webread_cache", empty);
}

test "cacheFileName is basename.sha16.md" {
    const a = std.testing.allocator;
    const name = try cacheFileName(a, "Gosai_Nature_24.pdf", "0123456789abcdef0123456789abcdef");
    defer a.free(name);
    try std.testing.expectEqualStrings("Gosai_Nature_24.pdf.0123456789abcdef.md", name);
}

test "store then read round-trips; missing and empty read as null" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const cpath = try std.fs.path.join(a, &.{ root, ".webread_cache", "x.pdf.deadbeefdeadbeef.md" });
    defer a.free(cpath);

    store(a, cpath, "CACHED MARKDOWN");
    const got = read(a, cpath).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("CACHED MARKDOWN", got);

    const missing = try std.fs.path.join(a, &.{ root, "nope.md" });
    defer a.free(missing);
    try std.testing.expect(read(a, missing) == null);

    try tmp.dir.writeFile(.{ .sub_path = "empty.md", .data = "" });
    const empty_path = try tmp.dir.realpathAlloc(a, "empty.md");
    defer a.free(empty_path);
    try std.testing.expect(read(a, empty_path) == null);
}
```

- [ ] **Step 2: Register in the fast suite** — in `src/test_fast.zig`, add directly under line 57 (`_ = @import("web_read.zig");`):

```zig
    _ = @import("web_read_cache.zig");
```

- [ ] **Step 3: Run the tests**

Run: `zig build test 2>&1 | tail -15`
Expected: PASS (the 4 new tests pass; build clean).

- [ ] **Step 4: Commit**

```bash
git add src/web_read_cache.zig src/test_fast.zig
git commit -m "feat(web_read_cache): pure on-disk cache helpers (sha256, path, read/store)"
```

---

## Task 2: `web_read.zig` — fields + refactor (no behavior change)

**Files:**
- Modify: `src/web_read.zig` — `Options` (line 15-18), `ReadResult` (line 20-28), add `resolveFilePath`, extract `parseResponseInto`, rename `fetchFile`→`uploadFile(lf)`, rewrite `executeRead` (line 290-321).

This refactor sets up the cache without adding it yet. Existing tests must stay green (no new test). The only behavior change: a **relative** file target is now resolved against `cache_dir`, which is `null` in all existing tests, so behavior is unchanged there.

- [ ] **Step 1: Add the two struct fields**

`Options` (currently lines 15-18) → add `cache_dir`:

```zig
pub const Options = struct {
    api_key: []const u8 = "", // "" = anonymous (no Authorization header)
    max_file_bytes: usize = 25 * 1024 * 1024, // reject larger local files (OOM guard)
    cache_dir: ?[]const u8 = null, // working dir; null = cache next to the file. Used for the
    // .webread_cache root AND to resolve a relative file target.
};
```

`ReadResult` (currently lines 20-28) → add `cached`:

```zig
pub const ReadResult = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    url: []const u8,
    content: []const u8,
    cached: bool = false,
    pub fn deinit(self: *ReadResult) void {
        self.arena.deinit();
    }
};
```

- [ ] **Step 2: Add `resolveFilePath`** — place it just above `readLocalFileForUpload` (before line 116):

```zig
/// Resolve a relative file `target` against `cache_dir` (the working dir); an absolute
/// target is returned as-is. Caller frees. Mirrors ai_chat_tools.resolveLocalPath so
/// `webread` resolves the same way the file-edit tools do.
fn resolveFilePath(allocator: std.mem.Allocator, target: []const u8, cache_dir: ?[]const u8) ![]u8 {
    if (std.fs.path.isAbsolute(target)) return allocator.dupe(u8, target);
    if (cache_dir) |cd| if (cd.len > 0) return std.fs.path.join(allocator, &.{ cd, target });
    return allocator.dupe(u8, target);
}
```

- [ ] **Step 3: Rename `fetchFile` → `uploadFile(lf)`** — replace the whole `fetchFile` function (lines 259-286) with a version that takes an already-read `LocalFile` (the read moves into `executeRead`):

```zig
fn uploadFile(gpa: std.mem.Allocator, lf: LocalFile, opts: Options) !platform_http.Response {
    const mp = try buildMultipartBody(gpa, lf.basename, lf.bytes);
    defer gpa.free(mp.body);
    defer gpa.free(mp.content_type);
    const bearer: ?[]u8 = if (opts.api_key.len > 0) try std.fmt.allocPrint(gpa, "Bearer {s}", .{opts.api_key}) else null;
    defer if (bearer) |b| gpa.free(b);

    var headers: [4]platform_http.Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "Content-Type", .value = mp.content_type };
    n += 1;
    headers[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    appendAuthHeader(&headers, &n, bearer);

    return platform_http.fetch(gpa, .{
        .method = .POST,
        .url = reader_url,
        .headers = headers[0..n],
        .body = mp.body,
        .timeout_ms = 60_000,
    }) catch |err| {
        setNetworkErrorDetail(err);
        return error.Network;
    };
}
```

- [ ] **Step 4: Extract `parseResponseInto`** — add this helper just above `executeRead` (before line 288's doc comment). It is the status-check + parse block lifted verbatim from `executeRead`:

```zig
/// Check the HTTP status and parse the Jina JSON body into `result` (title/url/content
/// duped into result.arena). Sets the threadlocal error detail on failure.
fn parseResponseInto(result: *ReadResult, response: platform_http.Response) !void {
    if (response.status != 200) {
        const trimmed = std.mem.trim(u8, response.body, " \t\r\n");
        const excerpt = trimmed[0..@min(trimmed.len, 300)];
        if (excerpt.len > 0)
            setErrorDetail(.http_status, "Web read failed: Jina returned HTTP {d}: {s}", .{ response.status, excerpt })
        else
            setErrorDetail(.http_status, "Web read failed: Jina returned HTTP {d}.", .{response.status});
        std.log.warn("jina reader HTTP {d}: {s}", .{ response.status, trimmed });
        return error.HttpStatus;
    }
    const fields = parseReaderResponse(result.arena.allocator(), response.body) catch |err| {
        if (err == error.ParseFailed)
            setErrorDetail(.parse_failed, "Web read failed: could not parse the Jina response ({s}).", .{@errorName(err)});
        return err;
    };
    result.title = fields.title;
    result.url = fields.url;
    result.content = fields.content;
}
```

- [ ] **Step 5: Rewrite `executeRead`** — replace the whole function (lines 290-321) with the refactored version (URL branch unchanged in effect; file branch now reads the file itself and calls `uploadFile`). No cache yet:

```zig
/// Read `target` (http(s) URL or local file path) into clean markdown. The returned
/// `ReadResult` owns its strings via its arena (free with `result.deinit()`).
pub fn executeRead(gpa: std.mem.Allocator, target: []const u8, opts: Options) !ReadResult {
    clearErrorDetail();
    var result = ReadResult{ .arena = std.heap.ArenaAllocator.init(gpa), .title = "", .url = "", .content = "" };
    errdefer result.arena.deinit();

    if (isHttpUrl(target)) {
        var response = try fetchUrl(gpa, target, opts);
        defer response.deinit(gpa);
        try parseResponseInto(&result, response);
        return result;
    }

    const resolved = try resolveFilePath(gpa, target, opts.cache_dir);
    defer gpa.free(resolved);
    const lf = try readLocalFileForUpload(gpa, resolved, opts.max_file_bytes);
    defer gpa.free(lf.bytes);

    var response = try uploadFile(gpa, lf, opts);
    defer response.deinit(gpa);
    try parseResponseInto(&result, response);
    return result;
}
```

- [ ] **Step 6: Run the tests** (existing web_read tests must still pass)

Run: `zig build test 2>&1 | tail -15`
Expected: PASS, 0 failed. The `executeRead reports a missing local file` test still returns `FileNotFound` (resolveFilePath passes the absolute path through, `readLocalFileForUpload` fails before any upload).

- [ ] **Step 7: Commit**

```bash
git add src/web_read.zig
git commit -m "refactor(web_read): cache_dir/cached fields + split file read from upload"
```

---

## Task 3: `web_read.zig` — cache hit/miss + `(cached)` marker

**Files:**
- Modify: `src/web_read.zig` — import `web_read_cache`, add cache logic to `executeRead`'s file branch, `(cached)` marker in `formatForUser` (line 144-160), new tests.

- [ ] **Step 1: Write the failing integration test** — append to the end of `src/web_read.zig` (needs the import from Step 3; the test references `web_read_cache`):

```zig
test "executeRead returns cached content with no network on a cache hit" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    try tmp.dir.writeFile(.{ .sub_path = "doc.pdf", .data = "PDFDATA" });
    const pdf = try std.fs.path.join(a, &.{ dir, "doc.pdf" });
    defer a.free(pdf);

    // Pre-seed the cache at the exact path executeRead will compute.
    var hb: [64]u8 = undefined;
    const hash = web_read_cache.sha256Hex("PDFDATA", &hb);
    const cpath = try web_read_cache.cachePath(a, dir, pdf, hash);
    defer a.free(cpath);
    web_read_cache.store(a, cpath, "CACHED MARKDOWN");

    var result = try executeRead(a, pdf, .{ .cache_dir = dir });
    defer result.deinit();
    try std.testing.expect(result.cached);
    try std.testing.expectEqualStrings("CACHED MARKDOWN", result.content);
    try std.testing.expectEqualStrings(pdf, result.url);
}

test "formatForUser marks cached results" {
    const a = std.testing.allocator;
    var r = ReadResult{ .arena = std.heap.ArenaAllocator.init(a), .title = "", .url = "x", .content = "body", .cached = true };
    defer r.deinit();
    const text = try formatForUser(a, "x", &r);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "(cached)") != null);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `web_read_cache` not imported / `executeRead` does not set `cached` / no `(cached)` in output.

- [ ] **Step 3: Add the import** — near the top of `src/web_read.zig`, under `const platform_http = @import("platform/http_client.zig");`:

```zig
const web_read_cache = @import("web_read_cache.zig");
```

- [ ] **Step 4: Add cache logic to `executeRead`'s file branch** — replace the file-branch tail (from `const resolved = ...` through `return result;`) with:

```zig
    const resolved = try resolveFilePath(gpa, target, opts.cache_dir);
    defer gpa.free(resolved);
    const lf = try readLocalFileForUpload(gpa, resolved, opts.max_file_bytes);
    defer gpa.free(lf.bytes);

    var hash_buf: [64]u8 = undefined;
    const hash = web_read_cache.sha256Hex(lf.bytes, &hash_buf);
    const cpath: ?[]u8 = web_read_cache.cachePath(gpa, opts.cache_dir, resolved, hash) catch null;
    defer if (cpath) |p| gpa.free(p);

    if (cpath) |p| {
        if (web_read_cache.read(gpa, p)) |cached| {
            defer gpa.free(cached);
            const arena = result.arena.allocator();
            result.url = try arena.dupe(u8, resolved);
            result.content = try arena.dupe(u8, cached);
            result.cached = true;
            return result;
        }
    }

    var response = try uploadFile(gpa, lf, opts);
    defer response.deinit(gpa);
    try parseResponseInto(&result, response);
    if (cpath) |p| web_read_cache.store(gpa, p, result.content);
    return result;
```

- [ ] **Step 5: Add the `(cached)` marker to `formatForUser`** — change its header line (currently `try w.print("Read \"{s}\":\n", .{target});`) to:

```zig
    try w.print("Read \"{s}\"{s}:\n", .{ target, if (result.cached) " (cached)" else "" });
```

- [ ] **Step 6: Run the tests**

Run: `zig build test 2>&1 | tail -15`
Expected: PASS, 0 failed (the two new tests pass; the cache-hit test runs fully offline).

- [ ] **Step 7: Commit**

```bash
git add src/web_read.zig
git commit -m "feat(web_read): content-hash cache for local-file reads + (cached) marker"
```

---

## Task 4: Wire the working directory through both entry points

**Files:**
- Modify: `src/ai_chat_tools.zig` — `webReadTool` signature + dispatch (lines 200-205, 305-316).
- Modify: `src/ai_chat.zig` — `WebReadRequest` (lines 215-231), `startWebReadRequest` (the `create` call ~line 2359).
- Modify: `src/ai_chat_request.zig` — `webReadThreadMain` (lines 172-199).

Verified by `zig build test-full` (these touch the app graph; no isolated unit test, like the original webread wiring).

- [ ] **Step 1: Agent tool** — in `src/ai_chat_tools.zig`, change the dispatch call (line 204) to pass the working dir:

```zig
        return webReadTool(ctx.allocator, url, ctx.settings.working_dir);
```

And change `webReadTool` (lines 305-316) to accept and forward it:

```zig
/// Agent `webread` tool: read a URL or local file into markdown for the model.
/// Key is optional (anonymous read works), so a null key becomes "". `working_dir`
/// (the conversation's cwd) is the cache root and resolves relative file targets.
fn webReadTool(allocator: std.mem.Allocator, target_in: []const u8, working_dir: ?[]const u8) ![]u8 {
    const target = std.mem.trim(u8, target_in, " \t\r\n");
    const key_opt = web_search.jinaApiKeyAlloc(allocator) catch null;
    defer if (key_opt) |k| allocator.free(k);
    const key = key_opt orelse "";
    var result = web_read.executeRead(allocator, target, .{ .api_key = key, .cache_dir = working_dir }) catch |err|
        return web_read.formatErrorText(allocator, err);
    defer result.deinit();
    return web_read.formatForAgent(allocator, target, &result);
}
```

- [ ] **Step 2: `WebReadRequest` gains `working_dir`** — in `src/ai_chat.zig`, replace the struct (lines 215-231):

```zig
pub const WebReadRequest = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    target: []u8,
    working_dir: []u8, // "" = none; used as the cache root

    pub fn create(allocator: std.mem.Allocator, session: *Session, target: []const u8, working_dir: []const u8) !*WebReadRequest {
        const self = try allocator.create(WebReadRequest);
        errdefer allocator.destroy(self);
        const target_dup = try allocator.dupe(u8, target);
        errdefer allocator.free(target_dup);
        self.* = .{ .allocator = allocator, .session = session, .target = target_dup, .working_dir = try allocator.dupe(u8, working_dir) };
        return self;
    }

    pub fn deinit(self: *WebReadRequest) void {
        self.allocator.free(self.target);
        self.allocator.free(self.working_dir);
        self.allocator.destroy(self);
    }
};
```

- [ ] **Step 3: Capture the working dir in `startWebReadRequest`** — in `src/ai_chat.zig`, the `create` call is currently:

```zig
        const req = WebReadRequest.create(self.allocator, self, target) catch {
```

Change it to read the effective working dir under the lock (it is held here) and pass it:

```zig
        const wd = self.effectiveWorkingDirLocked() orelse "";
        const req = WebReadRequest.create(self.allocator, self, target, wd) catch {
```

- [ ] **Step 4: Pass `cache_dir` in `webReadThreadMain`** — in `src/ai_chat_request.zig`, change the `executeRead` call (line 182) to derive the cache dir from the request:

```zig
    const cache_dir: ?[]const u8 = if (req.working_dir.len > 0) req.working_dir else null;
    var result = web_read.executeRead(allocator, req.target, .{ .api_key = key, .cache_dir = cache_dir }) catch |err| {
```

- [ ] **Step 5: Run the full suite**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS, 0 failed (the app graph links; `WebReadRequest.create` now takes 4 args at its one call site).

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_tools.zig src/ai_chat.zig src/ai_chat_request.zig
git commit -m "feat(webread): pass conversation working dir as the cache root"
```

---

## Task 5: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Fast suite**

Run: `zig build test 2>&1 | tail -5; echo "exit: ${PIPESTATUS[0]}"`
Expected: exit 0, 0 failed.

- [ ] **Step 2: Full suite**

Run: `zig build test-full 2>&1 | tail -5; echo "exit: ${PIPESTATUS[0]}"`
Expected: exit 0, 0 failed.

- [ ] **Step 3: Release build compiles**

Run: `zig build 2>&1 | tail -5; echo "exit: ${PIPESTATUS[0]}"`
Expected: exit 0, no errors.

- [ ] **Step 4: Wiring grep** (no change — confirm connectivity)

Run: `rg -n "cache_dir|web_read_cache|\.cached|\.webread_cache|working_dir" src/web_read.zig src/web_read_cache.zig src/ai_chat_tools.zig src/ai_chat.zig src/ai_chat_request.zig | sort`
Expected: hits in all five source files (module defines helpers; web_read uses cache_dir + web_read_cache; the three chat files pass working_dir/cache_dir).

- [ ] **Step 5: GUI verification is manual** — note in the final report that GUI smoke is pending: ask the agent to `webread` a local PDF twice (second call should be near-instant), and confirm a `.webread_cache/<name>.md` appears under the working dir (or next to the PDF when no working dir is set). Matches the project's standing "GUI verify pending" convention.

---

## Notes for the implementer

- **TDD order:** pure cache module (Task 1, fast suite) → web_read refactor (Task 2, existing tests stay green) → cache integration + offline HIT test (Task 3) → app-graph wiring (Task 4, `test-full`). Do not reorder 2 before 1 (Task 3 imports the Task 1 module; Task 2 is independent of it).
- **Best-effort invariant:** never let a cache problem fail a read. `cachePath` failure → `catch null` → skip caching. `read` returns null on any error. `store` swallows everything. Keep it that way.
- **Why `uploadFile` takes a `LocalFile`:** the bytes must be read *before* the cache lookup (to hash them) and reused for the upload on a miss — so the read moves up into `executeRead` and `uploadFile` receives the already-read bytes. Do not re-read the file.
- **`cached` field default:** `ReadResult{ ... }` literals that omit `cached` get `false` — existing literals (tests, the URL branch) compile unchanged.
- **YAGNI:** no eviction/size-cap/pruning, no config toggle, no URL caching. Content addressing means stale entries are simply never read.
```
