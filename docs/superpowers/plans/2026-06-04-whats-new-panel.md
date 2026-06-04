# What's New Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After upgrading WispTerm, show a one-time scrollable "What's New" modal with the current build's release notes, plus an on-demand command to reopen it.

**Architecture:** The matching `release-notes/vX.Y.Z.md` is read at build time and threaded into the binary as a `release_notes` build option (no network, no `@embedFile` hard-fail). A pure gate compares the running version against a `last-seen-version` persisted in the existing UI state file to decide whether to auto-show. A centered modal overlay (mirroring the existing close-confirm modal) renders the notes via the existing `markdown_text.zig` helpers. A config toggle disables only the auto-popup; the command-center entry always works.

**Tech Stack:** Zig 0.15.2, the existing `src/renderer/overlays.zig` overlay/modal system, `src/markdown_text.zig` markdown helpers, `src/platform/window_state_codec.zig` state-file codec, `build.zig` options.

**Conventions:**
- Fast unit suite: `zig build test` (runs everything registered in `src/test_fast.zig`).
- Full app suite: `zig build test-full`.
- There is no per-test name filter wired; "verify it fails" means run `zig build test` and observe the new test (or compile) fail, then turn it green.
- Commit after every green task.

**Intentional spec deviation (i18n):** Spec §6 asked for the modal title/buttons to go through `i18n.zig`. The adjacent modals (`renderWindowCloseConfirm`, the update prompt) use English string literals and are **not** i18n-routed. To stay consistent with the surrounding code and avoid an i18n catalog refactor, the modal title/buttons use English literals; localization is applied only to the **command-center entry** via the established `commandTitle`/`commandDetail` zh-override mechanism (Task 9). This is a deliberate, pattern-consistent narrowing of §6.

---

## File Structure

| File | Responsibility | New? |
|------|----------------|------|
| `build.zig` | Read `release-notes/v{version}.md` at configure time → `release_notes` build option | modify |
| `src/app_metadata.zig` | Expose `release_notes` to app code | modify |
| `src/shared_compile_test.zig` | Assert the build option exists | modify |
| `src/whats_new_gate.zig` | Pure auto-show decision | **new** |
| `src/platform/window_state_codec.zig` | `last-seen-version` field + merge helper | modify |
| `src/platform/window_state.zig` | I/O helpers `lastSeenVersion` / `recordSeenVersion` | modify |
| `src/renderer/overlays/whats_new_model.zig` | Pure layout / scroll / hit-test / URL helpers | **new** |
| `src/renderer/overlays.zig` | Modal state, `showWhatsNew`, `renderWhatsNew`, key/click handlers, command dispatch | modify |
| `src/input.zig` | Route keys/clicks to the modal when visible | modify |
| `src/AppWindow.zig` | Render call sites + startup gate hookup | modify |
| `src/config.zig` | `whats-new-on-update` key | modify |
| `src/App.zig` | Cache `whats_new_on_update`; `maybeShowWhatsNewOnStartup` | modify |
| `src/command_center_state.zig` | `show_whats_new` command + table entry | modify |
| `src/i18n.zig` | zh-CN override for the command entry | modify |
| `src/platform/menu_macos_bridge.m` (+ wiring) | macOS menu item (optional) | modify |
| `src/test_fast.zig` | Register new pure test modules | modify |

---

## Task 1: `release_notes` build option

**Files:**
- Modify: `build.zig` (`createAppModuleWithRoot` ~795-798; `fast_test_options` ~575-577; `shared_test_options` ~596-598; add helper near `packageVersion` ~970)
- Modify: `src/app_metadata.zig`
- Modify: `src/shared_compile_test.zig`

- [ ] **Step 1: Add the build helper.** In `build.zig`, directly below the `packageVersion` function, add:

```zig
/// Read the release notes for `app_version` (`release-notes/vX.Y.Z.md`) at
/// configure time so they can be embedded as a build option. Returns "" when the
/// file is missing or unreadable — a missing notes file must never fail the build.
fn readReleaseNotes(b: *std.Build, app_version: []const u8) []const u8 {
    const path = std.fmt.allocPrint(b.allocator, "release-notes/v{s}.md", .{app_version}) catch return "";
    return b.build_root.handle.readFileAllocOptions(
        b.allocator,
        path,
        256 * 1024,
        null,
        .of(u8),
        null,
    ) catch "";
}
```

- [ ] **Step 2: Thread the option into the app module.** In `createAppModuleWithRoot`, immediately after the existing `app_options.addOption([]const u8, "app_version", app_version);` line, add:

```zig
    app_options.addOption([]const u8, "release_notes", readReleaseNotes(b, app_version));
```

- [ ] **Step 3: Add the option to the test option blocks.** The shared/fast test binaries compile `app_metadata.zig`, so they must also define the option (an empty string is fine for tests). After `fast_test_options.addOption([]const u8, "app_version", app_version);` add:

```zig
    fast_test_options.addOption([]const u8, "release_notes", "");
```

After `shared_test_options.addOption([]const u8, "app_version", app_version);` add:

```zig
    shared_test_options.addOption([]const u8, "release_notes", "");
```

- [ ] **Step 4: Expose it in `app_metadata.zig`.** Add below `pub const version = build_options.app_version;`:

```zig
/// Release notes for the running build (contents of `release-notes/v{version}.md`),
/// embedded at build time. Empty string when no notes file existed at build time.
pub const release_notes = build_options.release_notes;
```

- [ ] **Step 5: Add a compile/existence assertion.** In `src/shared_compile_test.zig`, extend the existing metadata test:

