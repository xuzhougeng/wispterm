# Linux SP1 — SDL3 Host Bring-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring up a single SDL3 window on Linux/X11 that renders a live terminal through the existing OpenGL 3.3 core backend, with keyboard/mouse input and a shell over `pty_posix`.

**Architecture:** Mirror the Windows host's two-file shape — `window_backend_linux.zig` (re-export) + `apprt/sdl.zig` (the SDL3 runtime). SDL has a single main-thread event queue (events carry a `windowID`), so the host follows the **macOS** model: the main thread pumps and routes events to per-window thread-safe queues, and worker-thread windows marshal window-ops back to main. All genuinely-testable logic (key mapping, drag-region hit-test, the run-on-main queue, window routing) lives in **pure std-only modules** with unit tests that run in `zig build test`/`test-full` today; the thin SDL shell is build- and GUI-smoke-verified.

**Tech Stack:** Zig 0.15.2, SDL3 (C, via `@cImport`), the vendored glad OpenGL loader (`pkg/opengl`), FreeType/HarfBuzz (vendored), `pty_posix` (done).

**Spec:** [2026-06-08-linux-sp1-sdl3-host-design.md](../specs/2026-06-08-linux-sp1-sdl3-host-design.md). **Roadmap:** [2026-06-08-linux-port-design.md](../specs/2026-06-08-linux-port-design.md).

**Conventions used below:**
- Fast pure tests: `zig build test`. Full graph + cross-compile + posix thread tests: `zig build test-full`.
- Linux host build (needs SDL3 dev headers + native Linux or a Linux target): `zig build -Dtarget=x86_64-linux-gnu`.
- Commit after every green step. Keep `x86_64-windows-gnu` the default target untouched.

---

## Phase A — Pure foundations (full TDD, run in existing suites)

These compile and test on the **current** default target with no SDL. They are the testable core of the host.

### Task A1: SDL key/modifier → neutral mapping

**Files:**
- Create: `src/input/sdl_keymap.zig`
- Modify: `src/test_fast.zig` (register the module)

- [ ] **Step 1: Write the failing test**

Create `src/input/sdl_keymap.zig` with only tests first:

```zig
//! Pure SDL3 scancode/modifier → neutral input mapping. Operates on SDL3's
//! stable ABI integer values (see SDL_scancode.h / SDL_keycode.h KMOD_*), so it
//! has no SDL dependency and runs in the fast suite. The SDL shell
//! (`apprt/sdl.zig`) passes `@intFromEnum(event.key.scancode)` and the keymod
//! bitmask here.
const std = @import("std");
const ev = @import("../platform/input_events.zig");

test "special scancodes map to neutral key codes" {
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_left), keyCodeFromScancode(80)); // SDL_SCANCODE_LEFT
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_up), keyCodeFromScancode(82)); // SDL_SCANCODE_UP
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_enter), keyCodeFromScancode(40)); // SDL_SCANCODE_RETURN
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_escape), keyCodeFromScancode(41)); // SDL_SCANCODE_ESCAPE
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_delete), keyCodeFromScancode(76)); // SDL_SCANCODE_DELETE
    try std.testing.expectEqual(@as(?ev.KeyCode, ev.key_left_shift), keyCodeFromScancode(225)); // SDL_SCANCODE_LSHIFT
    // A printable key has no special mapping (text arrives via TEXT_INPUT).
    try std.testing.expectEqual(@as(?ev.KeyCode, null), keyCodeFromScancode(4)); // SDL_SCANCODE_A
}

test "modifier bitmask decodes to neutral flags" {
    const m = modifiers(0x0040 | 0x0001); // KMOD_LCTRL | KMOD_LSHIFT
    try std.testing.expect(m.ctrl and m.shift and !m.alt and !m.super);
    const g = modifiers(0x0400); // KMOD_LGUI
    try std.testing.expect(g.super and !g.ctrl);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/input/sdl_keymap.zig`
Expected: FAIL — `keyCodeFromScancode`/`modifiers` not defined.

- [ ] **Step 3: Write minimal implementation**

Add above the tests:

