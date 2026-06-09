# PubMed Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `pubmed` tool (agent tool + `$pubmed` user command) that searches NCBI PubMed for biomedical literature and returns articles with abstracts, where the model decomposes the user's question into keywords before calling.

**Architecture:** A self-contained pure module `src/pubmed.zig` (sibling of `web_search.zig`) holds URL builders, response parsers (esearch JSON + efetch XML), formatters, and one `executeSearch` that does two GET calls via `platform/http_client.zig`. Two thin entry points reuse it: an agent tool dispatched in `ai_chat_tools.zig` (schema in `ai_chat_protocol.zig`), and a `$pubmed` background command mirroring `$websearch`.

**Tech Stack:** Zig 0.15.2, `std.json`, hand-rolled targeted XML tag-scanning, `platform/http_client.zig`. Tests via `zig build test` (fast) and `zig build test-full`.

---

## Background for the implementer (read first)

- **Existing pattern to mirror:** `src/web_search.zig` is the template. It has the same shape: pure build/parse/format helpers + threadlocal error-detail buffer + `errorText`/`formatErrorText` + one network `executeSearch`. Read it before starting.
- **NCBI E-utilities** (no API key, anonymous):
  - esearch: `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&retmode=json&retmax=<N>&tool=wispterm&term=<url-encoded query>` → JSON `{"esearchresult":{"idlist":["123",...]}}`.
  - efetch: `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&retmode=xml&rettype=abstract&tool=wispterm&id=<pmid,pmid,...>` → XML with one `<PubmedArticle>` per result.
- **HTTP client:** `platform/http_client.zig` — `fetch(allocator, Request)` where `Request{ .method = .GET, .url, .headers = &.{}, .body = "", .timeout_ms }`. Response has `.status: u16`, `.body: []u8`, and `.deinit(allocator)`. The query string must already be in `.url`.
- **Error set for this module:** `error.MissingQuery`, `error.Network`, `error.HttpStatus`, `error.ParseFailed`. Empty results are NOT an error — formatters print "No PubMed results for: <query>".
- **Zig 0.15.2 notes:** `std.ArrayListUnmanaged(u8)` is `.empty`-initialized; append with `list.append(allocator, x)` / `list.appendSlice(allocator, s)`; writer via `list.writer(allocator)`; finalize with `list.toOwnedSlice(allocator)`. `std.json.parseFromSlice(std.json.Value, allocator, bytes, .{})` returns a `Parsed` you `.deinit()`. When duping parsed strings into an arena, aliasing the source buffer is fine.

---

## File Structure

- **Create `src/pubmed.zig`** — entire pure core + `executeSearch` + all unit tests. One responsibility: turn a query into formatted PubMed results.
- **Modify `src/test_fast.zig`** — register `pubmed.zig` so its tests run in the fast suite.
- **Modify `src/ai_chat_protocol.zig`** — add the `pubmed` tool spec to `forEachToolSpec` + a tool-set test.
- **Modify `src/ai_chat_tools.zig`** — import `pubmed`, dispatch the `pubmed` call to a new `pubMedTool`.
- **Modify `src/ai_chat_composer.zig`** — `WebCommand.pubmed`, `reserved_web_commands` entry, `parseWebCommand` + tests.
- **Modify `src/ai_chat.zig`** — `WebPubMedRequest` struct, `.pubmed` dispatch arm, `startPubMedRequest`.
- **Modify `src/ai_chat_request.zig`** — `pubMedThreadMain` worker.
- **Modify `src/platform/agent_prompt.zig`** — keyword-decomposition guidance line + test.

---

## Task 1: Create `src/pubmed.zig` with types + URL builders

**Files:**
- Create: `src/pubmed.zig`

- [ ] **Step 1: Write the file header, imports, types, and the first failing tests**

Create `src/pubmed.zig` with exactly this content:

```zig
//! NCBI PubMed literature search. Pure URL-build / response-parse / format
//! helpers plus one two-call network flow (`executeSearch`): esearch (JSON, get
//! PMIDs) then efetch (XML, get article metadata + abstracts). The model is
//! responsible for decomposing the user's question into keywords + boolean
//! operators; this module passes the constructed query straight to esearch.
//! HTTP transport goes through `platform/http_client.zig` so desktop builds can
//! use system proxies. Anonymous access only (no API key); `tool=wispterm` is
//! sent per NCBI etiquette.
const std = @import("std");
const platform_http = @import("platform/http_client.zig");

const esearch_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi";
const efetch_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi";

/// Authors beyond this count collapse to "et al." in the joined author string.
const max_authors_shown = 3;
/// Abstract byte cap for the user-facing `$pubmed` transcript output.
const user_abstract_limit = 400;

pub const Article = struct {
    pmid: []const u8,
    title: []const u8,
    authors: []const u8, // pre-joined, e.g. "Smith J, Doe A, et al."
    journal: []const u8,
    year: []const u8,
    doi: []const u8,
    abstract: []const u8,
};

pub const Options = struct {
    max_results: usize = 10,
    tool_name: []const u8 = "wispterm",
};

pub const Results = struct {
    arena: std.heap.ArenaAllocator,
    items: []Article,
    pub fn deinit(self: *Results) void {
        self.arena.deinit();
    }
};

fn isUnreserved(ch: u8) bool {
    return switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

/// Append `s` percent-encoded (RFC 3986 unreserved set kept literal) to `out`.
fn appendUrlEncoded(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |ch| {
        if (isUnreserved(ch)) {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0F]);
        }
    }
}

/// Build the esearch GET URL. Caller frees.
pub fn buildEsearchUrl(allocator: std.mem.Allocator, query: []const u8, opts: Options) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, esearch_url);
    try out.appendSlice(allocator, "?db=pubmed&retmode=json&retmax=");
    try out.writer(allocator).print("{d}", .{opts.max_results});
    try out.appendSlice(allocator, "&tool=");
    try appendUrlEncoded(allocator, &out, opts.tool_name);
    try out.appendSlice(allocator, "&term=");
    try appendUrlEncoded(allocator, &out, query);
    return out.toOwnedSlice(allocator);
}

/// Build the efetch GET URL for a list of PMIDs. Caller frees.
pub fn buildEfetchUrl(allocator: std.mem.Allocator, pmids: []const []const u8, opts: Options) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, efetch_url);
    try out.appendSlice(allocator, "?db=pubmed&retmode=xml&rettype=abstract&tool=");
    try appendUrlEncoded(allocator, &out, opts.tool_name);
    try out.appendSlice(allocator, "&id=");
    for (pmids, 0..) |id, i| {
        if (i != 0) try out.appendSlice(allocator, "%2C"); // comma
        try appendUrlEncoded(allocator, &out, id);
    }
    return out.toOwnedSlice(allocator);
}

test "buildEsearchUrl encodes query and includes db/retmax/tool" {
    const a = std.testing.allocator;
    const url = try buildEsearchUrl(a, "metformin AND diabetes", .{ .max_results = 5 });
    defer a.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "esearch.fcgi") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "db=pubmed") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "retmax=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "tool=wispterm") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "term=metformin%20AND%20diabetes") != null);
}

test "buildEfetchUrl joins pmids with encoded commas" {
    const a = std.testing.allocator;
    const ids = [_][]const u8{ "111", "222", "333" };
    const url = try buildEfetchUrl(a, &ids, .{});
    defer a.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "efetch.fcgi") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "id=111%2C222%2C333") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "rettype=abstract") != null);
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: builds and passes (the two URL tests run; module compiles). If `zig build test` does not yet pick up `pubmed.zig`, that is fine — Task 6 registers it; for now verify it at least compiles with `zig build-obj -fno-emit-bin src/pubmed.zig` is NOT required. Instead, temporarily verify by Task 6 ordering: proceed; we register in Task 6 and run the suite there. To get fast feedback now, register early:

Edit `src/test_fast.zig` — after the line `_ = @import("web_read_cache.zig");` add:
```zig
    _ = @import("pubmed.zig");
