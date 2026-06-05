# `$websearch` (Jina Search, pluggable engines) Design

## Goal

Add web search to the AI chat, exposed two ways:

1. **`$websearch <query>` user command** — typed in the chat composer. WispTerm runs
   the search itself and renders the raw results into the transcript. No AI turn.
2. **`websearch` agent tool** — the AI model calls it on its own when it needs current
   information. Returns results (including page content) to the model.

The search backend is provider-agnostic so other engines can be added later, but the
only engine implemented now is **Jina** (`s.jina.ai`). A future engine is a new branch
in one `switch`, nothing more.

## Architecture

A new module `src/web_search.zig` owns everything search-specific: the engine enum, the
result types, the pure request-building / response-parsing / formatting logic, and the
single impure HTTP function. Both entry points (the `$websearch` command and the agent
tool) call into this module; neither knows anything about Jina directly.

The `$websearch` command runs on a background thread that reuses the existing AI-request
lifecycle so it inherits the proven cancellation/teardown guarantees (the worker re-checks
`session.closing` under the session lock before touching the transcript). The agent tool
runs synchronously inside the existing tool worker thread, like every other tool.

```
ai_chat_composer.parseWebCommand ──► ai_chat (spawn bg job) ─┐
                                                             ├─► web_search.executeSearch ─► Jina HTTP
ai_chat_protocol.forEachToolSpec ──► ai_chat_tools.executeToolCall ─┘
```

## `src/web_search.zig`

### Types

```zig
pub const Engine = enum { jina };   // future engines added here

pub const SearchResult = struct {
    title: []const u8,
    url: []const u8,
    description: []const u8,
    content: ?[]const u8 = null,    // only when with_content == true
};

pub const Options = struct {
    engine: Engine = .jina,
    api_key: []const u8,
    with_content: bool,             // false = snippets, true = full page content
    max_results: usize = 10,
};

pub const Results = struct {        // owns its backing memory via an arena
    arena: std.heap.ArenaAllocator,
    items: []SearchResult,
    pub fn deinit(self: *Results) void;
};
```

### Pure functions (no network — unit tested)

- `buildJinaRequestBody(allocator, query) ![]u8` → `{"q":"<query>"}` (query JSON-escaped).
- `parseJinaResponse(arena, json_bytes) ![]SearchResult` → reads the `data[]` array of
  `{title, url, description, content?}`. Tolerates missing optional fields; caps at
  `max_results`. Uses `parseFromSlice` with `.allocate = .alloc_always` because the source
  buffer is freed before the parsed value is used (see the parseFromSlice alias UAF note).
- `formatForUser(allocator, query, results) ![]u8` → numbered markdown list for the
  transcript: `N. **title**` / `url` / `description`. Header line echoes the query and the
  result count. Snippets only (no `content`).
- `formatForAgent(allocator, query, results) ![]u8` → compact text block per result
  including `content` when present, sized for the model's context.

### Impure function

- `executeSearch(allocator, query, opts) !Results`
  - `switch (opts.engine)` → currently `.jina => searchJina(...)`.
  - `searchJina`: `POST https://s.jina.ai/` via `std.http.Client.fetch` with headers
    `Authorization: Bearer <api_key>`, `Content-Type: application/json`,
    `Accept: application/json`, and `X-Respond-With: no-content` when
    `opts.with_content == false`. Body is `buildJinaRequestBody`. On a non-`ok` status it
    returns `error.SearchHttp` carrying the trimmed body for the caller to surface; on a
    transport failure it returns the underlying error.

### Config key plumbing

`web_search.zig` holds a module-level Jina key (fixed buffer + length, mirroring
`ai_chat.g_default_working_dir_*`), set by:

```zig
pub fn setJinaApiKey(key: []const u8) void;   // called from the config-apply path
pub fn jinaApiKey() []const u8;               // "" when unset
```

Both entry points read `jinaApiKey()`; an empty key short-circuits with a clear message
("Jina API key not set — add `jina-api-key = <key>` to your WispTerm config.") and never
hits the network.

## Config: `jina-api-key`

In `src/config.zig`:

- New field `@"jina-api-key": []const u8 = ""`.
- Parse in `applyKeyValue` (dupe like `ai-agent-working-dir`).
- Allow in `setConfigValue`.
- `--help` line and a commented sample in the generated default config.

