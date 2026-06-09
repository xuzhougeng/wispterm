# PubMed tool — design

**Date:** 2026-06-09
**Branch:** `worktree-feat-tool-pubmed`
**Status:** Approved (ready for implementation plan)

## Goal

Add a `pubmed` tool for academic / literature questions. When a user asks a
scholarly question, the **model** decomposes it into English keywords joined
with PubMed boolean operators (`AND` / `OR`), then calls the tool with that
constructed query. The tool runs the query against NCBI E-utilities and returns
results **with abstracts**.

Two entry points, mirroring the existing `websearch` / `webread` pattern:
- an agent tool `pubmed` (the model calls it automatically), and
- a user command `$pubmed <query>` (manual lookup, no AI turn).

## Key decisions (from brainstorming)

1. **Keyword splitting is the model's job**, not the tool's. The tool receives
   an already-constructed PubMed query string and passes it through. The
   "decompose into keywords + boolean operators" instruction lives in the tool
   description and the agent system prompt — in text, not in code.
2. **Results include abstracts.** Each result carries title, authors, journal,
   year, PMID, DOI, and the full abstract.
3. **Both entry points** (agent tool + `$pubmed` user command), shared core.
4. **Anonymous NCBI access** for v1 — no API key config. (Optional
   `pubmed-api-key` to raise rate limits is deferred — YAGNI.)
5. **Hand-rolled targeted XML scanning** for efetch — not a general XML parser.

## Architecture

New pure module **`src/pubmed.zig`**, a sibling of `web_search.zig` with the
same shape:
- Pure helpers: URL builders, response parsers, formatters — all unit-testable
  offline with no network.
- One `executeSearch` that performs the network calls via
  `platform/http_client.zig` (GET), returning an arena-owned `Results`.

This keeps `pubmed.zig` a self-contained unit: callers depend only on
`executeSearch` + the formatters, and the internals (URL shape, XML scanning)
can change without touching consumers.

## NCBI E-utilities flow

PubMed has no single "search + abstracts" endpoint, so two GET calls:

1. **esearch** —
   `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&retmode=json&retmax=<N>&term=<query>&tool=wispterm`
   → JSON `{"esearchresult":{"idlist":["<pmid>",...]}}`, parsed with `std.json`.
2. **efetch** —
   `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&retmode=xml&rettype=abstract&id=<pmid,pmid,...>&tool=wispterm`
   → XML containing, per article, the title, authors, journal, year, DOI, and
   abstract.

`tool=wispterm` is included on both calls (NCBI etiquette). The anonymous rate
limit (~3 req/s) is acceptable for v1.

If esearch returns zero PMIDs, skip efetch and return a "no results" message.

### efetch XML parsing

efetch offers no JSON for abstracts, and Zig std has no XML parser, so
`pubmed.zig` includes a **targeted, defensive tag-scanner** — not a general XML
parser. It walks `<PubmedArticle>` blocks and, within each, extracts:

- `<PMID>` → PMID
- `<ArticleTitle>` → title
- `<AbstractText>` (possibly multiple, possibly with `Label=` attributes) →
  abstract (concatenated, labels preserved when present)
- `<AuthorList>` → `<LastName>` + `<ForeName>`/`<Initials>` per `<Author>`
- journal title + `<PubDate><Year>` → journal / year
- `<ArticleId IdType="doi">` → DOI

The scanner is defensive: any missing field yields an empty string rather than a
parse failure; an article is included as long as it has a PMID and a title. This
is the bulk of the implementation work and the primary test target.

## Data shapes

```zig
pub const Article = struct {
    pmid: []const u8,
    title: []const u8,
    authors: []const u8,   // pre-joined "Smith J, Doe A, et al."
    journal: []const u8,
    year: []const u8,
    doi: []const u8,
    abstract: []const u8,
};

pub const Options = struct {
    max_results: usize = 10,   // clamped to 1..=20 by callers
    tool_name: []const u8 = "wispterm",
};

pub const Results = struct {
    arena: std.heap.ArenaAllocator,
    items: []Article,
    pub fn deinit(self: *Results) void { self.arena.deinit(); }
};
```

