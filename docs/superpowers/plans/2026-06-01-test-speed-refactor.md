# Test-Speed Decoupling Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move pure-logic tests out of the heavy `zig build test-full` compile graph (full desktop app: AppWindow/Surface/renderer/ghostty-vt/xev/GL/FreeType/Harfbuzz/win32) and into the sub-second `zig build test` fast suite, by extracting self-contained types/logic out of modules that currently force a heavy import.

**Architecture:** A Zig module's tests can run in the fast suite (`src/test_fast.zig`) only if its *entire transitive import graph* compiles natively without the heavy app deps. Today, several pure-logic modules reach the heavy graph through a single thin coupling (e.g. `Surface.SshConnection`, `tab.g_active_tab`, `ai_chat.AgentPermission`). We sever each coupling by extracting the small shared type into its own light module, re-exporting from the original for source compatibility, then registering the freed module in `test_fast.zig`.

**Tech Stack:** Zig 0.14-era build, `src/test_fast.zig` (fast native aggregator) + `src/test_main.zig` (full app graph). Tests register only when `_ = @import("…")`'d in an aggregator (see memory: *Test inclusion wiring*).

**Ordering rationale (refined from the brief):** The brief's order was SshConnection → file_explorer/scp → input → overlays → config/split_tree last. We move **config→ai_chat first** because `config.zig` is *already in the fast suite* and is the only fast-suite module dragging in the 336 KB `ai_chat.zig`; cutting it speeds the fast loop itself and is trivially low-risk. Everything else follows the brief, biggest-test-migration-first.

**Baseline (measured 2026-06-01, branch `worktree-feat-refactor`):**
- `zig build test` (fast): ~5 s wall (~7 s user); 451 passed / 1 skipped.
- `zig build test-full`: ~50 s, dominated by the Windows app cross-compile (~49 s); `.exe` run fails under WSL (expected).
- Tests currently trapped in `test-full` only because of a thin heavy coupling:
  - `file_explorer.zig` 26, `scp.zig` 11, `ssh_tunnel.zig` 4, `file_backend.zig` 1 — all use **only** `Surface.SshConnection` from Surface (verified); file_explorer additionally uses only `tab.g_active_tab` from the heavy `appwindow/tab.zig`.
  - `input.zig` 8 — binds `AppWindow` + `Surface`.
  - `renderer/overlays.zig` 16 — binds `AppWindow` + `ai_chat` + `Surface`.
  - `split_tree.zig` 4 — binds `*Surface` as the leaf type.

**Verification gate used after every phase:**
```bash
zig build test        # fast suite — must stay green, ideally faster / more tests
zig build test-full   # full graph — must stay green (compile is the real check; .exe run-fail under WSL is OK)
```
Per memory *Phantty test execution env*: full suite green baseline is ~673+/677, 4 skipped, **0 failed**. Test counts only grow.

---

## Phase 1: Decouple `config.zig` from `ai_chat.zig` (brief item #5)

**Why first:** `config.zig` is in `test_fast.zig` and is the *only* fast-suite importer of `ai_chat.zig` (336 KB / ~8k lines). It imports it solely for the tiny self-contained `AgentPermission` enum. Cutting this removes the entire `ai_chat.zig` subgraph from the fast compile.

**Files:**
- Create: `src/ai_agent_config.zig`
- Modify: `src/ai_chat.zig` (re-export, remove local def)
- Modify: `src/config.zig:22` (import), `:293`, `:786`, tests `:1845`,`:1853`
- (No change needed in `src/App.zig:97` — it keeps using `ai_chat.AgentPermission` via the re-export.)

- [ ] **Step 1: Create the extracted module** — move the enum verbatim (it has zero non-std deps).

