# Enhance Copilot's Claude Code / Codex Capability — Design

Date: 2026-06-09
Branch: `worktree-feat-enhance-copilot`

## Problem

When the user asks the Copilot (副驾) to drive a Claude Code or Codex session
running in a terminal surface — e.g. "帮我点确认" (help me click confirm) — the
Copilot cannot see the live interactive prompt and ends up blindly guessing
keystrokes (`y`, `Yes`, `1`, `<enter>`), often the wrong ones.

### Root cause

The terminal snapshot is built **scrollback-history first, active screen last**
(`src/remote_snapshot.zig:32-37`), so the live interactive screen — where the
"Do you want to proceed? ❯ 1. Yes / 2. No" prompt lives — is at the **bottom**
of the snapshot text. Up to `default_max_history_rows = 10_000` rows of
scrollback can precede it.

The tool-output truncator keeps the **head**:

```zig
// src/ai_chat_tools.zig:2317
fn truncateOwned(allocator, settings, text) ![]u8 {
    const limit = settings.output_limit;      // default 16 KB
    if (text.len <= limit) return text;
    // keeps text[0..limit] — the OLDEST bytes — drops the tail
    ...
}
```

So once a Claude Code / Codex session accumulates more than ~16 KB of scrollback
(a few screens of conversation), the snapshot returned to the model is the
**oldest 16 KB**, and the bottom — the live prompt — is silently cut off. This
is exactly the "snapshot 始终被截断看不到最新画面" symptom in the screenshots.

## Goals

1. **Visibility (root cause):** the Copilot's terminal snapshot always shows the
   live interactive screen, never truncates it away.
2. **Guidance:** the prompt tells the Copilot where the live screen is and how to
   answer Claude Code / Codex confirmation prompts — and to never blind-press
   keys when it cannot see the current screen.
3. **Dedicated confirmation tool:** a `terminal_answer_prompt` tool that reads
   the on-screen options of a Claude Code / Codex approval prompt and sends the
   correct keystroke for a semantic answer (approve / approve_all / reject / a
   specific option), instead of the model improvising raw keystrokes.

## Non-goals