```zig
pub const Mods = struct { ctrl: bool, shift: bool, alt: bool, super: bool };

/// SDL3 stable scancode values → neutral KeyCode. Returns null for keys whose
/// text should arrive via SDL_EVENT_TEXT_INPUT (printable characters).
pub fn keyCodeFromScancode(scancode: u32) ?ev.KeyCode {
    return switch (scancode) {
        42 => ev.key_backspace, // SDL_SCANCODE_BACKSPACE
        43 => ev.key_tab, // TAB
        44 => ev.key_space, // SPACE
        40 => ev.key_enter, // RETURN
        41 => ev.key_escape, // ESCAPE
        62 => ev.key_f5, // F5
        73 => ev.key_insert, // INSERT
        74 => ev.key_home, // HOME
        75 => ev.key_page_up, // PAGEUP
        76 => ev.key_delete, // DELETE
        77 => ev.key_end, // END
        78 => ev.key_page_down, // PAGEDOWN
        79 => ev.key_right, // RIGHT
        80 => ev.key_left, // LEFT
        81 => ev.key_down, // DOWN
        82 => ev.key_up, // UP
        224 => ev.key_left_control, // LCTRL
        225 => ev.key_left_shift, // LSHIFT
        226 => ev.key_left_alt, // LALT
        227 => ev.key_left_control, // LGUI → treat as control-class? No: see note
        228 => ev.key_right_control, // RCTRL
        229 => ev.key_right_shift, // RSHIFT
        230 => ev.key_right_alt, // RALT
        else => null,
    };
}

/// SDL3 keymod bitmask (KMOD_*) → neutral modifier flags.
pub fn modifiers(mod: u16) Mods {
    return .{
        .ctrl = (mod & (0x0040 | 0x0080)) != 0, // LCTRL|RCTRL
        .shift = (mod & (0x0001 | 0x0002)) != 0, // LSHIFT|RSHIFT
        .alt = (mod & (0x0100 | 0x0200)) != 0, // LALT|RALT
        .super = (mod & (0x0400 | 0x0800)) != 0, // LGUI|RGUI
    };
}
```

Note: GUI/Super keys (LGUI=227/RGUI=231) have no neutral *key code* constant in `input_events.zig` (only the `super` modifier flag exists), so map them to `null` in `keyCodeFromScancode` rather than a control code. Correct the `227 =>` arm to `227 => null,` and drop the RGUI arm (231 falls through to `else => null`).

- [ ] **Step 4: Fix the LGUI arm and re-run**

Edit the `227 =>` line to `227 => null, // LGUI: super flag only, no key code`.
Run: `zig test src/input/sdl_keymap.zig`
Expected: PASS (both tests).

- [ ] **Step 5: Register in the fast suite**

In `src/test_fast.zig`, inside the `test { ... }` block, add next to the other `input/*` imports:

```zig
    _ = @import("input/sdl_keymap.zig");
```

Run: `zig build test`
Expected: PASS, suite green.

- [ ] **Step 6: Commit**

```bash
git add src/input/sdl_keymap.zig src/test_fast.zig
git commit -m "feat(linux): pure SDL key/modifier → neutral input mapping"
```

---

### Task A2: Window drag/resize region classifier (for SDL hit-test)

**Files:**
- Create: `src/apprt/window_drag_region.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing test**

```zig
//! Pure classifier for a borderless window's hit-test: maps a point to a
//! drag/resize zone so the SDL shell can return the matching SDL_HITTEST_*.
//! No SDL dependency. The shell supplies window size, titlebar height, the
//! resize border thickness, and the sub-rects that must stay clickable
//! (caption buttons, tab strip).
const std = @import("std");

test "edges classify as resize zones" {
    const o = Opts{ .titlebar_height = 30, .border = 4, .exclusions = &.{} };
    try std.testing.expectEqual(DragHit.resize_top_left, classify(800, 600, 1, 1, o));
    try std.testing.expectEqual(DragHit.resize_right, classify(800, 600, 799, 300, o));
    try std.testing.expectEqual(DragHit.resize_bottom, classify(800, 600, 400, 599, o));
}

