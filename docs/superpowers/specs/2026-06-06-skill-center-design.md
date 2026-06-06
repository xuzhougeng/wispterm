# Skill Center Design (技能中心)

**Date:** 2026-06-06
**Status:** Approved design, pending implementation plan
**Branch:** `worktree-feat-skill-center`

## Goal

Add a centralized, cross-server **Skill Center** panel to WispTerm. As the
number of managed servers grows, the user needs one place to inventory the
Claude Code / Codex *skills* that live on each machine — to see which skills a
server has, which it is missing, and whether the version matches the others.

**v1 scope is read-only inventory.** A single aggregate matrix (skill × server)
shows presence and version-consistency at a glance, with SKILL.md preview. The
later operations the user described — pull/import, push/distribute, two-way
sync — are explicitly **out of scope for v1** and will each get their own
spec → plan → implementation cycle. The v1 scanner + matrix model is the
foundation those phases build on.

This panel is a sibling of the existing **Sessions / AI History** browser
(`src/ai_history_*`): same multi-source (local / WSL / SSH) reach, same
pure/impure layering, but it inventories *skills* instead of *conversation
history*.

## Context

### Existing skill infrastructure (reused)

- **`src/skill_registry.zig`** — parses a `SKILL.md` (YAML-ish frontmatter:
  `name`, `description`), lists skills under a `skills/` root, and produces a
  deterministic `Snapshot` with a content hash. v1 reuses its frontmatter
  parsing for the local Claude Code path and its `loadSkillSnapshot` for
  preview content.
- **`src/skill_update.zig`** — pulls WispTerm's own bundled skills from GitHub
  into `<config>/plugins/skills`. Not used by Skill Center, but confirms the
  SKILL.md conventions.
- **`src/ai_chat_skills.zig`, `src/ai_skill_distill.zig`** — in-app skill
  invocation/distillation. Out of scope.

### Existing multi-source read pattern (the template)

The Sessions / AI History browser already solves "reach many machines and read
files from each":

- **`src/ai_history_source.zig`** — `Source { id, name, target, ... }` where
  `Target = union(enum) { local, wsl: {distro}, ssh: {profile_name} }`. Sources
  are enumerated from saved SSH profiles + WSL distros + local.
- **`src/ai_history_session.zig`** — a `RemoteExecHost` seam:
  `exec(ctx, allocator, command) ![]u8`. Implementations run the command
  locally, via `remote_file.wslExec`, or via `remote_file.sshExecCapture` over
  an `ssh_connection.SshConnection`. The browser builds `find ... -name
  '*.jsonl'` / `cat` commands and runs them through this seam. Tests drive it
  with a **fake exec** that returns canned output per command string.
- **`AiHistoryScanJob`** — background worker pattern (mutex + closing +
  generation counter) that scans sources off the UI thread and streams rows
  into the model progressively.
- **`src/ai_history_cache.zig`** — persisted on-disk cache for instant reopen.

Skill Center mirrors all four: same `Source`/`Target` enumeration, same
`RemoteExecHost.exec` seam, same async scan-job shape, same persisted cache.

### File transfer (reused later, not v1)

`src/scp.zig` provides `sshReadFile` / `sshWriteFile`. v1 does **not** transfer
files (read-only inventory via shell). These are the hooks for the later
pull/push/sync phases, plus the v1 hash fallback noted below.

## What counts as a "skill"

A configurable list of `(provider, root, format)` scan targets per source.
v1 ships these defaults; the design keeps the list data-driven so more targets
can be added without structural change.

| Provider | Root (relative to `$HOME`) | Format |
|---|---|---|
| `claude` | `.claude/skills/` | `skill_md` — `<name>/SKILL.md` with frontmatter |
| `codex`  | `.codex/skills/`  | `skill_md` — `<name>/SKILL.md` (if present) |
| `codex`  | `.codex/prompts/` | `prompt_md` — flat `*.md`, filename = name |

`skill_md` format: each immediate subdirectory containing a `SKILL.md` is one
skill; `name`/`description` come from frontmatter (fallback: dir name, empty
description). `prompt_md` format: each `*.md` file is one skill; name = file
stem; description = first non-empty line / `# heading` if present. Codex's real
on-disk layout is uncertain, so the scan surfaces **whatever is found** at these
roots and silently skips roots that don't exist.