```zig
test "shared compile target has app metadata" {
    try std.testing.expect(build_options.app_version.len > 0);
    try std.testing.expectEqualStrings("WispTerm", app_metadata.name);
    // release_notes is always a valid slice (possibly empty); referencing it here
    // forces the build option to exist for every target that compiles app_metadata.
    try std.testing.expect(app_metadata.release_notes.len >= 0);
}
```

- [ ] **Step 6: Build + test.**

Run: `zig build test`
Expected: PASS (whole fast suite green). Then run `zig build test-full` — Expected: PASS.

- [ ] **Step 7: Confirm the real build embeds notes.** Run:

`zig build 2>&1 | tail -5` — Expected: builds with no error (proves `readReleaseNotes` path + option wiring compile against the real `release-notes/v1.9.0.md`).

- [ ] **Step 8: Commit.**

```bash
git add build.zig src/app_metadata.zig src/shared_compile_test.zig
git commit -m "feat(build): embed current release notes as a build option"
```

---

## Task 2: Pure auto-show gate

**Files:**
- Create: `src/whats_new_gate.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the module with failing-first tests.** Create `src/whats_new_gate.zig`:

```zig
//! Pure decision for whether to auto-show the "What's New" modal on launch.
//! No I/O, no rendering, std-only — unit-tested in the fast suite. Compares the
//! running build version against the persisted last-seen version using the same
//! semver comparison the update checker uses.
const std = @import("std");
const update_check = @import("update_check.zig");

pub const Decision = enum { show, suppress };

/// Decide whether to auto-show the changelog.
/// - empty `last_seen` (fresh install / pre-feature upgrade) → suppress
/// - no embedded notes → suppress
/// - `current` strictly newer than `last_seen` → show
/// - same / older / unparseable → suppress
pub fn whatsNewDecision(last_seen: []const u8, current: []const u8, notes_present: bool) Decision {
    if (last_seen.len == 0) return .suppress;
    if (!notes_present) return .suppress;
    return switch (update_check.compareVersions(last_seen, current)) {
        .newer => .show,
        .older, .equal, .unknown => .suppress,
    };
}

test "fresh install suppresses (no last-seen version)" {
    try std.testing.expectEqual(Decision.suppress, whatsNewDecision("", "1.9.0", true));
}

test "upgrade with notes shows" {
    try std.testing.expectEqual(Decision.show, whatsNewDecision("1.8.0", "1.9.0", true));
}

test "upgrade without notes suppresses" {
    try std.testing.expectEqual(Decision.suppress, whatsNewDecision("1.8.0", "1.9.0", false));
}

test "same version suppresses" {
    try std.testing.expectEqual(Decision.suppress, whatsNewDecision("1.9.0", "1.9.0", true));
}

test "downgrade suppresses" {
    try std.testing.expectEqual(Decision.suppress, whatsNewDecision("1.9.0", "1.8.0", true));
}

test "unparseable last-seen suppresses" {
    try std.testing.expectEqual(Decision.suppress, whatsNewDecision("nightly", "1.9.0", true));
}
```

Note: `update_check.compareVersions(a, b)` returns `.newer` when `b` is newer than `a`; here `a = last_seen`, `b = current`, so `.newer` means current is newer than last-seen. Correct.

- [ ] **Step 2: Register in the fast suite.** In `src/test_fast.zig`, add next to the other `_ = @import(...)` lines (e.g. after the `window_state_codec` line):

```zig
    _ = @import("whats_new_gate.zig");
```

- [ ] **Step 3: Run tests.**

Run: `zig build test`
Expected: PASS, including the six new `whats_new_gate` tests.

- [ ] **Step 4: Commit.**

```bash
git add src/whats_new_gate.zig src/test_fast.zig
git commit -m "feat: pure What's New auto-show gate"
```

---

## Task 3: `last-seen-version` in the state codec

**Files:**
- Modify: `src/platform/window_state_codec.zig`

- [ ] **Step 1: Add the field + accessor.** In `PersistedState`, after `ai_setup_prompted`, add:

```zig
    // Last app version whose "What's New" was seen. Stored inline (fixed buffer)
    // so this pure codec stays allocation-free and never aliases the parse input.
    last_seen_version_buf: [version_max_len]u8 = undefined,
    last_seen_version_len: usize = 0,

    pub fn lastSeenVersion(self: *const PersistedState) []const u8 {
        return self.last_seen_version_buf[0..self.last_seen_version_len];
    }
```

Add a constant near `MAX_DIMENSION`:

```zig
/// Max stored length of the last-seen version string (e.g. "1.9.0"); longer
/// values are truncated on read (never overflow).
pub const version_max_len: usize = 24;
```

- [ ] **Step 2: Parse the key.** In `parse`, add a branch to the `else if` chain (after the `ai-setup-prompted` branch):

```zig
        } else if (std.mem.eql(u8, key, "last-seen-version")) {
            const n = @min(val.len, version_max_len);
            @memcpy(state.last_seen_version_buf[0..n], val[0..n]);
            state.last_seen_version_len = n;
```

- [ ] **Step 3: Format the key.** In `format`, before `return buf[0..len];`, after the `ai-setup-prompted` write, add:

```zig
    if (state.last_seen_version_len > 0) {
        len += (try std.fmt.bufPrint(buf[len..], "last-seen-version = {s}\n", .{state.lastSeenVersion()})).len;
    }
```

- [ ] **Step 4: Add a merge helper.** After `mergeQuakeFrame`, add:

```zig
/// Copy of `state` with the last-seen version overwritten (truncated to
/// version_max_len). Leaves all geometry + the onboarding flag untouched.
pub fn withLastSeenVersion(state: PersistedState, version: []const u8) PersistedState {
    var next = state;
    const n = @min(version.len, version_max_len);
    @memcpy(next.last_seen_version_buf[0..n], version[0..n]);
    next.last_seen_version_len = n;
    return next;
}
```

- [ ] **Step 5: Add tests.** Append to `src/platform/window_state_codec.zig`:

```zig
test "parse reads last-seen-version" {
    const s = parse("last-seen-version = 1.9.0\n");
    try std.testing.expectEqualStrings("1.9.0", s.lastSeenVersion());
}

test "old state file without last-seen-version leaves it empty" {
    const s = parse("window-x = 10\nai-setup-prompted = 1\n");
    try std.testing.expectEqual(@as(usize, 0), s.last_seen_version_len);
}

test "last-seen-version round-trips and is omitted when empty" {
    var buf: [256]u8 = undefined;
    // empty → omitted
    const empty_text = try format(&buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, empty_text, "last-seen-version") == null);
    // set → present and reparses
    const set = withLastSeenVersion(.{}, "1.9.0");
    const text = try format(&buf, set);
    const reparsed = parse(text);
    try std.testing.expectEqualStrings("1.9.0", reparsed.lastSeenVersion());
}