```

Then run: `zig build test 2>&1 | tail -20`
Expected: PASS, both new tests included.

- [ ] **Step 3: Commit**

```bash
git add src/pubmed.zig src/test_fast.zig
git commit -m "feat(pubmed): add pubmed module skeleton with URL builders"
```

---

## Task 2: Parse esearch JSON into PMIDs

**Files:**
- Modify: `src/pubmed.zig`

- [ ] **Step 1: Write the failing tests**

Append to `src/pubmed.zig` (before the closing of the file is not relevant — Zig files have no closing; just append at the end):

```zig
/// Parse esearch JSON (`{"esearchresult":{"idlist":["123",...]}}`) into PMIDs
/// duped into `arena`, capped at `max`. Duping means the parsed value may alias
/// `json_bytes`, which the caller frees after this returns.
pub fn parseEsearchPmids(arena: std.mem.Allocator, json_bytes: []const u8, max: usize) ![][]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{}) catch return error.ParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ParseFailed;
    const result = parsed.value.object.get("esearchresult") orelse return &.{};
    if (result != .object) return &.{};
    const idlist = result.object.get("idlist") orelse return &.{};
    if (idlist != .array) return &.{};
    const arr = idlist.array.items;
    const n = @min(arr.len, max);
    var out = try arena.alloc([]const u8, n);
    var count: usize = 0;
    for (arr[0..n]) |item| {
        if (item != .string) continue;
        out[count] = try arena.dupe(u8, item.string);
        count += 1;
    }
    return out[0..count];
}

test "parseEsearchPmids extracts idlist and honors max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"header":{"type":"esearch"},"esearchresult":{"count":"3","idlist":["111","222","333"]}}
    ;
    const ids = try parseEsearchPmids(arena.allocator(), json, 10);
    try std.testing.expectEqual(@as(usize, 3), ids.len);
    try std.testing.expectEqualStrings("111", ids[0]);
    try std.testing.expectEqualStrings("333", ids[2]);
    const capped = try parseEsearchPmids(arena.allocator(), json, 2);
    try std.testing.expectEqual(@as(usize, 2), capped.len);
}

test "parseEsearchPmids tolerates missing idlist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const empty = try parseEsearchPmids(arena.allocator(), "{\"esearchresult\":{\"count\":\"0\",\"idlist\":[]}}", 10);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const none = try parseEsearchPmids(arena.allocator(), "{\"header\":{}}", 10);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (the implementation is included alongside the tests in Step 1).

- [ ] **Step 3: Commit**

```bash
git add src/pubmed.zig
git commit -m "feat(pubmed): parse esearch JSON into PMIDs"
```

---

## Task 3: Parse efetch XML into Article records

This is the meatiest task: a targeted, defensive XML tag-scanner. Build it from small helpers (entity decode, element finder) up to `parseEfetchXml`.

**Files:**
- Modify: `src/pubmed.zig`

- [ ] **Step 1: Write the XML helper functions + their tests**

Append to `src/pubmed.zig`:

```zig
// --- efetch XML scanning (targeted, not a general parser) ---------------------

/// Decode the five named XML entities plus numeric (`&#NN;` / `&#xHH;`) into
/// `out`. Unknown entities are passed through literally.
fn appendXmlDecoded(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), raw: []const u8) !void {
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try out.append(allocator, raw[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
            try out.append(allocator, raw[i]);
            i += 1;
            continue;
        };
        const ent = raw[i + 1 .. semi];
        if (std.mem.eql(u8, ent, "amp")) {
            try out.append(allocator, '&');
        } else if (std.mem.eql(u8, ent, "lt")) {
            try out.append(allocator, '<');
        } else if (std.mem.eql(u8, ent, "gt")) {
            try out.append(allocator, '>');
        } else if (std.mem.eql(u8, ent, "quot")) {
            try out.append(allocator, '"');
        } else if (std.mem.eql(u8, ent, "apos")) {
            try out.append(allocator, '\'');
        } else if (ent.len >= 2 and ent[0] == '#') {
            const cp: ?u21 = blk: {
                if (ent[1] == 'x' or ent[1] == 'X') {
                    break :blk std.fmt.parseInt(u21, ent[2..], 16) catch null;
                }
                break :blk std.fmt.parseInt(u21, ent[1..], 10) catch null;
            };
            if (cp) |c| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch {
                    try out.appendSlice(allocator, raw[i .. semi + 1]);
                    i = semi + 1;
                    continue;
                };
                try out.appendSlice(allocator, buf[0..len]);
            } else {
                try out.appendSlice(allocator, raw[i .. semi + 1]);
            }
        } else {
            try out.appendSlice(allocator, raw[i .. semi + 1]);
        }
        i = semi + 1;
    }
}