## Approaches considered (scan implementation)

| Approach | How | Trade-off | Verdict |
|---|---|---|---|
| **A. Shell via `RemoteExecHost.exec`** | One `find` + `sha256sum` pipeline per source emits `provider \t name \t rel_dir \t agg_hash \t description?` rows | Fully reuses the Sessions exec seam (local/WSL/SSH); one round trip per server; zero new connection code | **Chosen** |
| B. `scp` pull then hash locally | Pull each SKILL.md (+ files) via `scp.sshReadFile`, hash on this machine | Many round trips, slow; only virtue is not needing remote `sha256sum` | Used **only** as the per-server hash fallback (see below) |
| C. Push a helper script per server | Upload + run a helper binary/script | Most flexible but introduces remote state to manage; too heavy for inventory | Rejected |

Approach A is structurally identical to how `ai_history_session.zig` already
reaches servers, so it inherits that code's connection handling and test
harness.

## Architecture & components

Mirrors the `ai_history_*` pure/impure split.

### Pure modules (fully unit-tested)

- **`src/skill_scan.zig`** — the scan command + parser.
  - `buildScanCommand(allocator, targets) -> []u8`: emits a single POSIX shell
    snippet that, for each `(provider, root, format)` target, discovers skills
    and prints one tab-separated row per skill:
    `provider \t name \t rel_dir \t agg_hash \t b64(description)`.
    Aggregate hash = hash of the directory's file set: for a `skill_md` skill,
    `find <dir> -type f | LC_ALL=C sort | xargs -r sha256sum | sha256sum` (a
    single combined digest over `path+content` of every file). The command
    probes for `sha256sum`/`shasum -a 256` once; **if neither exists it emits
    rows with an empty `agg_hash`** (presence-only for that server). Roots that
    don't exist are skipped without error.
  - `parseScanOutput(allocator, bytes) -> []SkillRow`: parses the rows into
    `SkillRow { provider, name, rel_dir, agg_hash: ?[]u8, description }`.
    Tolerant of blank/short lines (skips them).
  - `SkillRow` carries `agg_hash` as optional: `null` = "this server could not
    hash" (drives the `?`-vs-`✓` distinction at the cell level).

- **`src/skill_inventory.zig`** — the matrix model (the heart of v1).
  - Types: `Provider = enum { claude, codex }`; `SkillKey { provider, name }`;
    `ServerId = []const u8` (the `Source.id`); `CellState = enum { match,
    differ, absent, unknown }`; `Cell { state, short_hash: ?[…] }`.
  - `ServerScan { source_id, reachable: bool, rows: []SkillRow }` — one per
    source (a row-less unreachable scan is valid).
  - `buildMatrix(allocator, servers: []ServerScan) -> Matrix`: union of all
    `SkillKey`s → sorted rows; columns = servers in source order; each cell
    computed by the rule below. Pure, deterministic, sortable, filterable.
  - `Matrix` exposes row/column iteration, a per-row summary
    (`present_count`/`total`, `uniform: bool`), and a global counts summary
    (servers, skills) for the header.

### Cell-state rule (✓ / ≠ / ✗ / ?)

Per row (one skill across all servers):

1. Collect the `agg_hash` of every server where the skill is **present and
   hashed** (non-null hash).
2. The row's **reference hash** = the most frequent such hash (modal; ties
   broken by lexicographic order for determinism).