test "over-length last-seen-version is truncated, never overflows" {
    const long = "1.2.3-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const s = withLastSeenVersion(.{}, long);
    try std.testing.expectEqual(version_max_len, s.last_seen_version_len);
}
```

- [ ] **Step 6: Run tests.**

Run: `zig build test`
Expected: PASS, including the four new codec tests.

- [ ] **Step 7: Commit.**

```bash
git add src/platform/window_state_codec.zig
git commit -m "feat: persist last-seen-version in the UI state file"
```

---

## Task 4: State-file I/O helpers

**Files:**
- Modify: `src/platform/window_state.zig`

- [ ] **Step 1: Add the helpers.** After `setAiSetupPrompted`, add:

```zig
/// The last app version whose "What's New" the user has seen (empty when none).
/// The returned slice is copied into `buf`; pass a buffer at least
/// `codec.version_max_len` bytes.
pub fn lastSeenVersion(allocator: std.mem.Allocator, buf: []u8) []const u8 {
    const v = loadPersisted(allocator).lastSeenVersion();
    const n = @min(v.len, buf.len);
    @memcpy(buf[0..n], v[0..n]);
    return buf[0..n];
}

/// Record `version` as the last-seen "What's New" version (read-modify-write to
/// preserve geometry + the onboarding flag). No-op if already equal.
pub fn recordSeenVersion(allocator: std.mem.Allocator, version: []const u8) void {
    const current = loadPersisted(allocator);
    if (std.mem.eql(u8, current.lastSeenVersion(), version)) return;
    savePersisted(allocator, codec.withLastSeenVersion(current, version));
}
```

Note: `lastSeenVersion` copies into a caller buffer because `loadPersisted` frees its file buffer on return — but the version lives in the fixed inline `PersistedState` buffer (a value type), so it is already copy-safe; the caller buffer keeps the signature symmetric and avoids returning a slice into a stack temporary. Keep the copy.

- [ ] **Step 2: Build to verify it compiles.**

Run: `zig build test-full`
Expected: PASS (this module is exercised in the full suite, not the fast one).

- [ ] **Step 3: Commit.**

```bash
git add src/platform/window_state.zig
git commit -m "feat: state-file helpers for last-seen version"
```

---

## Task 5: Pure modal model (layout / scroll / hit-test / URL)

**Files:**
- Create: `src/renderer/overlays/whats_new_model.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the module with tests.** Create `src/renderer/overlays/whats_new_model.zig`:

