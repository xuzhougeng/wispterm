# Built-in Phantty Docs Tool (`phantty_docs`) — Design

Date: 2026-05-27
Status: Approved (pending implementation plan)

## Problem

Users want to ask the in-terminal AI agent questions about Phantty itself
("how do I configure X", "what shortcut does Y", "how does the AI agent
work"). Today the agent has no knowledge of Phantty's own documentation, and
the rich docs in `docs/*.md` are not shipped with release binaries (only
`plugins/skills/` is bundled).

We must NOT load the documentation into the system prompt — the prompt is
deliberately tiny (a test enforces `DEFAULT_SYSTEM_PROMPT.len < 1600`). Instead
the prompt should contain only a short pointer telling the agent where to find
the docs, and the agent reads them on demand.

## Goal

Add a dedicated agent tool, `phantty_docs`, that lets the agent list and read
Phantty's user-facing documentation on demand. The system prompt gains exactly
one short hint line; documentation content never sits in the prompt.

## Non-goals (YAGNI)

- Developer-internal docs (`architecture.md`, `development.md`,
  `decoupling-guide.md`) — out of scope; user-facing only.
- Localization: the embedded docs are English. If a user asks in another
  language, the model reads the English doc and answers in that language. We do
  not embed `.zh` variants (the `.md` docs have no `.zh` variants anyway).
- Fuzzy / partial topic matching.
- Runtime doc reloading from disk — docs are embedded at build time.

## Architecture

### 1. New module: `src/phantty_docs.zig`

- Uses `@embedFile` at build time to embed the five user-facing docs (paths
  relative to the source file):
  - `../docs/faq.md`
  - `../docs/configuration.md`
  - `../docs/ai-agent.md`
  - `../docs/file-explorer.md`
  - `../docs/media.md`
- Embedding means the docs auto-sync whenever those files are edited and work
  inside a standalone `phantty.exe` with no docs present on disk.
- A static, comptime-known table of entries:
  `{ name: []const u8, summary: []const u8, content: []const u8 }`.
  - `name` — topic key the agent passes (e.g. `faq`, `configuration`,
    `ai-agent`, `file-explorer`, `media`).
  - `summary` — a hand-written one-line description (rarely changes).
  - `content` — the embedded markdown (live).
- Public API:
  - `pub const topics: []const Topic` — the table.
  - `fn listTopics(allocator) ![]u8` — builds a human/model-readable list of
    `name — summary` lines, plus a trailing usage hint
    ("Call phantty_docs with a topic to read it.").
  - `fn readTopic(name: []const u8) ?[]const u8` — returns the embedded content
    for an exact-match topic name, or `null` if unknown.

Proposed summaries (hand-written):

| topic           | summary                                                        |
|-----------------|----------------------------------------------------------------|
| `faq`           | Common questions and troubleshooting.                          |
| `configuration` | Config file location, options, keybindings, clipboard behavior.|
| `ai-agent`      | AI chat/agent usage: profiles, providers, skills, exports.     |
| `file-explorer` | Built-in file explorer usage.                                  |
| `media`         | Displaying images/media in the terminal.                       |

(Summaries are confirmed/adjusted against each doc's actual H1 + intro during
implementation.)

### 2. Tool declaration: `src/ai_chat_protocol.zig`

Add `phantty_docs` to BOTH schema builders so it is offered under both
provider protocols:

- `toolSchema(...)` — OpenAI-compatible Chat Completions block.
- `responseToolSchema(...)` — OpenAI Responses API block.

Tool spec:

- name: `phantty_docs`
- description: `"Read Phantty's own documentation (features, configuration,
  shortcuts, AI agent, file explorer, media). Call with no topic to list
  available topics, then call again with a topic to read its full text."`
- parameters JSON:
  `{"topic":{"type":"string","description":"Topic name from the list. Omit to list available topics."}}`

### 3. Tool dispatch: `src/ai_chat.zig`

Add a branch alongside the existing `if (std.mem.eql(u8, call.name, "..."))`
handlers (near the `terminal_list` dispatch, ~line 3030):

- Parse optional `topic` from `call.arguments`.
- Empty / missing `topic` → return `phantty_docs.listTopics(...)` output as the
  tool result.
- Non-empty `topic`:
  - `readTopic(topic)` hit → return the embedded content as the tool result.
  - miss → return an error-style result: `"Unknown topic \"<topic>\". Available
    topics: <list of names>."`
- The result is recorded as a tool message like the other tool handlers (reuse
  the existing tool-result message construction path).

### 4. System-prompt hint: `src/platform/agent_prompt.zig`

Add one line to the shared tool guidance (the `common_tools_*` section so it
appears for Windows, macOS, and POSIX prompts):

> `- For questions about Phantty itself (features, config, shortcuts), call \`phantty_docs\` to list and read the built-in docs.`

- Mirror the same line into `src/prompt.md` (the documentation copy of the
  prompt) to keep them consistent.
- If adding the line pushes `DEFAULT_SYSTEM_PROMPT` past the existing
  `< 1600` length assertion, bump that threshold in the corresponding test to a
  value that still guards against unbounded growth (e.g. `< 1800`).

## Data flow

1. User asks the agent a Phantty question.
2. Prompt hint makes the model call `phantty_docs` (no topic).
3. Dispatch returns the topic list.
4. Model calls `phantty_docs` with the relevant topic.
5. Dispatch returns the embedded markdown.
6. Model answers from that content.

## Error handling

- Unknown topic → explicit tool result naming the bad topic and listing valid
  ones (lets the model self-correct without an extra round trip to list).
- Malformed/empty `arguments` JSON → treated as "no topic" → list topics.

## Testing

- `phantty_docs` module:
  - `listTopics` output contains all five topic names and is non-empty.
  - `readTopic` returns non-empty content for each known topic.
  - `readTopic` returns `null` for an unknown topic.
- Tool schema (`ai_chat_protocol.zig`): generated Chat Completions JSON and
  Responses JSON both contain `"phantty_docs"`.
- System prompt: `DEFAULT_SYSTEM_PROMPT` contains `phantty_docs`; length stays
  under the (possibly bumped) cap.
- Dispatch (`ai_chat.zig`): a `phantty_docs` call with no topic yields a result
  listing topics; a call with a known topic yields that doc's content; an
  unknown topic yields the error-style result.

## Decisions made (not asked)

- Single tool with an optional `topic` param, rather than separate `list` and
  `read` tools — keeps the tool count low and matches the natural
  list-then-read flow.
- Hand-written one-line summaries for the topic list, rather than
  auto-extracting each doc's first heading — simpler and stable; doc bodies
  still auto-sync via embedding.
