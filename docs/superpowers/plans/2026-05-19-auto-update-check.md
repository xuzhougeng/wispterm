# Auto Update Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a startup GitHub Release check that notifies when a newer Phantty version exists and opens the release page on user action.

**Architecture:** Keep version comparison and GitHub JSON parsing in a new testable `src/update_check.zig` module. Store runtime update-check state on `App`, start a background check when enabled, and let `AppWindow`/`renderer/overlays.zig` consume that state for command-center and overlay presentation.

**Tech Stack:** Zig 0.15.2, `std.http.Client`, `std.json`, existing `Config`, `App`, `AppWindow`, command center, overlay renderer, and `system_browser.zig`.

---

## File Structure

- Create `src/update_check.zig`: pure version comparison, GitHub release JSON parsing, result formatting, and the `std.http.Client` fetch helper.
- Modify `src/test_main.zig`: import `update_check.zig` so unit tests run.
- Modify `src/config.zig`: add `auto-update-check`, parse it, expose it in help/default config, and test true/false parsing.
- Modify `src/App.zig`: cache the setting, own update-check runtime state, start/manual-check worker thread, and expose result consumption/open-url helpers.
- Modify `src/AppWindow.zig`: copy hot-reloaded config value and poll update-check state each frame.
- Modify `src/command_center_state.zig`: add `Check for Updates` and `Open Latest Release` actions and tests.
- Modify `src/renderer/overlays.zig`: render update messages through the existing toast/pill style and execute update actions.
- Modify `src/input.zig`: add hit testing for the clickable update prompt.
- Modify `README.md`: document `auto-update-check`.

## Task 1: Config Flag

**Files:**
- Modify: `src/config.zig`
- Modify: `README.md`

- [ ] **Step 1: Write the failing config test**

Add this test near the other config boolean tests in `src/config.zig`:

```zig
test "config: auto update check option parses true false" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};

    try std.testing.expectEqual(true, cfg.@"auto-update-check");

    cfg.applyKeyValue(allocator, "auto-update-check", "false", ".");
    try std.testing.expectEqual(false, cfg.@"auto-update-check");

    cfg.applyKeyValue(allocator, "auto-update-check", "true", ".");
    try std.testing.expectEqual(true, cfg.@"auto-update-check");

    cfg.applyKeyValue(allocator, "auto-update-check", "maybe", ".");
    try std.testing.expectEqual(true, cfg.@"auto-update-check");
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`

Expected: FAIL because `Config` has no `auto-update-check` field.

- [ ] **Step 3: Add the config field and parser**

In `src/config.zig`, add the field near other user behavior booleans:

```zig
/// Check GitHub Releases for a newer Phantty version after startup.
@"auto-update-check": bool = true,
```

In `applyKeyValue`, add:

```zig
    } else if (std.mem.eql(u8, key, "auto-update-check")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"auto-update-check" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"auto-update-check" = false;
        } else {
            log.warn("invalid auto-update-check: {s}", .{value});
        }
```

In `printHelp`, add:

```text
        \\  --auto-update-check <bool>  Check GitHub Releases after startup
```

In `default_config_template`, add:

```text
    \\# Updates
    \\# auto-update-check = true
```

Update `README.md` example config and available keys with `auto-update-check`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test`

Expected: PASS for the new config test.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig README.md
git commit -m "feat: add update check config flag"
```

## Task 2: Update Check Pure Logic

**Files:**
- Create: `src/update_check.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write failing tests**

Create `src/update_check.zig` with tests first:

```zig
const std = @import("std");

test "update_check: compares semantic versions with optional v prefix" {
    try std.testing.expectEqual(Order.equal, compareVersions("0.23.2", "v0.23.2"));
    try std.testing.expectEqual(Order.newer, compareVersions("0.23.2", "v0.23.3"));
    try std.testing.expectEqual(Order.older, compareVersions("0.24.0", "v0.23.9"));
}

test "update_check: malformed versions are unknown" {
    try std.testing.expectEqual(Order.unknown, compareVersions("0.23.2-dev", "v0.23.3"));
    try std.testing.expectEqual(Order.unknown, compareVersions("0.23.2", "latest"));
}

test "update_check: parses latest release json" {
    const json =
        \\{"tag_name":"v0.23.3","html_url":"https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3","draft":false,"prerelease":false}
    ;
    const release = try parseLatestRelease(std.testing.allocator, json);
    defer release.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("v0.23.3", release.tag_name);
    try std.testing.expectEqualStrings("https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3", release.html_url);
    try std.testing.expect(!release.draft);
    try std.testing.expect(!release.prerelease);
}

test "update_check: decides when update is available" {
    const release = ReleaseInfo{
        .tag_name = "v0.23.3",
        .html_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3",
        .draft = false,
        .prerelease = false,
        .owned = false,
    };
    const result = evaluateRelease("0.23.2", release);
    try std.testing.expectEqual(State.update_available, result.state);
}
```

Add `_ = @import("update_check.zig");` to `src/test_main.zig`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`