```zig
//! src/ai_agent_config.zig
//! Small, dependency-light AI-agent config types shared by config.zig and
//! ai_chat.zig. Kept out of the 8k-line ai_chat.zig so config (and its fast
//! unit tests) need not compile the full AI session/API/tool-exec graph.
const std = @import("std");

pub const AgentPermission = enum {
    confirm,
    full,

    pub fn parse(value: []const u8) ?AgentPermission {
        if (std.mem.eql(u8, value, "confirm")) return .confirm;
        if (std.mem.eql(u8, value, "full") or std.mem.eql(u8, value, "full-permission")) return .full;
        return null;
    }

    pub fn name(self: AgentPermission) []const u8 {
        return switch (self) {
            .confirm => "confirm",
            .full => "full",
        };
    }
};

test "AgentPermission.parse accepts confirm/full/full-permission" {
    try std.testing.expectEqual(AgentPermission.confirm, AgentPermission.parse("confirm").?);
    try std.testing.expectEqual(AgentPermission.full, AgentPermission.parse("full").?);
    try std.testing.expectEqual(AgentPermission.full, AgentPermission.parse("full-permission").?);
    try std.testing.expectEqual(@as(?AgentPermission, null), AgentPermission.parse("nope"));
}
```

- [ ] **Step 2: Re-export from `ai_chat.zig`** — replace the local `pub const AgentPermission = enum { … };` block (src/ai_chat.zig:106–124) with:

```zig
pub const AgentPermission = @import("ai_agent_config.zig").AgentPermission;
```
Keep `AgentSettings` (which uses `AgentPermission`) as-is — it resolves through the re-export.

- [ ] **Step 3: Point `config.zig` at the light module.** At `src/config.zig:22` change:
```zig
const ai_chat = @import("ai_chat.zig");
```
to:
```zig
const ai_agent_config = @import("ai_agent_config.zig");
```
Then replace the 4 `ai_chat.AgentPermission` references (`:293`, `:786`, `:1845`, `:1853`) with `ai_agent_config.AgentPermission`. (Confirm `ai_chat` is not used elsewhere in config.zig: `grep -n 'ai_chat\.' src/config.zig` — must return nothing after this step.)

- [ ] **Step 4: Register the new module in the fast suite.** In `src/test_fast.zig`, add inside the `test { … }` block:
```zig
    _ = @import("ai_agent_config.zig");
```

- [ ] **Step 5: Verify fast suite green + faster, and no stray ai_chat import remains in fast graph.**
```bash
grep -n 'ai_chat' src/config.zig            # expect: no matches
( time zig build test ) 2>&1 | tail -5      # green; wall time should drop vs ~5s baseline
```
Expected: 452+ passed; ai_chat.zig no longer in the fast compile graph.

- [ ] **Step 6: Verify full suite still green.**
```bash
zig build test-full 2>&1 | tail -15
```
Expected: 0 failed (compile succeeds; WSL .exe run-fail is OK).

- [ ] **Step 7: Commit.**
```bash
git add src/ai_agent_config.zig src/ai_chat.zig src/config.zig src/test_fast.zig
git commit -m "refactor(config): extract AgentPermission to ai_agent_config, drop ai_chat from fast graph"
```

---

## Phase 2: Extract `SshConnection` out of `Surface.zig` (brief item #3, first cut)

**Why:** `SshConnection` is a fully self-contained struct (fixed buffers + accessors, no imports). `scp.zig`, `ssh_tunnel.zig`, `file_backend.zig`, `file_explorer.zig` reference **only** `Surface.SshConnection` from Surface (verified), yet importing `Surface.zig` drags in `ghostty-vt` + the GL renderer. Extracting it severs that.

**Files:**
- Create: `src/ssh_connection.zig`
- Modify: `src/Surface.zig:69-102` (replace struct with re-export)
- Modify: `src/scp.zig:8`, `src/ssh_tunnel.zig:5`, `src/file_backend.zig:8`, `src/file_explorer.zig:8` (import the light module; replace `Surface.SshConnection` → `ssh_connection.SshConnection`)

- [ ] **Step 1: Create `src/ssh_connection.zig`** with the struct moved verbatim:

