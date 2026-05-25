# Command Palette SSH Quick Jump Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add saved SSH profile quick-jump results to the `Ctrl+Shift+P` command center, matched only by server name.

**Architecture:** Put pure command-palette matching and ordering rules in `src/command_palette_model.zig` so they can be tested without pulling in the heavy overlay renderer dependencies. Keep rendering, selection, and SSH connection execution in `src/renderer/overlays.zig`, reusing existing SSH profile storage and connection helpers.

**Tech Stack:** Zig 0.15.2, Phantty overlay renderer, existing SSH profile storage, `zig build test`, `zig build`.

---

### Task 1: Add Testable Command Palette Model

**Files:**
- Create: `src/command_palette_model.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Add failing model tests**

Create `src/command_palette_model.zig` with tests for:

```zig
test "command palette model matches SSH profile names case-insensitively" {
    try std.testing.expect(sshProfileNameMatchesFilter("LabServer", "labserver"));
}

test "command palette model hides SSH profiles when filter is empty" {
    try std.testing.expect(!shouldSearchSshProfiles(""));
    try std.testing.expect(!sshProfileNameMatchesFilter("LabServer", ""));
}

test "command palette model does not match non-name SSH profile fields" {
    try std.testing.expect(!sshProfileNameMatchesFilter("ProdBox", "needle-host"));
    try std.testing.expect(!sshProfileNameMatchesFilter("ProdBox", "needle-user"));
}

test "command palette model orders SSH results after commands and before themes" {
    try std.testing.expect(resultGroupRank(.command_title) < resultGroupRank(.command_secondary));
    try std.testing.expect(resultGroupRank(.command_secondary) < resultGroupRank(.ssh_profile));
    try std.testing.expect(resultGroupRank(.ssh_profile) < resultGroupRank(.theme));
}
```

Import `command_palette_model.zig` from `src/test_main.zig`.

- [ ] **Step 2: Implement model functions**

Implement:

```zig
pub const ResultGroup = enum {
    command_title,
    command_secondary,
    ssh_profile,
    theme,
};

pub fn resultGroupRank(group: ResultGroup) u8;
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool;
pub fn shouldSearchSshProfiles(filter: []const u8) bool;
pub fn sshProfileNameMatchesFilter(name: []const u8, filter: []const u8) bool;
```

- [ ] **Step 3: Verify model tests**

Run: `zig build test`

Expected: the new command-palette model tests pass. Existing baseline failures in `platform.window_backend` and `updater_core` may remain.

### Task 2: Add SSH Profiles To Command Center Results

**Files:**
- Modify: `src/renderer/overlays.zig`

- [ ] **Step 1: Extend palette item type**

Add an `ssh_profile: usize` variant to `PaletteItem`.

- [ ] **Step 2: Append SSH profile matches**

In `rebuildPaletteScratch()`, keep the existing empty-filter behavior unchanged. For non-empty filters, append matching SSH profiles after command title/detail matches and before theme matches:

```zig
loadSshProfiles();
for (0..g_ssh_profile_count) |profile_idx| {
    if (g_palette_scratch_len >= COMMAND_PALETTE_MAX_VISIBLE_ROWS) break;
    const profile = &g_ssh_profiles[profile_idx];
    if (!command_palette_model.sshProfileNameMatchesFilter(profileField(profile, .name), filter)) continue;
    g_palette_scratch[g_palette_scratch_len] = .{ .ssh_profile = profile_idx };
    g_palette_scratch_len += 1;
}
```

- [ ] **Step 3: Execute SSH profile items**

In `executePaletteItem()`, call the existing connection path:

```zig
.ssh_profile => |profile_idx| connectSshProfile(profile_idx),
```

- [ ] **Step 4: Render SSH profile rows**

Render rows as `SSH: <server name>` with the safe target detail `user@host[:port]`. Extract the existing SSH launcher target formatting into `sshProfileTarget()` and use `renderTitlebarTextLimited()` on the detail to avoid overlap.

- [ ] **Step 5: Verify desktop compile**

Run: `zig build`

Expected: the Windows desktop target builds successfully.

### Task 3: Final Verification

**Files:**
- No additional files.

- [ ] **Step 1: Run full tests**

Run: `zig build test`

Expected: all command-palette model tests pass. Known baseline failures may remain in `platform.window_backend` and `updater_core`.

- [ ] **Step 2: Run Windows checkout safety checks**

Run the Windows path checks from `docs/development.md` against tracked and newly-added files.

Expected: zero Windows name violations, zero case-fold collisions, and no symlinks.