```zig
//! Pure layout + scroll + hit-test + URL helpers for the "What's New" modal.
//! No GL, no AppWindow — unit-tested in the fast suite. overlays.zig owns the
//! threadlocal modal state and the actual drawing; this module owns the math.
const std = @import("std");
const md = @import("../../markdown_text.zig");

pub const Action = enum { none, view_on_github, close };

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.w and
            py >= self.y and py <= self.y + self.h;
    }
};

/// All rects use a top-left origin (y grows downward). overlays converts to its
/// bottom-up draw space.
pub const Layout = struct {
    panel: Rect,
    content: Rect,
    view_btn: Rect,
    close_btn: Rect,
    visible_rows: usize,
};

pub const MIN_WRAP_COLS: usize = 8;

/// Display rows a single cleaned line of `display_len` bytes occupies at
/// `wrap_cols` columns (always at least 1). Byte-length approximation — adequate
/// for the ASCII-dominant release notes; wide glyphs may wrap a column early.
pub fn lineRows(display_len: usize, wrap_cols: usize) usize {
    if (wrap_cols == 0 or display_len == 0) return 1;
    return (display_len + wrap_cols - 1) / wrap_cols;
}

/// Total wrapped display rows for the whole notes blob at `wrap_cols` columns.
pub fn totalRows(notes: []const u8, wrap_cols: usize) usize {
    var total: usize = 0;
    var in_code = false;
    var it = std.mem.splitScalar(u8, notes, '\n');
    while (it.next()) |raw| {
        var buf: [1024]u8 = undefined;
        const cleaned = md.cleanedLine(&buf, raw, in_code);
        if (cleaned.style == .fence) in_code = !in_code;
        total += lineRows(cleaned.text.len, wrap_cols);
    }
    return total;
}

/// Clamp a (possibly negative or overscrolled) line offset into range.
pub fn clampScroll(offset: i64, total_lines: usize, visible_lines: usize) usize {
    if (total_lines <= visible_lines) return 0;
    const max_off: i64 = @intCast(total_lines - visible_lines);
    if (offset < 0) return 0;
    if (offset > max_off) return @intCast(max_off);
    return @intCast(offset);
}

/// Which button (if any) a top-left-origin point hits.
pub fn buttonActionAt(layout: Layout, px: f32, py: f32) Action {
    if (layout.view_btn.contains(px, py)) return .view_on_github;
    if (layout.close_btn.contains(px, py)) return .close;
    return .none;
}

pub const fallback_url = "https://github.com/xuzhougeng/wispterm/releases/latest";

/// Build the release page URL for `version` (e.g. ".../releases/tag/v1.9.0").
/// Falls back to the latest-releases page if formatting fails.
pub fn releaseTagUrl(buf: []u8, version: []const u8) []const u8 {
    const v = std.mem.trimLeft(u8, version, "vV");
    return std.fmt.bufPrint(
        buf,
        "https://github.com/xuzhougeng/wispterm/releases/tag/v{s}",
        .{v},
    ) catch fallback_url;
}

/// Centered modal layout. `row_h` is the pixel height of one text row.
pub fn computeLayout(window_w: f32, window_h: f32, row_h: f32) Layout {
    const panel_w = @min(window_w - 80, 720);
    const panel_h = @min(window_h - 80, 560);
    const panel_x = (window_w - panel_w) / 2;
    const panel_y = (window_h - panel_h) / 2;

    const pad: f32 = 28;
    const title_h: f32 = row_h + 18;
    const footer_h: f32 = 56;
    const content = Rect{
        .x = panel_x + pad,
        .y = panel_y + title_h,
        .w = panel_w - pad * 2,
        .h = panel_h - title_h - footer_h,
    };

    const btn_w: f32 = 150;
    const btn_h: f32 = 34;
    const btn_y = panel_y + panel_h - footer_h + (footer_h - btn_h) / 2;
    const close_btn = Rect{ .x = panel_x + panel_w - pad - btn_w, .y = btn_y, .w = btn_w, .h = btn_h };
    const view_btn = Rect{ .x = close_btn.x - 14 - btn_w, .y = btn_y, .w = btn_w, .h = btn_h };

    const rows: usize = if (row_h > 0) @intFromFloat(@max(@as(f32, 1), content.h / row_h)) else 1;
    return .{ .panel = .{ .x = panel_x, .y = panel_y, .w = panel_w, .h = panel_h },
        .content = content, .view_btn = view_btn, .close_btn = close_btn, .visible_rows = rows };
}

test "lineRows is at least one and wraps by columns" {
    try std.testing.expectEqual(@as(usize, 1), lineRows(0, 40));
    try std.testing.expectEqual(@as(usize, 1), lineRows(40, 40));
    try std.testing.expectEqual(@as(usize, 2), lineRows(41, 40));
}

test "totalRows counts blank, heading, and wrapped lines" {
    const notes = "# Title\n\nshort\n";
    // "Title" (1) + blank (1) + "short" (1) = 3
    try std.testing.expectEqual(@as(usize, 3), totalRows(notes, 40));
}

test "clampScroll clamps both ends" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(-5, 100, 10));
    try std.testing.expectEqual(@as(usize, 90), clampScroll(999, 100, 10));
    try std.testing.expectEqual(@as(usize, 0), clampScroll(7, 5, 10)); // content fits
    try std.testing.expectEqual(@as(usize, 7), clampScroll(7, 100, 10));
}

test "releaseTagUrl strips leading v and builds tag URL" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://github.com/xuzhougeng/wispterm/releases/tag/v1.9.0",
        releaseTagUrl(&buf, "1.9.0"),
    );
    try std.testing.expectEqualStrings(
        "https://github.com/xuzhougeng/wispterm/releases/tag/v1.9.0",
        releaseTagUrl(&buf, "v1.9.0"),
    );
}

test "buttonActionAt resolves clicks" {
    const layout = computeLayout(1200, 800, 20);
    const close_pt_x = layout.close_btn.x + 1;
    const close_pt_y = layout.close_btn.y + 1;
    try std.testing.expectEqual(Action.close, buttonActionAt(layout, close_pt_x, close_pt_y));
    const view_pt_x = layout.view_btn.x + 1;
    const view_pt_y = layout.view_btn.y + 1;
    try std.testing.expectEqual(Action.view_on_github, buttonActionAt(layout, view_pt_x, view_pt_y));
    try std.testing.expectEqual(Action.none, buttonActionAt(layout, layout.panel.x + 1, layout.panel.y + 1));
}

test "computeLayout keeps buttons inside the panel and visible_rows positive" {
    const layout = computeLayout(1200, 800, 20);
    try std.testing.expect(layout.visible_rows >= 1);
    try std.testing.expect(layout.close_btn.x >= layout.panel.x);
    try std.testing.expect(layout.close_btn.x + layout.close_btn.w <= layout.panel.x + layout.panel.w);
    try std.testing.expect(layout.view_btn.x >= layout.panel.x);
}
```

- [ ] **Step 2: Register in the fast suite.** In `src/test_fast.zig`, after the `update_prompt_model.zig` import line, add:

```zig
    _ = @import("renderer/overlays/whats_new_model.zig");
```

- [ ] **Step 3: Run tests.**

Run: `zig build test`
Expected: PASS, including the seven new `whats_new_model` tests.

- [ ] **Step 4: Commit.**

```bash
git add src/renderer/overlays/whats_new_model.zig src/test_fast.zig
git commit -m "feat: pure layout/scroll model for What's New modal"
```

---

## Task 6: Config toggle `whats-new-on-update`

**Files:**
- Modify: `src/config.zig` (field decl ~388; parse branch ~910)

- [ ] **Step 1: Add the field.** In `src/config.zig`, directly below the `@"auto-update-check": bool = true,` field, add:

```zig
@"whats-new-on-update": bool = true,
```

- [ ] **Step 2: Add the parse branch.** Find the `auto-update-check` parse block (around line 910):

