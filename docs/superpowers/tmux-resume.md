# tmux Control Mode — Resume Guide (for a GUI host)

Snapshot: **2026-06-03**. Branch: `worktree-feat-remote-perssitance` (pushed to `origin` = `github.com:xuzhougeng/wispterm`). This file is the portable record so work can resume on a macOS/Windows machine where the GUI can actually be driven — the detailed Claude Code memory is machine-local and does **not** travel; the repo (this doc + the plans/spec below) does.

## Goal

iTerm2-style **tmux `-CC` control-mode** integration so remote ssh sessions survive app close / network drop. tmux *windows* ↔ WispTerm *tabs*, tmux *panes* ↔ native *splits*, no visible tmux chrome. Only the server needs tmux; WispTerm *is* the tmux client (hand-rolled, in `src/tmux/`).

## Status — done, committed, both suites green, but **NO user-facing behavior yet** (all dead code until 3c-2/3d wire it in)

| Phase | What | Key commits |
|---|---|---|
| P1 | `src/tmux/control.zig` + `layout.zig` parsers | `af5a956` `3efb3a3` `2492458` |
| P2 | `src/tmux/session.zig` headless controller (model, command queue, `PaneSink`, `sendKeys`) | `4755d4c` |
| P3a | `Pty.openVirtual` — socketpair virtual PTY (`src/platform/pty_posix.zig`) | `47c5d70` `c8c11a5` |
| P3b | `Surface.initVirtual` (no-child pane surface) + `src/tmux/pane.zig` `PaneMap` (sink + `pumpKeystrokes`) | `7d2e478` `65ce6d2` `a6391d0` |
| infra | `src/test_posix.zig` so `zig build test-full` actually runs the posix-only tests | `10d4893` |
| P3c-1 | `SplitTree.fromTmuxLayout` — tmux layout → binary split tree (N-ary fold + ratios) | `ff41e9b` `3a29677` |

Suites: fast `zig build test` ≈ 604 passed; full `zig build test-full` ≈ 25/25 steps, 0 failed (incl. native `wispterm-posix-test`).

## Design docs (read first)

- Spec: `docs/superpowers/specs/2026-06-03-tmux-control-mode-integration-design.md`
- Plans: `docs/superpowers/plans/2026-06-03-tmux-control-mode-phase{1,2,3a-virtual-pty,3b-pane-surface,3c1-layout-to-splittree}.md`

## NEXT: Phase 3c-2 (do it on the GUI host — it's GUI-verifiable here, not in WSL)

Wire the pieces into the running app:

1. Give `PaneMap.Pane` a `surface: ?*Surface` field.
2. Build a reconcile entry: on a `Session` `%layout-change` for a window, call `SplitTree.fromTmuxLayout(gpa, layout_root, ctx, factory)` where the factory, per `pane_id`, returns `paneMap.find(id).?.surface.?.ref()` if the pane exists, else opens a `Pty.openVirtual`, builds a `Surface.initVirtual`, does `paneMap.addPane(id, controller_fd)` + stores the surface, and returns it (ref 1).
3. Swap the new tree into the live `TabState` with the standard idiom: `var old = t.tree; t.tree = new; old.deinit();` (the old tree's `deinit` unrefs vanished panes to destruction).
4. `paneMap.removePane(id)` for every pane that was in the old set but not the new layout.
5. Map `Session` window events → tabs: `%window-add` → new tab, `%window-renamed` → tab title, `%window-close` → close tab, `%window-pane-changed` → set `t.focused`.

Study targets: `src/appwindow/tab.zig` (the tree-swap in `splitFocusedSurfaceWithCommand` ~lines 712–730; `spawnTabWithCommandAndCwd`; `closeTab`) and `AppWindow` threading. Then **Phase 3d**: launch `ssh -tt host -- tmux -CC new -A -s <name>`, run the controller read-loop (poll the ssh fd + every `controller_fd`; route ssh→`Session.feed`, drain `Session.pendingCommands()`→ssh pipe, call `PaneMap.pumpKeystrokes`), and wire `list-windows` / `capture-pane -p -e -J` / `refresh-client -C`.

## Critical non-obvious findings (don't relearn the hard way)

1. **Don't reuse ghostty-vt's tmux parser.** It ships one but it's compiled out (oniguruma gated off in `GhosttyZig.zig`); enabling it means forking the pinned dep + adding a C regex lib. We hand-roll in `src/tmux/`.
2. **POSIX-only tests must be registered in `src/test_posix.zig`, not just `test_main.zig`.** The default build target is `x86_64-windows-gnu`; tests guarded `!= .windows` in `test_main.zig` are silently excluded there, and the linux target doesn't build the app test binary. `test_posix.zig` is a native, libc-linked binary run by `test-full` on a posix host. (This was discovered after Phase 3a's tests had never actually run.)
3. **A real `Surface` cannot be built in a headless test** (its `Renderer` needs the GPU backend; no test constructs one). Keep runtime-tested logic Surface-agnostic (e.g. `PaneMap`, `fromTmuxLayout` with sentinel factories); everything that touches a real `Surface`/`TabState`/`AppWindow` is compile-checked + **GUI-verified** — which is why 3c-2/3d belong on a GUI host.
4. **A no-child pane needs no new type:** the posix `Command` default `.{}` has `pid = -1`, so `wait()` already reports "still running" and `deinit()` is a safe no-op. `Surface.initVirtual` just leaves `command = .{}`.
5. **`SplitTree` ref-count ownership:** it's an immutable, ref-counted, binary tree. `fromTmuxLayout`/`fromSnapshot` factories transfer **one** ref per leaf to the new tree (they do *not* call `.ref()` themselves). To reuse an existing surface, the factory returns `surface.ref()`. Replace a tab's tree via `old = t.tree; t.tree = new; old.deinit();`.
6. tmux layouts are **N-ary** (`{a,b,c}` row / `[a,b,c]` column); `SplitTree` is **binary**. `fromTmuxLayout` folds right into binary splits with ratios from each child's cell width/height. Mutually-recursive `build`/`buildChain` need an **explicit** error set (Zig can't infer it).

## Build / test / run

Install **Zig 0.15.2** (exact). First build pulls deps (network).

- **Both platforms:** `zig build test` (native fast suite), `zig build test-full` (full; on a posix host this also runs the native `wispterm-posix-test` step covering `PaneMap`/virtual PTY).
- **macOS** (default build target is windows-gnu, so pass a native target for the app): `zig build macos-app -Dtarget=aarch64-macos` (Intel: `x86_64-macos`) → open the `.app`. Native smoke tests: `zig build test-metal`, `test-macos-window`, `test-macos-font`. Needs Xcode Command Line Tools.
- **Windows:** `zig build` → run `zig-out\bin\wispterm.exe`. (POSIX virtual PTY / `PaneMap` are unix-only and don't compile on Windows — by design; the posix test step is skipped.)

What's verifiable per platform **right now**: the `Surface.initVirtual`/`finishInit` refactor touches the real `Surface.init` path, so confirm normal terminals/splits/tabs still work (GUI regression); and on macOS confirm the posix tests are green. The tmux feature itself can't be exercised until 3c-2/3d.

## Resuming with Claude Code on the new machine

Install Claude Code + the superpowers plugin, open this repo, then: *"Read `docs/superpowers/tmux-resume.md` and continue with Phase 3c-2."* The plans + spec + this guide are the full portable context. (Optional: the richer machine-local memory can be copied from the old machine's `~/.claude/projects/<slug>/memory/`, but the slug is path-derived so it's fiddly — this doc is the reliable path.)