```zig
//! src/ssh_connection.zig
//! Self-contained SSH connection descriptor (fixed-buffer fields + accessors).
//! Lives outside Surface.zig so remote-IO logic modules (scp, ssh_tunnel,
//! file_backend, file_explorer) can use it without compiling the heavy
//! ghostty-vt / renderer graph that Surface pulls in.

pub const SshConnection = struct {
    user_buf: [128]u8 = undefined,
    user_len: usize = 0,
    host_buf: [128]u8 = undefined,
    host_len: usize = 0,
    port_buf: [16]u8 = undefined,
    port_len: usize = 0,
    password_buf: [128]u8 = undefined,
    password_len: usize = 0,
    proxy_jump_buf: [256]u8 = undefined,
    proxy_jump_len: usize = 0,
    password_auth: bool = false,
    legacy_algorithms: bool = false,

    pub fn user(self: *const SshConnection) []const u8 {
        return self.user_buf[0..self.user_len];
    }
    pub fn proxyJump(self: *const SshConnection) []const u8 {
        return self.proxy_jump_buf[0..self.proxy_jump_len];
    }
    pub fn host(self: *const SshConnection) []const u8 {
        return self.host_buf[0..self.host_len];
    }
    pub fn port(self: *const SshConnection) []const u8 {
        return self.port_buf[0..self.port_len];
    }
    pub fn password(self: *const SshConnection) []const u8 {
        return self.password_buf[0..self.password_len];
    }
};
```

- [ ] **Step 2: Re-export from `Surface.zig`.** Add near the top imports of `src/Surface.zig`:
```zig
const ssh_connection = @import("ssh_connection.zig");
```
Replace the `pub const SshConnection = struct { … };` block (lines 69–102) with:
```zig
pub const SshConnection = ssh_connection.SshConnection;
```
(All in-file uses like `setSshConnection`, `ssh_connection: ?SshConnection` at `:179` continue to resolve.)

- [ ] **Step 3: Repoint the four consumers.** In each of `scp.zig`, `ssh_tunnel.zig`, `file_backend.zig`, `file_explorer.zig`: add `const ssh_connection = @import("ssh_connection.zig");` and replace every `Surface.SshConnection` with `ssh_connection.SshConnection`. Then drop the now-unused `const Surface = @import("Surface.zig");` **only if** `grep -n 'Surface\.' <file>` shows no other `Surface.` use (verified: only SshConnection). Do NOT drop the Surface import in `file_explorer.zig` yet if anything else needs it — re-grep to confirm (expected: safe to drop in all four).

Per-file commands to confirm clean removal:
```bash
for f in scp ssh_tunnel file_backend file_explorer; do echo "== $f =="; grep -n 'Surface' src/$f.zig; done
```
Expected after edit: no `Surface` references remain in any of the four.

- [ ] **Step 4: Register `ssh_connection.zig` in fast suite.** Add `_ = @import("ssh_connection.zig");` to `src/test_fast.zig`.

