# Source Layout Management

Directory moves are allowed only after a responsibility boundary is already
stable. A move should describe ownership that exists today; it must not be used
as a substitute for splitting responsibilities.

Ghostty is the reference shape for mature terminal-code layout: it keeps root
integration files such as `App.zig`, `Surface.zig`, `input.zig`, `config.zig`,
`renderer.zig`, `pty.zig`, and `termio.zig` at the top, while cohesive domains
live in named directories such as `terminal/`, `renderer/`, `font/`, `input/`,
`config/`, `termio/`, `os/`, and `apprt/`. WispTerm should follow that bias:
move stable feature families into domain directories, but leave root integration
nodes alone until their ownership boundaries have converged.

## Rules

- One directory PR moves one stable feature family.
- Directory PRs are mechanical: move files, update `@import` paths, update
  tests, docs, and source guards, then format.
- No behavior changes, public type renames, compatibility wrapper files, broad
  `mod.zig` re-export hubs, config changes, or opportunistic refactors.
- Directory names use domain names, not buckets such as `features/`, `services/`,
  `utils/`, or `models/`.
- Keep root integration files at `src/`: `main.zig`, `App.zig`,
  `AppWindow.zig`, `Surface.zig`, `input.zig`, `config.zig`,
  `process_runner.zig`, and `text_search.zig`.
- After every move, old active source imports must be gone and source guards must
  still cover the same boundary.

## Completed Stable Moves

These feature families have already moved into owner directories:

1. external terminal agent sessions -> `src/terminal_agents/sessions/`
2. command modules -> `src/command/`
3. preview modules -> `src/preview/`
4. small browser/html/jupyter families -> `src/browser/`, `src/html/`,
   `src/jupyter/`
5. skill modules -> `src/skill/`
6. port-forward modules -> `src/port_forward/`
7. AI conversation session and helpers -> `src/assistant/conversation/`
8. SSH/SCP helpers -> `src/ssh/`

Do not move `agent/`, overlay-owned SSH profile UI files, or the root integration
files without a separate ownership reason. Directory cleanup must stay
mechanical.

## Guard Checklist

Each directory PR must inspect and update these when paths change:

- `src/source_guards/global_state_guard.zig`
- `src/source_guards/input_feature_boundary_guard.zig`
- `src/source_guards/layered_dependency_guard.zig`
- `src/source_guards/overlay_boundary_guard.zig`
- `src/source_guards/process_runner_guard.zig`
- `src/test_fast.zig`
- `src/test_main.zig`
- `src/shared_compile_test.zig`

Do not raise ceilings. If the actual count drops, lower the ceiling.

## Validation

Run:

```bash
zig fmt src build.zig
zig build test
zig build test-full -Dtarget=native
```

Also search for old active paths after each family move. Historical plans may
keep old names, but active source imports must not.
