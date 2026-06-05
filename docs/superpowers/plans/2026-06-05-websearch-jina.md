# `$websearch` (Jina) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add web search to the AI chat — a `$websearch <query>` user command (shows raw Jina snippets in the transcript) and a `websearch` agent tool (returns full page content to the model) — behind an engine-agnostic core whose only engine today is Jina.

**Architecture:** A new leaf module `src/web_search.zig` owns all search logic (engine enum, result types, pure request-build / response-parse / format helpers, the single HTTP call, and a process-global Jina API key). The `$websearch` command runs on a background thread that reuses the existing `request_thread`/`request_inflight` lifecycle (so `Session.deinit` joins it — no UAF). The agent tool calls the same core synchronously inside the existing tool worker.

**Tech Stack:** Zig, `std.http.Client.fetch`, `std.json` (dynamic `Value` parsing), existing WispTerm AI-chat modules.

> **Discovery that refines the spec:** `$` is *already* the skill-invocation prefix (`composerSuggestionPrefix` maps `'$' => .skill`, and `parseSkillInvocation` parses `$name rest`). So `$websearch` is a **reserved** command intercepted in `Session.submit` *before* skill handling, and surfaced in the existing `$` suggestion dropdown via a small reserved list. There is **no** new `firstCharKind`/prefix branch (the spec's wording there is superseded).

> **Refinement of spec error handling:** Zig errors can't carry a payload, so the "HTTP status + trimmed body" detail is logged via `std.log.warn`; the user/model see a friendly message from `errorText`. This satisfies the spec's "specific, user-readable message" goal.

---

## File Structure

- **Create** `src/web_search.zig` — engine-agnostic core: `Engine`, `SearchResult`, `Options`, `Results`, the Jina key globals, pure helpers (`buildJinaRequestBody`, `parseJinaResponse`, `formatForUser`, `formatForAgent`, `errorText`), and the impure `executeSearch`/`searchJina`. Only depends on `std`.
- **Modify** `src/test_fast.zig` — register `web_search.zig` so its pure tests run in the fast suite.
- **Modify** `src/config.zig` — `jina-api-key` field, parse branch, `--help` line, sample comment.
- **Modify** `src/AppWindow.zig` — push `cfg.@"jina-api-key"` into `web_search.setJinaApiKey` on config apply.
- **Modify** `src/ai_chat_composer.zig` — `WebCommand`/`parseWebCommand` + reserved `$websearch` suggestion in the `$` dropdown.
- **Modify** `src/ai_chat.zig` — `WebSearchRequest`, `startWebSearchRequest`, `appendWebSearchResult`, and the `$websearch` interception in `submit`.
- **Modify** `src/ai_chat_request.zig` — `webSearchThreadMain` worker.
- **Modify** `src/ai_chat_protocol.zig` — one `emit(...)` line registering the `websearch` tool schema.
- **Modify** `src/ai_chat_tools.zig` — `websearch` dispatch + `webSearchTool`.

---

## Task 1: `web_search.zig` core types + `buildJinaRequestBody`

**Files:**
- Create: `src/web_search.zig`
- Modify: `src/test_fast.zig` (add the import)

- [ ] **Step 1: Write the failing test**

Create `src/web_search.zig` with the types and the function stub plus this test at the bottom:

```zig
//! Engine-agnostic web search core. Pure request-build / response-parse / format
//! helpers plus one HTTP call (`executeSearch`). Only the `jina` engine exists
//! today; a new engine is a new branch in `executeSearch`. Leaf module: std only.
const std = @import("std");

pub const Engine = enum { jina };

pub const SearchResult = struct {
    title: []const u8,
    url: []const u8,
    description: []const u8,
    content: ?[]const u8 = null,
};

pub const Options = struct {
    engine: Engine = .jina,
    api_key: []const u8,
    with_content: bool,
    max_results: usize = 10,
};

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => |ch| if (ch < 0x20)
            try out.writer(allocator).print("\\u{x:0>4}", .{ch})
        else
            try out.append(allocator, ch),
    };
    try out.append(allocator, '"');
}

/// Build the Jina search request body: `{"q":<json-escaped query>}`.
pub fn buildJinaRequestBody(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"q\":");
    try appendJsonString(allocator, &out, query);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

test "buildJinaRequestBody json-escapes the query" {
    const a = std.testing.allocator;
    const body = try buildJinaRequestBody(a, "say \"hi\"\nbye");
    defer a.free(body);
    try std.testing.expectEqualStrings("{\"q\":\"say \\\"hi\\\"\\nbye\"}", body);
}
```

Then add this line to `src/test_fast.zig` next to the other `ai_chat_*` imports (after line `_ = @import("ai_chat_composer.zig");`):

```zig
    _ = @import("web_search.zig");
```

- [ ] **Step 2: Run test to verify it fails (then passes once the file compiles)**

Run: `zig build test 2>&1 | tail -20`
Expected: compiles and the `buildJinaRequestBody` test passes. (If you stubbed the body to return `""` first, it FAILS on the string compare; the implementation above already makes it pass.)

- [ ] **Step 3: Commit**

```bash
git add src/web_search.zig src/test_fast.zig
git commit -m "feat(websearch): web_search core types + request body builder"
```

---

## Task 2: `parseJinaResponse` + `Results`

**Files:**
- Modify: `src/web_search.zig`

- [ ] **Step 1: Write the failing test**

Add the `Results` type and `parseJinaResponse` + helper to `src/web_search.zig` (place `Results` after `Options`):

```zig
pub const Results = struct {
    arena: std.heap.ArenaAllocator,
    items: []SearchResult,
    pub fn deinit(self: *Results) void {
        self.arena.deinit();
    }
};

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Parse a Jina search JSON response (`{"data":[{title,url,description,content?},...]}`)
/// into result structs whose strings are duped into `arena`. Caps at `max_results`.
/// Duping into `arena` means the parsed value may safely alias `json_bytes`, which
/// the caller frees after this returns.
pub fn parseJinaResponse(arena: std.mem.Allocator, json_bytes: []const u8, max_results: usize) ![]SearchResult {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{}) catch return error.ParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ParseFailed;
    const data_val = parsed.value.object.get("data") orelse return error.ParseFailed;
    if (data_val != .array) return &.{};
    const arr = data_val.array.items;
    const n = @min(arr.len, max_results);
    const list = try arena.alloc(SearchResult, n);
    var count: usize = 0;
    for (arr[0..n]) |item| {
        if (item != .object) continue;
        const obj = item.object;
        list[count] = .{
            .title = try arena.dupe(u8, jsonStr(obj, "title") orelse ""),
            .url = try arena.dupe(u8, jsonStr(obj, "url") orelse ""),
            .description = try arena.dupe(u8, jsonStr(obj, "description") orelse ""),
            .content = if (jsonStr(obj, "content")) |c| try arena.dupe(u8, c) else null,
        };
        count += 1;
    }
    return list[0..count];
}

test "parseJinaResponse extracts fields, honors max, tolerates missing content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"code":200,"data":[
        \\{"title":"First","url":"https://a.example","description":"desc a","content":"body a"},
        \\{"title":"Second","url":"https://b.example","description":"desc b"}
        \\]}
    ;
    const items = try parseJinaResponse(arena.allocator(), json, 10);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("First", items[0].title);
    try std.testing.expectEqualStrings("https://b.example", items[1].url);
    try std.testing.expectEqualStrings("body a", items[0].content.?);
    try std.testing.expect(items[1].content == null);
}

test "parseJinaResponse caps at max_results and handles empty data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = "{\"data\":[{\"title\":\"a\",\"url\":\"u\",\"description\":\"d\"},{\"title\":\"b\",\"url\":\"u\",\"description\":\"d\"}]}";
    const capped = try parseJinaResponse(arena.allocator(), json, 1);
    try std.testing.expectEqual(@as(usize, 1), capped.len);
    const empty = try parseJinaResponse(arena.allocator(), "{\"data\":[]}", 10);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (3 web_search tests now).

- [ ] **Step 3: Commit**

```bash
git add src/web_search.zig
git commit -m "feat(websearch): parse Jina JSON response into result structs"
```

---

## Task 3: `formatForUser` + `formatForAgent`

**Files:**
- Modify: `src/web_search.zig`

- [ ] **Step 1: Write the failing test**

Add both formatters to `src/web_search.zig`:

```zig
/// Render results for the transcript (user `$websearch`): snippets only.
pub fn formatForUser(allocator: std.mem.Allocator, query: []const u8, results: []const SearchResult) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    if (results.len == 0) {
        try w.print("No web results for: {s}", .{query});
        return out.toOwnedSlice(allocator);
    }
    try w.print("Web results for \"{s}\":\n", .{query});
    for (results, 0..) |r, i| {
        try w.print("\n{d}. {s}\n{s}\n", .{ i + 1, r.title, r.url });
        if (r.description.len > 0) try w.print("{s}\n", .{r.description});
    }
    return out.toOwnedSlice(allocator);
}