```zig
    } else if (std.mem.eql(u8, key, "auto-update-check")) {
        if (...) {
            self.@"auto-update-check" = true;
        } else if (...) {
            self.@"auto-update-check" = false;
        } else {
            log.warn("invalid auto-update-check: {s}", .{value});
        }
```

Directly after that block's closing `}`, add a parallel block (copy the exact true/false condition expressions used by `auto-update-check`):

```zig
    } else if (std.mem.eql(u8, key, "whats-new-on-update")) {
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) {
            self.@"whats-new-on-update" = true;
        } else if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) {
            self.@"whats-new-on-update" = false;
        } else {
            log.warn("invalid whats-new-on-update: {s}", .{value});
        }
```

(If the existing `auto-update-check` branch uses helper functions instead of literal `eql` comparisons, mirror those exactly rather than the literals above.)

- [ ] **Step 3: Run tests.**

Run: `zig build test`
Expected: PASS. Then `zig build test-full` — Expected: PASS.

- [ ] **Step 4: Commit.**

```bash
git add src/config.zig
git commit -m "feat(config): add whats-new-on-update toggle (default on)"
```

---

## Task 7: Modal state, render, and handlers in overlays.zig

**Files:**
- Modify: `src/renderer/overlays.zig` (imports/state near `g_update_prompt_*` ~119-131; dispatch switch ~547-573; new functions near `renderWindowCloseConfirm`/`renderUpdatePrompt`)

- [ ] **Step 1: Add the import + threadlocal state.** Near the top imports (by `update_prompt_model`):

```zig
const whats_new_model = @import("overlays/whats_new_model.zig");
const WhatsNewAction = whats_new_model.Action;
```

Near the `g_update_prompt_*` threadlocals, add:

```zig
threadlocal var g_whats_new_visible: bool = false;
threadlocal var g_whats_new_scroll: i64 = 0;
```

- [ ] **Step 2: Add show/hide/visible + the notes accessor.** Add near `closeConfirmOpen`:

```zig
fn whatsNewNotes() []const u8 {
    return app_metadata.release_notes;
}

pub fn showWhatsNew() void {
    g_whats_new_scroll = 0;
    g_whats_new_visible = true;
}

pub fn hideWhatsNew() void {
    g_whats_new_visible = false;
}

pub fn whatsNewVisible() bool {
    return g_whats_new_visible;
}
```

Ensure `app_metadata` is imported at the top of `overlays.zig` (it already imports many `../` modules; add `const app_metadata = @import("../app_metadata.zig");` if absent).

- [ ] **Step 3: Add key + scroll + click handlers.** Add:

```zig
pub fn whatsNewHandleKey(ev: input_key.KeyEvent) void {
    if (!g_whats_new_visible) return;
    switch (ev.key) {
        .escape, .enter => hideWhatsNew(),
        .page_up => g_whats_new_scroll -= 10,
        .page_down => g_whats_new_scroll += 10,
        .up => g_whats_new_scroll -= 1,
        .down => g_whats_new_scroll += 1,
        .home => g_whats_new_scroll = 0,
        .end => g_whats_new_scroll = std.math.maxInt(i32),
        else => {},
    }
}

pub fn whatsNewHandleScroll(delta_y: f64) void {
    if (!g_whats_new_visible) return;
    g_whats_new_scroll += if (delta_y > 0) @as(i64, -3) else 3;
}

/// Returns true if the click was consumed by the modal (always true while the
/// modal is open, so clicks never fall through to the terminal underneath).
pub fn whatsNewExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32) bool {
    if (!g_whats_new_visible) return false;
    const row_h = font.g_titlebar_cell_height;
    const layout = whats_new_model.computeLayout(window_width, window_height, row_h);
    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos); // top-left origin to match computeLayout
    switch (whats_new_model.buttonActionAt(layout, px, py)) {
        .view_on_github => {
            openWhatsNewRelease();
            hideWhatsNew();
            return true;
        },
        .close => {
            hideWhatsNew();
            return true;
        },
        .none => {
            // click outside the panel dismisses; inside the panel is ignored
            if (!layout.panel.contains(px, py)) hideWhatsNew();
            return true;
        },
    }
}

fn openWhatsNewRelease() void {
    const allocator = AppWindow.g_allocator orelse return;
    var url_buf: [256]u8 = undefined;
    const url = whats_new_model.releaseTagUrl(&url_buf, app_metadata.version);
    _ = platform_open_url.open(allocator, .{ .url = url });
}
```

Confirm the `KeyEvent` field/enum names (`ev.key`, `.escape`, `.page_up`, etc.) match `input_key` used by `windowCloseConfirmHandleKey`/`close_confirm.keyOutcome`; adjust to the actual enum spelling if different (e.g. `.escape` vs `.esc`). The `platform_open_url` import already exists (used by `openLatestRelease`).

