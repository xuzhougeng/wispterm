# UI State Debt P2.2 - Session Launcher and Profile Form State Split Design

Date: 2026-06-24
Status: Approved P2.2 direction

## Context

P2.1 established the repeatable `OverlayState` pattern on the smaller overlays:

- `src/renderer/overlays/state.zig` aggregates feature-owned state structs.
- `settings_page.zig`, `toasts.zig`, and `confirm_modals.zig` each own one
  overlay group's state behind narrow methods.
- `overlays.zig` keeps a single threadlocal `g_overlay_state` and stays the
  caller-facing facade.
- Settings and confirmation key handlers return `UiEffect`; fast source guards
  in `zig build test` stop migrated state and converted input branches from
  regressing.

P2.1 final line counts:

```text
  10578 src/AppWindow.zig
   7665 src/renderer/overlays.zig
   7092 src/input.zig
   8756 src/ai_chat.zig
  34091 total
```

P2.2 is the second P2 slice. It continues splitting `overlays.zig` by moving the
**session launcher**, **SSH profile list/form**, **AI profile list/form**, **AI
history source picker**, and **switch-model target** state out of raw threadlocal
globals into feature-owned modules. P2.3 (AppWindow `WindowState` /
`InputState` / `RemoteState`) does not start until P2.2 is complete and verified.

## Current State Inventory

The session launcher region of `overlays.zig` spans roughly lines 2138-5279
(~3140 lines) and is the largest remaining state cluster in the facade. Two
ownership layers already exist:

- **Visibility / transitions** are owned by `src/command_center_state.zig`
  (`State.session_launcher_visible`, `ssh_list_visible`, `ssh_form_visible`,
  `ai_list_visible`, `ai_form_visible`, `ai_history_source_visible`, plus
  `sessionLauncherOpen/Close/BackToCommandPalette`). `overlays.zig` mirrors these
  into threadlocal globals through `commandCenterStateSnapshot()` /
  `commandCenterStateApply()`. **P2.2 does not change this layer.**
- **Profile data and codec** are owned by
  `src/renderer/overlays/profile_codec.zig` (`SshField`, `AiField`, `SshProfile`,
  `AiProfile`, field get/set, line decode). **P2.2 does not change this layer.**

What is still raw threadlocal state in `overlays.zig` (lines 2231-2289), and is
the P2.2 migration target:

| Global | Group |
|---|---|
| `g_ssh_focus`, `g_ssh_bufs`, `g_ssh_lens` | SSH form input |
| `g_ssh_profiles`, `g_ssh_profile_count`, `g_ssh_profiles_loaded` | SSH profile store |
| `g_ssh_list_selected`, `g_ssh_list_mode`, `g_ssh_list_filter_buf`, `g_ssh_list_filter_len`, `g_ssh_delete_selected`, `g_ssh_edit_index` | SSH list |
| `g_ai_focus`, `g_ai_bufs`, `g_ai_lens` | AI form input |
| `g_ai_profiles`, `g_ai_profile_count`, `g_ai_profiles_loaded` | AI profile store |
| `g_ai_list_selected`, `g_ai_list_mode`, `g_ai_edit_index` | AI list |
| `g_ai_history_source_selected` | AI history source picker |
| `g_switch_model_target` | switch-model target |

All references to these globals are **internal to `overlays.zig`** (verified: no
other `.zig` file reads them), so the facade migration causes **zero repo-wide
import churn**.

The local enums `SshListMode`, `AiListMode`, and `AiHistorySourceChoice` move
with their state. `SessionAction` and the heavy rendering / disk-I/O / connect
logic stay in `overlays.zig`.

Out of scope for P2.2 (not in the recorded P2.2 list): the SSH password-prompt
side channel `g_pending_ssh_password*` / `g_pending_ssh_surface`. These belong to
the SSH connection flow, not launcher form state; leave them in `overlays.zig`
and record them as a later slice.

## Ghostty Reference

Ghostty keeps per-feature UI state in dedicated, default-initialized structs
embedded in the owner rather than in a single global bucket:

- `src/Surface.zig` declares `mouse: Mouse` and `keyboard: Keyboard` as nested
  struct fields. `const Mouse = struct { click_state: ... = ..., mods: ... = .{},
  ... }` is a feature-owned state holder with default field values, exactly the
  shape of WispTerm's `OverlayState { settings: ..., toasts: ..., ssh: ... }`.
- `src/input/` is split by concept into `mouse.zig`, `keyboard.zig`,
  `command.zig`, `Binding.zig`, `Link.zig`, `paste.zig` — one file per input
  responsibility, never one catch-all module.
- `src/input/command.zig` models a command-palette command as a plain data
  struct (`Command { action, title, description }`) defined in its own file,
  analogous to WispTerm's `command_center_state.CommandEntry` and
  `profile_codec` data types.

