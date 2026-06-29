# macOS One-Click Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a macOS DMG update is downloaded, let the user click "立即更新" to swap the running `WispTerm.app` and relaunch — automating today's manual mount-and-drag step.

**Architecture:** Reuse the existing check → download flow (`update_check.zig`, `update_install.zig`). Add a new platform module `update_apply` that, on macOS, mounts the downloaded DMG, verifies its code signature, writes a detached `/bin/sh` helper that waits for the app to exit, swaps the bundle with `ditto`, and relaunches. The app then quits normally. Non-macOS targets return `error.UpdateInstallUnsupported` and the UI falls back to today's manual prompt.

**Tech Stack:** Zig, `std.process.Child` (hdiutil / codesign / sh), `std.fs`, existing renderer/overlay + command-center wiring.

## Global Constraints

- Single version source: `build.zig.zon` → `build_options.app_version`. Do NOT add another version constant.
- No new build target, no new packaged binary, no new dependency (Sparkle excluded — see [ROADMAP.md](../../../ROADMAP.md)). The update helper is a generated shell script.
- macOS bundle: `WispTerm.app`, identifier `com.wispterm.terminal`. The downloaded asset is `wispterm-macos-<tag>.dmg` ([src/platform/update_package_macos.zig:20](../../../src/platform/update_package_macos.zig)).
- Windows behavior is unchanged and out of scope. New code must still compile on the Windows target (default `zig build` target).
- Code-signature verification of the downloaded app is mandatory (download-integrity trust boundary). Never skip it.
- Fast pure-logic tests run via `zig build test`. macOS-only code runs via `zig build test-full -Dtarget=aarch64-macos` (bare `test-full` only compile-checks). The `skill center tool import` test is known-flaky and unrelated.

---

### Task 1: macOS apply module — pure helpers + platform dispatch scaffolding

Creates the new module with the two unit-testable pure functions and the cross-platform dispatch, wired into `App` (import only; used in Task 3). No behavior change yet; build stays green on all targets.

**Files:**
- Create: `src/platform/update_apply.zig`
- Create: `src/platform/update_apply_macos.zig`
- Create: `src/platform/update_apply_windows.zig`
- Create: `src/platform/update_apply_unsupported.zig`
- Modify: `src/App.zig` (add import near line 30, next to `update_install`)
- Test: inline tests in `src/platform/update_apply_macos.zig`

**Interfaces:**
- Produces:
  - `update_apply.isSupported() bool`
  - `update_apply.applyUpdate(allocator: std.mem.Allocator, dmg_path: []const u8, exe_path: []const u8) !void`
  - `update_apply_macos.resolveAppBundle(exe_path: []const u8) ?[]const u8` (slice into `exe_path`, no allocation)
  - `update_apply_macos.renderHelperScript(allocator, pid: i32, new_app: []const u8, dst_app: []const u8, mount_point: []const u8) ![]u8`

- [ ] **Step 1: Create the dispatch module**

Create `src/platform/update_apply.zig`:

```zig
//! Cross-platform dispatch for applying a downloaded update in place.
//! Only macOS implements an in-place swap today; other targets report
//! unsupported so the UI falls back to the manual "saved to Downloads" prompt.
const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .macos => @import("update_apply_macos.zig"),
    .windows => @import("update_apply_windows.zig"),
    else => @import("update_apply_unsupported.zig"),
};

/// True when this platform can swap the running app in place.
pub fn isSupported() bool {
    return builtin.os.tag == .macos;
}

/// Apply the update at `dmg_path` to the bundle that `exe_path` lives in.
/// On success the platform impl has launched a detached helper and the caller
/// MUST quit so the helper can swap and relaunch. On error the caller falls
/// back to the manual prompt; the running app is left untouched.
pub fn applyUpdate(allocator: std.mem.Allocator, dmg_path: []const u8, exe_path: []const u8) !void {
    return impl.applyUpdate(allocator, dmg_path, exe_path);
}
```

- [ ] **Step 2: Create the Windows + unsupported stubs**

Create `src/platform/update_apply_windows.zig`:

