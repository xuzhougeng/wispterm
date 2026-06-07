# Skill Center 预览键位 + 服务器技能预览 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Skill Center 统一键位为 `space`=预览 / `enter`=确认（主库 `enter`=部署），并让导入列表能用 `space` 异步预览服务器技能的 SKILL.md。

**Architecture:** 复用 `skill_center.Session` 已有的后台 op 机制（spec 2026-06-07-skill-sync-async）：给 `OpResult` 加 `.preview` 变体 + 一个 `SkillPreviewJob`，后台 ssh/local 读 SKILL.md，主线程 `pollSkillCenterOp` 把内容交给 `markdown_preview_panel.open`。键位改在 `input.zig`，legend 随 overlay 状态变化。

**Tech Stack:** Zig 0.15.2；现有 `skill_transfer_cmd` / `skill_center` op 机制 / `markdown_preview_panel` / `SkillLocExec` / `window_backend.postWakeup`。

参考设计：`docs/superpowers/specs/2026-06-07-skill-center-preview-keys-design.md`

---

## 文件结构

| 文件 | 职责 | 改动 |
|------|------|------|
| `src/skill_transfer_cmd.zig` | 加纯函数 `catSkillMdCmd`（构造 `cat <root>/'<name>'/'SKILL.md'`） | Modify |
| `src/skill_center.zig` | `OpResult` 加 `.preview` 变体 + deinit 分支 | Modify |
| `src/i18n.zig` | 改写 `sc_legend_v2`；新增 `sc_legend_import`、`sc_busy_loading`（en+zh_CN） | Modify |
| `src/AppWindow.zig` | `SkillPreviewJob`；`skillCenterPreviewServerSkill`；`skillCenterSpacePreview`；`pollSkillCenterOp` 加 `.preview`；view.legend 按 overlay 选 | Modify |
| `src/platform/input_events.zig` | 加 `key_space` 常量 | Modify |
| `src/input.zig` | space 分支调 `skillCenterSpacePreview`；主库 enter 改调 `skillCenterDeploy`；更新注释 | Modify |

测试命令：fast 逻辑单测 `zig build test`；AppWindow/input 编译 `zig build macos-app -Dtarget=aarch64-macos`；完整套件 `zig build test-full`。

---

## Task 1: skill_transfer_cmd.zig — `catSkillMdCmd`（纯函数）

**Files:**
- Modify: `src/skill_transfer_cmd.zig`

- [ ] **Step 1: Write the failing test**

Add this test at the bottom of `src/skill_transfer_cmd.zig` (after the existing `splitSkillPath` test):

```zig
test "skill_transfer_cmd: catSkillMdCmd reads SKILL.md under a $HOME root" {
    const a = std.testing.allocator;
    const root = try homeRootExpr(a, ".claude/skills");
    defer a.free(root);
    const c = try catSkillMdCmd(a, root, "pdf");
    defer a.free(c);
    try std.testing.expectEqualStrings("cat \"$HOME\"/'.claude/skills'/'pdf'/'SKILL.md'", c);
}

test "skill_transfer_cmd: catSkillMdCmd shell-escapes a tricky name" {
    const a = std.testing.allocator;
    const root = try absRootExpr(a, "/cfg/skills");
    defer a.free(root);
    const c = try catSkillMdCmd(a, root, "it's mine");
    defer a.free(c);
    try std.testing.expectEqualStrings("cat '/cfg/skills'/'it'\\''s mine'/'SKILL.md'", c);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — "no member named 'catSkillMdCmd'".

- [ ] **Step 3: Implement `catSkillMdCmd`**

Add this function in `src/skill_transfer_cmd.zig` right after `tarExtractCmd` (before `homeRootExpr`):

```zig
/// `cat <root_expr>/'<name>'/'SKILL.md'` — read one skill's SKILL.md under a
/// shell root expression (e.g. `"$HOME"/'.claude/skills'` or `'/abs/lib'`).
/// root_expr is already shell-ready (built by homeRootExpr/absRootExpr); name
/// and the SKILL.md literal are single-quote-escaped.
pub fn catSkillMdCmd(allocator: std.mem.Allocator, root_expr: []const u8, name: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "cat ");
    try buf.appendSlice(allocator, root_expr);
    try buf.append(allocator, '/');
    try appendQuoted(&buf, allocator, name);
    try buf.append(allocator, '/');
    try appendQuoted(&buf, allocator, "SKILL.md");
    return buf.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS (both new tests green; suite stays green).