Expected: FAIL because `Order`, `compareVersions`, `parseLatestRelease`, `ReleaseInfo`, and `evaluateRelease` are not implemented.

- [ ] **Step 3: Implement minimal pure logic**

Implement these public types and functions in `src/update_check.zig`:

```zig
const std = @import("std");

pub const latest_release_api_url = "https://api.github.com/repos/xuzhougeng/phantty/releases/latest";

pub const Order = enum { older, equal, newer, unknown };
pub const State = enum { idle, checking, up_to_date, update_available, failed };

pub const ReleaseInfo = struct {
    tag_name: []const u8,
    html_url: []const u8,
    draft: bool,
    prerelease: bool,
    owned: bool = true,

    pub fn deinit(self: ReleaseInfo, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        allocator.free(self.tag_name);
        allocator.free(self.html_url);
    }
};

pub const CheckResult = struct {
    state: State,
    latest_version: []const u8 = "",
    release_url: []const u8 = "",
};

const Semver = struct { major: u32, minor: u32, patch: u32 };
```

Use a small parser that trims a leading `v`, requires exactly `major.minor.patch`, and returns `null` for non-semver strings. `compareVersions(current, latest)` returns `.newer` only when `latest` is greater than `current`.

Parse JSON with `std.json.parseFromSlice(std.json.Value, allocator, bytes, .{})`, duplicate the two string fields, and default missing booleans to `false`.

`evaluateRelease(current_version, release)` returns `.up_to_date` for drafts/prereleases, malformed versions, older versions, and equal versions. It returns `.update_available` with `latest_version` and `release_url` for newer releases.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`

Expected: PASS for update-check pure logic tests.

- [ ] **Step 5: Commit**

```bash
git add src/update_check.zig src/test_main.zig
git commit -m "feat: add update check logic"
```

## Task 3: Runtime App State and Background Check

**Files:**
- Modify: `src/App.zig`
- Modify: `src/AppWindow.zig`
- Modify: `src/update_check.zig`

- [ ] **Step 1: Write failing runtime-state tests**

Add tests in `src/update_check.zig`:

```zig
test "update_check: formats update messages" {
    var buf: [96]u8 = undefined;
    const msg = try formatStatusMessage(&buf, .{
        .state = .update_available,
        .latest_version = "v0.23.3",
        .release_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.23.3",
    });
    try std.testing.expectEqualStrings("Update available: v0.23.3", msg);
}