```zig
//! Windows has no in-place updater yet (see ROADMAP). Report unsupported so the
//! UI keeps today's manual download behavior.
const std = @import("std");

pub fn applyUpdate(allocator: std.mem.Allocator, dmg_path: []const u8, exe_path: []const u8) !void {
    _ = allocator;
    _ = dmg_path;
    _ = exe_path;
    return error.UpdateInstallUnsupported;
}
```

Create `src/platform/update_apply_unsupported.zig` with identical contents (same `applyUpdate` returning `error.UpdateInstallUnsupported`).

- [ ] **Step 3: Write the macOS module with pure helpers (no orchestration yet) and failing tests**

Create `src/platform/update_apply_macos.zig`:

```zig
//! macOS in-place updater: mount the downloaded DMG, verify its signature,
//! and launch a detached shell helper that swaps the bundle once the running
//! app exits, then relaunches it. `applyUpdate` is added in a later task.
const std = @import("std");

/// Given an absolute executable path, return the enclosing `*.app` bundle path
/// (a slice of `exe_path`), or null when the executable is not inside a bundle
/// (e.g. a dev build run from zig-out/bin) — the caller then falls back to the
/// manual prompt.
pub fn resolveAppBundle(exe_path: []const u8) ?[]const u8 {
    var path = exe_path;
    while (true) {
        const base = std.fs.path.basename(path);
        if (std.mem.endsWith(u8, base, ".app")) return path;
        const parent = std.fs.path.dirname(path) orelse return null;
        if (parent.len >= path.len) return null; // reached root, no progress
        path = parent;
    }
}

/// Render the detached helper script. It waits for `pid` to exit, stages the
/// new bundle as `<dst>.new` (so a failed copy never deletes the working app),
/// swaps it into place, detaches the DMG, and relaunches. Caller owns the slice.
pub fn renderHelperScript(
    allocator: std.mem.Allocator,
    pid: i32,
    new_app: []const u8,
    dst_app: []const u8,
    mount_point: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\while kill -0 {d} 2>/dev/null; do sleep 0.2; done
        \\if ditto "{s}" "{s}.new"; then
        \\  rm -rf "{s}"
        \\  mv "{s}.new" "{s}"
        \\fi
        \\hdiutil detach "{s}" -quiet || true
        \\open "{s}"
        \\
    , .{ pid, new_app, dst_app, dst_app, dst_app, dst_app, mount_point, dst_app });
}

test "resolveAppBundle finds the .app for an executable inside a bundle" {
    const got = resolveAppBundle("/Applications/WispTerm.app/Contents/MacOS/WispTerm");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("/Applications/WispTerm.app", got.?);
}

test "resolveAppBundle returns null for a bare binary (dev build)" {
    try std.testing.expect(resolveAppBundle("/Users/x/code/zig-out/bin/WispTerm") == null);
}

test "renderHelperScript embeds pid, swap, detach and relaunch" {
    const a = std.testing.allocator;
    const s = try renderHelperScript(a, 4321, "/Volumes/WispTerm/WispTerm.app", "/Applications/WispTerm.app", "/Volumes/WispTerm");
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "kill -0 4321") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "ditto \"/Volumes/WispTerm/WispTerm.app\" \"/Applications/WispTerm.app.new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "mv \"/Applications/WispTerm.app.new\" \"/Applications/WispTerm.app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "hdiutil detach \"/Volumes/WispTerm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "open \"/Applications/WispTerm.app\"") != null);
}
```

- [ ] **Step 4: Wire the import into App so the macOS tests compile into the test binary**

In `src/App.zig`, add next to the existing update import (after line 30 `const update_install = @import("update_install.zig");`):

```zig
const update_apply = @import("platform/update_apply.zig");
```

(Unused for now — Zig allows unused container-level imports. Used in Task 3.)

