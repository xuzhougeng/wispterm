# Agent File-Access Guard (private allow/deny lists)

**Date:** 2026-06-03
**Branch:** `feat/agent-file-access-guard`
**Status:** Design — approved by user, pending spec review

## Problem

WispTerm's built-in AI agent can read any file on the machine. It does so not
through a structured `read_file` tool but by running ordinary shell commands
(`cat`, `head`, `less`, `xxd`, …) through the exec tools in
`src/ai_chat_tools.zig`:

- `localCommandExecTool` — commands on this machine
- `unixSessionExecTool` — `ssh_session_exec` and `wsl_session_exec`
- `terminalReplExecTool` — REPL input

We want a **private, machine-local** guard so that:

- **Deny list (blacklist):** defined paths must never be read without the user
  explicitly agreeing. Even in `full` permission mode, touching a denied path
  forces a per-command approval prompt.
- **Allow list (whitelist):** folders the user trusts can be read freely — safe
  reads confined to them skip the approval prompt even in `confirm` mode.

## Constraints & honest scope

Because reads ride on arbitrary shell command text, enforcement is a **heuristic
command-string gate**, not an OS sandbox. It scans the command for path
references and folds the verdict into the existing approval gate. This is a
strong guardrail but is bypassable by deliberate obfuscation (base64 decoding,
constructing paths from env vars at runtime, etc.). An unbypassable sandbox
(seccomp / landlock / `sandbox-exec`) is explicitly out of scope.

Rejected alternatives:

- **Structured `read_file` tool** — easy to gate, but the agent can still `cat`
  via the shell tools, so the hole stays open.
- **OS-level confinement** — truly unbypassable, but a large platform-specific
  effort; deferred.

## Architecture

### New leaf module: `src/ai_agent_access.zig`

Pure and Session-free so it registers in the **fast** test suite. The matcher
does **no filesystem access** — it resolves paths *lexically* against an injected
home directory and cwd, which keeps it deterministic and unit-testable.

Public surface:

```zig
pub const Decision = enum { neutral, blacklisted, whitelisted_safe };

pub const EvalResult = struct {
    decision: Decision,
    matched: []const u8, // borrowed slice into `command`; the path that triggered deny
};

pub const AccessRules = struct {
    allow_roots: [][]u8,   // absolute, lexically-normalized directory prefixes
    deny_roots:  [][]u8,   // absolute, lexically-normalized directory prefixes
    deny_names:  [][]u8,   // basename / glob patterns (e.g. "*.pem", ".env")

    pub fn deinit(self: *AccessRules, alloc) void;
};

/// Pure parser for the private file contents. `home` is injected (no env reads).
pub fn parseRules(alloc, file_contents: []const u8, home: []const u8) !AccessRules;

/// Pure, heuristic classification of one exec command.
pub fn evaluate(rules: *const AccessRules, command, cwd, home) EvalResult;

/// Compiled-in secure-by-default deny list (always merged in; see below).
pub const BUILTIN_DENY: []const []const u8;
```

A thin, non-pure loader lives alongside the pure core (tested under
`test_posix.zig`):

```zig
/// Reads the private file (if present), merges with BUILTIN_DENY, returns owned rules.
pub fn loadRules(alloc, file_path: []const u8, home: []const u8) !AccessRules;
```

### Private file

Path: `~/.config/wispterm/agent-access.local` (never written to synced/exported
config; `stripConfigKeys` / restore-defaults do not touch it). Line format:

```
# WispTerm agent file-access rules (private, machine-local)
allow ~/project
allow ~/work
deny  ~/.ssh
deny  *.pem
```

- `allow <path>` / `deny <path>`; leading/trailing whitespace trimmed.
- `~` and `$HOME` / `${HOME}` expand using the injected home.
- An entry containing `/` is a **directory prefix**; an entry with no `/` is a
  **basename/glob** matched against the basename of any referenced path.
- `#` comments and blank lines are ignored.
- **If the file is absent**, the built-in deny list still applies
  (secure-by-default); the allow list is empty.
- File entries **merge on top of** the built-ins (they extend, never replace the
  defaults).

### Built-in default deny list (`BUILTIN_DENY`)

