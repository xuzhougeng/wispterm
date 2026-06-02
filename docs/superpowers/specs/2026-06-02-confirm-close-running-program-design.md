# Confirm before closing a tab/window with a running program

**Date:** 2026-06-02
**Branch:** `worktree-feat-close-double-check`
**Status:** Design approved — ready for implementation planning

## Problem

When a full-screen TUI program is running in a terminal surface — an AI coding
agent (claude code, codex, opencode, oh-my-pi, reasonix, …) or any other
full-screen app (vim, htop, lazygit, less, man) — it is too easy to destroy that
session by accident:

- pressing **Ctrl+Shift+W** (close focused split/tab), or
- clicking the **window close (X)** button in the title bar, or
- clicking a **tab's × button**.

The user wants a confirmation prompt on these close paths *when a program is
running*, so a running session is never killed by a single stray action.

## Trigger signal: alternate screen

A full-screen TUI program switches the terminal to the **alternate screen
buffer** (DECSET 1049/1047/47). A plain shell prompt stays on the **primary**
screen. So "a program is running" is defined as:

```
surface.terminal.screens.active_key == .alternate
```

This is the exact check ghostty itself uses (`Terminal.zig:1343`). It is robust,
needs zero per-tool heuristics, and naturally covers every current and future
TUI tool ("et al"). Accepted trade-off: it also prompts for vim/less/man/etc. —
which is desirable, since you don't want to nuke those either. A plain shell at
its prompt is `.primary` and never prompts.

This is intentionally **independent** of the existing `agent_detector.zig`
(which classifies codex/claude-code state for the title-bar badge). The
detector is title/output heuristic and narrow; the alt-screen flag is
authoritative for "is something interactive running."

## Approach (selected: A — generalize the existing confirm modal)

The codebase already has a polished modal close-confirm overlay
(`renderer/overlays.zig`: `windowCloseConfirmOpen/Close/Visible`,
`windowCloseConfirmHandleKey`, `windowCloseConfirmExecuteAt`,
`renderWindowCloseConfirm`, `windowCloseConfirmLayout`). It is already wired into
input routing (`input.zig:1042` keyboard, `input.zig:2559` mouse) and
`restoreDefaultsConfirm` already reuses its layout — so reuse is an established
pattern.

Generalize this single overlay to carry a **pending close action** plus a
**message variant**, and route all three close paths through it. One modal, one
behavior, minimal new UI code.

Rejected alternatives:
- **B (separate overlay):** two near-identical modals; window-X could show
  either one depending on TUI state — duplicated code, confusing UX.
- **C (gate only):** the existing modal can only close the *whole window*, so it
  cannot serve Ctrl+Shift+W (close one split). Collapses into A/B anyway.

## Components

### 1. Detection helpers (`AppWindow.zig`)

```
fn surfaceHasRunningProgram(s: *const Surface) bool
    => s.terminal.screens.active_key == .alternate

fn tabHasRunningProgram(tab_idx: usize) bool
    => any surface in that tab's split tree is on the alternate screen

fn anyTabHasRunningProgram() bool
    => any surface in ANY tab in the window is on the alternate screen
```

All read on the main thread, where close handling and rendering already read
terminal state. (Reading a single enum is benign even if the IO thread mutates
terminal state concurrently — worst case is a one-frame stale decision. If a
surface/terminal lock is already held on this path, read under it.)

### 2. Generalized confirm overlay (`renderer/overlays.zig`)

Add a pending action and a message variant alongside the existing visibility
flag:

```
const PendingClose = union(enum) {
    window,             // set AppWindow.g_should_close = true
    focused_split,      // AppWindow.closeFocusedSplit()
    tab: usize,         // AppWindow.closeTab(idx)
};

const CloseConfirmVariant = enum {
    running_program,    // "A program is still running in this tab. Close anyway?"
    window_generic,     // existing: "Close WispTerm?" / "Running panels ... terminated."
};
```

- `closeConfirmOpen(action, variant)` — store both, set visible.
- **Confirm** (Enter key, or click the Close button): dispatch the stored
  `PendingClose` action, then hide.
- **Cancel** (Esc key, or click Cancel): hide, do nothing.
- `renderWindowCloseConfirm` selects title/body/hint text by variant. Strings
  stay English, consistent with the current modal (i18n lives on an unmerged
  branch).

**Behavior change:** today `windowCloseConfirmHandleKey` dismisses (cancels) on
*both* Esc and Enter, and you must click Close to confirm. The new behavior is
**Enter = confirm, Esc = cancel** (the chosen UX), applied to this modal for all
variants. The window-generic variant's text gains an "Enter to close" affordance
to match.