test "update_check: manual failure message is stable" {
    var buf: [96]u8 = undefined;
    const msg = try formatStatusMessage(&buf, .{ .state = .failed });
    try std.testing.expectEqualStrings("Update check failed", msg);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`

Expected: FAIL because `formatStatusMessage` is not implemented.

- [ ] **Step 3: Implement status formatting and HTTP fetch**

Add to `src/update_check.zig`:

```zig
pub fn formatStatusMessage(buf: []u8, result: CheckResult) ![]const u8 {
    return switch (result.state) {
        .checking => std.fmt.bufPrint(buf, "Checking for updates...", .{}),
        .update_available => std.fmt.bufPrint(buf, "Update available: {s}", .{result.latest_version}),
        .up_to_date => std.fmt.bufPrint(buf, "Phantty is up to date", .{}),
        .failed => std.fmt.bufPrint(buf, "Update check failed", .{}),
        .idle => std.fmt.bufPrint(buf, "", .{}),
    };
}

pub fn fetchLatestRelease(allocator: std.mem.Allocator, current_version: []const u8) !CheckResult {
    var client: std.http.Client = .{ .allocator = allocator, .write_buffer_size = 16 * 1024 };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = latest_release_api_url },
        .method = .GET,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = "phantty" } },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) return .{ .state = .failed };

    var list = body.toArrayList();
    defer list.deinit(allocator);
    const release = try parseLatestRelease(allocator, list.items);
    defer release.deinit(allocator);
    return evaluateRelease(current_version, release);
}
```

- [ ] **Step 4: Add App-owned runtime state**

In `src/App.zig`, import `update_check` and `app_metadata`, add fields:

```zig
auto_update_check: bool,
update_mutex: std.Thread.Mutex,
update_state: update_check.CheckResult,
update_latest_version_buf: [32]u8,
update_release_url_buf: [256]u8,
update_thread: ?std.Thread,
update_check_in_flight: bool,
```

Initialize them in `App.init`, copy `cfg.@"auto-update-check"`, and update it in `updateConfig`.

Add methods:

```zig
pub fn maybeStartStartupUpdateCheck(self: *App) void
pub fn requestManualUpdateCheck(self: *App) void
pub fn consumeUpdateResult(self: *App) update_check.CheckResult
pub fn latestReleaseUrl(self: *App) ?[]const u8
```

Use one worker thread function that calls `update_check.fetchLatestRelease(self.allocator, app_metadata.version)`, stores the result under `update_mutex`, and records `.failed` only for manual checks. Startup failures should log and leave state idle.

- [ ] **Step 5: Start and poll from AppWindow**

In `AppWindow.init`, after `g_app = app`, call:

```zig
app.maybeStartStartupUpdateCheck();
```

In the main render loop, after existing overlay/timing updates, call a small helper:

```zig
fn pollUpdateCheck(app: *App) void {
    const result = app.consumeUpdateResult();
    if (result.state != .idle) overlays.showUpdateCheckResult(result);
}
```

- [ ] **Step 6: Run tests and build**

Run: `zig build test`

Expected: PASS.

Run: `zig build`

Expected: debug build succeeds.

- [ ] **Step 7: Commit**

```bash
git add src/App.zig src/AppWindow.zig src/update_check.zig
git commit -m "feat: check releases in the background"
```

## Task 4: Command Center and Clickable Prompt

**Files:**
- Modify: `src/command_center_state.zig`
- Modify: `src/renderer/overlays.zig`
- Modify: `src/input.zig`

- [ ] **Step 1: Write failing command-center tests**

Add tests in `src/command_center_state.zig`:

```zig
test "command center includes update check actions" {
    try std.testing.expectEqual(CommandAction.check_for_updates, findCommandAction("Check for Updates"));
    try std.testing.expectEqual(CommandAction.open_latest_release, findCommandAction("Open Latest Release"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`

Expected: FAIL because the new command actions are not defined.

- [ ] **Step 3: Add command actions**

In `CommandAction`, add:

```zig
    check_for_updates,
    open_latest_release,
```

In `command_entries`, add near `Version`:

```zig
    .{ .title = "Check for Updates", .detail = "Check GitHub Releases for a newer Phantty version", .shortcut = "", .action = .check_for_updates },
    .{ .title = "Open Latest Release", .detail = "Open the latest Phantty GitHub Release", .shortcut = "", .action = .open_latest_release },
```

- [ ] **Step 4: Wire overlay execution**

In `src/renderer/overlays.zig`, extend `executeCommand`:

```zig
        .check_for_updates => if (AppWindow.g_app) |app| {
            showUpdateCheckingToast();
            app.requestManualUpdateCheck();
        },
        .open_latest_release => if (AppWindow.g_app) |app| {
            openLatestRelease(app);
        },
```

Add presentation helpers:

```zig
pub fn showUpdateCheckResult(result: update_check.CheckResult) void
pub fn showUpdateCheckingToast() void
pub fn updatePromptHitTest(xpos: f64, ypos: f64, window_height: f32) bool
pub fn openLatestRelease(app: *AppWindow.App) void
```

The helper stores the latest release URL in a fixed buffer and renders the
message with existing toast drawing. If the result is `update_available`, keep
the prompt visible longer than copy toasts and include `click to open`.

- [ ] **Step 5: Add click handling**

In `src/input.zig`, in the left-click press block before remote key handling,
add:

```zig
        if (overlays.updatePromptHitTest(xpos, ypos, @floatFromInt(fb.height))) {
            if (AppWindow.g_app) |app| overlays.openLatestRelease(app);
            return;
        }
```

- [ ] **Step 6: Run tests and build**

Run: `zig build test`

Expected: PASS.

Run: `zig build`

Expected: debug build succeeds.

- [ ] **Step 7: Commit**

```bash
git add src/command_center_state.zig src/renderer/overlays.zig src/input.zig
git commit -m "feat: surface update check actions"
```

## Task 5: Documentation and Final Verification

**Files:**
- Modify: `README.md`
- Maybe modify: `release-notes/v0.23.3.md` if this work is intended for a new release note before publishing.

- [ ] **Step 1: Update README**

Ensure `README.md` documents:

```text
auto-update-check = true
```

and the available key row says:

```markdown
| `auto-update-check` | `true` | Check GitHub Releases after startup and show a clickable prompt when a newer version is available. Set to `false` to disable startup checks. |
```

- [ ] **Step 2: Run the Windows path compatibility checks if files were added**

Run the PowerShell checks from `AGENTS.md` on Windows before final release work. In this Linux workspace, run the closest Git check:

```bash
git ls-files -s | rg '^120000' || true
```

Expected: no symlink entries introduced.

- [ ] **Step 3: Run full verification**

Run:

```bash
zig build test
zig build
```

Expected: both commands exit 0.

- [ ] **Step 4: Inspect final diff**

Run:

```bash
git status --short
git diff --stat HEAD
```

Expected: only intentional update-check files and docs are changed after the last commit.

- [ ] **Step 5: Commit final docs if needed**

```bash
git add README.md release-notes
git commit -m "docs: document update checks"
```

## Self-Review

- Spec coverage: Task 1 implements the opt-out config. Task 2 implements version comparison and GitHub JSON parsing. Task 3 implements startup/manual check state and background fetch. Task 4 implements prompt, jump, and command-center actions. Task 5 covers docs and verification.
- Placeholder scan: no `TBD`, `TODO`, `implement later`, or vague test-only instructions remain.
- Type consistency: `update_check.CheckResult`, `update_check.State`, and command action names are consistent across tasks.
