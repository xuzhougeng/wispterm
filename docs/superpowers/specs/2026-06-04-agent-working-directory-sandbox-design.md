# Design: Conversation working directory + working-directory sandbox

Issue: [#150](https://github.com/xuzhougeng/wispterm/issues/150) — clone/download
default to the system drive (Windows C:) because the local command tool inherits
WispTerm's own process cwd. The reporter wants a configurable project path so
they don't have to tell the agent the destination every time. The owner agreed
to "make a config — a project path — next version."

This design adds a **working directory** bound to the AI conversation (with a
persistent global default), used as the default cwd for local command execution,
and treats that directory as a lightweight **sandbox**: commands confined to it
skip the approval prompt even when the agent is in `auto`/`confirm` mode —
*except* genuinely destructive commands, which always confirm.

## Goals

- Local downloads / `git clone` / `npm install` land in a user-chosen directory
  by default, without the user (or agent) specifying a path each time.
- That directory acts as a sandbox: ordinary writes inside it run without an
  approval prompt; dangerous commands inside it still confirm; the private
  deny-list (`~/.ssh`, `.env`, `*.pem`, …) always wins.
- Works on Windows (the platform the issue is about: C: vs D:).
- Zero behavior change when no working directory is set.

## Non-goals (v1)

- No Settings-page GUI row. Configuration is a config-file key + a slash command.
- Scope is the **local** command tool only (`shell_exec` / `powershell_exec`).
  SSH/WSL exec (remote cwd), file-drop, and attachments are out of scope.
- Per-conversation overrides are in-memory only; they are not persisted into AI
  History and do not survive a resume (the global default does survive).
- The agent does not get a tool to *change* the working directory itself; it is
  set by the user only.

## Decisions (resolved during brainstorming)

1. **Binding & persistence:** global default **plus** per-conversation override.
   A new conversation starts from the global default.
2. **Sandbox destructive semantics:** ordinary operations inside the working dir
   run without a prompt; commands flagged by `isDangerousCommand` (`rm`, `mv`,
   `git reset --hard`, …) still confirm once, even inside the directory.
3. **Configuration surface:** slash command (`/cwd`) for the per-conversation
   override + config-file key (`ai-agent-working-dir`) for the global default. No
   Settings-page GUI in v1.

## Background: current architecture

- The local command tool is `shell_exec` (POSIX) / `powershell_exec` (Windows),
  dispatched in `ai_chat_tools.zig`. It accepts an optional `cwd` argument; when
  the model omits it, `std.process.Child.cwd` stays null and the child inherits
  WispTerm's process cwd — the root cause of "downloads land on C:".
  (`ai_chat_tools.zig:487` `localCommandExecTool`, `:544` `runArgv`.)
- Agent permission is **global**, three levels (`confirm` / `auto` / `full`) in
  `ai_agent_config.zig` (`AgentPermission`), stored in `g_agent_settings`
  (`ai_chat.zig`). `approvalRequiredForGate` (`ai_chat_tools.zig:473`):
  - `confirm` → prompt unless `gate.skip`
  - `auto` → prompt only if `gate.force` (dangerous or deny-listed)
  - `full` → never prompt
- `accessGate` (`ai_chat_tools.zig:457`) combines `isDangerousCommand`
  (`:1650`) with the file-access guard `ai_agent_access.evaluate`
  (`ai_agent_access.zig:147`). The guard already has an allow/deny-root model;
  `allow` roots auto-approve **read-only** commands confined to them
  (`Decision.whitelisted_safe`). The sandbox is a generalization of that
  confinement to *all* operations.
- Settings reach the tool layer through `ToolContext.settings`
  (`ai_chat_types.zig` `AgentSettings`), built per request in
  `toolContextFromRequest` (`ai_chat_request.zig:504`) from the global
  `currentAgentSettings()`.

## Design

### 1. Data model & lifecycle

- **Global default:** config key `ai-agent-working-dir` (string, default empty =
  unset), persisted in the config file alongside the other `ai-agent-*` keys
  (`config.zig`). On load it flows through `configureAgent` into an owned global
  `g_agent_working_dir` in `ai_chat.zig`.
- **Per-conversation override:** a new field on `Session` (`ai_chat.zig`) holding
  an owned path slice (default null). Set by `/cwd`, cleared by `/cwd reset`.
- **Effective value** = session override ?? global default. A new conversation
  has no override, so it starts from the global default.
- Empty/unset effective value ⇒ behavior is identical to today (no default cwd,
  no sandbox). This is the zero-regression invariant.

### 2. Threading the effective directory into the tool layer

- `AgentSettings` (`ai_chat_types.zig`) gains `working_dir: ?[]const u8 = null`
  (a borrowed slice, valid for the duration of the synchronous tool call).
- `currentAgentSettings()` fills it from `g_agent_working_dir`;
  `toolContextFromRequest` (`ai_chat_request.zig:504`) overlays the session
  override when present.
- `localCommandExecTool` (`ai_chat_tools.zig:487`): when the model omits `cwd`,
  default it to `settings.working_dir`. An explicit model-supplied `cwd` is
  respected as-is. The same effective cwd is passed to the access gate so
  confinement is judged against the directory the command actually runs in.
- The agent is told its working directory via the system prompt / tool context
  so it understands where artifacts land and what relative paths resolve
  against. (Default-cwd injection is the load-bearing mechanism; the prompt hint
  is advisory.)

### 3. Sandbox permission semantics

Pure logic lives in `ai_agent_access.zig` so it stays in the fast test suite.

- New pure function:

  ```
  pub fn workdirConfined(
      allocator, command, working_dir, effective_cwd, home,
  ) bool
  ```

  Returns true when **all** hold:
  - `working_dir` is non-empty,
  - `effective_cwd` resolves inside `working_dir` (`matchesRoot`), and
  - every path-bearing token in `command` resolves inside `working_dir`.

  Reuses the existing `resolveToken` / `matchesRoot` / `lexicalNormalize`
  machinery. A command with **no explicit path arguments** (e.g. `git clone
  <url>`, `npm install`, `curl <url> -O`) only writes into its cwd, so it counts
  as confined — this is the issue's primary use case.

- `accessGate` (`ai_chat_tools.zig:457`) extends the `skip` computation:

  ```
  skip  = (whitelisted_safe || workdirConfined) && !dangerous && !blacklisted
  force = dangerous || blacklisted      // unchanged; deny always wins
  ```

- `approvalRequiredForGate` is unchanged. Net effect:
  - `confirm` inside the working dir → ordinary writes auto-run (**the main
    win** for the default mode),
  - `auto` inside the working dir → unchanged in practice (auto already
    auto-runs non-dangerous writes; dangerous still confirm per decision 2),
  - `full` → unchanged (never prompts),
  - dangerous commands (`rm`, `mv`, `git reset --hard`, …) inside the working dir
    → still confirm, in every non-`full` mode,
  - deny-listed reads (`~/.ssh`, `.env`, …) → still forced, everywhere.

### 4. Windows paths

The issue is Windows-specific (C: vs D:), and the existing normalization
(`lexicalNormalize`, `resolveToken`) is POSIX — it splits on `/` only.
Confinement comparison must additionally handle:

- backslash ↔ forward-slash separators,
- drive letters / drive roots (`C:\`, `D:\`),
- case-insensitive comparison (Windows paths are case-insensitive).

Approach: normalize both the resolved token and the working-dir root for
comparison on Windows (convert `\` → `/`, lower-case, recognize a drive-letter
root), then reuse the existing prefix-match logic. The default-cwd injection
itself (`child.cwd = effective_cwd`) needs no normalization — Windows accepts the
path directly. The deny-list's existing Windows behavior is unchanged (out of
scope here).

### 5. Slash command & validation

- Add `/cwd` mirroring the `/permission` wiring: a `SlashCommand.cwd` enum value
  + `slash_command_entries` row (`ai_chat_composer.zig`), dispatched via an
  `applyCwdArg(arg)` in `ai_chat.zig` (cf. `applyPermissionArg`,
  `ai_chat.zig:316`).
  - `/cwd <path>` — set the per-conversation override. Expand `~` and resolve a
    relative path to absolute. **Validate the directory exists**; if it does not,
    report an error and do not set it (no silent `mkdir`).
  - `/cwd reset` — clear the override, falling back to the global default.
  - `/cwd` (no arg) — show the current effective directory and its source
    (override vs global default vs unset).

### 6. Edge cases & safety

- Effective working dir unset ⇒ no default cwd, no sandbox: identical to today.
- A model-supplied `cwd` **outside** the working dir ⇒ `effective_cwd` is outside
  ⇒ not confined ⇒ normal gating applies (safe).
- Deny beats sandbox: a confined command that nonetheless reads a deny-listed
  path (e.g. via `$(cat ~/.ssh/id_rsa)` — the token is scanned by the deny pass)
  is `blacklisted` ⇒ forced prompt.
- **Documented residual risk:** a command with no local path argument but
  arbitrary side effects (`curl <url> | sh`) is treated as confined and will
  auto-run inside the working dir in `confirm`/`auto`. This is the inherent limit
  of a command-string heuristic (the access guard already documents it is "not an
  OS sandbox"). Mitigations: dangerous commands still confirm, the deny-list
  still protects secrets, and the whole feature is opt-in (nothing relaxes until
  a working directory is explicitly set).

## Testing

- `ai_agent_access.zig` (fast suite): `workdirConfined`
  - POSIX: confined write, path escaping the root → not confined, no-path command
    → confined, nested deny still wins, cwd outside root → not confined.
  - Windows: `D:\proj` root with `\`-separated and mixed-case tokens, drive-root
    escape (`C:\Windows`) → not confined, case-insensitive match.
- `ai_chat_tools.zig`: `accessGate` skip/force matrix with a working dir set;
  `localCommandExecTool` default-cwd injection (model omits `cwd` → effective
  working dir used; model supplies `cwd` → respected); `confirm`-mode confined
  write auto-runs while a confined `rm` still requests approval.
- Slash command parsing/dispatch: `/cwd` set/reset/show, `~` expansion,
  non-existent path → error and no change.
- Both suites (`zig build test`, `zig build test-full`) green; Windows
  cross-compile clean.

## Out of scope / future

- Settings-page GUI row for the global default (+ i18n).
- Persisting the per-conversation override into AI History so a resumed
  conversation restores it.
- Extending the working-dir default/sandbox to SSH/WSL exec and to file-drop /
  attachment paths.
- Auto-creating a non-existent `/cwd` target.