- [ ] **Step 4: Add the renderer.** Add a `renderWhatsNew` modeled on `renderWindowCloseConfirm` (same color helpers: `mixColor`, `renderRoundedQuadAlpha`, `ui_pipeline.fillQuadAlpha`, `renderTitlebarTextStrong`, `renderTitlebarText`, `overlayTextHeight`). It must:
  1. Return early if `!g_whats_new_visible`.
  2. Compute `layout = whats_new_model.computeLayout(window_width, window_height, font.g_titlebar_cell_height)`.
  3. Compute `wrap_cols` from `layout.content.w / titlebar.titlebarGlyphAdvance('M')` (min `whats_new_model.MIN_WRAP_COLS`).
  4. `total = whats_new_model.totalRows(whatsNewNotes(), wrap_cols)`; `scroll = whats_new_model.clampScroll(g_whats_new_scroll, total, layout.visible_rows)`; write the clamped value back: `g_whats_new_scroll = @intCast(scroll);`.
  5. Dim the background, draw the panel + a title row `What's New in WispTerm v{version}` (format with `app_metadata.version`).
  6. Walk the notes with `md.cleanedLine` (tracking `in_code` via `.fence`), expand each into wrapped sub-rows, skip the first `scroll` rows, and draw up to `layout.visible_rows` rows inside `layout.content`. Headings (`style == .heading`) use `renderTitlebarTextStrong`; everything else uses `renderTitlebarText`. Convert each row's top-left `y` to the renderer's bottom-up space the same way `renderWindowCloseConfirm` does (`window_height - top - h`).
  7. Draw two footer buttons from `layout.view_btn` / `layout.close_btn` with labels `View on GitHub` and `Close`.
  8. If `whatsNewNotes().len == 0`, draw a single muted line `Release notes unavailable for this version.` in the content area instead of the walk.

Full reference body (adapt pixel/colors to match `renderWindowCloseConfirm`; this compiles against the named helpers):

```zig
pub fn renderWhatsNew(window_width: f32, window_height: f32) void {
    if (!g_whats_new_visible) return;

    const row_h = font.g_titlebar_cell_height;
    const layout = whats_new_model.computeLayout(window_width, window_height, row_h);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const panel = mixColor(bg, fg, 0.05);
    const panel_border = mixColor(bg, fg, 0.24);
    const muted = mixColor(bg, fg, 0.56);
    const body = mixColor(bg, fg, 0.85);

    // Background scrim + panel (panel drawn in bottom-up space).
    ui_pipeline.fillQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.46);
    const panel_y_bu = window_height - layout.panel.y - layout.panel.h;
    renderRoundedQuadAlpha(layout.panel.x - 1, panel_y_bu - 1, layout.panel.w + 2, layout.panel.h + 2, 13, panel_border, 0.42);
    renderRoundedQuadAlpha(layout.panel.x, panel_y_bu, layout.panel.w, layout.panel.h, 12, panel, 0.99);

    // Title.
    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "What's New in WispTerm v{s}", .{trimV(app_metadata.version)}) catch "What's New";
    const title_top = layout.panel.y + 16;
    renderTitlebarTextStrong(title, layout.content.x, window_height - title_top - row_h, fg);

    const notes = whatsNewNotes();
    if (notes.len == 0) {
        renderTitlebarText("Release notes unavailable for this version.", layout.content.x, window_height - layout.content.y - row_h, muted);
    } else {
        const adv = @max(@as(f32, 1), titlebar.titlebarGlyphAdvance('M'));
        var wrap_cols: usize = @intFromFloat(layout.content.w / adv);
        if (wrap_cols < whats_new_model.MIN_WRAP_COLS) wrap_cols = whats_new_model.MIN_WRAP_COLS;

        const total = whats_new_model.totalRows(notes, wrap_cols);
        const scroll = whats_new_model.clampScroll(g_whats_new_scroll, total, layout.visible_rows);
        g_whats_new_scroll = @intCast(scroll);

        var row_index: usize = 0; // absolute wrapped-row index
        var drawn: usize = 0;
        var in_code = false;
        var it = std.mem.splitScalar(u8, notes, '\n');
        outer: while (it.next()) |raw| {
            var cbuf: [1024]u8 = undefined;
            const cleaned = md.cleanedLine(&cbuf, raw, in_code);
            if (cleaned.style == .fence) in_code = !in_code;
            const rows = whats_new_model.lineRows(cleaned.text.len, wrap_cols);
            var r: usize = 0;
            while (r < rows) : (r += 1) {
                defer row_index += 1;
                if (row_index < scroll) continue;
                if (drawn >= layout.visible_rows) break :outer;
                const start = r * wrap_cols;
                const end = @min(cleaned.text.len, start + wrap_cols);
                const slice = if (start < cleaned.text.len) cleaned.text[start..end] else "";
                const top = layout.content.y + @as(f32, @floatFromInt(drawn)) * row_h;
                const y_bu = window_height - top - row_h;
                if (cleaned.style == .heading) {
                    renderTitlebarTextStrong(slice, layout.content.x, y_bu, fg);
                } else {
                    renderTitlebarText(slice, layout.content.x, y_bu, body);
                }
                drawn += 1;
            }
        }
    }

    // Footer buttons.
    drawWhatsNewButton(layout.view_btn, "View on GitHub", window_height, panel_border, body);
    drawWhatsNewButton(layout.close_btn, "Close", window_height, panel_border, fg);
}

fn drawWhatsNewButton(rect: whats_new_model.Rect, label: []const u8, window_height: f32, border: [3]f32, text: [3]f32) void {
    const y_bu = window_height - rect.y - rect.h;
    renderRoundedQuadAlpha(rect.x, y_bu, rect.w, rect.h, 8, border, 0.30);
    const tw = measureTitlebarText(label);
    renderTitlebarText(label, rect.x + (rect.w - tw) / 2, rowTextY(y_bu, rect.h), text);
}

fn trimV(v: []const u8) []const u8 {
    return std.mem.trimLeft(u8, v, "vV");
}
```

`md` must be imported in overlays (`const md = @import("../markdown_text.zig");`); add it if absent. `measureTitlebarText`, `rowTextY`, `titlebar`, `font`, `mixColor`, `renderRoundedQuadAlpha`, `renderTitlebarText(Strong)`, `ui_pipeline` are all already used by the close-confirm renderer in this file.