/// Strip any inner `<...>` markup from `raw`, decode XML entities, collapse
/// runs of whitespace to single spaces, and trim. Result duped into `arena`.
fn cleanText(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var stripped: std.ArrayListUnmanaged(u8) = .empty;
    defer stripped.deinit(arena);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, raw, i, '>') orelse break;
            i = close + 1;
            try stripped.append(arena, ' ');
            continue;
        }
        try stripped.append(arena, raw[i]);
        i += 1;
    }
    var decoded: std.ArrayListUnmanaged(u8) = .empty;
    defer decoded.deinit(arena);
    try appendXmlDecoded(arena, &decoded, stripped.items);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(arena);
    var pending_space = false; // defer emitting a separator until a non-ws char
    for (decoded.items) |ch| {
        const is_ws = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
        if (is_ws) {
            if (out.items.len > 0) pending_space = true; // skip leading whitespace
        } else {
            if (pending_space) {
                try out.append(arena, ' ');
                pending_space = false;
            }
            try out.append(arena, ch);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Find the raw inner content of the first `<tag ...>...</tag>` at/after `from`.
/// Returns `.content` (raw, between the open tag's `>` and `</tag>`) and `.end`
/// (index just past `</tag>`). Matches only when `<tag` is followed by `>` or a
/// space (so `<Title` does not match `<TitleX`).
const Element = struct { content: []const u8, end: usize };
fn findElement(xml: []const u8, tag: []const u8, from: usize) ?Element {
    var search = from;
    while (std.mem.indexOfPos(u8, xml, search, tag)) |hit| {
        // require a preceding '<'
        if (hit == 0 or xml[hit - 1] != '<') {
            search = hit + 1;
            continue;
        }
        const after = hit + tag.len;
        if (after >= xml.len or (xml[after] != '>' and xml[after] != ' ' and xml[after] != '\t' and xml[after] != '\n' and xml[after] != '\r')) {
            search = hit + 1;
            continue;
        }
        const open_close = std.mem.indexOfScalarPos(u8, xml, after, '>') orelse return null;
        const content_start = open_close + 1;
        // build "</tag>"
        var close_buf: [64]u8 = undefined;
        const close_tag = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
        const close_at = std.mem.indexOfPos(u8, xml, content_start, close_tag) orelse return null;
        return .{ .content = xml[content_start..close_at], .end = close_at + close_tag.len };
    }
    return null;
}

test "appendXmlDecoded handles named and numeric entities" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendXmlDecoded(a, &out, "a &amp; b &lt;c&gt; &#65; &#x42;");
    try std.testing.expectEqualStrings("a & b <c> A B", out.items);
}

test "cleanText strips tags, decodes, collapses whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try cleanText(arena.allocator(), "Role of  <i>p53</i>\n  in  cancer &amp; aging");
    try std.testing.expectEqualStrings("Role of p53 in cancer & aging", t);
}

test "findElement returns first element content and respects tag boundaries" {
    const xml = "<Year>2023</Year><YearList>x</YearList>";
    const e = findElement(xml, "Year", 0).?;
    try std.testing.expectEqualStrings("2023", e.content);
    // searching past the first Year should find nothing more named exactly Year
    try std.testing.expect(findElement(xml, "Year", e.end) == null);
}
```

- [ ] **Step 2: Run the helper tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (3 new helper tests).

- [ ] **Step 3: Commit the helpers**

```bash
git add src/pubmed.zig
git commit -m "feat(pubmed): add efetch XML scanning helpers"
```

- [ ] **Step 4: Write the failing test for `parseEfetchXml`**

Append to `src/pubmed.zig`:

```zig
test "parseEfetchXml extracts metadata, multi-section abstract, authors, doi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const xml =
        \\<?xml version="1.0"?>
        \\<PubmedArticleSet>
        \\<PubmedArticle><MedlineCitation>
        \\<PMID Version="1">12345678</PMID>
        \\<Article>
        \\<Journal><ISOAbbreviation>Lancet</ISOAbbreviation>
        \\<JournalIssue><PubDate><Year>2023</Year></PubDate></JournalIssue></Journal>
        \\<ArticleTitle>Metformin and cardiovascular outcomes</ArticleTitle>
        \\<Abstract>
        \\<AbstractText Label="BACKGROUND">We studied metformin.</AbstractText>
        \\<AbstractText Label="RESULTS">It helped.</AbstractText>
        \\</Abstract>
        \\<AuthorList>
        \\<Author><LastName>Smith</LastName><Initials>J</Initials></Author>
        \\<Author><LastName>Doe</LastName><Initials>A</Initials></Author>
        \\</AuthorList>
        \\</Article></MedlineCitation>
        \\<PubmedData><ArticleIdList>
        \\<ArticleId IdType="pubmed">12345678</ArticleId>
        \\<ArticleId IdType="doi">10.1016/s0140-6736(23)00001-2</ArticleId>
        \\</ArticleIdList></PubmedData>
        \\</PubmedArticle>
        \\<PubmedArticle><MedlineCitation>
        \\<PMID>99</PMID>
        \\<Article><ArticleTitle>No abstract here</ArticleTitle></Article>
        \\</MedlineCitation></PubmedArticle>
        \\</PubmedArticleSet>
    ;
    const items = try parseEfetchXml(arena.allocator(), xml);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("12345678", items[0].pmid);
    try std.testing.expectEqualStrings("Metformin and cardiovascular outcomes", items[0].title);
    try std.testing.expectEqualStrings("Lancet", items[0].journal);
    try std.testing.expectEqualStrings("2023", items[0].year);
    try std.testing.expectEqualStrings("10.1016/s0140-6736(23)00001-2", items[0].doi);
    try std.testing.expectEqualStrings("Smith J, Doe A", items[0].authors);
    try std.testing.expect(std.mem.indexOf(u8, items[0].abstract, "BACKGROUND: We studied metformin.") != null);
    try std.testing.expect(std.mem.indexOf(u8, items[0].abstract, "RESULTS: It helped.") != null);
    // second article: title present, abstract/doi empty, not dropped
    try std.testing.expectEqualStrings("99", items[1].pmid);
    try std.testing.expectEqualStrings("No abstract here", items[1].title);
    try std.testing.expectEqualStrings("", items[1].abstract);
    try std.testing.expectEqualStrings("", items[1].doi);
}