/// Render results for the model (agent `websearch` tool): includes page content.
pub fn formatForAgent(allocator: std.mem.Allocator, query: []const u8, results: []const SearchResult) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    if (results.len == 0) {
        try w.print("No results found for query: {s}", .{query});
        return out.toOwnedSlice(allocator);
    }
    try w.print("Search results for \"{s}\" ({d} results):\n", .{ query, results.len });
    for (results, 0..) |r, i| {
        try w.print("\n[{d}] {s}\nURL: {s}\n", .{ i + 1, r.title, r.url });
        if (r.description.len > 0) try w.print("{s}\n", .{r.description});
        if (r.content) |c| try w.print("\n{s}\n", .{c});
    }
    return out.toOwnedSlice(allocator);
}

test "formatForUser lists snippets and omits content" {
    const a = std.testing.allocator;
    const results = [_]SearchResult{
        .{ .title = "T", .url = "https://x", .description = "d", .content = "SECRET-CONTENT" },
    };
    const text = try formatForUser(a, "q", &results);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "1. T") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "https://x") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "SECRET-CONTENT") == null);
}

test "formatForAgent includes content; empty results message" {
    const a = std.testing.allocator;
    const results = [_]SearchResult{
        .{ .title = "T", .url = "https://x", .description = "d", .content = "BODY-TEXT" },
    };
    const text = try formatForAgent(a, "q", &results);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "BODY-TEXT") != null);
    const none = try formatForAgent(a, "q", &.{});
    defer a.free(none);
    try std.testing.expect(std.mem.indexOf(u8, none, "No results") != null);
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/web_search.zig
git commit -m "feat(websearch): user (snippets) and agent (content) result formatters"
```

---

## Task 4: Jina key globals + `errorText` + `executeSearch`/`searchJina`

**Files:**
- Modify: `src/web_search.zig`

- [ ] **Step 1: Write the code + tests**

Add to `src/web_search.zig`:

```zig
// --- Process-global Jina API key (set from config, read by both entry points) ---
var g_jina_mutex: std.Thread.Mutex = .{};
var g_jina_key_buf: [512]u8 = undefined;
var g_jina_key_len: usize = 0;