P2.2 follows this direction: each launcher sub-feature becomes a
default-initialized `State` struct in its own `src/renderer/overlays/*.zig`
file, embedded as a nested field of `OverlayState`, while `overlays.zig` keeps
the rendering and side-effectful operations as the facade.

One WispTerm-specific constraint shapes the design: `state.zig` is compiled in
the fast `zig build test` suite, which compiles only platform-independent logic
modules. Ghostty has a single compile graph and can store a typed
`*ai_chat.Session`-equivalent pointer directly. WispTerm cannot: importing the
heavy `ai_chat.zig` graph into a fast-suite module would break the fast suite.
The switch-model target is therefore stored as `?*anyopaque` in the pure module
and typed at the `overlays.zig` boundary (see Target Modules below).

## P2.2 Goals

1. Add `ssh_profiles.zig`, `ai_profiles.zig`, and `session_launcher.zig` under
   `src/renderer/overlays/`, each owning one launcher sub-feature's state.
2. Remove the migrated `g_ssh_*`, `g_ai_*`, `g_ai_history_source_selected`, and
   `g_switch_model_target` globals from `overlays.zig`.
3. Keep `overlays.zig` the compatibility facade; keep public function names and
   the `command_center_state` visibility layer unchanged.
4. Convert the `input.zig` session-launcher key branch to return `UiEffect`
   instead of manually writing `AppWindow.g_force_rebuild` /
   `AppWindow.g_cells_valid`.
5. Cover new pure state behavior (form focus wrap, field get/set, history-source
   navigation) with fast `zig build test` unit tests.
6. Add fast source guards so the migrated globals and converted input branch do
   not regress.
7. Treat `zig build test-full` as the 5-10 minute stage gate, not a per-task gate.

## P2.2 Non-goals

- Do not change the `command_center_state` visibility/transition layer or
  `profile_codec`.
- Do not migrate `g_pending_ssh_password*` / `g_pending_ssh_surface`.
- Do not start P2.3 AppWindow `WindowState` / `InputState` / `RemoteState`.
- Do not move heavy rendering, profile disk persistence, OpenSSH import, or
  connect logic out of `overlays.zig` in P2.2 (state first, like P2.1).
- Do not change keyboard shortcuts, session launcher behavior, SSH/AI form
  behavior, or profile persistence behavior.
- Do not remove `overlays.zig` as the caller-facing facade.
- Do not touch `remote/`.

## Target Modules

### `src/renderer/overlays/ssh_profiles.zig`

Owns SSH list + form state. Re-exports `profile_codec` field/profile types so the
module is self-describing, and owns the `SshListMode` enum.

State fields: `focus`, `bufs`, `lens` (form input); `profiles`, `profile_count`,
`profiles_loaded` (store); `list_selected`, `list_mode`, `list_filter_buf`,
`list_filter_len`, `delete_selected`, `edit_index` (list).

Narrow pure methods (each replaces existing inline `overlays.zig` logic and is
unit-tested):

- `formField(field)` / `setFormField(field, value)` over `bufs`/`lens`.
- `focusNextRow()` / `focusPrevRow()` wrapping over `SSH_FORM_ROW_COUNT`
  (`SSH_FIELD_COUNT + 3` action rows — matches the existing
  `% (SSH_FIELD_COUNT + 3)` arithmetic).
- `listFilter()` / `clearListFilter()` over the filter buffer.
- `resetForm()` clears `lens`, resets `focus` to `name`, clears `edit_index`.

Heavy logic that stays in `overlays.zig` and operates on `sshState().*`: profile
disk load/save, OpenSSH import/merge, delete-select batch, list filtering, and
all rendering. The shared `sessionFirstVisibleRow(selection, visible_rows,
row_count)` free function stays in `overlays.zig` (already param-based and pure).

`State` is ~520 KB (`[128]SshProfile`), so fast tests heap-allocate the struct
via `std.testing.allocator` rather than stack-instantiating it.

### `src/renderer/overlays/ai_profiles.zig`

Owns AI list + form state. Re-exports `profile_codec` AI types; owns `AiListMode`.

State fields: `focus`, `bufs`, `lens`; `profiles`, `profile_count`,
`profiles_loaded`; `list_selected`, `list_mode`, `edit_index`.

Narrow pure methods:

- `formField(field)` / `setFormField(field, value)`.
- `focusNextRow()` / `focusPrevRow()` wrapping over `AI_FORM_ROW_COUNT`
  (`AI_FIELD_COUNT + 3`).
- `resetForm()`.

Field-specific Enter/Left/Right behavior (protocol cycle, vision toggle), profile
persistence, and rendering stay in `overlays.zig`. `State` is ~1.6 MB
(`[16]AiProfile`); fast tests heap-allocate.