test "parseEfetchXml caps authors with et al" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const xml =
        \\<PubmedArticle><PMID>1</PMID><ArticleTitle>T</ArticleTitle>
        \\<AuthorList>
        \\<Author><LastName>A</LastName><Initials>A</Initials></Author>
        \\<Author><LastName>B</LastName><Initials>B</Initials></Author>
        \\<Author><LastName>C</LastName><Initials>C</Initials></Author>
        \\<Author><LastName>D</LastName><Initials>D</Initials></Author>
        \\</AuthorList></PubmedArticle>
    ;
    const items = try parseEfetchXml(arena.allocator(), xml);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("A A, B B, C C, et al.", items[0].authors);
}
```

- [ ] **Step 5: Run to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `parseEfetchXml` is not defined (compile error "use of undeclared identifier 'parseEfetchXml'").

- [ ] **Step 6: Implement `parseEfetchXml` and its sub-extractors**

Append to `src/pubmed.zig` (place these functions ABOVE the two tests you just added, or anywhere in the file — Zig is order-independent at container scope):

```zig
/// Extract joined authors from an `<AuthorList>...</AuthorList>` block. Up to
/// `max_authors_shown` names "LastName Initials", then ", et al." when more.
fn extractAuthors(arena: std.mem.Allocator, article_xml: []const u8) ![]const u8 {
    const list = findElement(article_xml, "AuthorList", 0) orelse return "";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(arena);
    var pos: usize = 0;
    var shown: usize = 0;
    var total: usize = 0;
    while (findElement(list.content, "Author", pos)) |author| {
        pos = author.end;
        const last = findElement(author.content, "LastName", 0) orelse continue;
        total += 1;
        if (shown >= max_authors_shown) continue;
        if (shown != 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, std.mem.trim(u8, last.content, " \t\r\n"));
        if (findElement(author.content, "Initials", 0)) |ini| {
            const t = std.mem.trim(u8, ini.content, " \t\r\n");
            if (t.len > 0) {
                try out.append(arena, ' ');
                try out.appendSlice(arena, t);
            }
        }
        shown += 1;
    }
    if (total > shown) try out.appendSlice(arena, ", et al.");
    return out.toOwnedSlice(arena);
}

/// Concatenate all `<AbstractText>` sections, prefixing `Label="X"` as "X: ".
fn extractAbstract(arena: std.mem.Allocator, article_xml: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(arena);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, article_xml, pos, "<AbstractText")) |open| {
        const open_close = std.mem.indexOfScalarPos(u8, article_xml, open, '>') orelse break;
        const open_tag = article_xml[open .. open_close + 1];
        const content_start = open_close + 1;
        const close_at = std.mem.indexOfPos(u8, article_xml, content_start, "</AbstractText>") orelse break;
        const raw = article_xml[content_start..close_at];
        pos = close_at + "</AbstractText>".len;

        const label = attrValue(open_tag, "Label");
        if (out.items.len > 0) try out.appendSlice(arena, "\n\n");
        if (label) |lbl| {
            if (lbl.len > 0) {
                try out.appendSlice(arena, lbl);
                try out.appendSlice(arena, ": ");
            }
        }
        const text = try cleanText(arena, raw);
        try out.appendSlice(arena, text);
    }
    return out.toOwnedSlice(arena);
}

/// Read the value of attribute `name` from a single open tag like
/// `<AbstractText Label="METHODS" NlmCategory="METHODS">`.
fn attrValue(open_tag: []const u8, name: []const u8) ?[]const u8 {
    var buf: [48]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "{s}=\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, open_tag, needle) orelse return null;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, open_tag, start, '"') orelse return null;
    return open_tag[start..end];
}

/// Find the DOI from `<ArticleId IdType="doi">...</ArticleId>`.
fn extractDoi(article_xml: []const u8) []const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, article_xml, pos, "<ArticleId")) |open| {
        const open_close = std.mem.indexOfScalarPos(u8, article_xml, open, '>') orelse break;
        const open_tag = article_xml[open .. open_close + 1];
        const content_start = open_close + 1;
        const close_at = std.mem.indexOfPos(u8, article_xml, content_start, "</ArticleId>") orelse break;
        pos = close_at + "</ArticleId>".len;
        const idtype = attrValue(open_tag, "IdType") orelse continue;
        if (std.mem.eql(u8, idtype, "doi")) {
            return std.mem.trim(u8, article_xml[content_start..close_at], " \t\r\n");
        }
    }
    return "";
}

/// Extract the journal title (prefer `<ISOAbbreviation>`, else `<Title>`).
fn extractJournal(arena: std.mem.Allocator, article_xml: []const u8) ![]const u8 {
    const journal = findElement(article_xml, "Journal", 0) orelse return "";
    if (findElement(journal.content, "ISOAbbreviation", 0)) |iso|
        return cleanText(arena, iso.content);
    if (findElement(journal.content, "Title", 0)) |title|
        return cleanText(arena, title.content);
    return "";
}

/// Parse efetch XML into Article records duped into `arena`. Defensive: a
/// missing field becomes "" and the article is kept as long as it has a PMID
/// and a title. Strings may alias `xml`, which the caller frees afterward.
pub fn parseEfetchXml(arena: std.mem.Allocator, xml: []const u8) ![]Article {
    var list: std.ArrayListUnmanaged(Article) = .empty;
    errdefer list.deinit(arena);
    var pos: usize = 0;
    while (findElement(xml, "PubmedArticle", pos)) |block| {
        pos = block.end;
        const ax = block.content;
        const pmid_el = findElement(ax, "PMID", 0);
        const title_el = findElement(ax, "ArticleTitle", 0);
        if (pmid_el == null or title_el == null) continue;
        const pmid = std.mem.trim(u8, pmid_el.?.content, " \t\r\n");
        const title = try cleanText(arena, title_el.?.content);
        if (pmid.len == 0 or title.len == 0) continue;
        const year = if (findElement(ax, "PubDate", 0)) |pd|
            (if (findElement(pd.content, "Year", 0)) |y| std.mem.trim(u8, y.content, " \t\r\n") else "")
        else ""; // scope to PubDate so DateCompleted/DateRevised <Year> are not picked up
        try list.append(arena, .{
            .pmid = try arena.dupe(u8, pmid),
            .title = title,
            .authors = try extractAuthors(arena, ax),
            .journal = try extractJournal(arena, ax),
            .year = try arena.dupe(u8, year),
            .doi = try arena.dupe(u8, extractDoi(ax)),
            .abstract = try extractAbstract(arena, ax),
        });
    }
    return list.toOwnedSlice(arena);
}
```

- [ ] **Step 7: Run to verify the `parseEfetchXml` tests pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (both `parseEfetchXml` tests).

- [ ] **Step 8: Commit**

```bash
git add src/pubmed.zig
git commit -m "feat(pubmed): parse efetch XML into Article records"
```

---

## Task 4: Formatters (`formatForAgent`, `formatForUser`)

**Files:**
- Modify: `src/pubmed.zig`

- [ ] **Step 1: Write the failing tests**

Append to `src/pubmed.zig`:

```zig
test "formatForAgent includes full abstract and metadata" {
    const a = std.testing.allocator;
    const items = [_]Article{.{
        .pmid = "123", .title = "T", .authors = "Smith J", .journal = "Lancet",
        .year = "2023", .doi = "10.1/x", .abstract = "FULL-ABSTRACT-BODY",
    }};
    const text = try formatForAgent(a, "q", &items);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[1] T") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Smith J. Lancet. 2023.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "PMID: 123") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "DOI: 10.1/x") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "FULL-ABSTRACT-BODY") != null);
    const none = try formatForAgent(a, "q", &.{});
    defer a.free(none);
    try std.testing.expect(std.mem.indexOf(u8, none, "No PubMed results for: q") != null);
}