> **Note:** the command-dispatch arm (`.show_whats_new => showWhatsNew()`) is **not** added here. Adding the `show_whats_new` enum value (Task 9) makes the existing `CommandAction` switch in this file non-exhaustive, so the new arm must land in the same commit as the enum value — it lives in Task 9. At the end of this task, `showWhatsNew`/`renderWhatsNew` are `pub` but not yet called; Zig does not flag unused `pub` functions, so the build is clean.

- [ ] **Step 5: Build.**

Run: `zig build test-full`
Expected: PASS (standalone — no dependency on Task 9 yet).

- [ ] **Step 6: Commit.**

```bash
git add src/renderer/overlays.zig
git commit -m "feat: What's New modal render + handlers in overlays"
```

---

## Task 8: Route input + render call sites

**Files:**
- Modify: `src/input.zig` (key route ~1182; click route ~2699; scroll route — near `updatePromptHitTest` ~2812)
- Modify: `src/AppWindow.zig` (render sites 2474-2475 and 5233-5234)

- [ ] **Step 1: Render the modal.** In `src/AppWindow.zig`, after **each** `overlays.renderWindowCloseConfirm(...)` call (lines ~2475 and ~5234), add an adjacent line so the modal draws on top:

```zig
    overlays.renderWhatsNew(@floatFromInt(fb_width), @floatFromInt(fb_height));
```

- [ ] **Step 2: Route keys.** In `src/input.zig`, immediately before the existing close-confirm key block (~1182):

```zig
    if (overlays.whatsNewVisible()) {
        overlays.whatsNewHandleKey(key_event);
        return;
    }
```

Match the surrounding early-return style (the close-confirm block returns after handling; mirror its exact return/flow).

- [ ] **Step 3: Route clicks.** In `src/input.zig`, immediately before the existing close-confirm click block (~2699):

```zig
    if (overlays.whatsNewVisible()) {
        _ = overlays.whatsNewExecuteAt(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height));
        return;
    }
```

(Use the same `fb.width`/`fb.height` accessors the adjacent close-confirm click handler uses.)

- [ ] **Step 4: Route scroll.** Find the scroll/wheel handler in `src/input.zig` (where wheel events are processed for terminals). At its very top, add:

```zig
    if (overlays.whatsNewVisible()) {
        overlays.whatsNewHandleScroll(yoffset);
        return;
    }
```

Use the actual wheel-delta parameter name in that function (e.g. `yoffset`). Locate it with: `grep -n "scroll\|yoffset\|wheel" src/input.zig | head`.

- [ ] **Step 5: Build + run.**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add src/input.zig src/AppWindow.zig
git commit -m "feat: route input + render for What's New modal"
```

---

## Task 9: Command-center entry + zh-CN override

**Files:**
- Modify: `src/command_center_state.zig` (enum ~36-40; table ~81-85; test ~268-270)
- Modify: `src/renderer/overlays.zig` (command-dispatch switch ~547-573)
- Modify: `src/i18n.zig` (`commandTitle` ~566-571; `commandDetail` ~610-…)

> **Do all edits in this task before building.** Adding the enum value makes the `CommandAction` switches in both `command_center_state.zig` (titles/details) and `overlays.zig` (dispatch) non-exhaustive; the build only goes green once every switch has the new arm.

- [ ] **Step 1: Add the enum value.** In `src/command_center_state.zig`, in the `CommandAction` enum next to `open_latest_release`, add:

```zig
    show_whats_new,
```

- [ ] **Step 2: Add the table entry.** In the command table, after the `open_latest_release` entry (line ~84):

```zig
    .{ .title = "What's New", .detail = "Show what changed in this version of WispTerm", .shortcut = app_metadata.version, .action = .show_whats_new },
```

- [ ] **Step 3: Add a lookup test.** Near the existing `findCommandAction` tests (~268), add:

```zig
test "findCommandAction resolves What's New" {
    try std.testing.expectEqual(CommandAction.show_whats_new, findCommandAction("What's New"));
}
```

- [ ] **Step 4: Wire the command dispatch.** In `src/renderer/overlays.zig`, in the command-action `switch` block (the one containing `.open_latest_release => openLatestRelease(),`), add after that arm:

```zig
        .show_whats_new => showWhatsNew(),
```

- [ ] **Step 5: Add zh-CN overrides.** In `src/i18n.zig`, in `commandTitle`'s switch (after `.open_latest_release => "打开最新发布",`):

```zig
        .show_whats_new => "更新内容",
```

In `commandDetail`'s switch (after `.open_latest_release => "打开最新的 WispTerm GitHub Release",`):

```zig
        .show_whats_new => "查看本版本的更新内容",
```

(Both `commandTitle` and `commandDetail` switches are exhaustive over `CommandAction`; the new value **must** be added to both or the build fails — that failure is the safety net.)

- [ ] **Step 6: Build + test.**

Run: `zig build test`
Expected: PASS (new `findCommandAction` test green). Then `zig build test-full` — Expected: PASS.

- [ ] **Step 7: Commit.**

```bash
git add src/command_center_state.zig src/renderer/overlays.zig src/i18n.zig
git commit -m "feat: wire What's New command-center entry + dispatch (+ zh-CN)"
```

---

## Task 10: Startup auto-show gate

**Files:**
- Modify: `src/App.zig` (cache field ~240 + ~407; new method)
- Modify: `src/AppWindow.zig` (call after the ai-setup gate, ~1834)

- [ ] **Step 1: Cache the toggle on `App`.** In `src/App.zig`, add a field near `auto_update_check`:

```zig
whats_new_on_update: bool,
```

In the init struct literal (near `.auto_update_check = cfg.@"auto-update-check",`):

```zig
        .whats_new_on_update = cfg.@"whats-new-on-update",
```

In `updateConfig` (near `self.auto_update_check = cfg.@"auto-update-check";`):

```zig
    self.whats_new_on_update = cfg.@"whats-new-on-update";