- [ ] **Step 5: Run the macOS tests to verify they pass**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | tail -30`
Expected: PASS (ignore the known-flaky `skill center tool import` test). The three new tests in `update_apply_macos.zig` run and pass.

- [ ] **Step 6: Verify the Windows target still compiles**

Run: `zig build 2>&1 | tail -20`
Expected: builds clean (dispatch selects `update_apply_windows.zig`).

- [ ] **Step 7: Commit**

```bash
git add src/platform/update_apply.zig src/platform/update_apply_macos.zig src/platform/update_apply_windows.zig src/platform/update_apply_unsupported.zig src/App.zig
git commit -m "feat(update): add macOS apply module scaffolding + pure helpers"
```

---

### Task 2: macOS `applyUpdate` orchestration

Adds the real mount/verify/stage/launch logic. Process I/O is not unit-testable (matches `update_install.zig` convention) — covered by compile + manual verification.

**Files:**
- Modify: `src/platform/update_apply_macos.zig`

**Interfaces:**
- Consumes: `resolveAppBundle`, `renderHelperScript` (from Task 1).
- Produces: `update_apply_macos.applyUpdate(allocator, dmg_path: []const u8, exe_path: []const u8) !void`

- [ ] **Step 1: Add the orchestration + private process helpers**

Append to `src/platform/update_apply_macos.zig` (after the pure functions, before the tests):

```zig
/// Mount the DMG, verify the new app's signature, stage a detached helper, and
/// launch it. On success the helper is running and the caller MUST quit. Any
/// failure before launch detaches the DMG (if mounted) and returns an error;
/// the running app is left untouched.
pub fn applyUpdate(allocator: std.mem.Allocator, dmg_path: []const u8, exe_path: []const u8) !void {
    const bundle = resolveAppBundle(exe_path) orelse return error.NotInAppBundle;

    const mount_point = try attachDmg(allocator, dmg_path);
    defer allocator.free(mount_point);
    errdefer detachQuiet(allocator, mount_point);

    const new_app = try std.fs.path.join(allocator, &.{ mount_point, "WispTerm.app" });
    defer allocator.free(new_app);
    std.fs.accessAbsolute(new_app, .{}) catch return error.AppNotFoundInDmg;

    try verifyCodesign(allocator, new_app);

    const script_path = try writeHelperScript(allocator, new_app, bundle, mount_point);
    defer allocator.free(script_path);

    // Helper now owns the mount point (it detaches after the swap), so do NOT
    // run the errdefer detach past this point.
    try launchHelper(allocator, script_path);
}

/// Run `hdiutil attach` and return the mount point (caller frees).
/// ponytail: parse the "/Volumes/..." token from text output instead of
/// -plist; our volume name ("WispTerm") has no spaces or newlines.
fn attachDmg(allocator: std.mem.Allocator, dmg_path: []const u8) ![]u8 {
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", dmg_path },
        .max_output_bytes = 64 * 1024,
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.term != .Exited or res.term.Exited != 0) return error.DmgMountFailed;

    const idx = std.mem.indexOf(u8, res.stdout, "/Volumes/") orelse return error.DmgMountFailed;
    var end = idx;
    while (end < res.stdout.len and res.stdout[end] != '\n' and res.stdout[end] != '\r') end += 1;
    const mp = std.mem.trimRight(u8, res.stdout[idx..end], " \t");
    return allocator.dupe(u8, mp);
}

fn detachQuiet(allocator: std.mem.Allocator, mount_point: []const u8) void {
    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/usr/bin/hdiutil", "detach", mount_point, "-quiet" },
        .max_output_bytes = 4 * 1024,
    }) catch return;
    allocator.free(res.stdout);
    allocator.free(res.stderr);
}

/// Verify the downloaded app's signature (download integrity). Mandatory.
fn verifyCodesign(allocator: std.mem.Allocator, app_path: []const u8) !void {
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/usr/bin/codesign", "--verify", "--deep", "--strict", app_path },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.term != .Exited or res.term.Exited != 0) return error.CodesignVerifyFailed;
}

/// Render the helper to a temp file and return its path (caller frees).
fn writeHelperScript(allocator: std.mem.Allocator, new_app: []const u8, dst_app: []const u8, mount_point: []const u8) ![]u8 {
    const pid = std.c.getpid();
    const script = try renderHelperScript(allocator, pid, new_app, dst_app, mount_point);
    defer allocator.free(script);

    const tmp = std.mem.trimRight(u8, std.posix.getenv("TMPDIR") orelse "/tmp", "/");
    const path = try std.fmt.allocPrint(allocator, "{s}/wispterm-update-{d}.sh", .{ tmp, pid });
    errdefer allocator.free(path);

    var f = try std.fs.createFileAbsolute(path, .{ .mode = 0o755 });
    defer f.close();
    try f.writeAll(script);
    return path;
}