/// Set the Jina API key from config. Empty clears it. Oversized keys truncate.
pub fn setJinaApiKey(key: []const u8) void {
    g_jina_mutex.lock();
    defer g_jina_mutex.unlock();
    const n = @min(key.len, g_jina_key_buf.len);
    @memcpy(g_jina_key_buf[0..n], key[0..n]);
    g_jina_key_len = n;
}

pub fn jinaApiKeySet() bool {
    g_jina_mutex.lock();
    defer g_jina_mutex.unlock();
    return g_jina_key_len > 0;
}

/// Return an owned copy of the Jina key, or null when unset. Caller frees.
/// Copying under the lock avoids racing a concurrent `setJinaApiKey`.
pub fn jinaApiKeyAlloc(allocator: std.mem.Allocator) !?[]u8 {
    g_jina_mutex.lock();
    defer g_jina_mutex.unlock();
    if (g_jina_key_len == 0) return null;
    return try allocator.dupe(u8, g_jina_key_buf[0..g_jina_key_len]);
}

/// Friendly, user/model-facing message for a search error.
pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingApiKey => "Jina API key not set — add `jina-api-key = <key>` to your WispTerm config.",
        error.Network => "Web search failed: could not reach the Jina search service.",
        error.HttpStatus => "Web search failed: the Jina search service returned an error.",
        error.ParseFailed => "Web search failed: could not parse the Jina response.",
        else => "Web search failed.",
    };
}