```

- [ ] **Step 2: Add the orchestration method.** In `src/App.zig`, add (imports: `const app_metadata = @import("app_metadata.zig");`, `const whats_new_gate = @import("whats_new_gate.zig");`, `const platform_window_state = @import("platform/window_state.zig");` — add any that are missing):

```zig
/// On launch: if enabled and the build version is newer than the last-seen
/// version (and notes exist), open the What's New modal once. Always records the
/// current version so it shows at most once per upgrade, regardless of the toggle.
pub fn maybeShowWhatsNewOnStartup(self: *App, allocator: std.mem.Allocator) void {
    const current = app_metadata.version;
    var seen_buf: [32]u8 = undefined;
    const last_seen = platform_window_state.lastSeenVersion(allocator, &seen_buf);
    const notes_present = app_metadata.release_notes.len > 0;

    if (self.whats_new_on_update and
        whats_new_gate.whatsNewDecision(last_seen, current, notes_present) == .show)
    {
        overlays.showWhatsNew();
    }
    // Record unconditionally so toggling the option off later never resurfaces a
    // stale popup, and so the popup shows at most once per upgrade.
    platform_window_state.recordSeenVersion(allocator, current);
}
```

Use the existing `overlays` import alias in `App.zig` if present; otherwise call via `AppWindow`/`overlays` the same way other App methods reach the renderer. If `App.zig` cannot import `overlays` cleanly (layering), instead expose the decision here and have the **AppWindow** caller (Step 3) call `overlays.showWhatsNew()` based on a returned bool:

```zig
pub fn shouldShowWhatsNewOnStartup(self: *App, allocator: std.mem.Allocator) bool {
    const current = app_metadata.version;
    var seen_buf: [32]u8 = undefined;
    const last_seen = platform_window_state.lastSeenVersion(allocator, &seen_buf);
    const show = self.whats_new_on_update and
        whats_new_gate.whatsNewDecision(last_seen, current, app_metadata.release_notes.len > 0) == .show;
    platform_window_state.recordSeenVersion(allocator, current);
    return show;
}
```

Prefer the `shouldShowWhatsNewOnStartup` form if `App` does not already import the renderer (cleaner layering). Pick one form and delete the other.

- [ ] **Step 3: Call it on startup.** In `src/AppWindow.zig`, right after the ai-setup gate block (after line ~1834, before `return true;`):

```zig
    if (g_app) |app| {
        if (app.shouldShowWhatsNewOnStartup(allocator)) overlays.showWhatsNew();
    }
```

(If you chose the `maybeShowWhatsNewOnStartup` form in Step 2, call that instead: `if (g_app) |app| app.maybeShowWhatsNewOnStartup(allocator);`.)

- [ ] **Step 4: Build + test.**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add src/App.zig src/AppWindow.zig
git commit -m "feat: auto-show What's New once after upgrade"
```

---

## Task 11 (optional): macOS menu item

Cross-platform on-demand access already exists via the command center (Task 9), so this is polish for macOS users who use the menu bar. Skip if not targeting macOS this pass.

**Files:**
- Modify: `src/platform/menu_macos_bridge.m` (+ its Zig menu-action wiring)

- [ ] **Step 1:** Locate the existing "Check for Updates" menu item in `src/platform/menu_macos_bridge.m` (`grep -n "Check for Updates\|checkForUpdates\|updateSkills" src/platform/menu_macos_bridge.m`).

- [ ] **Step 2:** Add a sibling "What's New" menu item that dispatches the same action path the command center uses for `show_whats_new` (route it through the existing menu→command bridge so it calls `overlays.showWhatsNew()` on the main thread). Mirror the wiring of the adjacent "Check for Updates" item exactly.

- [ ] **Step 3:** Cross-compile check (cannot run macOS GUI here): `zig build -Dtarget=aarch64-macos 2>&1 | tail -5` — Expected: no errors.

- [ ] **Step 4: Commit.**

```bash
git add src/platform/menu_macos_bridge.m
git commit -m "feat(macos): What's New menu item"
```

---

## Final verification

- [ ] `zig build test` — Expected: PASS (fast suite, all new pure tests green).
- [ ] `zig build test-full` — Expected: PASS.
- [ ] `zig build` — Expected: builds clean; binary embeds `release-notes/v1.9.0.md`.
- [ ] Manual GUI check (project convention — verification is GUI-pending until a human runs it):
  - Temporarily simulate an upgrade by editing the state file's `last-seen-version` to an older version (e.g. `1.8.0`) and relaunch → modal appears once; relaunch again → does not reappear.
  - Command center → "What's New" → modal opens regardless of the gate.
  - Scroll (wheel / PageDown / End), `View on GitHub` opens `…/releases/tag/v1.9.0`, `Close`/`Esc` dismiss.
  - Set `whats-new-on-update = false` in config, repeat the upgrade simulation → no auto-popup, but the command still works.

---

## Spec coverage check

- Content pipeline (embed at build) → Task 1. ✓
- Upgrade detection + persistence → Tasks 2, 3, 4. ✓
- Startup wiring + record-unconditionally → Task 10. ✓
- Modal (pure model + render + handlers) → Tasks 5, 7, 8. ✓
- On-demand entry (command center + optional menu) → Tasks 9, 11. ✓
- Config toggle gating only the auto-popup → Tasks 6, 10. ✓
- i18n (command entry; modal literals per documented deviation) → Task 9. ✓
- Edge cases (missing notes, fresh install, downgrade, malformed, oversize, overflow scroll) → Tasks 2, 3, 5 tests. ✓
- Testing strategy → Tasks 2, 3, 5, 9 fast-suite tests. ✓
```