/// Launch the helper fully detached so it survives this process exiting.
/// `nohup ... &` inside `sh -c` backgrounds and reparents the job; the outer
/// shell returns immediately. The script path is our temp path (no quotes).
fn launchHelper(allocator: std.mem.Allocator, script_path: []const u8) !void {
    const cmd = try std.fmt.allocPrint(allocator, "nohup /bin/sh '{s}' >/dev/null 2>&1 &", .{script_path});
    defer allocator.free(cmd);

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = child.wait() catch {}; // outer sh exits at once after backgrounding
}
```

- [ ] **Step 2: Verify macOS build compiles and pure tests still pass**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | tail -30`
Expected: PASS (the three pure tests from Task 1 still pass; new code compiles).

- [ ] **Step 3: Verify Windows target still compiles**

Run: `zig build 2>&1 | tail -20`
Expected: clean (only the macOS impl references `std.c.getpid`/hdiutil).

- [ ] **Step 4: Commit**

```bash
git add src/platform/update_apply_macos.zig
git commit -m "feat(update): implement macOS DMG mount-verify-swap orchestration"
```

---

### Task 3: `App.requestUpdateInstall`

Glue: read the downloaded asset name, resolve the running exe path, call `update_apply.applyUpdate`, and on success quit so the helper swaps + relaunches. No unit test (thin glue over orchestration + quit) — verified by compile and the end-to-end manual run in Task 5.

**Files:**
- Modify: `src/App.zig`

**Interfaces:**
- Consumes: `update_apply.applyUpdate`, `update_apply.isSupported` (Task 1/2); `update_install.downloadDestPath` ([src/update_install.zig:21](../../../src/update_install.zig)); `window_backend.requestQuit` (already imported as `window_backend`, [src/platform/window_backend.zig:273](../../../src/platform/window_backend.zig)); `self.update_result` / `self.update_mutex` / `self.allocator`.
- Produces: `App.requestUpdateInstall(self: *App) bool` — returns true when the helper launched and the app is now quitting; false when the caller should show the manual fallback.

- [ ] **Step 1: Add the method**

In `src/App.zig`, add near the other update methods (e.g. after `storeDownloadComplete`, around line 776):

```zig
/// Apply the downloaded macOS update in place and quit so the helper can swap
/// and relaunch. Returns false (no quit) when not applicable — caller shows the
/// manual fallback. Safe to call on any platform: non-macOS returns false.
pub fn requestUpdateInstall(self: *App) bool {
    if (!update_apply.isSupported()) return false;

    var asset_buf: [128]u8 = undefined;
    var asset_len: usize = 0;
    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        const r = self.update_result;
        if (r.state != .downloaded or r.asset_name.len == 0) return false;
        asset_len = @min(r.asset_name.len, asset_buf.len);
        @memcpy(asset_buf[0..asset_len], r.asset_name[0..asset_len]);
    }

    const dmg_path = update_install.downloadDestPath(self.allocator, asset_buf[0..asset_len]) catch return false;
    defer self.allocator.free(dmg_path);

    const exe_path = std.fs.selfExePathAlloc(self.allocator) catch return false;
    defer self.allocator.free(exe_path);

    update_apply.applyUpdate(self.allocator, dmg_path, exe_path) catch |err| {
        std.debug.print("Update install: failed: {}\n", .{err});
        return false;
    };

    window_backend.requestQuit();
    return true;
}
```

- [ ] **Step 2: Verify both targets compile**

Run: `zig build 2>&1 | tail -20 && zig build test-full -Dtarget=aarch64-macos 2>&1 | tail -10`
Expected: both clean / PASS.

- [ ] **Step 3: Commit**

```bash
git add src/App.zig
git commit -m "feat(update): add App.requestUpdateInstall for one-click macOS apply"
```

---

### Task 4: UI wiring — "立即更新" toast button + command-center entry

Adds the `install_update` prompt action and routes it to `App.requestUpdateInstall`, with the manual prompt as fallback. Touches every exhaustive switch over `UpdatePromptAction` and `CommandAction` in one task so the build stays green.

**Files:**
- Modify: `src/renderer/overlays/update_prompt_model.zig`
- Modify: `src/renderer/overlays.zig` (suffix switch ~6712, `activateUpdatePrompt` ~7546, command dispatcher ~685)
- Modify: `src/command/center_state.zig` (CommandAction enum ~41, entries ~94)

