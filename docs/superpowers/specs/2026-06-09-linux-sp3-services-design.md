# SP3 — Linux platform services (clipboard, cursor, notifications, file dialog)

Sub-project 3 of the Linux port roadmap
([2026-06-08-linux-port-design.md](2026-06-08-linux-port-design.md)). Fills the
platform-service capabilities that are still `unsupported` on Linux, using the
**SDL3** the host already links (no new system deps for the core set).

## Goal

Make copy/paste, cursor shapes, the bell/attention, and the file picker work on
Linux. Each is a `src/platform/<cap>_linux.zig` behind the existing facade, with
a `.linux` arm added to the facade's `Backend` enum + `impl` switch.

## Already working (no work)

`dirs` (XDG: `configDirFromXdgOrHome`), `open_url` (`.posix`/xdg-open),
`session_lock` (`.portable`), `display` (`.portable`). Confirmed: the config
already loads from `~/.config/wispterm`.

## The four services

Each facade currently selects `*_unsupported.zig` for Linux. SP3 adds
`*_linux.zig` and the `.linux` arm. All use `const c = @import("sdl").c;` (the
host's SDL is initialized before these run).

### 1. `clipboard_linux.zig` (highest value)

Facade API: `Owner`, `windowOwner`, `writeText`, `readText`,
`readImageAsPngTemp`, `normalizeText`.
- `writeText(text)` → `SDL_SetClipboardText` (NUL-terminate).
- `readText(allocator)` → `SDL_GetClipboardText` → dupe into allocator; SDL owns
  the returned buffer (`SDL_free` it).
- `normalizeText` → reuse the unsupported/shared pure impl (line-ending
  normalization) — copy it verbatim (it's std-only).
- `readImageAsPngTemp` → return `null` (clipboard **image** paste deferred; SDL
  has no portable clipboard-image API). OSC 52 text paste is unaffected (its own
  path).
- `Owner`/`windowOwner` → mirror the unsupported shapes (opaque/no-op owner).

### 2. `cursor_linux.zig`

Facade API: `Shape` enum + `set(shape: Shape)`.
- Map `Shape` → `SDL_SystemCursor` (`SDL_SYSTEM_CURSOR_DEFAULT`/`IBEAM`/`HAND`/
  `EW_RESIZE`/`NS_RESIZE`/`NESW_RESIZE`/`NWSE_RESIZE`/`MOVE`/`NOT_ALLOWED`, per
  the facade's `Shape` variants — read them).
- Lazily create + cache an `SDL_Cursor` per shape (module-level array indexed by
  shape; `SDL_CreateSystemCursor` once each), then `SDL_SetCursor`.

### 3. `notifications_linux.zig`

Facade API: `NotifAuthStatus`, `bell`, `requestAttention(handle)`,
`showDesktopNotification(title, body)`, `notificationAuthStatus`,
`requestNotificationAuth`.
- `bell()` / `requestAttention(handle)` → `SDL_FlashWindow(win,
  SDL_FLASH_UNTIL_FOCUSED)` (resolve the SDL_Window from the handle via the host
  registry, or flash the global window). `bell` may use `SDL_FLASH_BRIEFLY`.
- `showDesktopNotification(title, body)` → best-effort spawn `notify-send
  <title> <body>` (the standard desktop path; no-op if absent). Keep it simple;
  D-Bus/libnotify is a later refinement.
- `notificationAuthStatus` → `.authorized` (Linux needs no permission gate);
  `requestNotificationAuth` → no-op.

### 4. `file_dialog_linux.zig`

Facade API: `Owner`, `Filter`, `OpenRequest`, `SaveRequest`, `windowOwner`,
`openFile`, `saveFile`.
- **Read the facade's `openFile`/`saveFile` signature first** (sync-returns-path
  vs async-callback). SDL3's `SDL_ShowOpenFileDialog`/`SDL_ShowSaveFileDialog`
  are **async** (callback + `SDL_PumpEvents`). If the facade is synchronous,
  either (a) drive the SDL dialog to completion by pumping events until the
  callback fires (blocking the calling thread), or (b) spawn `zenity`/the XDG
  portal as a synchronous subprocess. Pick whichever matches the facade contract
  with the least friction; record the choice. Map `Filter` to the SDL filter
  list / zenity `--file-filter`.

## Deferred (noted, not in SP3)

- **config_watcher** (`config_watcher_linux.zig` via inotify) — config loads at
  startup; hot-reload (`Ctrl+,` re-read) just won't auto-fire. Keep
  `unsupported` for now.
- **text** (locale-aware compare) — the `unsupported` fallback (byte/ASCII
  compare) is acceptable; defer ICU/locale.
- **clipboard image paste** (`readImageAsPngTemp`) — null on Linux for now.

## Build wiring

These `_linux.zig` impls `@import("sdl")`, which is already wired into `app_mod`
on the linux target (SP1/SP2). Just add each facade's `.linux` arm. `notify-send`
spawn uses `std.process` (no new link dep). No `build.zig` changes expected
beyond the facade arms compiling.

## Testing / acceptance

- **Pure:** `normalizeText` (if extracted) + any pure mapping (e.g. a
  `Shape→SDL_SystemCursor` table) get std-only tests in the fast suite.
- **Build:** `zig build -Dtarget=x86_64-linux-gnu` + `zig build test`/`test-full`
  green; windows/macos unaffected (`.linux` arms comptime-gated).
- **Smoke (user/controller):**
  - Clipboard: select text + copy, paste elsewhere (and paste INTO the terminal)
    — round-trips. Autonomously checkable via a tiny SDL round-trip if needed.
  - Cursor: hover over terminal text (I-beam), window edges (resize), links
    (hand) — shape changes.
  - Bell: trigger the bell / a background notification → the taskbar entry
    flashes.
  - File dialog: trigger open/save (e.g. from the action that calls it) → a
    native picker appears and returns a path.

## Open items for the plan

- `file_dialog` sync-vs-async resolution (read the facade signature).
- Exact `Shape` and `Owner`/`Filter`/`OpenRequest` shapes (read the facades).
