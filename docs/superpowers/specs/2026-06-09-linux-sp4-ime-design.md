# SP4 — Linux IME (preedit + candidate positioning)

Sub-project 4 of the Linux port roadmap
([2026-06-08-linux-port-design.md](2026-06-08-linux-port-design.md)). Builds on
SP1 (the SDL3 host) and the existing cross-platform IME machinery
(`src/ime_caret.zig`, `win.ime_composing`, `window_backend.imePreeditText`).

## Goal

Let the user **compose CJK in the window** via a system IME (fcitx5/ibus): show
the in-progress composition (preedit) inline, and place the IME's candidate
window at the cursor. Committed text already works (C3 wired
`SDL_EVENT_TEXT_INPUT` → `CharEvent` and calls `SDL_StartTextInput`); SP4 adds
the two missing pieces in `apprt/sdl.zig`.

## Prerequisite (environment, not code)

Linux IME requires a running IME daemon + the IM env vars
(`XMODIFIERS=@im=fcitx`, `GTK_IM_MODULE`/`QT_IM_MODULE=fcitx`). SDL3 talks to
fcitx5 over the **session DBus** (`org.fcitx.Fcitx5`, the loaded `dbusfrontend`
addon). This is user/system setup, outside WispTerm; the end-to-end smoke is
self-served (start `fcitx5 -d`, launch WispTerm with the IM env). In this dev
sandbox the daemon can't be kept alive from automation ("All display
connections are gone"), so SP4's acceptance for *code* is build + the user's
own smoke.

## Current state (the two stubs)

In `src/apprt/sdl.zig`'s `Window`:
- `imePreeditText(self)` returns `""` (no preedit shown).
- `setImeCaret(self, x, y, height)` stores `ime_caret_x/y/height` but the
  comment says "SDL_SetTextInputArea wiring deferred to C3" — it never calls
  SDL, so the IME candidate window doesn't track the cursor.
- `processEvent` handles `SDL_EVENT_TEXT_INPUT` (commit) but not
  `SDL_EVENT_TEXT_EDITING` (preedit), so `win.ime_composing` is never set.

The consuming side is **already built** (for Win/macOS IME): the render loop
reads `window_backend.imePreeditText(win)` (`AppWindow.zig:5564`) to draw inline
preedit, and `win.ime_composing` freezes the caret during composition
(`AppWindow.zig:5352/5372/5384/5400`). SP4 only feeds these.

## Design — three changes in `src/apprt/sdl.zig`

### 1. Preedit buffer on `Window`

Add a fixed buffer for the composition string:
```zig
ime_preedit_buf: [512]u8 = undefined,
ime_preedit_len: usize = 0,
```
`imePreeditText(self)` returns `self.ime_preedit_buf[0..self.ime_preedit_len]`.
(Single window = pump and render are the same thread, so no extra lock is
needed beyond what the existing queues use; document this assumption. Truncate
copies longer than the buffer.)

### 2. `SDL_EVENT_TEXT_EDITING` → preedit + `ime_composing`

New case in `processEvent`, routed by `event.edit.windowID` via the registry:
```zig
c.SDL_EVENT_TEXT_EDITING => {
    // event.edit.text is a UTF-8 C string (may be empty when composition ends)
    const w = ...registry lookup...;
    const txt = if (event.edit.text) |t| std.mem.span(@as([*:0]const u8, t)) else "";
    const n = @min(txt.len, w.ime_preedit_buf.len);
    @memcpy(w.ime_preedit_buf[0..n], txt[0..n]);
    w.ime_preedit_len = n;
    w.ime_composing = n > 0;
}
```
Also **clear preedit on commit**: in the existing `SDL_EVENT_TEXT_INPUT` case,
after pushing the char events, set `w.ime_preedit_len = 0; w.ime_composing =
false;` (the composition is done once text is committed).

### 3. `setImeCaret` → `SDL_SetTextInputArea`

After storing the caret coords, tell SDL where the text-input area is so the IME
candidate window anchors at the cursor:
```zig
pub fn setImeCaret(self: *Window, x: i32, y: i32, height: i32) void {
    self.ime_caret_x = @max(0, x);
    self.ime_caret_y = @max(0, y);
    self.ime_caret_height = @max(1, height);
    const rect = c.SDL_Rect{ .x = self.ime_caret_x, .y = self.ime_caret_y, .w = 1, .h = self.ime_caret_height };
    _ = c.SDL_SetTextInputArea(self.sdl_window, &rect, 0);
}
```
Coordinate convention (verified): `setImeCaret` receives **top-left window
pixel** coords — the caller passes `ime_caret.pixelPosition(...)` output
(`AppWindow.zig:5436-5441`), not a GL-flipped Y. `SDL_SetTextInputArea` wants the
same top-left window pixels, so pass them through with **no flip**. (The GL
Y-flip at `AppWindow.zig:5573` is only for the app drawing its own caret quad and
does not affect this input.)

## Out of scope

- Drawing our own candidate list (SDL3 exposes `event.edit.candidates`, but
  WispTerm uses the OS candidate window — keep it).
- ibus-specific tuning (the same DBus/env path covers ibus; fcitx5 is the test
  target).
- The IME *environment* setup (daemon + env vars) — documented as a prerequisite.

## Acceptance

1. `zig build -Dtarget=x86_64-linux-gnu` builds; `zig build test`/`test-full`
   green (no new failures — this is SDL-shell code, not unit-tested).
2. Self-served smoke (user): with `fcitx5 -d` running and the IM env set, launch
   WispTerm, press Ctrl+Space → Pinyin, type → **inline preedit shows**, the
   **candidate window appears at the cursor**, and selecting a candidate inserts
   the Chinese (commit path).