**Interfaces:**
- Consumes: `App.requestUpdateInstall` (Task 3).
- Produces: `UpdatePromptAction.install_update`; `CommandAction.install_update`.

- [ ] **Step 1: Update the pure action mapper + its test (fast suite)**

In `src/renderer/overlays/update_prompt_model.zig`, add the builtin import after line 6:

```zig
const builtin = @import("builtin");
```

Change the enum (line 8) to:

```zig
pub const UpdatePromptAction = enum { none, open_release, download_update, install_update };
```

Add a `.downloaded` branch in `updatePromptActionForResult` (before the final `else`):

```zig
    else if (result.state == .downloaded and builtin.os.tag == .macos)
        .install_update
```

Add a test (after the existing one):

```zig
test "overlays: downloaded maps to install_update on macOS only" {
    const expected: UpdatePromptAction = if (builtin.os.tag == .macos) .install_update else .none;
    try std.testing.expectEqual(expected, updatePromptActionForResult(.{ .state = .downloaded, .latest_version = "v1.31.0" }));
}
```

- [ ] **Step 2: Run the fast test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (the new mapper test plus the existing ones).

- [ ] **Step 3: Update `showUpdatePrompt` to render the install message + suffix**

In `src/renderer/overlays.zig`, replace the body of `showUpdatePrompt` (lines 6709-6722) so the install action gets a clean "Update ready" status and a 立即更新 suffix:

```zig
fn showUpdatePrompt(result: update_check.CheckResult, action: UpdatePromptAction) void {
    var status_buf: [96]u8 = undefined;
    const status = if (action == .install_update) blk: {
        if (result.latest_version.len > 0)
            break :blk std.fmt.bufPrint(&status_buf, "Update ready: {s}", .{result.latest_version}) catch return
        else
            break :blk "Update ready";
    } else update_check.formatStatusMessage(&status_buf, result) catch return;
    const suffix = switch (action) {
        .download_update => "  click to download",
        .open_release => "  click to open",
        .install_update => "  立即更新",
        .none => "",
    };
    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{s}{s}", .{ status, suffix }) catch return;
    const url: []const u8 = if (action == .open_release and result.release_url.len > 0) result.release_url else "";
    const duration = if (action != .none) toasts.UPDATE_PROMPT_DURATION_MS else toasts.UPDATE_STATUS_DURATION_MS;
    toastState().update.show(msg, url, action != .none, action, std.time.milliTimestamp(), duration);
}
```

- [ ] **Step 4: Handle `install_update` in the toast click handler**

In `src/renderer/overlays.zig`, add a case to the `activateUpdatePrompt` switch (after the `.download_update` case, line ~7558):

```zig
        .install_update => {
            if (AppWindow.g_app) |app| {
                if (!app.requestUpdateInstall()) {
                    // Fallback: app already revealed the DMG at download time;
                    // show the manual prompt again.
                    showUpdatePrompt(.{ .state = .downloaded }, .none);
                }
            } else {
                showUpdatePrompt(.{ .state = .downloaded }, .none);
            }
        },
```

- [ ] **Step 5: Add the command-center action + entry + dispatcher**

In `src/command/center_state.zig`, add to the `CommandAction` enum (near line 41-42, after `download_update`):

```zig
    install_update,
```

Add an entry to the command list (after the `Download Update` entry, line ~95):

```zig
    .{ .title = "Install Update", .detail = "Install the downloaded update and relaunch (macOS)", .shortcut = "", .action = .install_update },
```

In `src/renderer/overlays.zig`, add a case to the command dispatcher switch (after `.download_update`, line ~696):

```zig
        .install_update => {
            if (AppWindow.g_app) |app| {
                if (!app.requestUpdateInstall()) showUpdatePrompt(.{ .state = .downloaded }, .none);
            } else {
                showUpdateDownloadUnavailableToast();
            }
        },
```

- [ ] **Step 6: Catch any remaining exhaustive switch over the new enum variants**

