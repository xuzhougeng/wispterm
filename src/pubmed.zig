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
        const year = if (findElement(ax, "Year", 0)) |y| std.mem.trim(u8, y.content, " \t\r\n") else "";
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