test "titlebar is draggable except over exclusions" {
    const excl = [_]Rect{.{ .x = 700, .y = 0, .w = 100, .h = 30 }}; // caption buttons
    const o = Opts{ .titlebar_height = 30, .border = 4, .exclusions = &excl };
    try std.testing.expectEqual(DragHit.draggable, classify(800, 600, 200, 10, o));
    try std.testing.expectEqual(DragHit.normal, classify(800, 600, 750, 10, o)); // on buttons
    try std.testing.expectEqual(DragHit.normal, classify(800, 600, 200, 300, o)); // body
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/apprt/window_drag_region.zig`
Expected: FAIL — types/`classify` undefined.

- [ ] **Step 3: Implement**

```zig
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const DragHit = enum {
    normal, draggable,
    resize_top, resize_bottom, resize_left, resize_right,
    resize_top_left, resize_top_right, resize_bottom_left, resize_bottom_right,
};

pub const Opts = struct { titlebar_height: i32, border: i32, exclusions: []const Rect };

fn inRect(r: Rect, x: i32, y: i32) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

pub fn classify(w: i32, h: i32, x: i32, y: i32, o: Opts) DragHit {
    const b = o.border;
    const left = x < b;
    const right = x >= w - b;
    const top = y < b;
    const bottom = y >= h - b;
    if (top and left) return .resize_top_left;
    if (top and right) return .resize_top_right;
    if (bottom and left) return .resize_bottom_left;
    if (bottom and right) return .resize_bottom_right;
    if (top) return .resize_top;
    if (bottom) return .resize_bottom;
    if (left) return .resize_left;
    if (right) return .resize_right;
    if (y < o.titlebar_height) {
        for (o.exclusions) |r| if (inRect(r, x, y)) return .normal;
        return .draggable;
    }
    return .normal;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig test src/apprt/window_drag_region.zig`
Expected: PASS.

- [ ] **Step 5: Register + full suite**

Add `_ = @import("apprt/window_drag_region.zig");` to the `test { }` block in `src/test_fast.zig`.
Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/apprt/window_drag_region.zig src/test_fast.zig
git commit -m "feat(linux): pure window drag/resize region classifier"
```

---

### Task A3: Run-on-main marshaling queue

**Files:**
- Create: `src/apprt/run_on_main.zig`
- Modify: `src/test_posix.zig` (thread test; runs under `test-full` on a posix host)

- [ ] **Step 1: Write the failing test**

In `src/test_posix.zig`, add a test importing the module:

```zig
const run_on_main = @import("apprt/run_on_main.zig");

test "run_on_main marshals a task from a worker thread to the draining thread" {
    var q = run_on_main.Queue{};
    defer q.deinit(std.testing.allocator);

    const State = struct { value: i32 = 0, done: std.Thread.ResetEvent = .{} };
    var st = State{};

    const Worker = struct {
        fn go(queue: *run_on_main.Queue, state: *State) void {
            const run = struct {
                fn f(ctx: *anyopaque) void {
                    const s: *State = @ptrCast(@alignCast(ctx));
                    s.value = 42;
                    s.done.set();
                }
            }.f;
            queue.enqueue(std.testing.allocator, .{ .run = run, .ctx = state }) catch unreachable;
        }
    };
    var t = try std.Thread.spawn(.{}, Worker.go, .{ &q, &st });
    t.join();

    try std.testing.expectEqual(@as(i32, 0), st.value); // not run until drained
    q.drain(std.testing.allocator);
    st.done.wait();
    try std.testing.expectEqual(@as(i32, 42), st.value);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full`
Expected: FAIL — `apprt/run_on_main.zig` missing.

- [ ] **Step 3: Implement**

Create `src/apprt/run_on_main.zig`:

```zig
//! Thread-safe queue of closures to run on the main (event-pump) thread. The
//! Linux/SDL analog of macOS `wispterm_macos_run_on_main`: worker-thread
//! windows enqueue window-mutation closures here and wake the main pump
//! (`postWakeup`); the main thread drains them inside `pumpAppEvents`.
const std = @import("std");

pub const Task = struct {
    run: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const Queue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayListUnmanaged(Task) = .{},

    pub fn enqueue(self: *Queue, alloc: std.mem.Allocator, task: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(alloc, task);
    }

    /// Run every queued task in FIFO order. Tasks are copied out under the lock
    /// so a task may itself enqueue without deadlocking.
    pub fn drain(self: *Queue, alloc: std.mem.Allocator) void {
        self.mutex.lock();
        const batch = self.items.toOwnedSlice(alloc) catch {
            // OOM: fall back to running in place under the lock.
            defer self.mutex.unlock();
            for (self.items.items) |t| t.run(t.ctx);
            self.items.clearRetainingCapacity();
            return;
        };
        self.mutex.unlock();
        defer alloc.free(batch);
        for (batch) |t| t.run(t.ctx);
    }

    pub fn deinit(self: *Queue, alloc: std.mem.Allocator) void {
        self.items.deinit(alloc);
    }
};
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-full`
Expected: PASS (the new posix test included).

- [ ] **Step 5: Commit**

```bash
git add src/apprt/run_on_main.zig src/test_posix.zig
git commit -m "feat(linux): thread-safe run-on-main marshaling queue"
```

---

### Task A4: Window registry (windowID → window pointer)

**Files:**
- Create: `src/apprt/window_registry.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing test**

```zig
//! Pure map from an SDL windowID (u32) to an opaque window pointer, so the
//! main-thread pump can route each event to the owning window's queues. Stored
//! as *anyopaque to avoid an import cycle with apprt/sdl.zig.
const std = @import("std");

test "register, find, and remove by id" {
    var reg = Registry{};
    var a: u8 = 1;
    var b: u8 = 2;
    reg.set(10, &a);
    reg.set(20, &b);
    try std.testing.expect(reg.find(10).? == @as(*anyopaque, &a));
    try std.testing.expect(reg.find(20).? == @as(*anyopaque, &b));
    try std.testing.expect(reg.find(30) == null);
    reg.remove(10);
    try std.testing.expect(reg.find(10) == null);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/apprt/window_registry.zig`
Expected: FAIL — `Registry` undefined.

- [ ] **Step 3: Implement**

```zig
const MAX_WINDOWS = 64;

pub const Registry = struct {
    const Entry = struct { id: u32, ptr: *anyopaque };
    entries: [MAX_WINDOWS]?Entry = [_]?Entry{null} ** MAX_WINDOWS,
    mutex: std.Thread.Mutex = .{},

    pub fn set(self: *Registry, id: u32, ptr: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var free: ?usize = null;
        for (self.entries, 0..) |e, i| {
            if (e) |entry| { if (entry.id == id) { self.entries[i] = .{ .id = id, .ptr = ptr }; return; } }
            else if (free == null) free = i;
        }
        if (free) |i| self.entries[i] = .{ .id = id, .ptr = ptr };
    }

    pub fn find(self: *Registry, id: u32) ?*anyopaque {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries) |e| if (e) |entry| { if (entry.id == id) return entry.ptr; };
        return null;
    }

    pub fn remove(self: *Registry, id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries, 0..) |e, i| if (e) |entry| { if (entry.id == id) { self.entries[i] = null; return; } };
    }
};
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig test src/apprt/window_registry.zig`
Expected: PASS.

- [ ] **Step 5: Register + full suite**

Add `_ = @import("apprt/window_registry.zig");` to `src/test_fast.zig`'s `test { }` block.
Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/apprt/window_registry.zig src/test_fast.zig
git commit -m "feat(linux): pure windowID → window registry for event routing"
```

---

## Phase B — Build wiring (linux target emits the host)

### Task B1: Teach `build.zig` the Linux desktop backend + `pkg/sdl`

**Files:**
- Modify: `build.zig` (`PlatformFeatures.forOs`, the two guard tests, exe linking)
- Create: `pkg/sdl/build.zig`, `pkg/sdl/sdl.zig` (C-header module, mirrors `pkg/opengl`)

- [ ] **Step 1: Add a Linux arm to `PlatformFeatures.forOs`**

In `build.zig`, edit `forOs` (around line 84) so Linux is a desktop backend with SDL as its system library:

```zig
    fn forOs(os_tag: std.Target.Os.Tag) PlatformFeatures {
        const uses_windows_backend = os_tag == .windows;
        const uses_macos_backend = os_tag == .macos;
        const uses_linux_backend = os_tag == .linux;
        const has_desktop_backend = uses_windows_backend or uses_macos_backend or uses_linux_backend;
        const has_app_bundle = os_tag == .macos;
        const embedded_browser_backend: EmbeddedBrowserBackend = if (uses_windows_backend)
            .webview2
        else if (uses_macos_backend)
            .webkit
        else
            .none; // linux: webview disabled (SP5)
        return .{
            .supports_desktop_exe = has_desktop_backend,
            .supports_embedded_browser = embedded_browser_backend.isSupported(),
            .embedded_browser_backend = embedded_browser_backend,
            .supports_resource_manifest = uses_windows_backend,
            .supports_gui_subsystem = uses_windows_backend,
            .supports_remote_transport = uses_windows_backend,
            .supports_app_bundle = has_app_bundle,
            .system_libraries = if (uses_windows_backend) &windows_system_libraries else if (uses_linux_backend) &linux_system_libraries else &.{},
            .app_frameworks = if (has_app_bundle) &macos_app_frameworks else &.{},
            .opengl_system_library = if (uses_windows_backend) "opengl32" else null,
        };
    }
```

Add near `windows_system_libraries` (search for its definition):

```zig
const linux_system_libraries = [_][]const u8{ "SDL3" };
```

- [ ] **Step 2: Flip the guard tests that assert "Linux has no desktop backend"**

In `build.zig`, find and update these two tests (they currently encode the pre-port state):

```zig
test "desktop executable emission defaults to implemented platform backends" {
    try std.testing.expect(defaultEmitDesktopExe(PlatformFeatures.forOs(.windows)));
    try std.testing.expect(defaultEmitDesktopExe(PlatformFeatures.forOs(.linux))); // was: !defaultEmitDesktopExe
    try std.testing.expect(defaultEmitDesktopExe(PlatformFeatures.forOs(.macos)));
}

test "shared compile checks default to platforms without desktop backends" {
    try std.testing.expect(!defaultEmitSharedCompileChecks(PlatformFeatures.forOs(.windows)));
    try std.testing.expect(!defaultEmitSharedCompileChecks(PlatformFeatures.forOs(.linux))); // was: defaultEmitSharedCompileChecks
    try std.testing.expect(!defaultEmitSharedCompileChecks(PlatformFeatures.forOs(.macos)));
}
```

Also update the `PlatformFeatures.forOs(.linux)` assertion test (search for `const linux = PlatformFeatures.forOs(.linux);`) so it expects `supports_desktop_exe == true` and `embedded_browser_backend == .none`.

- [ ] **Step 3: Link SDL for the desktop exe**

Find where the desktop executable links `system_libraries` / `opengl_system_library` (search `linkSystemLibrary`). Confirm the existing loop over `systemLibrariesFor(platform)` will now link `SDL3` on Linux. If `opengl_system_library` is the only GL link path, add (Linux only) nothing extra — glad loads GL through SDL's proc-address loader at runtime, so no link-time `GL` is required. Leave a comment to that effect.

- [ ] **Step 4: Create `pkg/sdl` (mirror `pkg/opengl`)**

Read `pkg/opengl/build.zig` and `pkg/opengl/*.zig` first to copy the structure. Create `pkg/sdl/build.zig` that adds a module exposing `@cImport(@cInclude("SDL3/SDL.h"))` and links `SDL3`; create `pkg/sdl/sdl.zig` as the thin `pub const c = @cImport(@cInclude("SDL3/SDL.h"));` re-export. Add the `.sdl = .{ .path = "pkg/sdl" }` dependency to `build.zig.zon` and wire it into the module graph for desktop builds the same way `opengl`/`freetype` are wired in `build.zig`.

- [ ] **Step 5: Verify build.zig tests + default target unaffected**

Run: `zig build test`
Expected: PASS (guard-test edits compile and hold; default Windows target build path unchanged).

- [ ] **Step 6: Commit**

```bash
git add build.zig build.zig.zon pkg/sdl
git commit -m "build(linux): SDL3 desktop backend feature gate + pkg/sdl"
```

---

## Phase C — The SDL shell (build + GUI-smoke verified)

> These tasks touch real SDL/GL and a display server; they cannot run in `zig build test`. Verification = the exact build command + the GUI smoke checklist in each task. This matches the repo's existing "backend = GUI-verify" reality (macOS/Windows backends are not unit-tested either). Confirm SDL3 struct/enum field names against the installed `SDL3/SDL.h` while implementing — the call *sequence* below is fixed; SDL3 point releases occasionally rename a field.

### Task C1: Lower-level `window_linux.zig` + facade `.linux` arms

**Files:**
- Create: `src/platform/window_linux.zig`
- Create: `src/platform/window_backend_linux.zig`
- Modify: `src/platform/window.zig`, `src/platform/window_backend.zig`, `src/platform/font_backend.zig`

- [ ] **Step 1: `window_linux.zig` from the unsupported template**

Copy `src/platform/window_unsupported.zig` → `src/platform/window_linux.zig` as the starting point (it already provides correct no-op shapes for the Win32-message-shaped surface: `NativeHandle`, `MessageId`, `WordParam`, `LongParam`, `MessageResult`, `titlebar_height`, `CaptionButton`, caption color/width constants, `getClientRect`, `getWindowRect`, `setOuterFrame`, `nearestMonitorWorkArea`/`nearestMonitorRect`, `dpiForWindow`, `showVisible`/`showHidden`/`setForeground`/`isMaximized`/`showRestored`/`showMaximized`, `getWindowStyle`/`setWindowStyle`/`setWindowFrame`, `postCloseMessage`/`postMessage`/`sendMessage`/`appMessage`/`hotkey_message`, `nativeHandleFromBits`, `consumeReopenRequest`/`consumeQuitRequest`/`requestQuit`, `pumpAppEvents`, `postWakeup`). Read `window_unsupported.zig` to confirm the exact exported set.

- [ ] **Step 2: Route the real event-loop hooks to `apprt/sdl.zig`**

In `window_linux.zig`, replace the no-op `pumpAppEvents`, `postWakeup`, `consumeQuitRequest`, `consumeReopenRequest`, and `dpiForWindow` with calls into `apprt/sdl.zig` (added in C3):

```zig
const sdl = @import("../apprt/sdl.zig");
pub fn pumpAppEvents(timeout_seconds: f64) void { sdl.pumpAppEvents(timeout_seconds); }
pub fn postWakeup() void { sdl.postWakeup(); }
pub fn consumeQuitRequest() bool { return sdl.consumeQuitRequest(); }
pub fn consumeReopenRequest() bool { return false; } // no Dock reopen on Linux
pub fn dpiForWindow(handle: NativeHandle) u32 { return sdl.dpiForNativeHandle(handle); }
```

(Leave the Win32-message primitives as the unsupported no-ops; the SDL host does not use a Win32-style message bus.)

- [ ] **Step 3: `window_backend_linux.zig` re-export**

```zig
const sdl = @import("../apprt/sdl.zig");
pub const Window = sdl.Window;
pub const FileDropHandler = sdl.FileDropHandler;
pub const setGlobalWindow = sdl.setGlobalWindow;
pub const glGetProcAddress = sdl.glGetProcAddress;
```

- [ ] **Step 4: Add `.linux` arms to the three facades**

In `window.zig`, `window_backend.zig`, and `font_backend.zig`: add `linux` to each `Backend` enum, change `backendForOs` to `.linux => .linux`, and add the `.linux => @import("<name>_linux.zig")` arm to each `impl` switch. For `font_backend.zig`, point `.linux` at a 6-line `font_backend_linux.zig` that re-exports the `unsupported` impl for now (real fontconfig is SP2) — create it as `pub usingnamespace @import("font_backend_unsupported.zig");` or explicit re-exports matching that file's public decls.

- [ ] **Step 5: Build-check (will fail until C3 defines `apprt/sdl.zig`)**

This task does not build standalone; it is completed together with C2/C3. Mark done when the files exist and the facade arms compile against the C2/C3 `apprt/sdl.zig`. Do not commit until C2.

---

### Task C2: `apprt/sdl.zig` — window + GL 3.3 + hit-test (window opens)

**Files:**
- Create: `src/apprt/sdl.zig`

- [ ] **Step 1: Window struct + SDL init + GL context**

Create `src/apprt/sdl.zig`. Import the C header and the pure modules; define the `Window` struct with the field set enumerated in the spec (native `*c.SDL_Window`, `gl_ctx`, sizes/dpi/titlebar/sidebar/tab_count, mouse, hovered_button, button-bounds arrays, the flags, callbacks, and the five **mutex-guarded** event queues). Implement `init` doing the GL-attribute + `SDL_CreateWindow(... OPENGL|RESIZABLE|BORDERLESS|HIGH_PIXEL_DENSITY)` + `SDL_GL_CreateContext` + `SDL_GL_MakeCurrent` sequence from the spec, register `SDL_SetWindowHitTest`, and store the window in a module-level `Registry` keyed by `SDL_GetWindowID`.

```zig
const c = @import("sdl").c; // pkg/sdl
const keymap = @import("../input/sdl_keymap.zig");
const region = @import("window_drag_region.zig");
const registry = @import("window_registry.zig");
const rom = @import("run_on_main.zig");
const ev = @import("../platform/input_events.zig");
// ... Window struct + init() per spec ...

pub fn glGetProcAddress(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    return @ptrCast(c.SDL_GL_GetProcAddress(name));
}
```

- [ ] **Step 2: Hit-test callback uses the pure classifier**

```zig
fn hitTest(win: ?*c.SDL_Window, pt: [*c]const c.SDL_Point, data: ?*anyopaque) callconv(.c) c.SDL_HitTestResult {
    const self: *Window = @ptrCast(@alignCast(data.?));
    const hit = region.classify(self.width, self.height, pt.*.x, pt.*.y, .{
        .titlebar_height = self.titlebar_height,
        .border = 4,
        .exclusions = self.captionExclusions(), // builds rects from close/plus button bounds
    });
    _ = win;
    return switch (hit) {
        .draggable => c.SDL_HITTEST_DRAGGABLE,
        .resize_top => c.SDL_HITTEST_RESIZE_TOP,
        // ... all resize_* arms ...
        .normal => c.SDL_HITTEST_NORMAL,
    };
}
```

- [ ] **Step 3: `swapBuffers` + minimal pump stubs to compile**

Implement `swapBuffers` (`SDL_GL_SwapWindow`), and provisional `pumpAppEvents`/`postWakeup`/`consumeQuitRequest`/`dpiForNativeHandle`/`setGlobalWindow` (filled fully in C3 — for now `pumpAppEvents` may just `SDL_PumpEvents` + clear the queue so it links). Wire `gpu/opengl/Context.zig:init(@ptrCast(&glGetProcAddress))` at window init so the renderer's glad table loads.

- [ ] **Step 4: Build for Linux**

Run: `zig build -Dtarget=x86_64-linux-gnu` (on a host with SDL3 dev installed; or native `zig build` on Linux).
Expected: links; produces `wispterm`.

- [ ] **Step 5: GUI smoke — window opens**

On an X11 session, run the produced binary. Expected: a borderless window appears, the GL clear color / first frame draws, and dragging the top region moves the window. Note any failure for the spike.

- [ ] **Step 6: Commit (C1 + C2 together)**

```bash
git add src/apprt/sdl.zig src/platform/window_linux.zig src/platform/window_backend_linux.zig src/platform/font_backend_linux.zig src/platform/window.zig src/platform/window_backend.zig src/platform/font_backend.zig
git commit -m "feat(linux): SDL3 window + GL 3.3 context + custom-chrome hit-test"
```

---

### Task C3: Event pump → neutral queues (terminal is interactive)

**Files:**
- Modify: `src/apprt/sdl.zig`

- [ ] **Step 1: Implement `pumpAppEvents` (main-thread pump + routing + marshal drain)**

```zig
pub fn pumpAppEvents(timeout_seconds: f64) void {
    var e: c.SDL_Event = undefined;
    const ms: i32 = @intFromFloat(timeout_seconds * 1000.0);
    if (c.SDL_WaitEventTimeout(&e, ms)) {
        routeEvent(&e);
        while (c.SDL_PollEvent(&e)) routeEvent(&e);
    }
    g_run_on_main.drain(g_alloc); // run marshaled window-ops
}
```

`routeEvent` switches on `e.type`: for input events, look up the target `Window` via `registry.find(windowID)` and push the translated neutral event onto that window's queue using `keymap.keyCodeFromScancode` / `keymap.modifiers`; `SDL_EVENT_TEXT_INPUT` → `CharEvent` (UTF-8 decode to `u21`); mouse button/motion/wheel → the matching neutral events; `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED` → set `size_changed` + `on_resize`; `SDL_EVENT_WINDOW_CLOSE_REQUESTED` → `close_requested`; `SDL_EVENT_QUIT` → set a module `g_quit` flag; `SDL_EVENT_DROP_FILE` → `on_file_drop`.

- [ ] **Step 2: `postWakeup` + `pollEvents` + quit**

```zig
pub fn postWakeup() void {
    var e: c.SDL_Event = .{ .type = g_wakeup_event_type };
    _ = c.SDL_PushEvent(&e); // interrupts SDL_WaitEventTimeout from any thread
}
pub fn consumeQuitRequest() bool { const q = g_quit; g_quit = false; return q; }
```

Register `g_wakeup_event_type = c.SDL_RegisterEvents(1)` during `SDL_Init`. `pollEvents(win)` returns `!win.close_requested`.

- [ ] **Step 3: Per-window queue pop accessors**

Implement `popKeyEvent`/`popCharEvent`/`popMouseButtonEvent`/`popMouseMoveEvent`/`popMouseWheelEvent`/`clearTransientInputQueues` on `Window` (mutex-guarded pop from the queues filled by the main-thread `routeEvent`). These satisfy the `window_backend.zig` facade drains.

- [ ] **Step 4: Build**

Run: `zig build -Dtarget=x86_64-linux-gnu`
Expected: links.

- [ ] **Step 5: GUI smoke — interactive terminal**

Run on X11. Expected checklist:
- A shell prompt renders in the cell grid (pty_posix spawned the shell).
- Typing ASCII echoes; Enter/Backspace/arrows work (special keys via A1).
- Mouse click positions the cursor / selects; wheel scrolls.
- Resizing the window reflows the grid with no GL corruption.
- Closing the window exits cleanly (no hang, no leak on `deinit`).

Record results in the SP1 spec's Acceptance section.

- [ ] **Step 6: Run full suite + commit**

Run: `zig build test && zig build test-full`
Expected: green (pure modules + guard tests; SDL shell is compiled in the full graph only on a linux target — confirm `test-full`'s default windows-gnu target still builds since the `.linux` arms are comptime-gated out).

```bash
git add src/apprt/sdl.zig
git commit -m "feat(linux): SDL event pump → neutral input queues; interactive terminal"
```

---

## Phase D — Threading spike + multi-window decision

### Task D1: Spike a second worker-thread window; decide SP1 vs SP1b

**Files:**
- Modify: `src/apprt/sdl.zig` (only if the spike succeeds and multi-window lands in SP1)
- Modify: the SP1 spec (record the decision in Acceptance #4)

- [ ] **Step 1: Reproduce the multi-window path**

With the single window working, trigger `Ctrl+Shift+N` (the existing `requestNewWindow`, which spawns a worker thread running `AppWindow.runMainLoop`). Observe: does the second window's `runMainLoop` (on a worker thread) receive routed input, and do its window-mutations (resize/setframe) crash or no-op?

- [ ] **Step 2: Apply the marshal model if needed**

If worker-thread windows mis-handle SDL calls, route every SDL *window mutation* invoked off the main thread through `run_on_main.Queue` (Task A3): the worker enqueues the closure + `postWakeup()`, the main `pumpAppEvents` drains it. Input already flows correctly because routing happens on the main thread into the thread-safe queues (Task A4 + C3).

- [ ] **Step 3: GUI smoke — two windows**

Open two windows; verify both render, both accept input independently, resizing/closing either works, and closing the last exits cleanly.

- [ ] **Step 4: Record the decision**

Edit the SP1 spec Acceptance #4: either "multi-window landed in SP1" (with the commit) or "multi-window deferred to SP1b" (with the specific blocker found). If deferred, gate `requestNewWindow` on Linux behind a clear "single window on Linux for now" path so the app stays usable.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(linux): multi-window via run-on-main marshaling (spike outcome)"
# or, if deferred:
# git commit -m "docs(linux): record SP1b multi-window deferral + single-window guard"
```

---

## Self-review (completed while writing)

- **Spec coverage:** structure mirror (C1), GL 3.3 (C2), input mapping incl. VK-valued neutral codes + TEXT_INPUT (A1/C3), event-loop hooks `pumpAppEvents`/`pollEvents`/`postWakeup` (C3), single-main-queue routing by windowID (A4/C3), run-on-main marshal mirroring macOS (A3/D1), borderless + hit-test custom chrome (A2/C2), DPI/geometry (C2/C3), build.zig gate + flipped guard tests + `pkg/sdl` + dev-system-link (B1), single-window acceptance + spike-decides-multi-window (C3/D1), embedded-font-for-bring-up + fontconfig deferred to SP2 (C1) — all mapped.
- **Placeholders:** none; pure modules have full test+impl code, the shell tasks give fixed SDL call sequences + exact build commands + explicit GUI checklists (the only honest verification for display-server code).
- **Type consistency:** `KeyCode`/`Mods`/`DragHit`/`Rect`/`Opts`/`Task`/`Queue`/`Registry` names and signatures are used identically across tasks; neutral event types match `input_events.zig`.

## Execution note for the worker

SP1 only lights up after C2/C3 (the shell), so Phase A commits are independently green in `zig build test` but the **first runnable Linux app** is at the end of C3. Do Phase A → B → C in order; Phase A is safe to parallelize internally. Needs a Linux box (or VM/WSLg with an X server) + SDL3 dev headers to run the GUI smokes.