Run: `grep -rnE "UpdatePromptAction|\.download_update =>|CommandAction|\.check_for_updates =>" src/ | grep -v test`
Expected: every `switch` over `UpdatePromptAction` now has an `.install_update` arm and every `switch` over `CommandAction` handles `.install_update`. If the build below reports a missing-case error, add the arm there (mirror the `.download_update` behavior).

- [ ] **Step 7: Verify both targets build and all tests pass**

Run: `zig build 2>&1 | tail -20 && zig build test 2>&1 | tail -10 && zig build test-full -Dtarget=aarch64-macos 2>&1 | tail -20`
Expected: Windows build clean; fast tests PASS; macOS app tests PASS (ignore known-flaky `skill center tool import`).

- [ ] **Step 8: Commit**

```bash
git add src/renderer/overlays/update_prompt_model.zig src/renderer/overlays.zig src/command/center_state.zig
git commit -m "feat(update): wire 立即更新 one-click install into toast + command center"
```

---

### Task 5: End-to-end manual verification on a signed build

The real test (process/`hdiutil`/swap can't run in CI). Validates the full flow on a notarized build.

**Files:** none (verification only).

- [ ] **Step 1: Build, sign, and install a notarized app one patch behind**

```bash
zig build macos-dist -Doptimize=ReleaseFast -Dtarget=aarch64-macos
```

Install the produced `.app` into `/Applications` (mount the DMG, drag once). Confirm `WispTerm.app --version` is older than the latest GitHub release tag, or temporarily lower `build.zig.zon` `version` before this build so the published release looks newer.

- [ ] **Step 2: Trigger check + download**

Launch the installed app. Run command-center "Check for Updates" → "Download Update". Wait for the toast to read `Update ready: vX.Y.Z  立即更新`. Confirm the DMG is in `~/Downloads`.

- [ ] **Step 3: Click 立即更新 and confirm the swap + relaunch**

Click the toast (or run command-center "Install Update"). Expected: the app quits and relaunches automatically; `/Applications/WispTerm.app --version` now reports the new version. Confirm the DMG was detached (`ls /Volumes` has no `WispTerm` volume) and the temp helper is gone (`ls $TMPDIR/wispterm-update-*.sh`).

- [ ] **Step 4: Verify the fallback path (no .app)**

```bash
zig build macos-app
zig-out/bin/WispTerm.app/Contents/MacOS/WispTerm  # run the binary, but also test a bare-binary path
```

With a downloaded update present, click 立即更新 while running from a non-`/Applications` location or a bare binary. Expected: no swap; the manual `Saved to Downloads - unzip to update` prompt appears; the app keeps running. (`resolveAppBundle` returns null for a bare binary, so `applyUpdate` errors → fallback.)

- [ ] **Step 5: Commit (docs/notes only, if any)**

No code changes expected. If verification surfaces a fix, loop back to the relevant task.

---

## Self-Review

**Spec coverage:**
- One-click "立即更新" after download → Task 4 (toast + command center) + Task 3 (apply).
- Reuse check/download flow → no changes to `update_check.zig`/download path; only `.downloaded` action mapping added.
- Mandatory codesign verify → Task 2 `verifyCodesign` (error → fallback).
- Auto-relaunch → helper `open` line (Task 1/2) + `window_backend.requestQuit` (Task 3).
- Fallback when unsafe (not a `.app`, mount/verify fail) → `applyUpdate` errors, `requestUpdateInstall` returns false, UI shows manual prompt (Task 4); DMG already revealed at download ([App.zig:733](../../../src/App.zig)).
- No Sparkle / no new binary / no build-target change → only new `.zig` modules + a generated shell script.
- Windows unchanged + still compiles → stubs in Task 1, build checks in every task.
- Eligibility (macOS, in `.app`, writable, DMG mounts, signed) → `isSupported` + `resolveAppBundle` + `accessAbsolute` + `verifyCodesign`.
- Tests: pure-logic (`resolveAppBundle`, `renderHelperScript`, mapper) covered; process I/O manual (Task 5) — matches `update_install.zig` convention.

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `applyUpdate(allocator, dmg_path, exe_path)` identical across dispatch + impls; `requestUpdateInstall(*App) bool` matches both call sites; `UpdatePromptAction.install_update` / `CommandAction.install_update` referenced consistently; `renderHelperScript` arg order matches its format string (pid, new_app, dst_app×4, mount_point, dst_app).