test "formatForUser truncates long abstract" {
    const a = std.testing.allocator;
    const long = "x" ** 600;
    const items = [_]Article{.{
        .pmid = "1", .title = "T", .authors = "", .journal = "", .year = "",
        .doi = "", .abstract = long,
    }};
    const text = try formatForUser(a, "q", &items);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "1. T") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "…") != null);
    // full 600-char body must not appear verbatim
    try std.testing.expect(std.mem.indexOf(u8, text, long) == null);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `formatForAgent` / `formatForUser` undefined.

- [ ] **Step 3: Implement the formatters**

Append to `src/pubmed.zig`:

```zig
/// Truncate `s` to at most `max` bytes without splitting a UTF-8 sequence.
fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1; // back off continuation bytes
    return s[0..end];
}

/// Append `s` followed by a period, unless `s` already ends with one.
fn appendDotted(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.appendSlice(allocator, s);
    if (s.len == 0 or s[s.len - 1] != '.') try out.append(allocator, '.');
}

/// Write the citation line "<authors>. <journal>. <year>." skipping empties.
/// Each present component is terminated by a period and joined by a space, so
/// authors="Smith J", journal="Lancet", year="2023" -> "Smith J. Lancet. 2023.".
fn writeCitation(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), art: Article) !void {
    var wrote = false;
    if (art.authors.len > 0) {
        try appendDotted(allocator, out, art.authors);
        wrote = true;
    }
    if (art.journal.len > 0) {
        if (wrote) try out.append(allocator, ' ');
        try appendDotted(allocator, out, art.journal);
        wrote = true;
    }
    if (art.year.len > 0) {
        if (wrote) try out.append(allocator, ' ');
        try appendDotted(allocator, out, art.year);
        wrote = true;
    }
    if (wrote) try out.append(allocator, '\n');
}

fn writeIds(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), art: Article) !void {
    try out.appendSlice(allocator, "PMID: ");
    try out.appendSlice(allocator, art.pmid);
    if (art.doi.len > 0) {
        try out.appendSlice(allocator, "  DOI: ");
        try out.appendSlice(allocator, art.doi);
    }
    try out.append(allocator, '\n');
}

/// Render for the model (agent `pubmed` tool): full abstracts.
pub fn formatForAgent(allocator: std.mem.Allocator, query: []const u8, items: []const Article) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (items.len == 0) {
        try out.writer(allocator).print("No PubMed results for: {s}", .{query});
        return out.toOwnedSlice(allocator);
    }
    try out.writer(allocator).print("PubMed results for \"{s}\" ({d} articles):\n", .{ query, items.len });
    for (items, 0..) |art, i| {
        try out.writer(allocator).print("\n[{d}] {s}\n", .{ i + 1, art.title });
        try writeCitation(allocator, &out, art);
        try writeIds(allocator, &out, art);
        if (art.abstract.len > 0) {
            try out.append(allocator, '\n');
            try out.appendSlice(allocator, art.abstract);
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Render for the user transcript (`$pubmed`): truncated abstracts.
pub fn formatForUser(allocator: std.mem.Allocator, query: []const u8, items: []const Article) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (items.len == 0) {
        try out.writer(allocator).print("No PubMed results for: {s}", .{query});
        return out.toOwnedSlice(allocator);
    }
    try out.writer(allocator).print("PubMed results for \"{s}\":\n", .{query});
    for (items, 0..) |art, i| {
        try out.writer(allocator).print("\n{d}. {s}\n", .{ i + 1, art.title });
        try writeCitation(allocator, &out, art);
        try writeIds(allocator, &out, art);
        if (art.abstract.len > 0) {
            const shown = truncateUtf8(art.abstract, user_abstract_limit);
            try out.appendSlice(allocator, shown);
            if (shown.len < art.abstract.len) try out.appendSlice(allocator, "…");
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/pubmed.zig
git commit -m "feat(pubmed): add agent and user result formatters"
```

---

## Task 5: Error handling + `executeSearch` (network)

**Files:**
- Modify: `src/pubmed.zig`

- [ ] **Step 1: Write the failing tests for error text + empty-query guard**

Append to `src/pubmed.zig`:

```zig
test "errorText maps known errors to friendly text" {
    clearErrorDetail();
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.MissingQuery), "query") != null);
    try std.testing.expect(std.mem.indexOf(u8, errorText(error.Network), "reach") != null);
}

test "formatErrorText includes unexpected lower-level error names" {
    const text = try formatErrorText(std.testing.allocator, error.ConnectionTimedOut);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "ConnectionTimedOut") != null);
}

test "executeSearch rejects an empty query without touching the network" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingQuery, executeSearch(arena.allocator(), "   ", .{}));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `errorText` / `formatErrorText` / `executeSearch` / `clearErrorDetail` undefined.

- [ ] **Step 3: Implement error infra + `executeSearch`**

Append to `src/pubmed.zig`:

```zig
// --- Error detail (threadlocal, mirrors web_search.zig) -----------------------

const ErrorDetailKind = enum { none, network, http_status, parse_failed };
threadlocal var g_error_detail_kind: ErrorDetailKind = .none;
threadlocal var g_error_detail_buf: [512]u8 = undefined;
threadlocal var g_error_detail_len: usize = 0;

fn clearErrorDetail() void {
    g_error_detail_kind = .none;
    g_error_detail_len = 0;
}

fn setErrorDetail(kind: ErrorDetailKind, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&g_error_detail_buf, fmt, args) catch {
        const fallback = "PubMed search failed: diagnostic message was too long.";
        @memcpy(g_error_detail_buf[0..fallback.len], fallback);
        g_error_detail_len = fallback.len;
        g_error_detail_kind = kind;
        return;
    };
    g_error_detail_len = text.len;
    g_error_detail_kind = kind;
}