/// Run a web search. `gpa` is used for transient HTTP buffers; the returned
/// `Results` owns its strings via its own arena (free with `results.deinit()`).
pub fn executeSearch(gpa: std.mem.Allocator, query: []const u8, opts: Options) !Results {
    if (opts.api_key.len == 0) return error.MissingApiKey;
    var results = Results{ .arena = std.heap.ArenaAllocator.init(gpa), .items = &.{} };
    errdefer results.arena.deinit();
    results.items = switch (opts.engine) {
        .jina => try searchJina(results.arena.allocator(), gpa, query, opts),
    };
    return results;
}

fn searchJina(arena: std.mem.Allocator, gpa: std.mem.Allocator, query: []const u8, opts: Options) ![]SearchResult {
    const body = try buildJinaRequestBody(gpa, query);
    defer gpa.free(body);
    const bearer = try std.fmt.allocPrint(gpa, "Bearer {s}", .{opts.api_key});
    defer gpa.free(bearer);

    var client: std.http.Client = .{ .allocator = gpa };
    defer client.deinit();

    var resp_buf: std.Io.Writer.Allocating = .init(gpa);
    defer resp_buf.deinit();

    var extra: [2]std.http.Header = undefined;
    var extra_len: usize = 0;
    extra[extra_len] = .{ .name = "Accept", .value = "application/json" };
    extra_len += 1;
    if (!opts.with_content) {
        extra[extra_len] = .{ .name = "X-Respond-With", .value = "no-content" };
        extra_len += 1;
    }

    const result = client.fetch(.{
        .location = .{ .url = "https://s.jina.ai/" },
        .method = .POST,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = bearer },
        },
        .extra_headers = extra[0..extra_len],
        .response_writer = &resp_buf.writer,
    }) catch return error.Network;

    var resp_list = resp_buf.toArrayList();
    defer resp_list.deinit(gpa);

    if (result.status != .ok) {
        std.log.warn("jina search HTTP {d}: {s}", .{ @intFromEnum(result.status), std.mem.trim(u8, resp_list.items, " \t\r\n") });
        return error.HttpStatus;
    }
    return parseJinaResponse(arena, resp_list.items, opts.max_results);
}

test "executeSearch rejects an empty api key without touching the network" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingApiKey, executeSearch(arena.allocator(), "q", .{ .api_key = "", .with_content = false }));
}

test "errorText maps known errors to friendly text" {
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.MissingApiKey), "jina-api-key") != null);
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.Network), "reach") != null);
}