3. For each server's cell:
   - skill **absent** → `absent` (`✗`).
   - present, server is **unreachable** OR its `agg_hash` is `null`
     (couldn't hash) → `unknown` (`?`).
   - present with hash **== reference** → `match` (`✓`).
   - present with hash **!= reference** → `differ` (`≠`).
4. If every present cell shares one hash, the whole row is uniform → all `✓`.

`unknown` (`?`) is kept strictly distinct from `absent` (`✗`): "we couldn't
check" must never read as "it's missing."

### Impure orchestration

- **Scan worker** (in `src/skill_center.zig` or a dedicated job file, mirroring
  `AiHistoryScanJob`): enumerates sources, dispatches a background scan per
  source through `RemoteExecHost.exec(buildScanCommand(...))`, parses output,
  and streams `ServerScan` results into the model under a mutex with a
  generation counter (so a stale scan's results are dropped after a refresh).
  Local source may run the same shell, or compute in-process via
  `skill_registry` + a local dir hasher — the shell path is preferred for
  parity and less code.
- **`src/skill_inventory_cache.zig`** (mirrors `ai_history_cache.zig`):
  persists the last `[]ServerScan` to `<config>` keyed by source id. On open,
  the matrix renders immediately from cache (offline servers show last-known,
  flagged **stale**), then the background rescan refreshes it.

### UI

- **`src/skill_center.zig`** — panel model + layout (mirrors `agent_history`
  panel structure): holds the `Matrix`, selection (row + column = focused
  cell), scroll, column show/hide state, scan status string
  (`Scanning… N/M`), and stale flags.
- **Render** — in the existing panel render layer, matching the Sessions
  panel's look. The matrix: rows = skill names (with `provider` tag), columns =
  servers; each cell glyph `✓ / ≠ / ✗ / ?`. A legend + header
  (`N servers · M skills`, refresh affordance).
- **Preview** — pressing Enter on a focused cell that is present runs `cat` of
  that **server's** copy of the skill's `SKILL.md` through the existing
  markdown preview (reuse `skill_registry.loadSkillSnapshot` shape / the
  Sessions preview path). Preview reads the chosen cell's server, not a
  canonical copy, so the user can inspect exactly what diverged.
- **Entry points** — a new command-center entry ("Skill Center / 技能中心") +
  a keybind, plus new i18n keys (en + zh-CN), following the Sessions panel's
  wiring.

## Data flow

1. User opens the panel (keybind or command center).
2. Panel enumerates sources: local + every WSL distro + every saved/imported
   SSH profile (same enumeration as Sessions). **All known sources auto-become
   columns**; columns can be hidden/folded in the UI.
3. Matrix renders **immediately** from `skill_inventory_cache` if present
   (offline columns flagged stale).
4. For each source, a background worker runs `buildScanCommand` through
   `RemoteExecHost.exec`, parses rows, and streams a `ServerScan` into the
   model; the header shows `Scanning… N/M`. The matrix re-aggregates as each
   server lands (progressive fill).
5. On completion the result set is written back to the cache.
6. Enter on a present cell → `cat` that server's `SKILL.md` → markdown preview.

## Error handling

- **Unreachable / offline server**: column marked **unreachable**; all its
  cells render `?`. If cache has a prior scan, fall back to last-known and flag
  the column **stale** instead of blanking it.
- **No `sha256sum`/`shasum` on a server**: that server's rows carry
  `agg_hash = null` → its present cells render `?` (presence-only); it never
  forces a false `≠`. (Chosen over the scp fallback for v1 simplicity; scp
  fallback remains a later option.)
- **Malformed / missing-frontmatter SKILL.md**: skill is still listed (name =
  dir/file stem, empty description); a parse failure for one skill never aborts
  the source's scan or the whole matrix.
- **Slow servers**: scans are async with a per-source timeout; the matrix fills
  progressively and never blocks the UI thread.
- **Stale generation**: a refresh bumps the generation counter; late results
  from a superseded scan are discarded.

## Testing

All pure modules are unit-tested; the scan is driven end-to-end with the fake
`RemoteExecHost.exec` already used in `ai_history_session` tests.

- **`skill_inventory` (matrix):** union-of-skills rows; cell states for
  match/differ/absent/unknown; the modal reference-hash rule incl. tie-break
  determinism; a fully-uniform row → all `✓`; `unknown` never collapses into
  `absent`; sorting; per-row + global summaries.
- **`skill_scan`:** `buildScanCommand` shape for `skill_md` + `prompt_md`
  targets and the `sha256sum`-absent branch (empty hash); `parseScanOutput`
  tolerance of blank/short/garbled lines; base64 description round-trip.
- **End-to-end:** a fake exec returning canned per-server output for 3–4
  servers (one offline, one without `sha256sum`, one with a diverged hash) →
  assert the resulting matrix cell states.
- **Cache:** persist + reload a `[]ServerScan`; stale-flag behavior when a
  server is offline on reopen.

## Out of scope (future specs)

- Pull/import a skill from a server into a local hub.
- Push/distribute a skill to one or many servers (`scp.sshWriteFile`).
- Two-way sync / conflict reconciliation.
- Project-level (`<project>/.claude/skills/`) and plugin skills.
- Editing skills in place.