- Changing the WeChat remote-snapshot path (`reply_progress` /
  `allocRemoteSnapshot`), which has its own priority budgeter (issue #118). The
  changes here must not regress it.
- Changing shell-command (`local_command_exec` / `*_session_exec`) output
  truncation, where the **beginning** of the output is usually the relevant part.
- Full TUI parsing / arrow-key navigation. The confirmation tool selects options
  by their number/shortcut key, which both apps accept as select-and-confirm.

## Design

Three independent, separately-testable pieces.

### Component 1 — Visibility fix

Fix in two places so no single edge case (huge scrollback **or** one oversized
active screen) can hide the live screen.

**1A. Tail-biased snapshot builder** (`src/remote_snapshot.zig`)

Add a builder that **always includes the full active screen**, then back-fills
the most recent scrollback rows up to a small budget (instead of dumping up to
10 000 rows oldest-first). Concretely:

- Introduce `agent_max_history_rows` (≈400) for the agent / live snapshot path,
  far smaller than the existing `default_max_history_rows = 10_000`.
- The active-screen rows are emitted unconditionally; history is capped to the
  most-recent `agent_max_history_rows` rows (the existing `history_start` math
  already takes the most-recent slice — only the cap shrinks).
- `default_max_history_rows` is left intact for any caller that still wants the
  full history; the agent path (`buildRemoteSurfaceSnapshot` →
  `agentSurfaceSnapshot` / `collectAgentToolSnapshot` per-surface `.snapshot`,
  and `activeSurfaceSnapshot`) passes the smaller cap.

Net effect: in the common case the snapshot is well under 16 KB and never gets
truncated at all, and the bottom-of-buffer live screen is always present.

**1B. Tail-keeping truncation** (`src/ai_chat_tools.zig`)

Add `truncateTailOwned(allocator, settings, text)`: when `text.len > limit`,
keep the **last** `limit` bytes and prepend a marker line
`...[older output truncated to N bytes]\n`.

Switch the snapshot-bearing return paths from `truncateOwned` to
`truncateTailOwned`:

- `terminalSnapshotTool` (`ai_chat_tools.zig:539`)
- `sendControlKey` result (`ai_chat_tools.zig:1112`)
- REPL / agent-app result paths that return a trailing "Latest snapshot:"
  (`plainReplInputTool` tail, `waitForAgentAppReplResult`, the input-sent path
  at `ai_chat_tools.zig:1204`)

`truncateOwned` is retained unchanged for shell-command output.

> Note: for a header+snapshot string (e.g. `"Sent <enter>...\nLatest
> snapshot:\n<body>"`), tail-truncation keeps the snapshot body (the important
> part) and may drop the header prefix; the marker makes that explicit. This is
> the desired trade-off — the live screen matters more than the echoed header.

### Component 2 — Prompt guidance

In `src/platform/agent_prompt.zig`, add a clause (applies on every OS, included
in the shared `posix_prompt` body so macOS/Windows inherit it):

- The terminal snapshot shows the **live interactive screen at the bottom** —
  read the bottom rows to find the current prompt/state.
- To answer a Claude Code / Codex approval menu, use `terminal_answer_prompt`.
- **Never blind-press keys when you cannot see the current screen.** If the
  snapshot looks truncated or stale, re-read with `terminal_snapshot` first.

A test asserts the new guidance string is present on every OS (mirroring the
existing `agent_prompt` tests).

### Component 3 — `terminal_answer_prompt` tool

**Pure module `src/agent_prompt_answer.zig`** (mirrors `agent_detector.zig`;
fully unit-tested, no I/O):

```zig
pub const Option = struct {
    number: u8,            // 1-based option number as shown, 0 if unnumbered
    highlighted: bool,     // line carried a ❯ / > selection marker
    shortcut: ?u8,         // letter in parens, e.g. (y) / (a) / (n)
    label: []const u8,     // trimmed option text
};

pub const Intent = enum { approve, approve_all, reject, enter, esc, option };

pub const Keystroke = struct {
    bytes: []const u8,         // e.g. "1", "y", "\x1b"
    confirm_enter: bool,       // follow with a delayed <enter> (Codex "Press enter to confirm")
};

pub fn parsePromptOptions(screen: []const u8, out: []Option) usize;  // returns count
pub fn resolveAnswer(options: []const Option, screen: []const u8, intent: Intent, option_number: u8) ?Keystroke;
```

Parsing rules:
- An option line matches optional leading `❯`/`>` marker, then `N.` (or `N)`),
  then label; capture a trailing `(x)` shortcut letter if present.
- Inline `[y/N]` / `[Y/n]` style prompts are recognized: `approve` → `y`,
  `reject` → `n`, honoring the capitalized default for bare `enter`.

Answer → keystroke resolution:
- `approve` → the first affirmative option whose label starts with "yes" and does
  **not** contain "all" / "don't ask" / "session" → send its number key.
- `approve_all` → the option whose label contains "all" or "don't ask" → its number.
- `reject` → send `<esc>` (universal cancel in both apps); fall back to the "no"
  option number if no esc-able prompt is detected.
- `option` → send `option_number`'s digit key.
- `enter` / `esc` → send that key directly.
- `confirm_enter` is set when the screen contains "press enter to confirm"
  (Codex), so the tool sends the digit, pauses `CODEX_SUBMIT_DELAY_MS`, then Enter.

**Tool wiring** (`src/ai_chat_tools.zig` + schema in `src/ai_chat_protocol.zig`):

`terminalAnswerPromptTool(ctx, surface_id, answer)`:
1. Resolve the surface (default = focused terminal, same as other tools).
2. Read the **live** screen via `host.surfaceSnapshot`.
3. Use `agent_detector.detect(title, screen)` to confirm it is `claude_code` or
   `codex`. If it is **not** in `waiting_approval` / `needs_input`, do **not**
   send anything — return what is on screen plus a note that no prompt is
   awaiting an answer (no blind guessing).
4. `parsePromptOptions` + `resolveAnswer`. If the answer cannot be resolved to a
   concrete key, return the parsed options and ask the model to pass an explicit
   option number — still no blind key.
5. Send the keystroke(s) through the existing `host.writeSurface` path (reusing
   `sendControlKey` semantics for `<esc>`/`<enter>`), wait briefly, re-read, and
   return the resulting live screen (via `truncateTailOwned`).

Approval gating mirrors `terminal_repl_exec`: the payload is a single
selector key (`1`/`y`/esc), not a destructive command string, so under `auto`
it is not gated and under `confirm` it prompts the operator — consistent with
existing REPL-input gating.

Schema (added to `appendCommonToolSchemas` in `ai_chat_protocol.zig`):

```
terminal_answer_prompt — Answer a Claude Code or Codex confirmation/approval
prompt in a terminal surface. Reads the on-screen options and sends the right
keystroke. Use this instead of terminal_repl_exec to confirm/reject an agent
approval menu.
  surface_id: optional, defaults to the focused terminal
  answer: "approve" | "approve_all" | "reject" | "enter" | "esc" | a digit "1".."9"
```

## Data flow

```
user: "帮我点确认"
  -> Copilot calls terminal_answer_prompt(answer="approve")
     -> read live screen (tail-biased, full active screen visible)
     -> agent_detector: claude_code, waiting_approval ✓
     -> parsePromptOptions -> [ {1,❯,Yes}, {2,_,allow all}, {3,_,No (esc)} ]
     -> resolveAnswer(approve) -> key "1"
     -> writeSurface("1") -> wait -> re-read
     -> return resulting screen (Claude Code now running)
```

## Error handling

- No matching surface → existing `allocNoSurfaceError`.
- Surface is not Claude Code / Codex, or not awaiting input → return the live
  screen + "no prompt awaiting an answer"; send nothing.
- Answer unresolvable against on-screen options → return parsed options + guidance
  to pass an explicit option number; send nothing.
- `writeSurface` fails → existing "Failed to write to terminal surface." message.

## Testing

- `remote_snapshot`: tail-biased builder includes the full active screen and only
  the most-recent `agent_max_history_rows` of scrollback; with a huge scrollback,
  the active-screen content is present and the oldest history is dropped.
- `truncateTailOwned`: over-limit input keeps the tail + marker; under-limit input
  is returned unchanged.
- `agent_prompt_answer`: `parsePromptOptions` against the real Claude Code and
  Codex prompt strings from `agent_detector.zig` tests; `resolveAnswer` for
  approve / approve_all / reject / explicit number / `[y/N]` inline; Codex
  "press enter to confirm" sets `confirm_enter`.
- `agent_prompt`: guidance clause present on every OS.
- Tool-level: `terminalAnswerPromptTool` against a mock host that reports a
  waiting-approval screen → sends the expected key and returns the settled screen;
  a non-prompt screen → sends nothing.

Both suites (`zig build test`, `zig build test-full`) must stay green; the new
pure modules register in `test_main.zig`.

## Risks

- Reducing the agent-path history cap could hide context the model wanted from
  far up the scrollback. Mitigation: the active screen is always complete, the
  cap (≈400 rows) still covers several screens, and the model can re-run
  `terminal_snapshot` (or read the file) for deeper history.
- Prompt-string parsing is heuristic and apps change their wording. Mitigation:
  the parser is generic (marker + `N.` + label) rather than wording-specific, and
  reuses `agent_detector`'s already-maintained phrase lists for the gate.