The existing public function names can be kept as thin wrappers (e.g.
`windowCloseConfirmOpen()` => `closeConfirmOpen(.window, .window_generic)`) to
minimize churn at call sites, or renamed — implementation detail for the plan.

### 3. Wiring the three close paths

**a. Ctrl+Shift+W** — `input.zig` `closePanelOrTab()` (currently `input.zig:481`):
- Markdown/browser/AI panels: unchanged (not terminals).
- If the focused surface is on the alternate screen →
  `closeConfirmOpen(.focused_split, .running_program)`. **This takes precedence
  over the existing last-tab "press-again" toast.**
- Else: existing logic — if `closeFocusedSplitWouldCloseWindow()` show the
  press-again toast; otherwise close immediately.

**b. Window X** — `AppWindow.zig` main loop (currently ~`AppWindow.zig:4786`,
the `window_backend.closeRequested(win)` block):
- Open the confirm when `closeRequestPromptsConfirmation()` **OR**
  `anyTabHasRunningProgram()`.
- Variant: `.running_program` when a TUI is running, else `.window_generic`.
- Action: `.window`.
- This adds the prompt on **macOS** (which today tears down with no prompt) when
  a program is running, while preserving the existing **Windows** always-prompt.

**c. Per-tab × button** — `input.zig` tab-close click paths (currently
`input.zig:2729` and `input.zig:3307`, both `AppWindow.closeTab(idx)`):
- If `tabHasRunningProgram(idx)` → `closeConfirmOpen(.{ .tab = idx },
  .running_program)` instead of closing immediately.
- Else close immediately.

### 4. Config toggle

Add `confirm-close-running-program` to `config.zig`, default `true`. When
`false`, all three paths skip the running-program check and behave as they do
today. The window-generic Windows prompt is unaffected by this toggle (it is the
pre-existing behavior).

## Data flow

```
close gesture (Ctrl+Shift+W | window X | tab ×)
   │
   ▼
config.confirm-close-running-program == true ?
   │ no → existing behavior
   ▼ yes
detection helper (alt-screen?) ── no ─→ existing behavior
   │ yes
   ▼
closeConfirmOpen(pending_action, .running_program)
   │
   ├─ Enter / click Close → dispatch pending_action (window | focused_split | tab)
   └─ Esc / click Cancel  → hide, no-op
```

## Error handling / edge cases

- **Last tab + TUI running + Ctrl+Shift+W:** shows the running-program modal
  (not the press-again toast); confirming closes the split, which closes the
  window. The press-again toast remains only for the non-TUI last-tab case.
- **Window X with multiple tabs:** warns if *any* tab has a running program, so a
  background-tab agent is never killed silently.
- **Panels (markdown/browser/AI copilot):** never treated as running programs;
  their existing close logic is untouched.
- **Overlay already open:** opening is idempotent (just resets the pending
  action/variant); input routing already swallows keys/clicks while visible.

## Risks

- **macOS window-X teardown:** today the macOS path deliberately skips the
  in-app prompt with the note that "the backend owns process lifecycle." Routing
  it through the overlay + `g_should_close` must be validated on macOS to confirm
  teardown still completes correctly and the red-X / Cmd-W semantics are
  preserved. Implementation-time check.
- **No Linux GUI backend:** this worktree (Linux/WSL) cannot run the GUI.
  Automated tests cover the pure logic; GUI 目检 on macOS/Windows stays pending,
  as with other features.

## Testing

Unit tests (run under `zig build test` / `zig build test-full`):

- `surfaceHasRunningProgram`: `.primary` → false, `.alternate` → true.
- `tabHasRunningProgram` / `anyTabHasRunningProgram`: false when all primary,
  true when at least one surface is on the alternate screen.
- `PendingClose` dispatch: each variant calls the correct close action (via a
  seam/fake so no real window is needed).
- Key handling: Enter → confirm (dispatch), Esc → cancel (no-op), other keys
  ignored.
- Config gate: when `confirm-close-running-program == false`, the helpers are
  bypassed.

GUI verification (deferred, macOS + Windows): each of the three gestures with a
running TUI shows the modal; Cancel keeps the session; Close terminates it;
plain shell prompt closes with no modal.

## Out of scope

- Distinguishing "busy" vs "idle" agents — any alt-screen program prompts.
- Per-program allow/deny lists.
- Changing `agent_detector.zig` or the title-bar badge.