In the existing config-apply path (alongside `ai_chat.setDefaultWorkingDir(cfg.…)` in
`AppWindow`/`App`), add `web_search.setJinaApiKey(cfg.@"jina-api-key")` so live config
reloads update the key.

Decisions (locked): config-file only — **no** `JINA_API_KEY` env fallback, **no**
per-profile key.

## `$websearch` user command

### Composer (`src/ai_chat_composer.zig`)

- Add a `WebCommand = enum { websearch }` and `parseWebCommand(input) ?WebCommand` that
  matches a leading `$websearch` token (trimmed; rejects bare `$`, `$foo`, etc.).
- Add a single `$websearch` suggestion so typing `$` surfaces it, mirroring the existing
  slash-suggestion data (one entry — not a general `$`-command framework).
- Add a `firstCharKind` / prefix branch for `$` so the suggestion popup triggers.

### Dispatch (`src/ai_chat.zig`)

- In the submit path (where `parseSlashCommand` is checked, ~line 1619), detect
  `parseWebCommand`. Extract the query = text after the command token, trimmed.
  - Empty query → append a usage tool message (`Usage: $websearch <query>`); no network.
  - Otherwise: set status "Searching the web…", clear the submitted input, and spawn a
    background search job carrying an owned copy of the query.
- The job reuses the existing background-request lifecycle. Concretely: a
  `webSearchThreadMain(req)` worker (sibling to `titleThreadMain`/`distillThreadMain`)
  that owns its request, calls `web_search.executeSearch(..., with_content=false)`, then
  on success calls a new `pub fn appendWebSearchResult(session, text)` and on failure a
  `pub fn appendWebSearchError(session, msg)`. Both mirror `appendAssistantResult`:
  bail if `session.closing`, take the lock, append a local tool message, set status
  "Ready", notify the history change. This is what makes the result show up in the
  transcript as raw text with no assistant turn.

## Agent `websearch` tool

### Schema (`src/ai_chat_protocol.zig`)

One new `emit(...)` line in `forEachToolSpec` (single source of truth → all three
protocols):

- name: `websearch`
- description: "Search the web for current information via Jina. Returns the top results
  with titles, URLs, and page content. Use when you need facts newer than your training or
  to look something up online."
- properties: `{"query":{"type":"string"},"max_results":{"type":"integer"}}`

### Dispatch (`src/ai_chat_tools.zig`)

- New branch in `executeToolCall` for `"websearch"`: parse `query` (required) and optional
  `max_results`; call `web_search.executeSearch(..., with_content=true)`; return
  `formatForAgent`. Missing key / empty query / HTTP error → return a clear message string
  (tools return error text, they do not throw).
- **No approval gate** (read-only network fetch) — runs unprompted at every permission
  level.

## Errors

Each surface produces a specific, user-readable message; none logs the API key:

- Jina API key not set.
- Empty query (command usage hint; tool "query is required").
- HTTP non-200 from Jina (status + trimmed body).
- Network/transport failure.
- Zero results ("No results for: <query>").

## Testing

Pure tests in `web_search.zig`, registered in the fast suite (import in
`test_fast.zig`/`test_main.zig` so they actually run):

- `parseJinaResponse` on captured sample JSON (with and without `content`); missing
  optional fields; `max_results` cap; empty `data[]`.
- `buildJinaRequestBody` escapes a query containing quotes.
- `formatForUser` (snippets, no content) and `formatForAgent` (includes content) shape.
- Empty-key short-circuit path.

Composer test in test-full: `parseWebCommand` accepts `$websearch foo bar`, extracts the
query, and rejects `$`, `$websearchx`, `/websearch`, and plain text.

No live network in tests — the Jina HTTP path is exercised only against captured JSON.

Implement with TDD. Run `zig build test`; run `zig build test-full` before finishing.

## Scope guards (YAGNI)

- Only the `jina` engine.
- Config-file key only; no env var, no per-profile key.
- User command shows snippets only — no AI summarization turn.
- Autocomplete is a single `$websearch` entry, not a general `$`-command system.
- No result caching, no pagination, no rerank/reader (`r.jina.ai`) integration.