## Keyword splitting (the model's job)

Two text touch-points instruct the model to translate/decompose academic
questions into English keywords + boolean operators **before** calling:

- The `pubmed` tool **description** in `forEachToolSpec`
  (`ai_chat_protocol.zig`).
- A line in `platform/agent_prompt.zig` (the live agent system prompt — note
  `prompt.md` is NOT the live prompt).

The tool itself does no splitting; it passes `term=<query>` straight to esearch.

## Entry points

### Agent tool `pubmed`
- Registered in `forEachToolSpec` (`ai_chat_protocol.zig`) and dispatched in
  `ai_chat_tools.zig`.
- Params: `query` (required string), `max_results` (optional integer, default
  10, max 20).
- Read-only → **no approval gate** (same as `websearch`).
- Output via `formatForAgent`: numbered entries with title, authors, journal,
  year, PMID, DOI, and the **full** abstract.

### User command `$pubmed <query>`
- Add `pubmed` to the `WebCommand` enum, `reserved_web_commands` (for the `$`
  dropdown), and `parseWebCommand` in `ai_chat_composer.zig`.
- Background job in `ai_chat.zig` / `ai_chat_request.zig` mirroring
  `$websearch`: runs off the UI thread, appends a local tool message with the
  result (no AI turn).
- Output via `formatForUser`: title, authors, journal, year, PMID, DOI with a
  **truncated** abstract (keep the transcript readable).

## Error handling

Mirror `web_search.zig`:
- threadlocal error-detail buffer + `setErrorDetail` / `errorDetail`,
- `errorText(err)` and `formatErrorText(allocator, err)`,
- error set mapped to friendly text: `MissingQuery`, `Network`, `HttpStatus`,
  `ParseFailed`, and `NoResults` ("No PubMed results for: <query>").

Network/transport errors are captured with detail the way `web_search` does
(timeout, DNS, TLS, refused, …), keyed to the eutils host.

## Testing (TDD)

All pure functions get unit tests:
- `buildEsearchUrl` / `buildEfetchUrl` — query escaping, retmax, joined ids,
  `tool=` param.
- `parseEsearchPmids` — JSON `idlist` → `[]PMID`; empty / missing handled.
- `parseEfetchXml` — XML → `[]Article`, using real PubMed sample XML; covers
  multi-`AbstractText` (labeled sections), missing DOI, missing abstract,
  multiple authors + `et al`. The meatiest tests.
- `formatForAgent` / `formatForUser` — fields present, abstract full vs
  truncated, empty-results message.
- `errorText` mapping.

`executeSearch` is tested only for no-network early returns (empty query →
`error.MissingQuery`). The two live HTTP calls are not exercised in tests.

## Files touched

- `src/pubmed.zig` — **new** pure core + `executeSearch` + tests.
- `src/ai_chat_protocol.zig` — add `pubmed` to `forEachToolSpec`; add a
  tool-set test.
- `src/ai_chat_tools.zig` — import `pubmed`; dispatch `pubmed` call →
  `pubMedTool`.
- `src/ai_chat_composer.zig` — `WebCommand.pubmed`, `reserved_web_commands`
  entry, `parseWebCommand`.
- `src/ai_chat.zig` — `WebCommand` dispatch arm + `startPubMedRequest`
  background job + append-result helper.
- `src/ai_chat_request.zig` — `$pubmed` background worker (mirror `$webread` /
  `$websearch`).
- `src/platform/agent_prompt.zig` — keyword-decomposition guidance line.
- Test registration (`src/test_main.zig` / `src/test_fast.zig`) if needed so
  `pubmed.zig` tests run in the suites.

## Out of scope / deferred

- `pubmed-api-key` config (rate-limit boost).
- MeSH term auto-expansion or field-tag UI.
- Caching of results.
- Non-PubMed databases (PMC full text, other E-utilities dbs).