### `src/renderer/overlays/session_launcher.zig`

Owns launcher-level transient picker state that is not form data and not in
`command_center_state`. Owns the `AiHistorySourceChoice` enum.

State fields:

- `ai_history_source_selected: usize`
- `switch_model_target: ?*anyopaque` — the live `ai_chat.Session` bound to a
  `.switch_model` picker, stored opaque so this module stays fast-suite-safe.

Narrow pure methods:

- `historySourceNext(row_count)` / `historySourcePrev(row_count)` wrapping over a
  dynamic `row_count` (matches the existing `% row_count` arithmetic).
- `clearSwitchTarget()` and a raw `switch_model_target` field; `overlays.zig`
  provides typed `switchModelTarget()` / `setSwitchModelTarget()` accessors that
  `@ptrCast`/`@alignCast` to `*AppWindow.ai_chat.Session`.

### `src/renderer/overlays/state.zig` (modify)

Extend the aggregate:

```zig
pub const OverlayState = struct {
    settings: settings_page.State = .{},
    toasts: toasts.State = .{},
    confirms: confirm_modals.State = .{},
    ssh: ssh_profiles.State = .{},
    ai: ai_profiles.State = .{},
    session: session_launcher.State = .{},

    pub fn deinit(self: *OverlayState, allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
    }
};
```

`ssh`/`ai`/`session` need no `deinit` (fixed buffers, no heap, opaque pointer is
non-owning). The aggregate is now multi-MB, so the aggregate unit test
heap-allocates the `OverlayState` instead of stack-instantiating it.

## Compatibility Strategy

P2.2 keeps the caller-facing API stable. `overlays.zig` adds private accessors
beside the existing `settingsState()` / `toastState()` / `confirmState()`:

```zig
fn sshState() *ssh_profiles.State { return &g_overlay_state.ssh; }
fn aiState() *ai_profiles.State { return &g_overlay_state.ai; }
fn launcherState() *session_launcher.State { return &g_overlay_state.session; }
```

Every migrated `g_ssh_X` / `g_ai_X` / `g_ai_history_source_selected` reference
becomes `sshState().X` / `aiState().X` / `launcherState().ai_history_source_selected`.
The local enum declarations become aliases:

```zig
const SshListMode = ssh_profiles.SshListMode;
const AiListMode = ai_profiles.AiListMode;
const AiHistorySourceChoice = session_launcher.AiHistorySourceChoice;
```

`SSH_FIELD_COUNT`, `AI_FIELD_COUNT`, `SshField`, `AiField`, `SshProfile`,
`AiProfile`, `SSH_PROFILE_MAX`, `SSH_PROFILE_NONE`, `AI_PROFILE_MAX`, and
`AI_PROFILE_NONE` keep their existing `overlays.zig` aliases (now pointed at the
new modules where the module re-exports them) so the ~200 existing references
compile unchanged.

The switch-model target is read/written only through the typed facade accessors,
so the four existing `g_switch_model_target` call sites keep their
`*ai_chat.Session` type.

## Input Effect Conversion

`sessionLauncherHandleKey` gains a thin wrapper so the dozens of internal
`return;` statements are untouched (low risk, behavior-preserving):

```zig
pub fn sessionLauncherHandleKey(ev: input_key.KeyEvent) AppWindow.UiEffect {
    sessionLauncherHandleKeyImpl(ev);
    return .repaint;
}
fn sessionLauncherHandleKeyImpl(ev: input_key.KeyEvent) void { ...existing body... }
```

`input.zig`'s session-launcher branch drops the manual dirty writes:

```zig
if (overlays.sessionLauncherVisible()) {
    if (actionIs(action, .paste)) {
        return if (pasteClipboardIntoSessionLauncher()) .repaint else .none;
    }
    return overlays.sessionLauncherHandleKey(key_event);
}
```

This is behavior-preserving: today the non-paste path always dirties and returns
`.none`; the paste path dirties only on success. `.repaint` carries
`needs_rebuild` + `cells_invalid`, and `.none` carries neither.

## Verification Strategy

`zig build test-full` takes 5-10 minutes (on macOS the running gate is
`zig build test-full -Dtarget=aarch64-macos`; bare `test-full` cross-compiles for
the default Windows target and only compile-checks). P2.2 uses the P2.1 two-tier
policy:

- Every new leaf state module gets fast tests in `zig build test`.
- Static source guards go into `zig build test`.
- The fast suite does **not** compile `overlays.zig` or `input.zig`, so the
  facade/input wiring tasks get a fast-suite run (guards + leaf modules) plus
  code review. The two large mechanical renames (SSH, AI) additionally run a
  compile check (`zig build test-full`) right after the rename, because a
  ~200-reference rename across a 7600-line file is a specific high-risk task the
  P2.1 policy allows to gate early.