- [ ] **Step 5: Verify both suites green.**
```bash
zig build test 2>&1 | tail -5
zig build test-full 2>&1 | tail -15
```
Expected: both green; consumers still compile under test-full (they're added to fast in Phase 3).

- [ ] **Step 6: Commit.**
```bash
git add src/ssh_connection.zig src/Surface.zig src/scp.zig src/ssh_tunnel.zig src/file_backend.zig src/file_explorer.zig src/test_fast.zig
git commit -m "refactor(surface): extract SshConnection to ssh_connection.zig"
```

---

## Phase 3: Free file_explorer / scp / ssh_tunnel / file_backend into the fast suite (brief item #3, payoff)

**Why:** After Phase 2, `scp` / `ssh_tunnel` / `file_backend` reach only light deps. `file_explorer` still imports the heavy `appwindow/tab.zig` — but uses **only** `tab.g_active_tab` (a `threadlocal var usize`). Extract that global to a light module so file_explorer drops the heavy import; then register all four in the fast suite. **Migrates 42 tests.**

**Files:**
- Create: `src/appwindow/active_tab.zig`
- Modify: `src/appwindow/tab.zig:106` (move the var; reference from new module)
- Modify all `g_active_tab` users: `AppWindow.zig`, `browser_panel.zig`, `browser_panel_stub.zig`, `input.zig`, `file_explorer.zig`, `renderer/titlebar.zig`, `markdown_preview_panel.zig`
- Modify: `src/test_fast.zig` (register the four freed modules)

- [ ] **Step 1: Create `src/appwindow/active_tab.zig`** as the single source of truth:
```zig
//! src/appwindow/active_tab.zig
//! Index of the currently-active tab. Extracted from appwindow/tab.zig so
//! light modules (e.g. file_explorer) can read/write it without importing the
//! heavy tab module (which pulls in Surface/ai_chat/split_tree).
pub threadlocal var g_active_tab: usize = 0;
```

- [ ] **Step 2: Re-home the var in `tab.zig`.** In `src/appwindow/tab.zig`, remove the `pub threadlocal var g_active_tab: usize = 0;` at line 106 and add (with imports):
```zig
const active_tab = @import("active_tab.zig");
```
Then replace tab.zig's internal `g_active_tab` references with `active_tab.g_active_tab`. (Zig cannot alias a mutable `var` through a `const` re-export, so use the qualified name. `grep -n 'g_active_tab' src/appwindow/tab.zig` to find all ~12 sites.)
*Optional source-compat shim to limit blast radius:* keep `tab.zig` exposing the name via a getter/setter is NOT enough for `+=`/`-=` call sites, so we update references directly — see Step 3.

- [ ] **Step 3: Repoint every other `g_active_tab` user.** In each of `AppWindow.zig`, `browser_panel.zig`, `browser_panel_stub.zig`, `input.zig`, `file_explorer.zig`, `renderer/titlebar.zig`, `markdown_preview_panel.zig`: add an import to `active_tab.zig` (path-adjusted) and replace `tab.g_active_tab` (or local alias) with `active_tab.g_active_tab`. For `file_explorer.zig` specifically, after this it uses nothing else from `appwindow/tab.zig` — **remove** `const tab = @import("appwindow/tab.zig");`. Confirm:
```bash
grep -n 'appwindow/tab.zig\|tab\.g_active_tab' src/file_explorer.zig   # expect: no matches
```

- [ ] **Step 4: Register `active_tab.zig` + the four freed modules in the fast suite.** Add to `src/test_fast.zig`'s `test {}` block:
```zig
    _ = @import("appwindow/active_tab.zig");
    _ = @import("scp.zig");
    _ = @import("ssh_tunnel.zig");
    _ = @import("file_backend.zig");
    _ = @import("file_explorer.zig");
```

- [ ] **Step 5: Verify fast suite now runs the 42 migrated tests and stays fast/green.**
```bash
( time zig build test ) 2>&1 | tail -6
```
Expected: ~493+ passed (451 + ~42), wall time still in the single-digit seconds.

- [ ] **Step 6: Verify full suite green (no double-registration errors, heavy modules still compile).**
```bash
zig build test-full 2>&1 | tail -15
```

- [ ] **Step 7: Commit.**
```bash
git add -A
git commit -m "refactor(tabs): extract g_active_tab; move file_explorer/scp/ssh_tunnel/file_backend tests to fast suite"
```

---

## Phase 4: `input.zig` pure-rule extraction (brief item #1)

**Why:** `input.zig` (167 KB) imports `AppWindow` + `Surface` + `SplitTree`, trapping its 8 tests in test-full. Prior work already split out `input/{key,command_dispatch,click_tracker,hit_test,mouse_report,preview_source,clipboard}.zig`. The remaining 8 tests assert pure input rules that can move to AppWindow-free submodules. Ghostty reference: `src/input.zig` is a thin re-export of small `input/*` modules, not bound to the window loop.

**Files:**
- Read first: `src/input.zig` test blocks (8) + the helper fns they exercise.
- Create (as the tests dictate): candidate `input/action_router.zig`, `input/selection_model.zig`, `input/terminal_link_action.zig` (only those actually needed — YAGNI).
- Modify: `src/input.zig` (delegate to extracted fns; keep AppWindow adapter layer), `src/test_fast.zig`.

- [ ] **Step 1: Read & inventory.** `grep -n '^test ' src/input.zig` then read each test + the functions it calls. Classify each as (a) pure logic (no AppWindow/Surface state) → extract, or (b) genuinely window-coupled → leave in test-full. Record the mapping in the commit message.

- [ ] **Step 2: For each pure test group, TDD the extraction.** Create the target `input/<name>.zig` containing the pure fn(s) + the moved `test` blocks. Replace the body in `input.zig` with a thin call into the new module (or `pub const x = mod.x;`). Each extracted module must NOT `@import` `AppWindow.zig`/`Surface.zig`/`split_tree.zig`. Verify with `grep -nE 'AppWindow|Surface|split_tree' src/input/<name>.zig` → no matches.

- [ ] **Step 3: Register extracted modules** in `src/test_fast.zig` (`_ = @import("input/<name>.zig");`).

- [ ] **Step 4: Verify.** `zig build test` (new tests appear, green) then `zig build test-full` (green). If a test cannot be cleanly separated from window state, leave it in `input.zig`/test-full and note why — do not force it.

- [ ] **Step 5: Commit** per extracted module (frequent commits): `git commit -m "refactor(input): extract <name> pure logic to fast suite"`.

---

## Phase 5: `renderer/overlays.zig` model extraction (brief item #2)

**Why:** `overlays.zig` (201 KB) imports `AppWindow` + `ai_chat` + `Surface`, trapping its 16 tests. It mixes pure model/codec logic (SSH/AI profile encode-decode, command-center model, transfer toast, update prompt) with actual GL drawing. The pure parts need neither GL nor a window. Prior work already split `overlays/{primitives,scrollbar,resize,startup_shortcuts}.zig`.

**Files:**
- Read first: `src/renderer/overlays.zig` test blocks (16) + the fns under test.
- Create (as tests dictate): `renderer/overlays/profile_codec.zig`, `renderer/overlays/command_center_model.zig`, `renderer/overlays/transfer_toast_model.zig`, `renderer/overlays/update_prompt_model.zig` (only those the tests actually need).
- Modify: `src/renderer/overlays.zig` (delegate; keep draw fns), `src/test_fast.zig`.

- [ ] **Step 1: Read & inventory** the 16 tests (`grep -n '^test ' src/renderer/overlays.zig`); map each to a target pure module or "stays in test-full" (drawing/GL-coupled). Note macOS-gated `SkipZigTest` ones (lines ~4156, ~4208) — they may stay.

- [ ] **Step 2: TDD each extraction.** Move the pure fn(s) + their `test` blocks into the target submodule; the original calls into it. Each new module must not `@import` `AppWindow`/`ai_chat`/`Surface`. Verify via grep.

- [ ] **Step 3: Register** extracted modules in `src/test_fast.zig`.

- [ ] **Step 4: Verify** `zig build test` then `zig build test-full` (both green).

- [ ] **Step 5: Commit** per extracted model module.

---

## Phase 6: Generic-ize `split_tree.zig` (brief item #4)

**Why:** `split_tree.zig` (41 KB) is pure topology but hard-binds `*Surface` as its leaf, so its 4 tests need the heavy graph. Ghostty reference: `datastruct/split_tree.zig` is a generic data structure. Parameterize over the leaf type; AppWindow layer instantiates with `*Surface`.

**Decision to confirm at execution:** `SplitTree` calls `Surface.ref()`/`deref()` (see `refNodes`, line ~657). Two options:
- **(A) Generic over leaf type** `SplitTree(comptime Leaf: type)` requiring `Leaf.ref()/.deref()` — type-checks at instantiation; tests instantiate with a tiny fake leaf.
- **(B) Opaque handle** (leaf = `usize`/index) with ref/deref via injected callbacks — looser coupling, more call-site churn.
Prefer **(A)** unless call-site churn proves smaller for (B).

**Files:**
- Modify: `src/split_tree.zig` (parameterize; move the 4 tests to use a fake leaf), and every importer: `src/Surface.zig`(?), `src/AppWindow.zig`, `src/input.zig`, `src/renderer/overlays.zig`, `src/appwindow/tab.zig`, `src/renderer/titlebar.zig` — `grep -rln 'split_tree.zig' src/` for the full list.
- Modify: `src/test_fast.zig`.

- [ ] **Step 1: Map call sites.** `grep -rn 'SplitTree\b' src/` — list every instantiation and method call. Most refer to a `SplitTree` value/type alias.
- [ ] **Step 2: Parameterize** `split_tree.zig` to `pub fn SplitTree(comptime Leaf: type) type { return struct { … }; }` (option A). Internally use `Leaf` instead of `*Surface`. Keep `Surface.ref/deref` calls as `leaf.ref()/leaf.deref()`.
- [ ] **Step 3: Add the concrete alias where Surface lives** (e.g. in `Surface.zig` or a small `surface_split_tree.zig`): `pub const SurfaceSplitTree = @import("split_tree.zig").SplitTree(*Surface);`. Repoint heavy callers to the alias.
- [ ] **Step 4: Move the 4 topology tests** into `split_tree.zig` using a minimal fake leaf type with no-op `ref/deref`, so they compile light. Register `split_tree.zig` in `src/test_fast.zig`.
- [ ] **Step 5: Verify** `zig build test` (topology tests now fast) then `zig build test-full` (all callers compile, green).
- [ ] **Step 6: Commit.** `git commit -m "refactor(split_tree): generic over leaf type; topology tests to fast suite"`.

---

## Final verification & wrap-up

- [ ] Re-measure: `( time zig build test ) 2>&1 | tail -3` — record new fast-suite count + wall time vs the ~5 s / 451-test baseline.
- [ ] `zig build test-full 2>&1 | tail -15` — confirm 0 failed.
- [ ] Update memory note *Phantty test execution env* with the new fast-suite count and which modules migrated.

---

## Execution outcome (2026-06-01, branch `worktree-feat-refactor`)

Landed Phases 1–5 (+5b), one commit each; both suites green after every phase.

| Phase | Commit | Fast tests |
|---|---|---|
| Baseline | — | 451 / ~5 s (incl. ai_chat dragged in via config) |
| 1 config→ai_chat | `41dd703` | 315 / ~1.9 s |
| 2 SshConnection | `3a5fef1` | 315 |
| 3 g_active_tab + file_explorer/scp/file_backend | `c7d6c9c` | 367 |
| 4 input terminal_link_action + preview_path | `2fa7dcb` | 378 |
| 5 overlays profile_codec | `418d22c` | 384 |
| 5b overlays transfer_toast + update_prompt models | `063b67c` | **410** / ~1.9 s cold, ~0.45 s incremental |

Full suite throughout: **780/786 passed, 6 skipped, 0 failed**.

New light modules: `ai_agent_config`, `ssh_connection`, `appwindow/active_tab`,
`input/preview_path`, `input/terminal_link_action`, `renderer/overlays/{profile_codec,
transfer_toast_model, update_prompt_model}`. Also relocated 5 AI default constants
to `ai_chat_protocol`. ssh_tunnel stayed in test-full (uses the full `*Surface`).

### Phase 6 (split_tree) — DEFERRED, not done

Assessment after exploration: split_tree.zig's only heavy import is `Surface.zig`
(session_persist is light). The clean fix is a concrete-alias generic —
`pub const SplitTree = SplitTreeImpl(*Surface)` in split_tree.zig, with the generic
`SplitTreeImpl(comptime Leaf)` + the 4 topology tests in a new Surface-free
`split_tree_impl.zig`. This gives **zero caller churn** (the 113 `SplitTree*`
references keep working against the concrete alias). **However**, it requires
genericizing ~1000 lines of intricate tree topology (handle arithmetic, backtracking,
zoom/resize/remove, fromSnapshot factory) — effectively a full rewrite of core
window-management code — for only **4 tests**. Highest risk / lowest reward of the
refactor; the brief itself ranked it last. Recommended as its own focused PR with
review, not the tail of a batch.

## Self-Review notes

- **Spec coverage:** Brief items #1 (input)→Phase 4, #2 (overlays)→Phase 5, #3 (SshConnection + file_explorer/scp)→Phases 2–3, #4 (split_tree)→Phase 6, #5 (config→ai_chat)→Phase 1. All five covered.
- **Type consistency:** New module names used consistently — `ai_agent_config.AgentPermission`, `ssh_connection.SshConnection`, `active_tab.g_active_tab`. Re-exports preserve `ai_chat.AgentPermission` and `Surface.SshConnection` so unrelated callers (App.zig, RendererThread.zig, etc.) are untouched.
- **Risk note:** Phases 1–3 are turn-key (full code given; types verified self-contained). Phases 4–6 require reading the in-file `test` blocks at execution time before carving, because the exact pure/coupled split can only be decided against the real test bodies; each lists explicit read-first + grep-verify gates instead of speculative code.
