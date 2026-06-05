# Agent file-edit tools (local + remote SSH) — Design

Date: 2026-06-05
Branch: `worktree-feat-agent-file-edit`
Status: Approved (brainstorming complete), pending implementation plan.

## Problem

The AI agent has no first-class file read/write/edit tools. Today it edits
files indirectly by running shell commands in a terminal surface
(`local_command_exec`, `ssh_session_exec`): `cat >`, `sed`, here-docs, or by
driving an editor REPL. That is fragile (quoting, sentinel parsing, terminal
corruption), opaque (no diff shown), and unreliable for precise edits.

Goal: give the agent dedicated `read_file` / `write_file` / `edit_file` tools
that work uniformly on **local files** and **files on a remote SSH server**,
like opencode / codex / auto-coder, integrated with the existing file-access
guard and approval UI.

## Decisions (from brainstorming)

1. **Edit interface:** Read + Write + Edit trio with exact unique-match string
   replacement (Claude Code / opencode style). NOT a codex-style `apply_patch`
   envelope.
2. **Remote target:** addressed by `surface_id`. If it resolves to an SSH
   surface, the op runs out-of-band on that host reusing the surface's
   connection; otherwise local. Consistent with the existing surface model
   (`terminal_select` / `ssh_session_exec`), no new auth path.
3. **Approval model:** reuse the existing file-access guard
   (`ai_agent_access.zig`: allow/deny + 3-level confirm/auto/full). Reads run
   the read gate (deny blocks); writes/edits run the write gate via
   `approvalRequiredForGate`. When a prompt is required, show a diff.
4. **Diff display:** render the unified diff in the chat transcript (scrollable)
   and keep the existing compact approval card referencing it.

## Tools

Defined once in `forEachToolSpec` (`ai_chat_protocol.zig`) so they fan out to
all three protocol emitters (OpenAI chat-completions, OpenAI responses,
Anthropic). Dispatched by name in `executeToolCall` (`ai_chat_tools.zig`).

| Tool         | Schema                                                                    |
|--------------|---------------------------------------------------------------------------|
| `read_file`  | `{path (req), surface_id?, offset?, limit?}`                              |
| `write_file` | `{path (req), content (req), surface_id?}`                                |
| `edit_file`  | `{path (req), old_string (req), new_string (req), replace_all?, surface_id?}` |

- `offset` = 1-based start line, `limit` = max lines (both optional; default
  reads from the top up to the size cap).
- **Local vs remote:** `surface_id` omitted, or resolving to a local/WSL
  surface, → local filesystem. Relative paths resolve against
  `ctx.settings.working_dir`. `surface_id` resolving to an SSH surface → remote
  op over that surface's connection, out-of-band (a fresh SSH like `scp.zig`
  already does — never typed into the live terminal).

## Components

### 1. Pure logic module — `agent_file_edit.zig` (no IO, fully unit-tested)

- `applyEdit(content, old_string, new_string, replace_all) -> EditOutcome`:
  exact match. Error on **0 matches** ("string not found") and on **>1 matches
  without `replace_all`** ("string not unique"). Returns new content +
  occurrence count.
- `sliceLines(content, offset, limit)` + `cat -n`-style numbered formatting for
  `read_file` output (so the model can locate edit anchors).
- `unifiedDiff(path, old, new) -> []u8`: minimal unified diff for the transcript.
- Guards: max read size (~256 KiB) / line cap; binary detection (NUL byte) →
  refuse with guidance; UTF-8 assumed.

### 2. Transport + host seam

- **Local:** `std.fs` read/write. Writes atomic: write a temp file in the same
  directory, then rename over the target.
- **Remote:** out-of-band SSH via `scp.zig`, reusing the surface's
  `SshConnection`. Read = `cat --`. Write = pipe content to a temp path then
  `mv` (atomic). Edit = read-modify-write (read remote, `applyEdit` in memory,
  write back).
- **One new `ToolHost` callback:**
  `surfaceFileTarget(surface_ptr) -> union(enum){ local, ssh: SshConnection }`,
  implemented in the AppWindow/Session host. Only invoked when a `surface_id` is
  supplied; the pure module never sees connection details beyond what `scp.zig`
  needs.

### 3. Safety / approval (reuses existing guard)

A new **path-aware** gate runs the resolved path (not a command string) through
`ai_agent_access` allow/deny + `workdirConfined`:

- `read_file` → read gate: deny-list blocks; otherwise free.
- `write_file` / `edit_file` → write gate via existing
  `approvalRequiredForGate(permission, gate)`:
  - **confirm** → always prompt.
  - **auto** → prompt only when risky (outside `working_dir` / dotfile / system
    path / deny-list); otherwise apply.
  - **full** → apply without prompt; deny-list still blocks.
- "risky" reuses `workdirConfined` (confined = safe) plus a dotfile / system-path
  check.

### 4. Diff in transcript + compact card

Before an edit/write applies, the unified diff is surfaced in the transcript
(scrollable, reusing existing transcript rendering). The approval card stays
compact: e.g. `Apply edit to <path> (+A -D)?  [Approve] [Deny]`.

Implementation detail (to settle in the plan): tools currently only return a
result string, so surfacing the diff **before** the card needs either a small
optional `ApprovalView.diff` field or a transcript-note callback on
`ToolContext`. Pick the lighter option.

### 5. Prompt & docs

- Brief `prompt.md` guidance: prefer file tools over `cat`/`sed` for editing.
- Update the `wispterm_docs` AI-agent topic and keep `docs/` <-> `wiki/` in sync
  (repo convention: 6 `docs/*.md` are `@embedFile`'d for the in-app docs tool).

## Testing (TDD)

- Pure module: `applyEdit` (0 / 1 / many matches, `replace_all`, multiline,
  CRLF), `sliceLines`, `unifiedDiff`, binary + oversize refusal.
- Gate mapping: read vs write, confirm/auto/full, confined vs risky, deny-list.
- Schema presence: each tool appears in all three protocol emitters.
- Remote transport: a fake host returning a stub `SshConnection`, capturing the
  SSH command string (read = `cat`, write = temp + `mv`).

## Out of scope (YAGNI)

- `apply_patch` / multi-file diff envelope.
- Directory-listing / file move / delete tools (shell already covers these).
- Git integration, syntax-aware edits.