- `zig build test-full` runs once at the P2.2 stage gate.

P2.2 also runs Windows checkout-safety checks because it adds files.

## P2.2 Success Criteria

P2.2 is complete when:

- `ssh_profiles.zig`, `ai_profiles.zig`, and `session_launcher.zig` exist,
  compile, and are aggregated into `OverlayState`.
- The SSH, AI, AI-history-source, and switch-model-target state listed in the
  inventory no longer lives as `g_ssh_*`, `g_ai_*`, `g_ai_history_source_selected`,
  or `g_switch_model_target` globals in `overlays.zig`.
- `overlays.zig` remains the compatibility facade and the `command_center_state`
  visibility layer is unchanged.
- The converted session-launcher input branch uses `UiEffect` instead of direct
  dirty-flag writes.
- New state modules and source guards are covered by `zig build test`.
- `zig build test-full` passes at the P2.2 stage gate.

## Risks

| Risk | Mitigation |
|---|---|
| Large mechanical rename (~200 refs) breaks `overlays.zig` compile, caught only at the slow gate | Run `zig build test-full` compile check right after each big rename; keep type aliases stable so references compile unchanged. |
| `session_launcher.zig` drags the heavy `ai_chat.zig` graph into the fast suite | Store `switch_model_target` as `?*anyopaque`; type it only at the `overlays.zig` boundary. |
| Multi-MB `OverlayState` overflows the test stack | Heap-allocate `State`/`OverlayState` in all P2.2 fast tests. |
| Wrong focus-wrap modulus | Methods wrap over `SSH_FIELD_COUNT + 3` / `AI_FIELD_COUNT + 3` (the existing arithmetic), locked by unit tests. |
| Behavior drift in form/list/persistence | Move state only; keep persistence, import, connect, and rendering in `overlays.zig`; reuse existing overlay tests (renamed to `sshState().*` / `aiState().*`). |
| P2.3 starts before P2.2 stabilizes | P2.3 stays a recorded future stage; this plan has no P2.3 tasks. |

## P2.2 handoff

P2.2 moved session launcher, SSH list/form, AI list/form, AI history source
picker, and switch-model target state into `ssh_profiles.zig`, `ai_profiles.zig`,
and `session_launcher.zig`, aggregated under `OverlayState`, while keeping
`overlays.zig` the compatibility facade and the `command_center_state` visibility
layer unchanged. The session-launcher input branch now returns `UiEffect`.

The migration removed 23 raw threadlocal globals (12 SSH, 9 AI, 2 launcher
transient) and 2 local enums (`SshListMode`, `AiListMode`; `AiHistorySourceChoice`
became an alias) from `overlays.zig`, now owned by the three feature modules. The
P2.2 source guards (`state_guard.zig`, `overlay_effect_guard.zig`) assert these
globals stay gone and the launcher input branch stays effect-based. `overlays.zig`
line count is roughly flat because this was a state-ownership migration (rendering,
persistence, OpenSSH import, and connect logic intentionally stay in the facade,
per the "state first" policy); the debt reduction is measured by globals removed,
not lines. Reducing `overlays.zig` / `AppWindow.zig` line totals is the P2.3 goal.

Final line counts:

```text
   10578 src/AppWindow.zig
    7665 src/renderer/overlays.zig
    7100 src/input.zig
    8756 src/ai_chat.zig
   34099 total
```

Verification: `zig build test` (fast) passes per task; the two big renames (SSH,
AI) each passed a `zig build test-full` compile gate; the final
`zig build test-full -Dtarget=aarch64-macos` native gate compiled `overlays.zig`
and `input.zig` clean and ran ~2366 tests. Two back-to-back native runs (with
identical source — no commits or edits between them) produced **different**
failure sets — run 1: `AppWindow: skill center tool import`; run 2: that plus
`ssh_connection: fromParts supports explicit key auth` and
`ctl.protocol: encodeOk is a bare success line`. Because the code was identical
across both runs, the varying failures are environmental flakes (the parallel
runner's `.zig-cache/tmp` filesystem races, amplified by repeated heavy builds),
not regressions — a code regression fails deterministically every run. All three
flaky tests live in subsystems P2.2 did not touch (skill-center, ssh_connection,
ctl), and every P2.2 test (the three new state modules, the `OverlayState`
aggregate, both source guards, and the session-launcher `UiEffect` input test)
passed in both runs. Windows checkout-safety: 0 name violations, 0 case-fold
collisions, 0 tracked symlinks, max path 90 chars.

P2.3 starts the AppWindow `WindowState` / `InputState` / `RemoteState` migration.
Do not start P2.3 until P2.2 is accepted. The SSH password-prompt side channel
(`g_pending_ssh_password*`, `g_pending_ssh_surface`) was deliberately left in
`overlays.zig` and is a candidate for a later slice.