fn errorDetail(kind: ErrorDetailKind) ?[]const u8 {
    if (g_error_detail_kind != kind or g_error_detail_len == 0) return null;
    return g_error_detail_buf[0..g_error_detail_len];
}

fn setNetworkErrorDetail(err: anyerror, url: []const u8) void {
    setErrorDetail(.network, "PubMed request failed before response: {s} ({s})", .{ @errorName(err), url });
}

/// Friendly, user/model-facing message for a PubMed error.
pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingQuery => "PubMed search needs a query.",
        error.Network => errorDetail(.network) orelse "PubMed search failed: could not reach the NCBI E-utilities service.",
        error.HttpStatus => errorDetail(.http_status) orelse "PubMed search failed: NCBI returned an error status.",
        error.ParseFailed => errorDetail(.parse_failed) orelse "PubMed search failed: could not parse the NCBI response.",
        else => "PubMed search failed.",
    };
}

/// Owned error text for transcript/model output. Keeps unexpected lower-level
/// error names visible instead of collapsing them.
pub fn formatErrorText(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return switch (err) {
        error.MissingQuery, error.Network, error.HttpStatus, error.ParseFailed => allocator.dupe(u8, errorText(err)),
        else => std.fmt.allocPrint(allocator, "PubMed search failed: {s}.", .{@errorName(err)}),
    };
}

fn httpGet(gpa: std.mem.Allocator, url: []const u8) !platform_http.Response {
    return platform_http.fetch(gpa, .{
        .method = .GET,
        .url = url,
        .headers = &.{},
        .body = "",
        .timeout_ms = 30_000,
    });
}

/// Run a PubMed search: esearch (PMIDs) then efetch (articles). `gpa` is used
/// for transient HTTP buffers; the returned `Results` owns its strings via its
/// own arena (free with `results.deinit()`).
pub fn executeSearch(gpa: std.mem.Allocator, query_in: []const u8, opts: Options) !Results {
    clearErrorDetail();
    const query = std.mem.trim(u8, query_in, " \t\r\n");
    if (query.len == 0) return error.MissingQuery;

    var results = Results{ .arena = std.heap.ArenaAllocator.init(gpa), .items = &.{} };
    errdefer results.arena.deinit();
    const arena = results.arena.allocator();

    // 1. esearch -> PMIDs
    const es_url = try buildEsearchUrl(gpa, query, opts);
    defer gpa.free(es_url);
    var es_resp = httpGet(gpa, es_url) catch |err| {
        setNetworkErrorDetail(err, es_url);
        std.log.warn("{s}", .{errorText(error.Network)});
        return error.Network;
    };
    defer es_resp.deinit(gpa);
    if (es_resp.status != 200) {
        setErrorDetail(.http_status, "PubMed search failed: esearch returned HTTP {d}.", .{es_resp.status});
        return error.HttpStatus;
    }
    const pmids = parseEsearchPmids(arena, es_resp.body, opts.max_results) catch |err| {
        if (err == error.ParseFailed)
            setErrorDetail(.parse_failed, "PubMed search failed: could not parse the esearch response.", .{});
        return err;
    };
    if (pmids.len == 0) return results; // empty -> formatters print "No PubMed results"

    // 2. efetch -> articles
    const ef_url = try buildEfetchUrl(gpa, pmids, opts);
    defer gpa.free(ef_url);
    var ef_resp = httpGet(gpa, ef_url) catch |err| {
        setNetworkErrorDetail(err, ef_url);
        std.log.warn("{s}", .{errorText(error.Network)});
        return error.Network;
    };
    defer ef_resp.deinit(gpa);
    if (ef_resp.status != 200) {
        setErrorDetail(.http_status, "PubMed search failed: efetch returned HTTP {d}.", .{ef_resp.status});
        return error.HttpStatus;
    }
    results.items = try parseEfetchXml(arena, ef_resp.body);
    return results;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (3 new tests; whole suite green).

- [ ] **Step 5: Commit**

```bash
git add src/pubmed.zig
git commit -m "feat(pubmed): add error handling and two-call executeSearch"
```

---

## Task 6: Confirm fast-suite registration + full build

**Files:**
- Verify: `src/test_fast.zig` (already edited in Task 1)

- [ ] **Step 1: Confirm registration line exists**

Run: `grep -n "pubmed.zig" src/test_fast.zig`
Expected: one line `    _ = @import("pubmed.zig");`. If missing, add it after `_ = @import("web_read_cache.zig");`.

- [ ] **Step 2: Run both suites**

Run: `zig build test 2>&1 | tail -5 && echo "---FULL---" && zig build test-full 2>&1 | tail -8`
Expected: both exit 0. (Baseline full suite: 0 failed; a single pre-existing `web_read_cache` failure noted in project memory may appear — confirm no NEW failures from `pubmed`.)

- [ ] **Step 3: Commit (if Step 1 changed anything)**

```bash
git add src/test_fast.zig
git commit -m "test(pubmed): register module in fast suite" || echo "nothing to commit"
```

---

## Task 7: Register the `pubmed` agent tool schema

**Files:**
- Modify: `src/ai_chat_protocol.zig` (add to `forEachToolSpec` after the `webread` emit at line ~679; add a test near line ~1503)

- [ ] **Step 1: Write the failing test**

In `src/ai_chat_protocol.zig`, directly AFTER the `test "agent tool set includes webread" { ... }` block (around line 1503-1509), add:

```zig
test "agent tool set includes pubmed" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("hi") }};
    const params = RequestParams{ .model = "m", .system_prompt = "", .protocol = .anthropic, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .max_tokens = 8192 };
    const json = try buildRequestJson(a, params, &msgs, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pubmed\"") != null);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full 2>&1 | grep -A3 "includes pubmed" | head; zig build test-full 2>&1 | tail -5`
Expected: FAIL — the assertion that `"pubmed"` appears in the tool JSON fails.

- [ ] **Step 3: Add the tool spec**

In `forEachToolSpec`, immediately after the `webread` emit line (the one starting `try emit(ctx, "webread",`), add:

```zig
    try emit(ctx, "pubmed", "Search PubMed (NCBI) for biomedical and life-sciences literature and return matching articles with title, authors, journal, year, PMID, DOI, and abstract. Before calling, decompose the user's academic question into English keywords joined with PubMed boolean operators (AND/OR), then pass that as `query`. Use for scholarly/medical literature questions, not general web search.", "{\"query\":{\"type\":\"string\",\"description\":\"PubMed query: English keywords joined with AND/OR, e.g. metformin AND type 2 diabetes AND cardiovascular events.\"},\"max_results\":{\"type\":\"integer\",\"description\":\"Optional max number of articles (default 10, max 20).\"}}");
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-full 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_protocol.zig
git commit -m "feat(pubmed): declare the pubmed agent tool schema"
```

---

## Task 8: Dispatch the `pubmed` agent tool call

**Files:**
- Modify: `src/ai_chat_tools.zig` (import near line 33-34; dispatch near line 213-218; helper near line 350-364)

- [ ] **Step 1: Add the import**

In `src/ai_chat_tools.zig`, after the line `const web_read = @import("web_read.zig");` (line ~34), add:

```zig
const pubmed = @import("pubmed.zig");
```

- [ ] **Step 2: Add the dispatch arm**

In the tool dispatch chain, after the `webread` block (the `if (std.mem.eql(u8, call.name, "webread")) { ... }` ending around line 218), add:

```zig
    if (std.mem.eql(u8, call.name, "pubmed")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const query = jsonStringArg(args.value, "query") orelse return ctx.allocator.dupe(u8, "Missing query");
        const max_results = jsonIntArg(args.value, "max_results");
        return pubMedTool(ctx.allocator, query, max_results);
    }
```

- [ ] **Step 3: Add the `pubMedTool` helper**

After the `webReadTool` function (ends around line 364), add:

```zig
/// Agent `pubmed` tool: NCBI PubMed search with abstracts, formatted for the model.
fn pubMedTool(allocator: std.mem.Allocator, query: []const u8, max_results: ?u32) ![]u8 {
    const max: usize = if (max_results) |m| @min(@max(m, 1), 20) else 10;
    var results = pubmed.executeSearch(allocator, query, .{ .max_results = max }) catch |err|
        return pubmed.formatErrorText(allocator, err);
    defer results.deinit();
    return pubmed.formatForAgent(allocator, query, results.items);
}
```

- [ ] **Step 4: Write a dispatch test**

PubMed dispatch needs the network, so test only the argument-guard path. Find where `ai_chat_tools.zig` tests live (search `test "` in the file). If the file has tests, add near them; otherwise add at the end of the file:

```zig
test "pubmed dispatch reports missing query" {
    const a = std.testing.allocator;
    // Build a minimal ToolContext-free check: call pubMedTool's guard via the
    // dispatcher requires a ctx; instead verify the empty-query path of the core.
    try std.testing.expectError(error.MissingQuery, pubmed.executeSearch(a, "", .{}));
}
```

(Note: a full dispatch test needs a `ToolContext`; the core guard test above is sufficient and avoids network. If the file already constructs a test `ToolContext` for `websearch`, mirror that instead and assert `Missing query` text — but do not make a network call.)

- [ ] **Step 5: Run both suites**

Run: `zig build test 2>&1 | tail -3 && echo "---" && zig build test-full 2>&1 | tail -5`
Expected: both green.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "feat(pubmed): dispatch the pubmed agent tool"
```

---

## Task 9: `$pubmed` user command — composer

**Files:**
- Modify: `src/ai_chat_composer.zig` (lines 27-42 + tests near 471-491)

- [ ] **Step 1: Write the failing tests**

In `src/ai_chat_composer.zig`, after the test `"parseWebCommand matches $webread and still matches $websearch"` (ends ~line 491), add:

```zig
test "parseWebCommand matches $pubmed" {
    try std.testing.expectEqual(WebCommand.pubmed, parseWebCommand("$pubmed").?);
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("$pubmedx"));
    try std.testing.expectEqual(@as(?WebCommand, null), parseWebCommand("pubmed"));
}