test "jina api key globals round-trip and clear" {
    setJinaApiKey("abc123");
    try std.testing.expect(jinaApiKeySet());
    const k = (try jinaApiKeyAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(k);
    try std.testing.expectEqualStrings("abc123", k);
    setJinaApiKey("");
    try std.testing.expect(!jinaApiKeySet());
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (no network is hit — only the empty-key, errorText, and globals tests run).

- [ ] **Step 3: Commit**

```bash
git add src/web_search.zig
git commit -m "feat(websearch): Jina key globals, errorText, and executeSearch HTTP"
```

---

## Task 5: Config `jina-api-key` + push into `web_search`

**Files:**
- Modify: `src/config.zig` (field ~line 306, parse ~line 820, help ~line 1280, sample ~line 1644)
- Modify: `src/AppWindow.zig` (config apply, after line 2605)

- [ ] **Step 1: Write the failing test**

Add this test near the other config tests at the end of `src/config.zig` (mirroring the existing `ai-agent-working-dir` test at line 2059):

```zig
test "config: jina-api-key parses from a config line" {
    const allocator = std.testing.allocator;
    var cfg = Config{};
    defer cfg.deinit(allocator);
    cfg.applyKeyValue(allocator, "jina-api-key", "jina_abc", ".");
    try std.testing.expectEqualStrings("jina_abc", cfg.@"jina-api-key");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -25`
Expected: FAIL — `cfg.@"jina-api-key"` does not exist (compile error: no field named 'jina-api-key').

- [ ] **Step 3: Add the field**

In `src/config.zig`, after the `@"ai-agent-working-dir"` field (line 306) add:

```zig
/// API key for the Jina web search engine (https://s.jina.ai). Empty = unset.
@"jina-api-key": []const u8 = "",
```

- [ ] **Step 4: Add the parse branch**

In `applyKeyValue`, after the `ai-agent-working-dir` branch (line 820-821) add:

```zig
    } else if (std.mem.eql(u8, key, "jina-api-key")) {
        self.@"jina-api-key" = self.dupeString(allocator, value) orelse return;
```

- [ ] **Step 5: Add help + sample lines**

After the `--ai-agent-working-dir` help line (line 1280) add:

```zig
        \\  --jina-api-key <key>         API key for the Jina web search ($websearch)
```

After the `# ai-agent-working-dir =` sample line (line 1644) add:

```zig
    \\
    \\# Web search (Jina) — used by $websearch and the websearch agent tool
    \\# jina-api-key =
```

- [ ] **Step 6: Push the key into web_search on config apply**

In `src/AppWindow.zig`, immediately after line 2605 (`ai_chat.setDefaultWorkingDir(cfg.@"ai-agent-working-dir");`) add:

```zig
    @import("web_search.zig").setJinaApiKey(cfg.@"jina-api-key");
```

- [ ] **Step 7: Run test to verify it passes**

Run: `zig build test-full 2>&1 | tail -25`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/config.zig src/AppWindow.zig
git commit -m "feat(websearch): add jina-api-key config and wire it to web_search"
```

---

## Task 6: Composer `parseWebCommand` + reserved `$websearch` suggestion

**Files:**
- Modify: `src/ai_chat_composer.zig`

- [ ] **Step 1: Write the failing test**

Add this test at the end of `src/ai_chat_composer.zig` (after the existing suggestion tests):

```zig
test "parseWebCommand matches only the $websearch token" {
    try std.testing.expectEqual(WebCommand.websearch, parseWebCommand("$websearch").?);
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("$websearchx"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("$web"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("/websearch"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("websearch"));
}

test "reserved $websearch appears in the $ suggestion dropdown" {
    // Typing "$web" with no skills should surface the reserved websearch entry.
    try std.testing.expectEqual(@as(usize, 1), skillSuggestionCountForPrefix("$web", &.{}));
    const s = skillSuggestionAtForPrefix("$web", &.{}, 0).?;
    try std.testing.expectEqual(ComposerSuggestionKind.skill, s.kind);
    try std.testing.expectEqualStrings("websearch", s.text);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `WebCommand` / `parseWebCommand` undefined.

- [ ] **Step 3: Add `WebCommand` + `parseWebCommand`**

In `src/ai_chat_composer.zig`, after the `SlashCommand` enum (line 22) add:

```zig
pub const WebCommand = enum { websearch };

/// Reserved `$`-prefixed commands shown in the same dropdown as skills.
pub const ReservedWebCommand = struct { name: []const u8, description: []const u8 };
pub const reserved_web_commands = [_]ReservedWebCommand{
    .{ .name = "websearch", .description = "search the web (Jina)" },
};

/// Match the first whitespace-delimited token against a reserved `$` command.
/// `token` is e.g. "$websearch" (the value of `first_tok` in Session.submit).
pub fn parseWebCommand(token: []const u8) ?WebCommand {
    if (std.mem.eql(u8, token, "$websearch")) return .websearch;
    return null;
}
```

- [ ] **Step 4: Surface reserved commands in the `$` dropdown**

In `skillSuggestionCountForPrefix` (line 257), add reserved-command counting at the top of the function body (after the `if (prefix.len == 0 or prefix[0] != '$') return 0;` guard and `const skill_prefix = prefix[1..];`):

```zig
    var count: usize = 0;
    for (reserved_web_commands) |rc| {
        if (std.mem.startsWith(u8, rc.name, skill_prefix)) count += 1;
    }
```

(Remove the existing `var count: usize = 0;` line so it is not declared twice; keep the existing skills loop that follows.)

In `skillSuggestionAtForPrefix` (line 267), enumerate reserved commands before skills. After the guard and `const skill_prefix = prefix[1..];`, replace `var match_index: usize = 0;` with:

```zig
    var match_index: usize = 0;
    for (reserved_web_commands) |rc| {
        if (!std.mem.startsWith(u8, rc.name, skill_prefix)) continue;
        if (match_index == suggestion_index) return .{
            .kind = .skill,
            .text = rc.name,
            .description = rc.description,
        };
        match_index += 1;
    }
```

(The existing skills loop continues incrementing `match_index` after this.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS, including the two new tests. The existing composer suggestion tests still pass (they pass `&.{}` skills and prefixes like `$br` that do not match `websearch`).

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_composer.zig
git commit -m "feat(websearch): parse \$websearch and surface it in the \$ dropdown"
```

---

## Task 7: `ai_chat` dispatch + background worker

**Files:**
- Modify: `src/ai_chat.zig` (struct + methods + `submit` interception)
- Modify: `src/ai_chat_request.zig` (`webSearchThreadMain`)

- [ ] **Step 1: Add the `web_search` import and `WebSearchRequest`**

In `src/ai_chat.zig`, near the other top-level imports (e.g. after `const ai_chat_request = @import("ai_chat_request.zig");` at line 141) add:

```zig
const web_search = @import("web_search.zig");
```

After the `ChatRequest` struct (after line 189) add:

```zig
/// Lightweight background job for a `$websearch` user command. Owns its query.
/// The spawning code stores the thread in `session.request_thread`, so
/// `Session.deinit` joins it before freeing the session (no use-after-free).
pub const WebSearchRequest = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    query: []u8,

    pub fn create(allocator: std.mem.Allocator, session: *Session, query: []const u8) !*WebSearchRequest {
        const self = try allocator.create(WebSearchRequest);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .session = session, .query = try allocator.dupe(u8, query) };
        return self;
    }

    pub fn deinit(self: *WebSearchRequest) void {
        self.allocator.free(self.query);
        self.allocator.destroy(self);
    }
};
```

- [ ] **Step 2: Add `appendWebSearchResult` (worker → transcript)**

In `src/ai_chat.zig`, after `appendAssistantResult` (after line 3404) add:

```zig
/// Append a `$websearch` result (or error text) as a local tool message and
/// finish the in-flight request. Called from the web-search worker thread with
/// no lock held. Mirrors the closing-guarded shape of `appendAssistantResult`.
pub fn appendWebSearchResult(session: *Session, text: []const u8) void {
    if (session.closing.load(.acquire)) return;
    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;
    session.appendLocalToolMessageLocked(text) catch {
        session.request_inflight = false;
        session.setStatusLocked("Out of memory");
        return;
    };
    session.request_inflight = false;
    session.setStatusLocked("Ready");
}
```

- [ ] **Step 3: Add `startWebSearchRequest`**

In `src/ai_chat.zig`, add this method to the `Session` struct, right after `startDistillRequest`'s closing brace (after line 2130):

```zig
    /// Run a `$websearch <query>` command on a background thread. Mirrors
    /// `startDistillRequest`: reuses `request_thread`/`request_inflight` so the
    /// existing submit-guard and `deinit` join cover lifetime. Called AFTER the
    /// caller has unlocked `self.mutex`.
    fn startWebSearchRequest(self: *Session, query_in: []const u8) void {
        self.mutex.lock();
        if (self.request_thread) |thread| {
            if (self.request_inflight) {
                self.clearSubmittedInputLocked();
                self.appendLocalToolMessageLocked("Wait for the current request to finish.") catch {};
                self.setStatusLocked("Ready");
                self.mutex.unlock();
                return;
            }
            self.request_thread = null;
            self.mutex.unlock();
            thread.join();
            self.mutex.lock();
        }

        const query = std.mem.trim(u8, query_in, " \t\r\n");
        if (query.len == 0) {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Usage: $websearch <query>") catch self.setStatusLocked("Out of memory");
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        }
        if (!web_search.jinaApiKeySet()) {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Jina API key not set — add `jina-api-key = <key>` to your WispTerm config.") catch self.setStatusLocked("Out of memory");
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        }

        const req = WebSearchRequest.create(self.allocator, self, query) catch {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Out of memory.") catch {};
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };
        self.clearSubmittedInputLocked();
        self.stop_requested.store(false, .release);
        self.request_stopping = false;
        self.request_inflight = true;
        self.setStatusLocked("Searching the web…");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, ai_chat_request.webSearchThreadMain, .{req}) catch {
            req.deinit();
            self.mutex.lock();
            self.request_inflight = false;
            self.appendLocalToolMessageLocked("Failed to start web search thread.") catch {};
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };
        self.mutex.lock();
        self.request_thread = thread;
        self.mutex.unlock();
    }
```

- [ ] **Step 4: Intercept `$websearch` in `submit`**

In `src/ai_chat.zig` `submit`, after the custom-command block and before the `if (self.api_key_len == 0)` gate — i.e. immediately after the `// otherwise (...): fall through.` comment (line 1628) — insert:

```zig
        if (ai_chat_composer.parseWebCommand(first_tok)) |_| {
            self.clearPendingWeixinReplyContextLocked();
            self.mutex.unlock();
            self.startWebSearchRequest(arg);
            return;
        }
```

- [ ] **Step 5: Add the worker in `ai_chat_request.zig`**

In `src/ai_chat_request.zig`, add the import near the other imports (after line 11 `const ai_chat_tools = @import("ai_chat_tools.zig");`):

```zig
const web_search = @import("web_search.zig");
```

Then add this function after `distillThreadMain` (after the function that ends around line 110):

```zig
/// Background worker for one `$websearch` command. Owns `req`; frees it on exit.
/// Re-fetches the Jina key on this thread, runs the search (snippets only), and
/// appends the formatted results to the transcript.
pub fn webSearchThreadMain(req: *ai_chat.WebSearchRequest) void {
    defer req.deinit();
    const allocator = req.allocator;
    const session = req.session;
    if (session.closing.load(.acquire)) return;

    const key = (web_search.jinaApiKeyAlloc(allocator) catch null) orelse {
        ai_chat.appendWebSearchResult(session, web_search.errorText(error.MissingApiKey));
        return;
    };
    defer allocator.free(key);

    var results = web_search.executeSearch(allocator, req.query, .{
        .engine = .jina,
        .api_key = key,
        .with_content = false,
        .max_results = 10,
    }) catch |err| {
        ai_chat.appendWebSearchResult(session, web_search.errorText(err));
        return;
    };
    defer results.deinit();

    const text = web_search.formatForUser(allocator, req.query, results.items) catch {
        ai_chat.appendWebSearchResult(session, "Out of memory formatting results.");
        return;
    };
    defer allocator.free(text);
    ai_chat.appendWebSearchResult(session, text);
}
```

- [ ] **Step 6: Build to verify it compiles**

Run: `zig build test-full 2>&1 | tail -25`
Expected: PASS — full graph compiles and all existing tests still pass. (No new unit test here; behavior is verified by the build plus the GUI smoke test in Task 9.)

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat.zig src/ai_chat_request.zig
git commit -m "feat(websearch): \$websearch command dispatch and background worker"
```

---

## Task 8: Agent `websearch` tool

**Files:**
- Modify: `src/ai_chat_protocol.zig` (`forEachToolSpec` + a schema test)
- Modify: `src/ai_chat_tools.zig` (import + dispatch + `webSearchTool`)

- [ ] **Step 1: Write the failing test**

Add this test to `src/ai_chat_protocol.zig` after the test at line 1478:

```zig
test "agent tool set includes websearch" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m", .system_prompt = "", .protocol = .anthropic, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .max_tokens = 8192 };
    const json = try buildRequestJson(a, params, &msgs, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"websearch\"") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -25`
Expected: FAIL — `"websearch"` not present in the tool JSON.

- [ ] **Step 3: Register the tool schema**

In `src/ai_chat_protocol.zig` `forEachToolSpec`, after the `wispterm_docs` emit line (line 670) add:

```zig
    try emit(ctx, "websearch", "Search the web for current information via Jina. Returns the top results with titles, URLs, and page content. Use when you need facts newer than your training or to look something up online.", "{\"query\":{\"type\":\"string\",\"description\":\"The search query.\"},\"max_results\":{\"type\":\"integer\",\"description\":\"Optional max number of results (default 10, max 20).\"}}");
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test-full 2>&1 | tail -25`
Expected: PASS.

- [ ] **Step 5: Add the tool implementation + dispatch**

In `src/ai_chat_tools.zig`, add the import after line 27 (`const ai_agent_access = @import("ai_agent_access.zig");`):

```zig
const web_search = @import("web_search.zig");
```

Add the `websearch` dispatch in `executeToolCall`, after the `wispterm_docs` branch (the dispatch lives around line 139-145 in this file; place it just before the final `return std.fmt.allocPrint(... "Unknown tool: {s}" ...)`):

```zig
    if (std.mem.eql(u8, call.name, "websearch")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const query = jsonStringArg(args.value, "query") orelse return ctx.allocator.dupe(u8, "Missing query");
        const max_results = jsonIntArg(args.value, "max_results");
        return webSearchTool(ctx.allocator, query, max_results);
    }
```

Add the implementation in the "Skill / docs tools" area (e.g. after `wisptermDocsTool`, near line 220):

```zig
/// Agent `websearch` tool: full-content Jina search, formatted for the model.
fn webSearchTool(allocator: std.mem.Allocator, query: []const u8, max_results: ?u32) ![]u8 {
    const key = (web_search.jinaApiKeyAlloc(allocator) catch null) orelse
        return allocator.dupe(u8, web_search.errorText(error.MissingApiKey));
    defer allocator.free(key);
    const max: usize = if (max_results) |m| @min(@max(m, 1), 20) else 10;
    var results = web_search.executeSearch(allocator, query, .{
        .engine = .jina,
        .api_key = key,
        .with_content = true,
        .max_results = max,
    }) catch |err| return allocator.dupe(u8, web_search.errorText(err));
    defer results.deinit();
    return web_search.formatForAgent(allocator, query, results.items);
}
```

- [ ] **Step 6: Run tests to verify everything passes**

Run: `zig build test-full 2>&1 | tail -25`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat_protocol.zig src/ai_chat_tools.zig
git commit -m "feat(websearch): register and implement the websearch agent tool"
```

---

## Task 9: Final verification

**Files:** none (verification + optional GUI smoke).

- [ ] **Step 1: Run the full fast + full suites**

Run: `zig build test 2>&1 | tail -5 && zig build test-full 2>&1 | tail -5`
Expected: both exit 0, 0 failed. (Baseline per project memory is ~0 failed; the new web_search/composer/protocol/config tests are additive.)

- [ ] **Step 2: Build the app**

Run: `zig build 2>&1 | tail -5`
Expected: builds clean.

- [ ] **Step 3: GUI smoke (manual, requires a Jina key)**

Set `jina-api-key = <key>` in the WispTerm config, open the AI chat, and verify:
- Typing `$` shows `websearch` in the dropdown; typing `$websearch zig language\n` appends a numbered snippet list to the transcript (no AI turn) and the status returns to "Ready".
- `$websearch` with no query shows the usage hint; with no key set, shows the "not set" message.
- With the agent enabled, ask the model something requiring fresh info and confirm it calls the `websearch` tool (results include page content) with no approval prompt.

Note any failures and fix before merging. This step is best-effort: there is no Linux GUI backend in this repo, so it may be deferred to macOS/Windows per project practice.

- [ ] **Step 4: (Optional) docs sync**

If documenting this feature for users, add a short note to the config reference in `docs/` AND `wiki/` (they must stay in sync — `docs/*.md` are `@embedFile`'d for the in-app `wispterm_docs` tool). Out of scope for the core feature; do only if requested.

---

## Self-Review Notes

- **Spec coverage:** core module (Tasks 1-4), Jina HTTP specifics (Task 4), `jina-api-key` config-only key + setter (Task 5), `$websearch` snippets command with no AI turn (Tasks 6-7), `websearch` agent tool with content and no approval gate (Task 8), tests + verification (Tasks 1-3, 5, 6, 8, 9). All spec sections map to a task.
- **Type consistency:** `Engine`/`SearchResult`/`Options`/`Results`, `executeSearch`/`searchJina`/`parseJinaResponse`/`formatForUser`/`formatForAgent`/`errorText`, `setJinaApiKey`/`jinaApiKeySet`/`jinaApiKeyAlloc`, `WebSearchRequest.create`/`deinit`, `appendWebSearchResult`, `startWebSearchRequest`, `webSearchThreadMain`, `WebCommand`/`parseWebCommand`/`reserved_web_commands` are referenced with identical names across all tasks.
- **Spec deviations (documented above):** `$` is the existing skill prefix → `$websearch` is reserved + intercepted (no new prefix branch); HTTP error body is logged not surfaced (errors can't carry payloads).