Directory prefixes: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`,
`~/.config/wispterm`, `~/.kube`. Files/globs: `~/.netrc`, `~/.docker/config.json`,
`*.pem`, `*.key`, `.env`. (Reviewable.)

### Decision logic & precedence

Precedence is **deny > allow > base permission mode**. `deny` always wins, so an
`allow` entry cannot carve a hole inside a denied tree.

For each exec command, computed alongside the existing `isDangerousCommand`:

| Condition | Result |
|---|---|
| Command references a **deny** path | `blacklisted` → **force approval** even in `full` mode; reason names the matched path |
| Else read-only command **fully confined to allow** roots, no deny hit | `whitelisted_safe` → **auto-approve** (skips prompt even in `confirm` mode) |
| Else | `neutral` → existing behavior |

The combined gate in each tool becomes:

```zig
const access = ai_agent_access.evaluate(rules, command, cwd, home);
const dangerous = isDangerousCommand(command);
const force = dangerous or access.decision == .blacklisted;
const skip  = access.decision == .whitelisted_safe and !dangerous;
if (force or (ctx.settings.permission != .full and !skip)) {
    const reason = if (access.decision == .blacklisted)
        "Reads protected path — confirm to allow"  // includes matched path
    else if (dangerous) DANGEROUS_COMMAND_APPROVAL_REASON
    else <existing per-tool label>;
    if (!ctx.requestApproval(tool, command, reason)) return denied;
}
```

### Matching heuristics

- **Deny matching is generous** (bias to over-trigger → safer). Scan the command
  for path-like tokens; for each, lexically expand `~`/`$HOME`, resolve relative
  tokens against cwd, collapse `.`/`..`, then test prefix against `deny_roots`
  and basename against `deny_names`. A false positive only adds one extra prompt.
- **Allow auto-approve is strict** (bias to ask). Fires only when:
  1. every leading verb (the command, plus each segment after `|`, `&&`, `||`,
     `;`) is in a known **read-only verb set**
     (`cat bat head tail less more grep egrep fgrep rg ls ll find stat file wc nl
     od xxd hexdump strings cut sort uniq diff tree readlink realpath dirname
     basename pwd`), and
  2. **every** path-like token resolves under an `allow_root`, and
  3. no deny hit.
  Any parsing uncertainty (unknown verb, unresolvable token) → not
  `whitelisted_safe` → falls through to normal approval.

### Wiring

- `AccessRules` is loaded once at app startup and **owned by `App`**.
- A `?*const AccessRules` pointer is threaded through `AgentSettings` (keeps the
  struct copyable) and reaches the tool layer via `ToolContext.settings`.
- The home dir and the command's `cwd` reach the matcher: home from the app
  environment at load time (stored on the rules or passed alongside); cwd from
  the existing exec-tool `cwd` argument (or the surface cwd for ssh/wsl/repl).
- The three gates call **one shared helper** so the logic lives in a single place
  rather than being copy-pasted across `localCommandExecTool`,
  `unixSessionExecTool`, and `terminalReplExecTool`.

### Error handling

- Missing private file → use built-ins only (not an error).
- Malformed line → log a warning, skip that line, keep parsing the rest.
- If rules fail to load entirely → fall back to `BUILTIN_DENY` so deny protection
  is never silently disabled.
- `null` rules pointer (feature not wired for a surface) → behaves as built-ins
  only is still preferable, but if genuinely null, the gate degrades to existing
  behavior (no crash).

## Testing

**Fast suite (`src/ai_agent_access.zig` tests, pure):**

- Parser: allow/deny lines, `~` and `$HOME` expansion, comments/blanks, glob vs
  directory entry, malformed-line skipping.
- `evaluate` deny: `cat ~/.ssh/id_rsa`, `cat $HOME/.ssh/config`,
  `cat /home/u/.ssh/x` (absolute), cwd-relative `cat ../.ssh/id_rsa`, glob
  `cat secret.pem`, `.env`, and that deny beats an overlapping allow.
- `evaluate` allow: read-only command confined to an allow root → `whitelisted_safe`;
  a write/unknown verb in the same dir → `neutral`; a read touching one allowed +
  one outside path → `neutral`.
- Read-only verb classification incl. pipelines (`cat a | grep b`).

**Posix suite (`src/test_posix.zig`):**

- `loadRules`: real file read, merge with built-ins, absent-file path.

## YAGNI / out of scope

- OS-level sandboxing.
- Per-profile rule sets (single machine-local file for v1).
- Allowing `allow` to override `deny` (deny always wins).
- A UI editor for the rules (hand-edited file for v1).
```