test "reserved $pubmed appears in reserved web commands" {
    var found = false;
    for (reserved_web_commands) |rc| {
        if (std.mem.eql(u8, rc.name, "pubmed")) found = true;
    }
    try std.testing.expect(found);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `WebCommand.pubmed` does not exist (compile error).

- [ ] **Step 3: Extend the enum, reserved list, and parser**

In `src/ai_chat_composer.zig`:

Change line 27 from:
```zig
pub const WebCommand = enum { websearch, webread };
```
to:
```zig
pub const WebCommand = enum { websearch, webread, pubmed };
```

Change the `reserved_web_commands` array (lines 31-34) to add a third entry:
```zig
pub const reserved_web_commands = [_]ReservedWebCommand{
    .{ .name = "websearch", .description = "search the web (Jina)" },
    .{ .name = "webread", .description = "read a web page or local file (Jina)" },
    .{ .name = "pubmed", .description = "search PubMed (NCBI)" },
};
```

In `parseWebCommand` (lines 38-42), add before `return null;`:
```zig
    if (std.mem.eql(u8, token, "$pubmed")) return .pubmed;
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_composer.zig
git commit -m "feat(pubmed): add \$pubmed reserved command parsing"
```

---

## Task 10: `$pubmed` background worker + dispatch

**Files:**
- Modify: `src/ai_chat.zig` (import ~line 146; new `WebPubMedRequest` struct ~after line 242; dispatch arm ~line 1761; new `startPubMedRequest` ~after line 2444)
- Modify: `src/ai_chat_request.zig` (import ~line 13; new `pubMedThreadMain` ~after line 200)

- [ ] **Step 1: Add the import in `ai_chat.zig`**

After `const web_search = @import("web_search.zig");` (line 146), add:
```zig
const pubmed = @import("pubmed.zig");
```

- [ ] **Step 2: Add the request struct**

After the `WebReadRequest` struct (ends line 242), add:

```zig
/// Lightweight background job for a `$pubmed` user command. Owns its query.
/// Mirrors `WebSearchRequest`; joined by `Session.deinit` via `request_thread`.
pub const WebPubMedRequest = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    query: []u8,

    pub fn create(allocator: std.mem.Allocator, session: *Session, query: []const u8) !*WebPubMedRequest {
        const self = try allocator.create(WebPubMedRequest);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .session = session, .query = try allocator.dupe(u8, query) };
        return self;
    }

    pub fn deinit(self: *WebPubMedRequest) void {
        self.allocator.free(self.query);
        self.allocator.destroy(self);
    }
};
```

- [ ] **Step 3: Add the dispatch arm**

In the `switch (web_cmd)` block (lines 1759-1762), add a `.pubmed` arm:
```zig
            switch (web_cmd) {
                .websearch => self.startWebSearchRequest(arg),
                .webread => self.startWebReadRequest(arg),
                .pubmed => self.startPubMedRequest(arg),
            }
```

- [ ] **Step 4: Add `startPubMedRequest`**

After `startWebReadRequest` (ends line 2501), add:

```zig
    /// Run a `$pubmed <query>` command on a background thread. Mirrors
    /// `startWebSearchRequest` but needs no API key (NCBI is anonymous). Called
    /// AFTER the caller has unlocked `self.mutex`.
    fn startPubMedRequest(self: *Session, query_in: []const u8) void {
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
            self.appendLocalToolMessageLocked("Usage: $pubmed <query>") catch self.setStatusLocked("Out of memory");
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        }

        const req = WebPubMedRequest.create(self.allocator, self, query) catch {
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
        self.setStatusLocked("Searching PubMed…");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, ai_chat_request.pubMedThreadMain, .{req}) catch {
            req.deinit();
            self.mutex.lock();
            self.request_inflight = false;
            self.appendLocalToolMessageLocked("Failed to start PubMed search thread.") catch {};
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };
        self.mutex.lock();
        self.request_thread = thread;
        self.mutex.unlock();
    }
```

- [ ] **Step 5: Add the import + worker in `ai_chat_request.zig`**

After `const web_read = @import("web_read.zig");` (line 13), add:
```zig
const pubmed = @import("pubmed.zig");
```

After `webReadThreadMain` (ends line 200), add:

```zig
/// Background worker for one `$pubmed` command. Owns `req`; frees it on exit.
/// Runs the two-call NCBI search and appends the formatted articles to the
/// transcript. Reuses `appendWebSearchResult` (generic local tool message).
pub fn pubMedThreadMain(req: *ai_chat.WebPubMedRequest) void {
    defer req.deinit();
    const allocator = req.allocator;
    const session = req.session;
    if (session.closing.load(.acquire)) return;

    var results = pubmed.executeSearch(allocator, req.query, .{ .max_results = 10 }) catch |err| {
        const text = pubmed.formatErrorText(allocator, err) catch {
            ai_chat.appendWebSearchResult(session, pubmed.errorText(err));
            return;
        };
        defer allocator.free(text);
        ai_chat.appendWebSearchResult(session, text);
        return;
    };
    defer results.deinit();

    const text = pubmed.formatForUser(allocator, req.query, results.items) catch {
        ai_chat.appendWebSearchResult(session, "Out of memory formatting PubMed results.");
        return;
    };
    defer allocator.free(text);
    ai_chat.appendWebSearchResult(session, text);
}
```

- [ ] **Step 6: Run both suites**

Run: `zig build test 2>&1 | tail -3 && echo "---" && zig build test-full 2>&1 | tail -6`
Expected: both green. The `$pubmed` worker compiles and the existing exhaustive `switch (web_cmd)` now covers `.pubmed`.

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat.zig src/ai_chat_request.zig
git commit -m "feat(pubmed): wire \$pubmed background command"
```

---

## Task 11: Agent prompt keyword-decomposition guidance

**Files:**
- Modify: `src/platform/agent_prompt.zig` (add a line in `common_tools_after_wsl` near line 56; add a test near line 133)

- [ ] **Step 1: Write the failing test**

In `src/platform/agent_prompt.zig`, after the test `"platform agent prompt points at the wispterm_docs tool on every OS"` (lines 133-138), add a test that mirrors its exact structure (it iterates the per-OS prompts via `defaultSystemPromptForOs`):

```zig
test "platform agent prompt mentions the pubmed tool on every OS" {
    for ([_]std.Target.Os.Tag{ .windows, .linux, .macos }) |os| {
        const p = defaultSystemPromptForOs(os);
        try std.testing.expect(std.mem.indexOf(u8, p, "pubmed") != null);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full 2>&1 | tail -6`
Expected: FAIL — "pubmed" not found in the prompts.

- [ ] **Step 3: Add the guidance line**

In `common_tools_after_wsl` (the multiline string, lines 48-69), after the `wispterm_docs` line (line 56, `\\- For WispTerm questions, call \`wispterm_docs\`.`), add:

```zig
    \\- For biomedical/medical/life-sciences literature questions, decompose the question into English keywords joined with AND/OR, then call `pubmed`.
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-full 2>&1 | tail -6`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/platform/agent_prompt.zig
git commit -m "feat(pubmed): teach the agent to use pubmed for literature questions"
```

---

## Task 12: Final verification + full build

**Files:** none (verification only)

- [ ] **Step 1: Build the app binary (compile check beyond tests)**

Run: `zig build 2>&1 | tail -15`
Expected: builds with no errors. (If the project's default build needs a target/options, use the same invocation the repo README/CI uses; check `grep -n "zig build" .github/workflows/*.yml | head` if unsure.)

- [ ] **Step 2: Run both suites once more**

Run: `zig build test 2>&1 | tail -5 && echo "---FULL---" && zig build test-full 2>&1 | tail -8`
Expected: both exit 0; no NEW failures vs. the pre-existing baseline (project memory notes a possible single pre-existing `web_read_cache` failure — confirm nothing new from `pubmed`).

- [ ] **Step 3: Review the diff**

Run: `git log --oneline main..HEAD && git diff --stat main..HEAD`
Expected: commits for tasks 1-11; files limited to: `src/pubmed.zig`, `src/test_fast.zig`, `src/ai_chat_protocol.zig`, `src/ai_chat_tools.zig`, `src/ai_chat_composer.zig`, `src/ai_chat.zig`, `src/ai_chat_request.zig`, `src/platform/agent_prompt.zig`, and the two docs files.

- [ ] **Step 4: Request code review**

Use the `superpowers:requesting-code-review` skill (or `/code-review`) over `main..HEAD` before merging.

---

## Notes & gotchas

- **`prompt.md` is NOT the live agent prompt** — the live prompt is `src/platform/agent_prompt.zig` (per project memory). Only Task 11 touches the prompt.
- **Reuse `appendWebSearchResult`** for `$pubmed` output — it is a generic "append a local tool message" sink, not websearch-specific. No new append helper is needed.
- **No approval gate** for `pubmed` — it is read-only network access, exactly like `websearch`; do not add it to any access-gate list.
- **No config key** in v1 — NCBI works anonymously; do not add a `pubmed-api-key` (deferred). This avoids the startup-config-load wiring that web_search's Jina key needs.
- **efetch returns XML only** — there is no JSON abstract endpoint; the hand-rolled scanner in Task 3 is intentional and bounded to the six fields we need.
- If `zig build test` does not run `pubmed.zig`'s tests, re-check the `_ = @import("pubmed.zig");` line in `src/test_fast.zig` (Task 1 Step 2 / Task 6).
```