- [ ] **Step 5: Commit**

```bash
git add src/skill_transfer_cmd.zig
git commit -m "feat(skill-transfer-cmd): catSkillMdCmd to read a skill's SKILL.md

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: skill_center.zig — `OpResult.preview` 变体

**Files:**
- Modify: `src/skill_center.zig` (`OpResult` union ~line 257-280)

- [ ] **Step 1: Write the failing test**

Add this test near the existing op tests in `src/skill_center.zig` (after the `startOp` tests):

```zig
test "OpResult.preview deinit frees title and content" {
    const a = std.testing.allocator;
    var r: OpResult = .{ .preview = .{
        .title = try a.dupe(u8, "roundtable"),
        .content = try a.dupe(u8, "# SKILL\nbody"),
    } };
    r.deinit(a); // must free both; testing allocator catches a leak
    try std.testing.expect(r == .failed); // deinit resets to .failed
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `.preview` is not a member of `OpResult`.

- [ ] **Step 3: Add the `.preview` variant and its deinit arm**

In `src/skill_center.zig`, in the `pub const OpResult = union(enum) { ... }` (starts ~line 257), add the variant after `transfer:` and before `failed`:

```zig
    /// preview finished: show the fetched SKILL.md in the markdown preview panel.
    preview: struct { title: []u8, content: []u8 },
```

And in `OpResult.deinit`'s switch, add an arm (before `.failed => {}`):

```zig
            .preview => |*v| {
                allocator.free(v.title);
                allocator.free(v.content);
            },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/skill_center.zig
git commit -m "feat(skill-center): OpResult.preview variant for server skill preview

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: i18n.zig — legend 文案 + 加载提示

**Files:**
- Modify: `src/i18n.zig` (`Strings` struct ~line 69-85; `en` ~line 266; `zh_CN` ~line 443)

- [ ] **Step 1: Add fields to the `Strings` struct**

In `pub const Strings = struct { ... }`, after the `sc_legend_v2: []const u8,` field (~line 85), add:

```zig
    sc_legend_import: []const u8,
    sc_busy_loading: []const u8,
```

- [ ] **Step 2: Update `sc_legend_v2` and add the new values in `en`**

In `const en = Strings{ ... }`, replace the existing line
`    .sc_legend_v2 = "[⏎] preview   [d] deploy   [i] import   [r] rescan",`
with:

```zig
    .sc_legend_v2 = "[space] preview   [↵] deploy   [i] import   [r] rescan",
    .sc_legend_import = "[space] preview   [↵] import   [esc] back",
    .sc_busy_loading = "Loading…",
```

- [ ] **Step 3: Update `sc_legend_v2` and add the new values in `zh_CN`**

In `const zh_CN = Strings{ ... }`, replace the existing line
`    .sc_legend_v2 = "[⏎] 预览   [d] 部署   [i] 导入   [r] 重新扫描",`
with:

```zig
    .sc_legend_v2 = "[space] 预览   [↵] 部署   [i] 导入   [r] 重新扫描",
    .sc_legend_import = "[space] 预览   [↵] 导入   [esc] 返回",
    .sc_busy_loading = "加载中…",
```

- [ ] **Step 4: Verify it compiles**

Run: `zig build test`
Expected: PASS (a missing field in either language table is a compile error, so green confirms both tables have the two new fields).

- [ ] **Step 5: Commit**

```bash
git add src/i18n.zig
git commit -m "i18n(skill-center): space/enter legend + loading string

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: AppWindow.zig — 预览 Job + 入口 + poll 分支 + legend

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Add `SkillPreviewJob` after the other op Job structs**

Add immediately after `SkillTransferJob` (the last op Job struct):

```zig
/// Background op: read one skill's SKILL.md (local or via ssh) for preview.
const SkillPreviewJob = struct {
    conn: ?ssh_connection.SshConnection,
    name: []u8, // owned — becomes the preview title
    cmd: []u8, // owned — `cat <root>/'<name>'/'SKILL.md'`

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillPreviewJob = @ptrCast(@alignCast(ctx));
        var le = SkillLocExec{ .conn = job.conn };
        const host = le.host();
        const content = host.exec(host.ctx, allocator, job.cmd) catch return .failed;
        const title = allocator.dupe(u8, job.name) catch {
            allocator.free(content);
            return .failed;
        };
        return .{ .preview = .{ .title = title, .content = content } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillPreviewJob = @ptrCast(@alignCast(ctx));
        allocator.free(job.name);
        allocator.free(job.cmd);
        allocator.destroy(job);
    }
};
```

- [ ] **Step 2: Add `skillCenterPreviewServerSkill` (start a preview op)**

Add it near `skillCenterRunTransfer` / `skillCenterOpenImportList`:

```zig
/// Preview the selected server skill's SKILL.md — off the UI thread.
/// Only meaningful inside an import_list overlay.
fn skillCenterPreviewServerSkill(allocator: std.mem.Allocator) void {
    const session = activeSkillCenter() orelse return;
    var name_owned: ?[]u8 = null;
    var target_owned: ?skill_center.Target = null;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .import_list => |*il| {
                if (il.sel < il.names.len) {
                    name_owned = allocator.dupe(u8, il.names[il.sel]) catch null;
                    target_owned = il.target.clone(allocator) catch null;
                }
            },
            else => {},
        }
    }
    const name = name_owned orelse {
        if (target_owned) |*t| t.deinit(allocator);
        return;
    };
    var target = target_owned orelse {
        allocator.free(name);
        return;
    };
    defer target.deinit(allocator); // only need conn + software here

    const conn = skillCenterTargetConn(target);
    if (!target.is_local and conn == null) {
        overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        allocator.free(name);
        return;
    }
    const root_expr = skill_transfer_cmd.homeRootExpr(allocator, target.software.rootRel()) catch {
        allocator.free(name);
        return;
    };
    defer allocator.free(root_expr);
    const cmd = skill_transfer_cmd.catSkillMdCmd(allocator, root_expr, name) catch {
        allocator.free(name);
        return;
    };
    const job = allocator.create(SkillPreviewJob) catch {
        allocator.free(name);
        allocator.free(cmd);
        return;
    };
    job.* = .{ .conn = conn, .name = name, .cmd = cmd };
    if (!session.startOp(.{ .ctx = job, .run = SkillPreviewJob.run, .destroy = SkillPreviewJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_loading)) {
        SkillPreviewJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}
```

- [ ] **Step 3: Add `skillCenterSpacePreview` (space dispatcher) — pub for input.zig**

Add near `skillCenterPreviewSelected`:

```zig
/// Space key in the Skill Center: preview the selected item by overlay kind.
/// import_list → server skill (async); main library / deploy picker → local
/// library skill; import picker / confirm → no-op. UI thread.
pub fn skillCenterSpacePreview() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;
    const Kind = enum { lib, server, none };
    var kind: Kind = .lib;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .none, .busy => kind = .lib,
            .import_list => kind = .server,
            .picker => |*p| kind = if (p.purpose == .deploy) .lib else .none,
            .confirm => kind = .none,
        }
    }
    switch (kind) {
        .lib => _ = skillCenterPreviewSelected(),
        .server => skillCenterPreviewServerSkill(allocator),
        .none => {},
    }
    return true;
}
```

- [ ] **Step 4: Add the `.preview` arm to `pollSkillCenterOp`**

In `pollSkillCenterOp`'s `switch (result)`, add an arm (e.g. after `.transfer`):

```zig
        .preview => |*v| {
            markdown_preview_panel.open(.markdown, v.title, "SKILL.md", v.content);
        },
```

(`markdown_preview_panel.open` dupes title+content internally, so the trailing `defer result.deinit(allocator)` safely frees them. It uses threadlocal state — pollSkillCenterOp runs on the UI thread, which is correct.)

- [ ] **Step 5: Make `view.legend` depend on the overlay**

In the skill-center render block, replace:
```zig
            .legend = i18n.s().sc_legend_v2,
```
with:
```zig
            .legend = if (m.overlay == .import_list) i18n.s().sc_legend_import else i18n.s().sc_legend_v2,
```
(`m` is `&session.model`, already in scope under the lock at that point.)

- [ ] **Step 6: Build the macOS app (full type-check)**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: PASS (may take several minutes; use a long timeout).

- [ ] **Step 7: Run the fast suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(skill-center): async server skill preview + space dispatcher + legend

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: input_events.zig + input.zig — 键位

**Files:**
- Modify: `src/platform/input_events.zig`
- Modify: `src/input.zig:1481-1517`

- [ ] **Step 1: Add the `key_space` constant**

In `src/platform/input_events.zig`, after `pub const key_tab: KeyCode = 0x09;` (~line 6), add:

```zig
pub const key_space: KeyCode = 0x20;
```

- [ ] **Step 2: Rewire the Skill Center key handling**

In `src/input.zig`, the Skill Center block is at lines 1481-1519. Make three edits:

(a) Update the comment line 1481:
```zig
    // Skill Center: ↑/↓ move, space preview, ⏎ confirm (deploy in library), esc cancel, d deploy, i import, r rescan.
```

(b) Replace the `key_enter` arm (currently previews in the library) so the non-overlay case deploys:
```zig
            platform_input.key_enter => {
                if (AppWindow.skillCenterOverlayActive()) {
                    _ = AppWindow.skillCenterOverlaySelect();
                } else {
                    _ = AppWindow.skillCenterDeploy();
                }
                return;
            },
```

(c) Add a `key_space` arm (right after the `key_enter` arm):
```zig
            platform_input.key_space => if (plain and !ev.shift) {
                _ = AppWindow.skillCenterSpacePreview();
                return;
            },
```

- [ ] **Step 3: Build the macOS app**

Run: `zig build macos-app -Dtarget=aarch64-macos`
Expected: PASS.

- [ ] **Step 4: Run the fast suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/platform/input_events.zig src/input.zig
git commit -m "feat(skill-center): space=preview, enter=confirm/deploy key bindings

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 集成验证（手动）

**Files:** none

- [ ] **Step 1: Full suite**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 2: Manual smoke test (superpowers:verification-before-completion)**

Launch from a terminal (stderr visible):
```bash
zig build macos-app -Dtarget=aarch64-macos
./zig-out/bin/WispTerm.app/Contents/MacOS/WispTerm
```
In the Skill Center, observe behavior (not just "it built"):
1. Main library list: `space` opens the markdown preview of the selected library skill; `enter` opens the deploy target picker (same as `d`).
2. The legend reads `[space] preview  [↵] deploy  [i] import  [r] rescan`.
3. Press `i`, pick an SSH target → import list appears, legend reads `[space] preview  [↵] import  [esc] back`.
4. In the import list: `space` shows "加载中…" briefly then opens the server skill's SKILL.md in the preview panel; the UI/mouse stay responsive during the ssh read; `enter` imports.
5. Preview against an unreachable target → failure toast, no hang.

- [ ] **Step 3: Final commit (if any fixups)**

```bash
git add -A
git commit -m "test(skill-center): verify preview keys end-to-end

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

- **Spec coverage:** key remap (space/enter) → Task 5 + Task 4 (skillCenterSpacePreview); main-library enter=deploy → Task 5; server preview async → Task 1+2+4; legend by context → Task 3+4. All covered.
- **Type consistency:** `catSkillMdCmd(allocator, root_expr, name)`, `OpResult.preview{title,content}`, `SkillPreviewJob{conn,name,cmd}`, `skillCenterSpacePreview()`, `skillCenterPreviewServerSkill(allocator)`, `key_space`, `sc_legend_import`/`sc_busy_loading` — names consistent across tasks.
- **Ownership:** `skillCenterPreviewServerSkill` frees name/cmd/root_expr on every pre-startOp failure path; on rejection calls `SkillPreviewJob.destroy`; `SkillPreviewJob.run` frees content if title dup fails; `OpResult.preview` freed by `pollSkillCenterOp`'s `defer result.deinit` (open dupes first). `target` is deinit'd after conn+software are read (conn is a value copy).
