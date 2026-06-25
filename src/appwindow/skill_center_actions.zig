//! Skill Center action/input and async operation glue for AppWindow.

const std = @import("std");
const ai_chat = @import("../ai_chat.zig");
const ai_chat_request = @import("../ai_chat_request.zig");
const clipboard = @import("../input/clipboard.zig");
const first_party_tools = @import("../first_party_tools.zig");
const i18n = @import("../i18n.zig");
const overlays = @import("../renderer/overlays.zig");
const platform_atomic_file = @import("../platform/atomic_file.zig");
const platform_dirs = @import("../platform/dirs.zig");
const platform_file_dialog = @import("../platform/file_dialog.zig");
const platform_pty_command = @import("../platform/pty_command.zig");
const platform_wsl = @import("../platform/wsl.zig");
const remote_file = @import("../platform/remote_file.zig");
const scp = @import("../scp.zig");
const skill_center = @import("../skill_center.zig");
const skill_install = @import("../skill_install.zig");
const skill_local_fs = @import("../skill_local_fs.zig");
const skill_scan = @import("../skill_scan.zig");
const skill_transfer = @import("../skill_transfer.zig");
const skill_transfer_cmd = @import("../skill_transfer_cmd.zig");
const ssh_connection = @import("../ssh_connection.zig");
const ssh_error = @import("../ssh_error.zig");
const tab = @import("tab.zig");
const tool_import = @import("../tool_import.zig");
const tool_registry = @import("../tool_registry.zig");
const tool_skill_draft = @import("../tool_skill_draft.zig");
const update_install = @import("../update_install.zig");
const window_backend = @import("../platform/window_backend.zig");

pub const OpenFileOverride = ?*const fn (std.mem.Allocator, platform_file_dialog.OpenRequest) ?[]u8;

pub const Host = struct {
    allocator: ?std.mem.Allocator,
    open_file_override: OpenFileOverride,
    current_native_handle_bits: ?usize,
    mark_ui_dirty: *const fn () void,
};

fn activeSkillCenter() ?*skill_center.Session {
    return tab.activeSkillCenter();
}

fn markUiDirty(host: Host) void {
    host.mark_ui_dirty();
}

fn scMoveSel(sel: *usize, len: usize, delta: isize) void {
    if (len == 0) {
        sel.* = 0;
        return;
    }
    const cur: isize = @intCast(sel.*);
    sel.* = @intCast(std.math.clamp(cur + delta, 0, @as(isize, @intCast(len - 1))));
}

/// Move selection in the active overlay list, else in the library list.
pub fn skillCenterMove(host: Host, delta: isize) bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .picker => |*p| scMoveSel(&p.sel, p.labels.len, delta),
        .import_list => |*il| scMoveSel(&il.sel, il.names.len, delta),
        .install_pick => |*p| scMoveSel(&p.sel, p.entries.len, delta),
        .url_input => {},
        .tool_import_confirm => {},
        .tool_import_preview => {},
        else => {
            const n = session.model.entryCount();
            scMoveSel(&session.model.sel_row, n, delta);
        },
    }
    markUiDirty(host);
    return true;
}

/// True if an overlay (picker/import/confirm) is open (captures Enter/Esc).
pub fn skillCenterOverlayActive() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.model.overlay != .none;
}

pub fn skillCenterOverlayCancel() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    if (session.model.overlay == .none) {
        session.mutex.unlock();
        return false;
    }
    session.model.clearOverlay();
    session.mutex.unlock();
    return true;
}

/// True when the URL-input overlay is capturing text. UI thread.
pub fn skillCenterUrlInputActive() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.model.overlay == .url_input;
}

/// 'g': open the URL-input overlay, prefilled from the clipboard if it looks
/// like a GitHub URL. UI thread.
pub fn skillCenterOpenUrlInput(host: Host) bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = host.allocator orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.model.overlay != .none) return false;
    var st: skill_center.UrlInputState = .{};
    if (clipboard.readClipboardTextOwned(allocator)) |clip| {
        defer allocator.free(clip);
        const trimmed = std.mem.trim(u8, clip, " \t\r\n");
        if (std.mem.indexOf(u8, trimmed, "github.com/") != null and trimmed.len < 512)
            st.insertSlice(allocator, trimmed);
    }
    session.model.setOverlay(.{ .url_input = st });
    markUiDirty(host);
    return true;
}

/// Append a typed codepoint to the URL buffer (no-op unless url_input active).
pub fn skillCenterUrlInsertChar(host: Host, codepoint: u21) bool {
    if (codepoint < 0x20 or codepoint == 0x7f) return false;
    const session = activeSkillCenter() orelse return false;
    const allocator = host.allocator orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .url_input => |*u| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &buf) catch return false;
            u.insertSlice(allocator, buf[0..len]);
            markUiDirty(host);
            return true;
        },
        else => return false,
    }
}

/// Backspace in the URL buffer. UI thread.
pub fn skillCenterUrlBackspace(host: Host) bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .url_input => |*u| {
            u.backspace();
            markUiDirty(host);
            return true;
        },
        else => return false,
    }
}

/// Ctrl/Cmd+V: append clipboard text to the URL buffer. UI thread.
pub fn skillCenterUrlPaste(host: Host) bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = host.allocator orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .url_input => |*u| {
            if (clipboard.readClipboardTextOwned(allocator)) |clip| {
                defer allocator.free(clip);
                const trimmed = std.mem.trim(u8, clip, " \t\r\n");
                u.insertSlice(allocator, trimmed);
            }
            markUiDirty(host);
            return true;
        },
        else => return false,
    }
}

/// Enter in the URL-input overlay: snapshot the URL, clear the overlay, start
/// the enumerate op. UI thread.
fn skillCenterStartEnumerate(host: Host, session: *skill_center.Session, allocator: std.mem.Allocator) void {
    var url_owned: ?[]u8 = null;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .url_input => |*u| {
                const t = std.mem.trim(u8, u.text(), " \t\r\n");
                if (t.len > 0) url_owned = allocator.dupe(u8, t) catch null;
                session.model.clearOverlay();
            },
            else => return,
        }
    }
    const url = url_owned orelse {
        markUiDirty(host);
        return;
    };
    // Validate the URL on the UI thread so a parse error gets a precise toast
    // (a worker-thread .failed can't distinguish bad-URL from network error).
    if (skill_install.parseGithubUrl(allocator, url)) |rr| {
        var probe = rr;
        probe.deinit(allocator);
    } else |_| {
        allocator.free(url);
        overlays.showStatusToast(i18n.s().sc_toast_bad_url);
        markUiDirty(host);
        return;
    }
    const job = allocator.create(SkillInstallEnumerateJob) catch {
        allocator.free(url);
        return;
    };
    job.* = .{ .url = url };
    if (!session.startOp(.{ .ctx = job, .run = SkillInstallEnumerateJob.run, .destroy = SkillInstallEnumerateJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_fetching)) {
        SkillInstallEnumerateJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
    markUiDirty(host);
}

/// True when the install checklist is active. UI thread.
pub fn skillCenterPickActive() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.model.overlay == .install_pick;
}

/// Space: toggle the highlighted checklist row. UI thread.
pub fn skillCenterPickToggle(host: Host) bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .install_pick => |*p| {
            p.toggle();
            markUiDirty(host);
            return true;
        },
        else => return false,
    }
}

/// 'a': toggle select-all in the checklist. UI thread.
pub fn skillCenterPickSelectAll(host: Host) bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .install_pick => |*p| {
            p.setAll(!p.anyChecked());
            markUiDirty(host);
            return true;
        },
        else => return false,
    }
}

/// Enter in the checklist: snapshot the selection + repo, clear the overlay,
/// start the download op. UI thread.
fn skillCenterStartInstall(host: Host, session: *skill_center.Session, allocator: std.mem.Allocator) void {
    var repo_owned: ?skill_install.RepoRef = null;
    var entries_owned: ?[]skill_install.SkillEntry = null;
    var empty = false;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .install_pick => |*p| {
                if (!p.anyChecked()) {
                    empty = true;
                } else {
                    repo_owned = p.repo.clone(allocator) catch null;
                    entries_owned = p.selectedEntries(allocator) catch null;
                    session.model.clearOverlay();
                }
            },
            else => return,
        }
    }
    if (empty) {
        overlays.showStatusToast(i18n.s().sc_toast_no_skills);
        markUiDirty(host);
        return;
    }
    const repo = repo_owned orelse {
        if (entries_owned) |e| skill_install.freeEntries(allocator, e);
        markUiDirty(host);
        return;
    };
    const entries = entries_owned orelse {
        var rr = repo;
        rr.deinit(allocator);
        markUiDirty(host);
        return;
    };
    const job = allocator.create(SkillInstallDownloadJob) catch {
        var rr = repo;
        rr.deinit(allocator);
        skill_install.freeEntries(allocator, entries);
        return;
    };
    job.* = .{ .repo = repo, .entries = entries };
    if (!session.startOp(.{ .ctx = job, .run = SkillInstallDownloadJob.run, .destroy = SkillInstallDownloadJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_installing)) {
        SkillInstallDownloadJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
    markUiDirty(host);
}

/// Library root `<config>/skills`. Caller frees.
fn skillCenterLibraryDir(allocator: std.mem.Allocator) ?[]const u8 {
    return platform_dirs.pathInConfigDir(allocator, "skills") catch null;
}

/// Download every selected skill's files into a temp staging dir under the
/// library, then per-skill atomically replace `<config>/skills/<name>`. Returns
/// {installed, overwritten, failed}. A skill whose download fails is skipped
/// (counted in `failed`); others still install. Staging dir is always removed.
fn downloadSelectedSkillsToLibrary(
    allocator: std.mem.Allocator,
    repo: skill_install.RepoRef,
    entries: []const skill_install.SkillEntry,
) struct { installed: usize, overwritten: usize, failed: usize } {
    var installed: usize = 0;
    var overwritten: usize = 0;
    var failed: usize = 0;

    const lib_dir = skillCenterLibraryDir(allocator) orelse return .{ .installed = 0, .overwritten = 0, .failed = entries.len };
    defer allocator.free(lib_dir);
    const ref = repo.ref orelse "main";

    const tmp_dir = std.fs.path.join(allocator, &.{ lib_dir, ".install-tmp" }) catch
        return .{ .installed = 0, .overwritten = 0, .failed = entries.len };
    defer allocator.free(tmp_dir);
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    for (entries) |entry| {
        // Defense-in-depth: never let a downloaded skill name escape the library dir.
        if (entry.name.len == 0 or
            std.mem.eql(u8, entry.name, ".") or
            std.mem.eql(u8, entry.name, "..") or
            std.mem.indexOfScalar(u8, entry.name, '/') != null or
            std.mem.indexOfScalar(u8, entry.name, '\\') != null)
        {
            failed += 1;
            continue;
        }
        var ok = true;
        for (entry.files) |file_path| {
            const rel = skill_install.relInstallPath(entry.root_path, file_path) orelse continue;
            // Fetch via the GitHub Contents API (api.github.com) rather than
            // raw.githubusercontent.com: the same host that enumeration used and
            // proved reachable. `Accept: application/vnd.github.raw` returns the
            // file's raw bytes.
            const url = skill_install.contentsApiUrl(allocator, repo.owner, repo.repo, file_path, ref) catch {
                ok = false;
                break;
            };
            defer allocator.free(url);
            const dest = std.fs.path.join(allocator, &.{ tmp_dir, rel }) catch {
                ok = false;
                break;
            };
            defer allocator.free(dest);
            update_install.downloadAssetAccept(allocator, url, dest, "application/vnd.github.raw") catch {
                ok = false;
                break;
            };
        }
        if (!ok) {
            failed += 1;
            continue;
        }

        const final = std.fs.path.join(allocator, &.{ lib_dir, entry.name }) catch {
            failed += 1;
            continue;
        };
        defer allocator.free(final);
        const staged = std.fs.path.join(allocator, &.{ tmp_dir, entry.name }) catch {
            failed += 1;
            continue;
        };
        defer allocator.free(staged);

        const existed = blk: {
            std.fs.accessAbsolute(final, .{}) catch break :blk false;
            break :blk true;
        };
        std.fs.deleteTreeAbsolute(final) catch {
            failed += 1;
            continue;
        };
        std.fs.renameAbsolute(staged, final) catch {
            failed += 1;
            continue;
        };
        installed += 1;
        if (existed) overwritten += 1;
    }

    return .{ .installed = installed, .overwritten = overwritten, .failed = failed };
}

/// ExecHost over a location: local POSIX, SSH when a conn is present, or the
/// default WSL distro (`wsl.exe --exec sh -lc`) when `is_wsl` is set.
const SkillLocExec = struct {
    conn: ?ssh_connection.SshConnection,
    is_wsl: bool = false,
    fn exec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) anyerror![]u8 {
        const self: *SkillLocExec = @ptrCast(@alignCast(ctx));
        if (self.conn) |c| return remote_file.sshExecCapture(allocator, c, command);
        if (self.is_wsl) return remote_file.wslExec(allocator, command) orelse error.RemoteExecFailed;
        return remote_file.localPosixExec(allocator, command, 4 * 1024 * 1024);
    }
    fn host(self: *SkillLocExec) skill_scan.ExecHost {
        return .{ .ctx = self, .exec = exec };
    }
};

/// Resolve a target's SshConnection (null for a local target / unresolved).
fn skillCenterTargetConn(target: skill_center.Target) ?ssh_connection.SshConnection {
    if (target.is_local) return null;
    if (std.mem.startsWith(u8, target.machine_id, "ssh:")) {
        return overlays.aiHistorySshConnection(target.machine_id["ssh:".len..]);
    }
    return null;
}

/// Absolute path of a local target software's skills root (`~/.claude/skills`).
/// Used by the native (non-POSIX) scan/transfer path where `$HOME` can't be
/// expanded by a shell. Null if the home dir can't be resolved. Caller frees.
fn skillCenterLocalRootPath(allocator: std.mem.Allocator, software: skill_center.Software) ?[]u8 {
    const home = platform_dirs.homeDir(allocator) catch return null;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, software.rootRel() }) catch null;
}

/// Scan a skills endpoint, picking the right backend:
///   - remote (conn set): the POSIX `find`/`sha256sum` command over SSH.
///   - WSL (`is_wsl`): the same command via `wsl.exe --exec sh -lc`.
///   - local on a POSIX host: the same command via `sh -c` (preserves the
///     existing Linux/macOS hashes).
///   - local on a non-POSIX host (Windows, no WSL): a native `std.fs` scan whose
///     aggregate hash matches the POSIX recipe byte-for-byte.
/// `root_expr` is the shell root expression (for the SSH/POSIX/WSL paths);
/// `local_path` is the raw absolute root (for the native path; null when remote).
fn skillCenterScanOutcome(
    allocator: std.mem.Allocator,
    root_expr: []const u8,
    local_path: ?[]const u8,
    conn: ?ssh_connection.SshConnection,
    is_wsl: bool,
) skill_scan.ScanOutcome {
    if (conn) |c| {
        var le = SkillLocExec{ .conn = c };
        return skill_scan.scanLocation(allocator, root_expr, le.host()) catch
            return .{ .reachable = false, .rows = &.{} };
    }
    if (is_wsl) {
        var le = SkillLocExec{ .conn = null, .is_wsl = true };
        return skill_scan.scanLocation(allocator, root_expr, le.host()) catch
            return .{ .reachable = false, .rows = &.{} };
    }
    if (remote_file.localPosixExecSupported()) {
        var le = SkillLocExec{ .conn = null };
        return skill_scan.scanLocation(allocator, root_expr, le.host()) catch
            return .{ .reachable = false, .rows = &.{} };
    }
    const lp = local_path orelse return .{ .reachable = false, .rows = &.{} };
    return skill_local_fs.scanOutcome(allocator, lp);
}

/// Adapts skill_transfer.Ops onto local/ssh/scp/WSL. conn null + !is_wsl → a
/// local-only target; is_wsl → both endpoints reached via `wsl.exe` (see
/// `wslSkillTransfer`, where the library lives under /mnt/<drive> and the target
/// under $HOME, so the copy primitive is never invoked).
/// `err_buf`/`err_len` capture the last ssh error summary for the UI toast.
const SkillTransferCtx = struct {
    conn: ?ssh_connection.SshConnection,
    is_wsl: bool = false,
    // Sized off ssh_error.MAX (+ margin) so a summary never gets re-truncated here.
    err_buf: [ssh_error.MAX + 40]u8 = undefined,
    err_len: usize = 0,

    fn noteErr(self: *SkillTransferCtx, msg: []const u8) void {
        const n = @min(msg.len, self.err_buf.len);
        @memcpy(self.err_buf[0..n], msg[0..n]);
        self.err_len = n;
    }
    fn lastErr(self: *const SkillTransferCtx) ?[]const u8 {
        return if (self.err_len > 0) self.err_buf[0..self.err_len] else null;
    }

    fn localExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        const self: *SkillTransferCtx = @ptrCast(@alignCast(ctx));
        // A WSL transfer runs every step (tar/extract/cleanup) over `wslExec`;
        // skill_transfer only calls localExec for the LOCAL_TMP cleanup, whose
        // path lives in the WSL /tmp and is already removed by the remoteExec
        // `rm`. A no-op keeps that ignored cleanup from spuriously failing.
        if (self.is_wsl) return true;
        return remote_file.localPosixExecOk(allocator, command);
    }
    fn remoteExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        const self: *SkillTransferCtx = @ptrCast(@alignCast(ctx));
        if (self.is_wsl) {
            // Default WSL distro; stdout discarded (only exit status matters).
            const out = remote_file.wslExec(allocator, command) orelse return false;
            allocator.free(out);
            return true;
        }
        const c = self.conn orelse return false;
        // stdout is discarded; remoteExec only cares about exit status + stderr.
        var cap = remote_file.sshExecCaptureFull(allocator, c, command) catch return false;
        defer cap.deinit(allocator);
        if (!cap.exited_ok) {
            if (ssh_error.summarize(cap.stderr)) |s| self.noteErr(s);
            return false;
        }
        return true;
    }
    fn copy(ctx: *anyopaque, allocator: std.mem.Allocator, dir: skill_transfer.CopyDir, local_tmp: []const u8, remote_tmp: []const u8) bool {
        const self: *SkillTransferCtx = @ptrCast(@alignCast(ctx));
        const c = self.conn orelse return false;
        var buf: [512]u8 = undefined;
        const spec = scp.remoteSpec(&buf, &c, remote_tmp);
        const r = switch (dir) {
            .to_remote => scp.transfer(allocator, &c, local_tmp, spec),
            .to_local => scp.transfer(allocator, &c, spec, local_tmp),
        };
        return r == .ok; // scp summary is best-effort; leave err_buf empty → generic toast
    }
    fn ops(self: *SkillTransferCtx) skill_transfer.Ops {
        return .{ .ctx = self, .localExec = localExec, .remoteExec = remoteExec, .copy = copy };
    }
};

/// Marker for a target skill vs the library (by name + hash).
fn skillCenterMarkerFor(model: *const skill_center.PanelModel, name: []const u8, target_hash: ?[]const u8) skill_center.Marker {
    const entries = model.entries orelse return .new_;
    for (entries) |entry| {
        switch (entry) {
            .prompt => |s| {
                if (std.mem.eql(u8, s.name, name)) {
                    const lh = s.agg_hash orelse return .differ;
                    const th = target_hash orelse return .differ;
                    return if (std.mem.eql(u8, lh, th)) .same else .differ;
                }
            },
            .tool, .first_party_tool => {},
        }
    }
    return .new_;
}

/// Build an ImportState from a target's scanned rows. Caller holds the lock.
pub fn makeImportState(allocator: std.mem.Allocator, model: *const skill_center.PanelModel, rows: []const skill_scan.SkillRow, target: skill_center.Target) !skill_center.ImportState {
    var names: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var markers: std.ArrayListUnmanaged(skill_center.Marker) = .empty;
    errdefer markers.deinit(allocator);
    for (rows) |r| {
        const marker = skillCenterMarkerFor(model, r.name, r.agg_hash);
        const n = try allocator.dupe(u8, r.name);
        // Explicit cleanup: once `n` is in `names`, the function-level errdefer
        // owns it — a per-item errdefer here would double-free on a later error.
        names.append(allocator, n) catch |e| {
            allocator.free(n);
            return e;
        };
        try markers.append(allocator, marker);
    }
    var tgt = try target.clone(allocator);
    errdefer tgt.deinit(allocator);
    return .{
        .target = tgt,
        .names = try names.toOwnedSlice(allocator),
        .markers = try markers.toOwnedSlice(allocator),
        .sel = 0,
    };
}

fn skillCenterAddMachine(allocator: std.mem.Allocator, labels: *std.ArrayListUnmanaged([]u8), targets: *std.ArrayListUnmanaged(skill_center.Target), machine_id: []const u8, machine_label: []const u8, is_local: bool, is_wsl: bool) !void {
    const sws = [_]skill_center.Software{ .claude, .codex };
    for (sws) |sw| {
        const sw_label = switch (sw) {
            .claude => i18n.s().sc_sw_claude,
            .codex => i18n.s().sc_sw_codex,
        };
        // Explicit per-append cleanup: once an item is in its list, the outer
        // (buildPicker) errdefer owns it — a per-item errdefer would double-free.
        const label = try std.fmt.allocPrint(allocator, "{s} · {s}", .{ machine_label, sw_label });
        labels.append(allocator, label) catch |e| {
            allocator.free(label);
            return e;
        };
        var tgt = try skill_center.Target.dupe(allocator, machine_id, machine_label, sw, is_local);
        tgt.is_wsl = is_wsl;
        targets.append(allocator, tgt) catch |e| {
            tgt.deinit(allocator);
            return e;
        };
    }
}

/// Build a target picker over {local, WSL (Windows), ssh profiles} × {claude, codex}.
fn skillCenterBuildPicker(allocator: std.mem.Allocator, purpose: skill_center.Purpose, skill_name: []const u8) !skill_center.PickerState {
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var targets: std.ArrayListUnmanaged(skill_center.Target) = .empty;
    errdefer {
        for (labels.items) |l| allocator.free(l);
        labels.deinit(allocator);
        for (targets.items) |*t| t.deinit(allocator);
        targets.deinit(allocator);
    }
    try skillCenterAddMachine(allocator, &labels, &targets, "local", i18n.s().sc_local, true, false);
    // The default WSL distro, only when one is actually installed (registry
    // probe — never spawns wsl.exe, so a WSL-less machine never pops the
    // "install WSL" window). Hidden on non-Windows hosts (wslAvailable false).
    if (platform_pty_command.wslAvailable()) {
        try skillCenterAddMachine(allocator, &labels, &targets, "wsl", i18n.s().sc_wsl, false, true);
    }
    const names = overlays.sshProfileNames(allocator) catch &[_][]u8{};
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    for (names) |nm| {
        const id = try std.fmt.allocPrint(allocator, "ssh:{s}", .{nm});
        defer allocator.free(id);
        try skillCenterAddMachine(allocator, &labels, &targets, id, nm, false, false);
    }
    const name_copy = try allocator.dupe(u8, skill_name);
    errdefer allocator.free(name_copy);
    return .{
        .purpose = purpose,
        .skill_name = name_copy,
        .labels = try labels.toOwnedSlice(allocator),
        .targets = try targets.toOwnedSlice(allocator),
        .sel = 0,
    };
}

pub fn openPicker(host: Host, purpose: skill_center.Purpose) bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = host.allocator orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    const name = switch (purpose) {
        .deploy => blk: {
            const sk = session.model.selected() orelse return false;
            break :blk sk.name;
        },
        .import_ => blk: {
            if (session.model.entryCount() == 0) break :blk "";
            const entry = session.model.selectedEntry() orelse return false;
            switch (entry) {
                .prompt => break :blk "",
                .tool, .first_party_tool => return false,
            }
        },
    };
    const picker = skillCenterBuildPicker(allocator, purpose, name) catch return true;
    session.model.setOverlay(.{ .picker = picker });
    markUiDirty(host);
    return true;
}

pub fn skillCenterDeploy(host: Host) bool {
    return openPicker(host, .deploy);
}
pub fn skillCenterImport(host: Host) bool {
    return openPicker(host, .import_);
}

fn scPathParent(path: []const u8) ?[]const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') return path[0..i];
    }
    return null;
}

fn scPathBase(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') return path[i + 1 ..];
    }
    return path;
}

pub fn toolManifestPath(allocator: std.mem.Allocator, tool: skill_center.ToolSkill) ?[]u8 {
    if (tool.skill_path) |skill_path| {
        if (std.mem.eql(u8, scPathBase(skill_path), "SKILL.md")) {
            const tool_dir = scPathParent(skill_path) orelse return null;
            return std.fs.path.join(allocator, &.{ tool_dir, "manifest.json" }) catch null;
        }
    }
    const bin_dir = scPathParent(tool.executable_path) orelse return null;
    if (!std.mem.eql(u8, scPathBase(bin_dir), "bin")) return null;
    const tool_dir = scPathParent(bin_dir) orelse return null;
    return std.fs.path.join(allocator, &.{ tool_dir, "manifest.json" }) catch null;
}

pub fn applyToolEnabledByManifestPath(
    allocator: std.mem.Allocator,
    entries: []skill_center.LibraryEntry,
    manifest_path: []const u8,
    enabled: bool,
) bool {
    for (entries) |*entry| {
        switch (entry.*) {
            .prompt, .first_party_tool => {},
            .tool => |*tool| {
                const path = toolManifestPath(allocator, tool.*) orelse continue;
                defer allocator.free(path);
                if (std.mem.eql(u8, path, manifest_path)) {
                    tool.enabled = enabled;
                    return true;
                }
            },
        }
    }
    return false;
}

pub fn applyFirstPartyEnabledByName(
    entries: []skill_center.LibraryEntry,
    name: []const u8,
    enabled: bool,
) bool {
    for (entries) |*entry| {
        switch (entry.*) {
            .prompt, .tool => {},
            .first_party_tool => |*tool| {
                if (std.mem.eql(u8, tool.name, name)) {
                    tool.enabled = enabled;
                    return true;
                }
            },
        }
    }
    return false;
}

pub fn manifestJsonWithEnabled(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    enabled: bool,
) ![]u8 {
    var manifest = try tool_registry.parseManifestJson(allocator, bytes);
    defer manifest.deinit(allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolManifest;

    const entry = try parsed.value.object.getOrPutValue("enabled", std.json.Value{ .bool = enabled });
    entry.value_ptr.* = std.json.Value{ .bool = enabled };
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

pub fn setStatusLocked(session: *skill_center.Session, text: []const u8) void {
    const next = session.allocator.dupe(u8, text) catch return;
    if (session.status.len > 0) session.allocator.free(session.status);
    session.status = next;
}

fn skillCenterOpenFileDialog(host: Host, allocator: std.mem.Allocator, request: platform_file_dialog.OpenRequest) ?[]u8 {
    if (host.open_file_override) |open_fn| return open_fn(allocator, request);
    return platform_file_dialog.openFile(allocator, request);
}

fn skillCenterImportErrorSummary(allocator: std.mem.Allocator, err: anyerror) []u8 {
    switch (err) {
        error.ProbeSpawnFailed => return allocator.dupe(u8, "Tool import failed: could not inspect the executable.") catch return &.{},
        error.ReservedToolName => return allocator.dupe(u8, "Tool import failed: reserved built-in tool names cannot be imported.") catch return &.{},
        else => {},
    }
    return std.fmt.allocPrint(allocator, "Tool import failed: {}", .{err}) catch allocator.dupe(u8, "Tool import failed") catch return &.{};
}

fn skillCenterCloneToolImportPreview(
    allocator: std.mem.Allocator,
    preview: skill_center.ToolImportPreviewState,
) !skill_center.ToolImportPreviewState {
    var clone: skill_center.ToolImportPreviewState = .{
        .tool_id = try allocator.dupe(u8, preview.tool_id),
        .function_name = &.{},
        .source_path = &.{},
        .staged_binary_path = &.{},
        .skill_md = &.{},
        .doc_source = preview.doc_source,
        .ai_review_required = preview.ai_review_required,
        .owns_staging_dir = false,
        .scroll = preview.scroll,
    };
    errdefer clone.deinit(allocator);
    clone.function_name = try allocator.dupe(u8, preview.function_name);
    clone.source_path = try allocator.dupe(u8, preview.source_path);
    clone.staged_binary_path = try allocator.dupe(u8, preview.staged_binary_path);
    clone.skill_md = try allocator.dupe(u8, preview.skill_md);
    return clone;
}

fn skillCenterBinaryPlatformLabel(path: []const u8) []const u8 {
    if (std.ascii.endsWithIgnoreCase(path, ".exe")) return "windows";
    return "native";
}

fn skillCenterBinaryFileSize(path: []const u8) !u64 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return (try file.stat()).size;
}

fn skillCenterToolImportConfirmText(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "WispTerm will run the selected executable with `--skill` and `--help` to inspect it before import.\n\n" ++
            "Press Enter to continue to the import preview, or Esc to cancel and remove the staged copy.\n\n" ++
            "Selected file:\n{s}\n",
        .{source_path},
    );
}

const TOOL_IMPORT_DRAFT_SYSTEM_PROMPT =
    "You write concise, accurate WispTerm SKILL.md files for local executable tools. " ++
    "Stay within the evidence provided and name uncertainty when needed.";

const ToolImportDraftJob = struct {
    profile: overlays.DefaultAiProfileSnapshot,
    tool_id: []u8,
    function_name: []u8,
    source_path: []u8,
    staged_binary_path: []u8,
    prompt: []u8,
    success: bool = false,

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *ToolImportDraftJob = @ptrCast(@alignCast(ctx));
        const draft = ai_chat_request.runOneShotPrompt(
            allocator,
            .{
                .base_url = job.profile.base_url,
                .api_key = job.profile.api_key,
                .model = job.profile.model,
                .protocol = job.profile.protocol,
                .thinking_enabled = job.profile.thinking_enabled,
                .reasoning_effort = job.profile.reasoning_effort,
                .max_tokens = job.profile.max_tokens,
            },
            TOOL_IMPORT_DRAFT_SYSTEM_PROMPT,
            job.prompt,
        ) catch |err| {
            return .{ .tool_import_failed = std.fmt.allocPrint(allocator, "Tool import failed: {}", .{err}) catch return .failed };
        };
        defer allocator.free(draft);

        const docs = tool_import.resolveDocs(allocator, .{
            .tool_name = job.function_name,
            .help_output = "",
            .skill_output = "",
            .sibling_skill = null,
            .ai_draft = draft,
        }) catch |err| {
            return .{ .tool_import_failed = std.fmt.allocPrint(allocator, "Tool import failed: {}", .{err}) catch return .failed };
        };
        const tool_id = allocator.dupe(u8, job.tool_id) catch {
            allocator.free(docs.skill_md);
            return .{ .tool_import_failed = allocator.dupe(u8, "Tool import failed: could not stage the generated preview.") catch return .failed };
        };
        const function_name = allocator.dupe(u8, job.function_name) catch {
            allocator.free(tool_id);
            allocator.free(docs.skill_md);
            return .{ .tool_import_failed = allocator.dupe(u8, "Tool import failed: could not stage the generated preview.") catch return .failed };
        };
        const source_path = allocator.dupe(u8, job.source_path) catch {
            allocator.free(tool_id);
            allocator.free(function_name);
            allocator.free(docs.skill_md);
            return .{ .tool_import_failed = allocator.dupe(u8, "Tool import failed: could not stage the generated preview.") catch return .failed };
        };
        const staged_binary_path = allocator.dupe(u8, job.staged_binary_path) catch {
            allocator.free(tool_id);
            allocator.free(function_name);
            allocator.free(source_path);
            allocator.free(docs.skill_md);
            return .{ .tool_import_failed = allocator.dupe(u8, "Tool import failed: could not stage the generated preview.") catch return .failed };
        };

        job.success = true;
        return .{ .tool_import_preview = .{
            .tool_id = tool_id,
            .function_name = function_name,
            .source_path = source_path,
            .staged_binary_path = staged_binary_path,
            .skill_md = docs.skill_md,
            .doc_source = docs.source,
            .ai_review_required = true,
        } };
    }

    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *ToolImportDraftJob = @ptrCast(@alignCast(ctx));
        if (!job.success) tool_import.cleanupStagedBinaryPath(job.staged_binary_path);
        var profile = job.profile;
        profile.deinit(allocator);
        allocator.free(job.tool_id);
        allocator.free(job.function_name);
        allocator.free(job.source_path);
        allocator.free(job.staged_binary_path);
        allocator.free(job.prompt);
        allocator.destroy(job);
    }
};

fn skillCenterContinueToolImport(
    host: Host,
    session: *skill_center.Session,
    allocator: std.mem.Allocator,
    confirm: *skill_center.ToolImportConfirmState,
) bool {
    var probe = tool_import.probeBinary(allocator, confirm.staged_binary_path) catch |err| {
        const summary = skillCenterImportErrorSummary(allocator, err);
        defer if (summary.len > 0) allocator.free(summary);
        session.mutex.lock();
        setStatusLocked(session, if (summary.len > 0) summary else "Tool import failed");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    defer probe.deinit(allocator);
    const sibling_skill = tool_import.readSiblingSkillMd(allocator, confirm.source_path);
    defer if (sibling_skill) |skill_md| allocator.free(skill_md);

    const docs = tool_import.resolveDocs(allocator, .{
        .tool_name = confirm.function_name,
        .help_output = probe.help,
        .skill_output = probe.skill,
        .sibling_skill = sibling_skill,
        .ai_draft = null,
    }) catch |err| switch (err) {
        error.MissingToolDocumentation => null,
        else => {
            const summary = skillCenterImportErrorSummary(allocator, err);
            defer if (summary.len > 0) allocator.free(summary);
            session.mutex.lock();
            setStatusLocked(session, if (summary.len > 0) summary else "Tool import failed");
            session.mutex.unlock();
            markUiDirty(host);
            return true;
        },
    };
    if (docs) |resolved| {
        defer allocator.free(resolved.skill_md);
        session.mutex.lock();
        setStatusLocked(session, "");
        var opened = true;
        confirm.owns_staging_dir = false;
        session.model.openToolImportPreview(.{
            .tool_id = confirm.tool_id,
            .function_name = confirm.function_name,
            .source_path = confirm.source_path,
            .staged_binary_path = confirm.staged_binary_path,
            .skill_md = resolved.skill_md,
            .doc_source = resolved.source,
            .ai_review_required = false,
        }) catch {
            opened = false;
            confirm.owns_staging_dir = true;
        };
        if (!opened) setStatusLocked(session, "Tool import failed: could not open the preview.");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    }

    var profile = overlays.defaultAiProfileSnapshot(allocator) orelse {
        session.mutex.lock();
        setStatusLocked(session, "Add an AI profile or provide SKILL.md next to the binary.");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    var profile_owned = true;
    defer if (profile_owned) profile.deinit(allocator);

    const basename = std.fs.path.basename(confirm.source_path);
    const staged_sha256 = tool_import.sha256FileHex(allocator, confirm.staged_binary_path) catch {
        session.mutex.lock();
        setStatusLocked(session, "Tool import failed: could not hash the executable.");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    defer allocator.free(staged_sha256);
    const staged_size = skillCenterBinaryFileSize(confirm.staged_binary_path) catch {
        session.mutex.lock();
        setStatusLocked(session, "Tool import failed: could not inspect the staged executable.");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    const prompt = tool_skill_draft.buildDraftPrompt(allocator, .{
        .tool_name = confirm.function_name,
        .filename = basename,
        .sha256 = staged_sha256,
        .file_size = staged_size,
        .platform = skillCenterBinaryPlatformLabel(confirm.source_path),
    }) catch {
        session.mutex.lock();
        setStatusLocked(session, "Tool import failed: could not build the documentation draft request.");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    var prompt_owned = true;
    defer if (prompt_owned) allocator.free(prompt);

    const job = allocator.create(ToolImportDraftJob) catch {
        session.mutex.lock();
        setStatusLocked(session, "Tool import failed: could not start the documentation draft.");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    const job_tool_id = allocator.dupe(u8, confirm.tool_id) catch {
        allocator.destroy(job);
        session.mutex.lock();
        setStatusLocked(session, "Tool import failed: could not prepare the documentation draft.");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    const job_function_name = allocator.dupe(u8, confirm.function_name) catch {
        allocator.free(job_tool_id);
        allocator.destroy(job);
        session.mutex.lock();
        setStatusLocked(session, "Tool import failed: could not prepare the documentation draft.");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    const job_source_path = allocator.dupe(u8, confirm.source_path) catch {
        allocator.free(job_tool_id);
        allocator.free(job_function_name);
        allocator.destroy(job);
        session.mutex.lock();
        setStatusLocked(session, "Tool import failed: could not prepare the documentation draft.");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    const job_staged_binary_path = allocator.dupe(u8, confirm.staged_binary_path) catch {
        allocator.free(job_tool_id);
        allocator.free(job_function_name);
        allocator.free(job_source_path);
        allocator.destroy(job);
        session.mutex.lock();
        setStatusLocked(session, "Tool import failed: could not prepare the documentation draft.");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    job.* = .{
        .profile = profile,
        .tool_id = job_tool_id,
        .function_name = job_function_name,
        .source_path = job_source_path,
        .staged_binary_path = job_staged_binary_path,
        .prompt = prompt,
    };
    profile_owned = false;
    prompt_owned = false;
    if (!session.startOp(.{ .ctx = job, .run = ToolImportDraftJob.run, .destroy = ToolImportDraftJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_loading)) {
        ToolImportDraftJob.destroy(@ptrCast(job), allocator);
        session.mutex.lock();
        setStatusLocked(session, i18n.s().sc_toast_op_busy);
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    }
    confirm.owns_staging_dir = false;
    markUiDirty(host);
    return true;
}

pub fn skillCenterImportTool(host: Host) bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = host.allocator orelse return false;
    const filters = [_]platform_file_dialog.Filter{.{ .name = "All Files", .pattern = "*.*" }};
    const owner: platform_file_dialog.Owner = if (host.current_native_handle_bits) |handle_bits|
        platform_file_dialog.windowOwner(handle_bits)
    else
        .{};
    const source_path = skillCenterOpenFileDialog(host, allocator, .{
        .owner = owner,
        .title = "Import executable tool",
        .filters = &filters,
    }) orelse return false;
    defer allocator.free(source_path);

    const basename = std.fs.path.basename(source_path);
    const function_name = tool_registry.sanitizeFunctionName(allocator, basename) catch return false;
    defer allocator.free(function_name);
    tool_registry.validateImportedFunctionName(function_name) catch |err| {
        const summary = skillCenterImportErrorSummary(allocator, err);
        defer if (summary.len > 0) allocator.free(summary);
        session.mutex.lock();
        setStatusLocked(session, if (summary.len > 0) summary else "Tool import failed");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    const tool_id = allocator.dupe(u8, function_name) catch return false;
    defer allocator.free(tool_id);

    const tools_root = platform_dirs.toolsDir(allocator) catch return false;
    defer allocator.free(tools_root);
    const staging_name = std.fmt.allocPrint(allocator, ".import-staging-{d}-{s}", .{ std.time.milliTimestamp(), function_name }) catch return false;
    defer allocator.free(staging_name);
    const staging_root = std.fs.path.join(allocator, &.{ tools_root, staging_name }) catch return false;
    defer allocator.free(staging_root);
    const staging_bin_dir = std.fs.path.join(allocator, &.{ staging_root, "bin" }) catch return false;
    defer allocator.free(staging_bin_dir);
    const staged_binary_path = std.fs.path.join(allocator, &.{ staging_bin_dir, basename }) catch return false;
    defer allocator.free(staged_binary_path);
    var keep_stage = false;
    defer if (!keep_stage) tool_import.cleanupStagedBinaryPath(staged_binary_path);
    tool_import.ensureDirAbsolute(staging_bin_dir) catch return false;
    tool_import.copyFilePreserveMode(source_path, staged_binary_path) catch {
        tool_import.cleanupStagedBinaryPath(staged_binary_path);
        return false;
    };

    const confirm_text = skillCenterToolImportConfirmText(allocator, source_path) catch return false;
    defer allocator.free(confirm_text);
    session.mutex.lock();
    setStatusLocked(session, "");
    session.model.openToolImportConfirm(.{
        .tool_id = tool_id,
        .function_name = function_name,
        .source_path = source_path,
        .staged_binary_path = staged_binary_path,
        .warning_text = confirm_text,
    }) catch {
        setStatusLocked(session, "Tool import failed: could not open the warning.");
        session.mutex.unlock();
        markUiDirty(host);
        return true;
    };
    session.mutex.unlock();
    keep_stage = true;
    markUiDirty(host);
    return true;
}

fn skillCenterToolToggleFailed(host: Host, session: *skill_center.Session) bool {
    session.mutex.lock();
    setStatusLocked(session, i18n.s().sc_tool_toggle_failed);
    session.mutex.unlock();
    markUiDirty(host);
    return true;
}

fn skillCenterToggleFirstPartyToolEnabled(
    host: Host,
    session: *skill_center.Session,
    allocator: std.mem.Allocator,
    name: []const u8,
) bool {
    var disabled = first_party_tools.loadDisabledTools(allocator) catch {
        return skillCenterToolToggleFailed(host, session);
    };
    defer disabled.deinit(allocator);

    const new_enabled = disabled.contains(name);
    var next = first_party_tools.toggledDisabledTools(allocator, disabled, name) catch {
        return skillCenterToolToggleFailed(host, session);
    };
    defer next.deinit(allocator);

    first_party_tools.writeDisabledTools(allocator, next) catch {
        return skillCenterToolToggleFailed(host, session);
    };

    ai_chat.reloadFirstPartyToolState(allocator);
    session.mutex.lock();
    if (session.model.entries) |entries| {
        _ = applyFirstPartyEnabledByName(entries, name, new_enabled);
    }
    setStatusLocked(session, if (new_enabled) i18n.s().sc_tool_enabled else i18n.s().sc_tool_disabled);
    session.mutex.unlock();
    markUiDirty(host);
    return true;
}

pub fn skillCenterToggleToolEnabled(host: Host) bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = host.allocator orelse return false;
    var manifest_path: ?[]u8 = null;
    var first_party_name: ?[]u8 = null;
    var first_party_seen = false;
    var first_party_disableable = false;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        const entry = session.model.selectedEntry() orelse return false;
        switch (entry) {
            .prompt => return false,
            .tool => |tool| {
                manifest_path = toolManifestPath(allocator, tool);
            },
            .first_party_tool => |tool| {
                first_party_seen = true;
                first_party_disableable = tool.disableable;
                if (tool.disableable) {
                    first_party_name = allocator.dupe(u8, tool.name) catch null;
                }
            },
        }
    }
    if (first_party_seen) {
        if (!first_party_disableable) return skillCenterToolToggleFailed(host, session);
        const name = first_party_name orelse return skillCenterToolToggleFailed(host, session);
        defer allocator.free(name);
        return skillCenterToggleFirstPartyToolEnabled(host, session, allocator, name);
    }

    const path = manifest_path orelse {
        return skillCenterToolToggleFailed(host, session);
    };
    defer allocator.free(path);

    const bytes = skill_local_fs.readFileAllocAbsolute(allocator, path, 64 * 1024) catch {
        return skillCenterToolToggleFailed(host, session);
    };
    defer allocator.free(bytes);
    var manifest = tool_registry.parseManifestJson(allocator, bytes) catch {
        return skillCenterToolToggleFailed(host, session);
    };
    defer manifest.deinit(allocator);

    const new_enabled = !manifest.enabled;
    const json = manifestJsonWithEnabled(allocator, bytes, new_enabled) catch {
        return skillCenterToolToggleFailed(host, session);
    };
    defer allocator.free(json);
    platform_atomic_file.writeFileReplaceSafe(path, json) catch {
        return skillCenterToolToggleFailed(host, session);
    };

    ai_chat.reloadDynamicToolSpecs(allocator);
    session.mutex.lock();
    if (session.model.entries) |entries| {
        _ = applyToolEnabledByManifestPath(allocator, entries, path, new_enabled);
    }
    setStatusLocked(session, if (new_enabled) i18n.s().sc_tool_enabled else i18n.s().sc_tool_disabled);
    session.mutex.unlock();
    markUiDirty(host);
    return true;
}

/// Scan a chosen target and open the import list — off the UI thread.
fn skillCenterOpenImportList(allocator: std.mem.Allocator, target: skill_center.Target) void {
    const session = activeSkillCenter() orelse return;
    const conn = skillCenterTargetConn(target);
    if (target.requiresSshConn() and conn == null) {
        overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        return;
    }
    const root_expr = skill_transfer_cmd.homeRootExpr(allocator, target.software.rootRel()) catch return;
    // Raw root for the native (non-POSIX) path; null when remote or unresolvable.
    const local_path: ?[]u8 = if (target.is_local) skillCenterLocalRootPath(allocator, target.software) else null;
    // ownership of root_expr + local_path moves into the job on success
    const tgt = target.clone(allocator) catch {
        allocator.free(root_expr);
        if (local_path) |p| allocator.free(p);
        return;
    };
    const job = allocator.create(SkillImportScanJob) catch {
        allocator.free(root_expr);
        if (local_path) |p| allocator.free(p);
        var t = tgt;
        t.deinit(allocator);
        return;
    };
    job.* = .{ .target = tgt, .conn = conn, .root_expr = root_expr, .local_path = local_path };
    if (!session.startOp(.{ .ctx = job, .run = SkillImportScanJob.run, .destroy = SkillImportScanJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_syncing)) {
        SkillImportScanJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}

/// Run a transfer (library ⇆ target) off the UI thread; result handled in
/// pollSkillCenterOp.
pub fn runTransfer(allocator: std.mem.Allocator, is_import: bool, target: skill_center.Target, name: []const u8) void {
    const session = activeSkillCenter() orelse return;
    const conn = skillCenterTargetConn(target);
    if (target.requiresSshConn() and conn == null) {
        overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        return;
    }
    const lib_dir = skillCenterLibraryDir(allocator) orelse return;
    defer allocator.free(lib_dir);
    const lib_root = skill_transfer_cmd.absRootExpr(allocator, lib_dir) catch return;
    const tgt_root = skill_transfer_cmd.homeRootExpr(allocator, target.software.rootRel()) catch {
        allocator.free(lib_root);
        return;
    };
    const lib_path = allocator.dupe(u8, lib_dir) catch {
        allocator.free(lib_root);
        allocator.free(tgt_root);
        return;
    };
    // Raw target root for the native (non-POSIX) path; null when remote.
    const tgt_path: ?[]u8 = if (target.is_local) skillCenterLocalRootPath(allocator, target.software) else null;
    const name_dup = allocator.dupe(u8, name) catch {
        allocator.free(lib_root);
        allocator.free(tgt_root);
        allocator.free(lib_path);
        if (tgt_path) |p| allocator.free(p);
        return;
    };
    const job = allocator.create(SkillTransferJob) catch {
        allocator.free(lib_root);
        allocator.free(tgt_root);
        allocator.free(lib_path);
        if (tgt_path) |p| allocator.free(p);
        allocator.free(name_dup);
        return;
    };
    job.* = .{
        .is_import = is_import,
        .conn = conn,
        .is_wsl = target.is_wsl,
        .lib_root = lib_root,
        .tgt_root = tgt_root,
        .tgt_is_local = target.is_local,
        .name = name_dup,
        .lib_path = lib_path,
        .tgt_path = tgt_path,
        .tgt_software = target.software,
    };
    if (!session.startOp(.{ .ctx = job, .run = SkillTransferJob.run, .destroy = SkillTransferJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_syncing)) {
        SkillTransferJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}

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
    if (target.requiresSshConn() and conn == null) {
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
    // Absolute SKILL.md path for a LOCAL target so the worker can read it
    // natively on a non-POSIX host; null for remote (uses the ssh cat cmd).
    const local_md_path: ?[]u8 = if (target.is_local) blk: {
        const root = skillCenterLocalRootPath(allocator, target.software) orelse break :blk null;
        defer allocator.free(root);
        break :blk std.fs.path.join(allocator, &.{ root, name, "SKILL.md" }) catch null;
    } else null;
    const job = allocator.create(SkillPreviewJob) catch {
        allocator.free(name);
        allocator.free(cmd);
        if (local_md_path) |p| allocator.free(p);
        return;
    };
    job.* = .{ .conn = conn, .is_wsl = target.is_wsl, .name = name, .cmd = cmd, .local_md_path = local_md_path };
    if (!session.startOp(.{ .ctx = job, .run = SkillPreviewJob.run, .destroy = SkillPreviewJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_loading)) {
        SkillPreviewJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}

/// Arm an overwrite confirm overlay for a pending deploy/import.
pub fn armConfirm(host: Host, allocator: std.mem.Allocator, is_import: bool, target: skill_center.Target, name: []const u8) void {
    const session = activeSkillCenter() orelse return;
    var msg_buf: [256]u8 = undefined;
    const t = i18n.s();
    const msg = std.fmt.bufPrint(&msg_buf, "{s} → {s} {s}", .{ name, target.machine_label, t.sc_confirm_suffix }) catch t.sc_confirm_suffix;
    // Explicit cleanup (not errdefer): this is a void fn, so errdefer would
    // never fire on the `catch return` paths.
    var tgt = target.clone(allocator) catch return;
    const name_dup = allocator.dupe(u8, name) catch {
        tgt.deinit(allocator);
        return;
    };
    const text = allocator.dupe(u8, msg) catch {
        tgt.deinit(allocator);
        allocator.free(name_dup);
        return;
    };
    session.mutex.lock();
    defer session.mutex.unlock();
    session.model.setOverlay(.{ .confirm = .{ .text = text, .is_import = is_import, .target = tgt, .name = name_dup } });
    markUiDirty(host);
}

/// Deploy: scan the target off the UI thread; the decision happens in
/// pollSkillCenterOp once rows arrive.
fn skillCenterDeployDecide(allocator: std.mem.Allocator, target: skill_center.Target, name: []const u8, src_hash: ?[]const u8) void {
    const session = activeSkillCenter() orelse return;
    const conn = skillCenterTargetConn(target);
    if (target.requiresSshConn() and conn == null) {
        overlays.showStatusToast(i18n.s().sc_toast_no_conn);
        return;
    }
    const root_expr = skill_transfer_cmd.homeRootExpr(allocator, target.software.rootRel()) catch return;
    // Raw root for the native (non-POSIX) path; null when remote or unresolvable.
    const local_path: ?[]u8 = if (target.is_local) skillCenterLocalRootPath(allocator, target.software) else null;
    const tgt = target.clone(allocator) catch {
        allocator.free(root_expr);
        if (local_path) |p| allocator.free(p);
        return;
    };
    const name_dup = allocator.dupe(u8, name) catch {
        allocator.free(root_expr);
        if (local_path) |p| allocator.free(p);
        var t = tgt;
        t.deinit(allocator);
        return;
    };
    var hash_dup: ?[]u8 = null;
    if (src_hash) |h| {
        hash_dup = allocator.dupe(u8, h) catch {
            allocator.free(root_expr);
            if (local_path) |p| allocator.free(p);
            var t = tgt;
            t.deinit(allocator);
            allocator.free(name_dup);
            return;
        };
    }
    const job = allocator.create(SkillDeployScanJob) catch {
        allocator.free(root_expr);
        if (local_path) |p| allocator.free(p);
        var t = tgt;
        t.deinit(allocator);
        allocator.free(name_dup);
        if (hash_dup) |h| allocator.free(h);
        return;
    };
    job.* = .{ .target = tgt, .conn = conn, .root_expr = root_expr, .local_path = local_path, .name = name_dup, .src_hash = hash_dup };
    if (!session.startOp(.{ .ctx = job, .run = SkillDeployScanJob.run, .destroy = SkillDeployScanJob.destroy }, window_backend.postWakeup, i18n.s().sc_busy_syncing)) {
        SkillDeployScanJob.destroy(@ptrCast(job), allocator);
        overlays.showStatusToast(i18n.s().sc_toast_op_busy);
    }
}

/// Import: the marker already encodes new/same/differ.
fn skillCenterImportAct(host: Host, allocator: std.mem.Allocator, target: skill_center.Target, name: []const u8, marker: skill_center.Marker) void {
    switch (marker) {
        .same => overlays.showStatusToast(i18n.s().sc_toast_in_sync),
        .new_ => runTransfer(allocator, true, target, name),
        .differ => armConfirm(host, allocator, true, target, name),
    }
}

/// Enter inside an overlay: act on the selection. Snapshots under the lock,
/// then runs the (blocking) work after releasing it.
pub fn skillCenterOverlaySelect(host: Host) bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = host.allocator orelse return false;
    // URL input submits to the enumerate op (manages its own lock).
    if (skillCenterUrlInputActive()) {
        skillCenterStartEnumerate(host, session, allocator);
        return true;
    }
    // The install checklist submits to the download op (manages its own lock).
    if (skillCenterPickActive()) {
        skillCenterStartInstall(host, session, allocator);
        return true;
    }
    var tool_confirm_owned: ?skill_center.ToolImportConfirmState = null;
    var tool_preview_owned: ?skill_center.ToolImportPreviewState = null;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        if (session.model.overlay == .tool_import_confirm) {
            tool_confirm_owned = session.model.takeToolImportConfirm() orelse return false;
        }
        if (session.model.overlay == .tool_import_preview) {
            tool_preview_owned = skillCenterCloneToolImportPreview(allocator, session.model.overlay.tool_import_preview) catch return false;
        }
    }
    if (tool_confirm_owned) |*confirm| {
        defer confirm.deinit(allocator);
        return skillCenterContinueToolImport(host, session, allocator, confirm);
    }
    if (tool_preview_owned) |*preview| {
        defer preview.deinit(allocator);
        const tools_root = platform_dirs.toolsDir(allocator) catch {
            session.mutex.lock();
            setStatusLocked(session, "Tool import failed: could not open the tools directory.");
            session.mutex.unlock();
            markUiDirty(host);
            return true;
        };
        defer allocator.free(tools_root);
        const installed = tool_import.installToolPackageWithSource(
            allocator,
            tools_root,
            preview.staged_binary_path,
            preview.source_path,
            preview.function_name,
            preview.skill_md,
            false,
        ) catch |err| {
            const summary = skillCenterImportErrorSummary(allocator, err);
            defer if (summary.len > 0) allocator.free(summary);
            session.mutex.lock();
            setStatusLocked(session, if (summary.len > 0) summary else "Tool import failed");
            session.mutex.unlock();
            markUiDirty(host);
            return true;
        };
        defer allocator.free(installed);
        session.mutex.lock();
        session.model.clearOverlay();
        setStatusLocked(session, "");
        session.mutex.unlock();
        startScan(allocator, session);
        ai_chat.reloadDynamicToolSpecs(allocator);
        markUiDirty(host);
        return true;
    }
    const Act = enum { none, deploy_picked, import_picked, import_item, confirm };
    var act: Act = .none;
    var target: ?skill_center.Target = null;
    var name_owned: ?[]u8 = null;
    var src_hash_owned: ?[]u8 = null;
    var marker: skill_center.Marker = .new_;
    var is_import_confirm = false;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        switch (session.model.overlay) {
            .picker => |*p| {
                if (p.sel < p.targets.len) {
                    target = p.targets[p.sel].clone(allocator) catch null;
                    if (p.purpose == .deploy) {
                        name_owned = allocator.dupe(u8, p.skill_name) catch null;
                        if (session.model.entries) |entries| {
                            for (entries) |entry| {
                                switch (entry) {
                                    .prompt => |s| {
                                        if (std.mem.eql(u8, s.name, p.skill_name)) {
                                            if (s.agg_hash) |h| src_hash_owned = allocator.dupe(u8, h) catch null;
                                        }
                                    },
                                    .tool, .first_party_tool => {},
                                }
                            }
                        }
                        act = .deploy_picked;
                    } else {
                        act = .import_picked;
                    }
                }
                session.model.clearOverlay();
            },
            .import_list => |*il| {
                if (il.sel < il.names.len) {
                    name_owned = allocator.dupe(u8, il.names[il.sel]) catch null;
                    target = il.target.clone(allocator) catch null;
                    marker = il.markers[il.sel];
                    act = .import_item;
                }
                session.model.clearOverlay();
            },
            .confirm => |*c| {
                target = c.target.clone(allocator) catch null;
                name_owned = allocator.dupe(u8, c.name) catch null;
                is_import_confirm = c.is_import;
                act = .confirm;
                session.model.clearOverlay();
            },
            // Handled by the early guards above; safety no-ops here.
            .url_input => {},
            .install_pick => {},
            .text_preview => {},
            .tool_import_confirm => {},
            .tool_import_preview => {},
            .none, .busy => {},
        }
    }
    defer {
        if (target) |*t| t.deinit(allocator);
        if (name_owned) |n| allocator.free(n);
        if (src_hash_owned) |h| allocator.free(h);
    }
    markUiDirty(host);
    switch (act) {
        .none => {},
        .deploy_picked => {
            if (target) |tgt| if (name_owned) |nm| skillCenterDeployDecide(allocator, tgt, nm, src_hash_owned);
        },
        .import_picked => {
            if (target) |tgt| skillCenterOpenImportList(allocator, tgt);
        },
        .import_item => {
            if (target) |tgt| if (name_owned) |nm| skillCenterImportAct(host, allocator, tgt, nm, marker);
        },
        .confirm => {
            if (target) |tgt| if (name_owned) |nm| runTransfer(allocator, is_import_confirm, tgt, nm);
        },
    }
    return true;
}

/// Rescan all sources for the active Skill Center tab. UI thread.
pub fn skillCenterRescan(host: Host) bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = host.allocator orelse return false;
    startScan(allocator, session);
    markUiDirty(host);
    return true;
}

/// Preview the selected library skill's SKILL.md in the markdown panel.
pub fn skillCenterPreviewSelected(host: Host) bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = host.allocator orelse return false;
    var path_owned: ?[]u8 = null;
    var name_buf: [128]u8 = undefined;
    var name_len: usize = 0;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        const entry = session.model.selectedEntry() orelse return true;
        switch (entry) {
            .prompt => |sk| {
                name_len = @min(sk.name.len, name_buf.len);
                @memcpy(name_buf[0..name_len], sk.name[0..name_len]);
                const lib_dir = skillCenterLibraryDir(allocator) orelse return true;
                defer allocator.free(lib_dir);
                path_owned = std.fs.path.join(allocator, &.{ lib_dir, sk.rel_path }) catch null;
            },
            .tool => |tool| {
                const skill_path = tool.skill_path orelse return true;
                name_len = @min(tool.name.len, name_buf.len);
                @memcpy(name_buf[0..name_len], tool.name[0..name_len]);
                path_owned = allocator.dupe(u8, skill_path) catch null;
            },
            .first_party_tool => return true,
        }
    }
    const abs = path_owned orelse return true;
    defer allocator.free(abs);
    const text = skill_local_fs.readFileAllocAbsolute(allocator, abs, 1024 * 1024) catch null;
    if (text) |t| {
        defer allocator.free(t);
        var title_buf: [160]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s} / SKILL.md", .{name_buf[0..name_len]}) catch name_buf[0..name_len];
        session.mutex.lock();
        session.model.openTextPreview(title, t) catch {};
        session.mutex.unlock();
        markUiDirty(host);
    } else {
        overlays.showStatusToast(i18n.s().sc_toast_read_failed);
    }
    return true;
}

/// True when the scrollable SKILL.md preview overlay is showing.
pub fn skillCenterTextPreviewActive() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.model.isTextPreview();
}

pub const SkillCenterPreviewKind = enum {
    none,
    text,
    tool_import_confirm,
    tool_import,
};

pub fn skillCenterPreviewKind() SkillCenterPreviewKind {
    const session = activeSkillCenter() orelse return .none;
    session.mutex.lock();
    defer session.mutex.unlock();
    return switch (session.model.overlay) {
        .text_preview => .text,
        .tool_import_confirm => .tool_import_confirm,
        .tool_import_preview => .tool_import,
        else => .none,
    };
}

/// Scroll the open SKILL.md preview by `delta` wrapped lines (renderer clamps).
pub fn skillCenterPreviewScroll(host: Host, delta: isize) bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    session.model.scrollTextPreview(delta);
    session.mutex.unlock();
    markUiDirty(host);
    return true;
}

/// Close the SKILL.md preview overlay.
pub fn skillCenterPreviewClose(host: Host) bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    session.model.clearOverlay();
    session.mutex.unlock();
    markUiDirty(host);
    return true;
}

/// Space key in the Skill Center: preview the selected item by overlay kind.
/// import_list → server skill (async); main library / deploy picker → local
/// library skill; import picker / confirm → no-op. UI thread.
pub fn skillCenterSpacePreview(host: Host) bool {
    if (skillCenterPickActive()) return skillCenterPickToggle(host);
    const session = activeSkillCenter() orelse return false;
    const allocator = host.allocator orelse return false;
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
            .url_input => kind = .none,
            .install_pick => kind = .none,
            .text_preview => kind = .none, // input intercepts Space while previewing
            .tool_import_confirm => kind = .none,
            .tool_import_preview => kind = .none,
        }
    }
    switch (kind) {
        .lib => _ = skillCenterPreviewSelected(host),
        .server => skillCenterPreviewServerSkill(allocator),
        .none => {},
    }
    return true;
}

// ===========================================================================
// Skill Center — scan worker, host factory, source enumeration
// ===========================================================================

/// Everything a Skill Center scan host needs for one source, snapshotted on the
/// UI thread. `ssh` carries a copied `SshConnection` value (inline buffers, no
/// threadlocal pointers); `local`/`wsl` resolve inside the worker. `unreachable_`
/// marks a source we want to show as an unreachable column (e.g. an SSH profile
/// that could not be resolved, or local on a non-POSIX host).
/// Background job: scan the local library (`<config>/skills`) off the UI thread.
const SkillLibraryScanJob = struct {
    root_expr: []u8, // owned shell expression for the library root (POSIX path)
    local_path: []u8, // owned raw absolute library root (native path)
    tools_root: []const u8, // owned raw absolute installed binary tools root

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]skill_center.LibraryEntry {
        const job: *SkillLibraryScanJob = @ptrCast(@alignCast(ctx));
        const outcome = skillCenterScanOutcome(allocator, job.root_expr, job.local_path, null, false);
        const prompt_entries = if (outcome.reachable) entries: {
            const prompt_lib = try skill_center.libraryFromRows(allocator, outcome.rows);
            break :entries try skill_center.entriesFromLibrary(allocator, prompt_lib);
        } else try allocator.alloc(skill_center.LibraryEntry, 0);
        var prompt_entries_owned = true;
        errdefer if (prompt_entries_owned) skill_center.freeEntries(allocator, prompt_entries);

        const tools = try tool_registry.scanInstalledTools(allocator, job.tools_root);
        defer tool_registry.freeInstalledTools(allocator, tools);

        const first_party_defs = try first_party_tools.activeDefinitions(allocator);
        defer first_party_tools.freeDefinitions(allocator, first_party_defs);
        var disabled_first_party = try first_party_tools.loadDisabledTools(allocator);
        defer disabled_first_party.deinit(allocator);

        const entries = try allocator.alloc(skill_center.LibraryEntry, prompt_entries.len + tools.len + first_party_defs.len);
        var filled: usize = 0;
        errdefer {
            for (entries[0..filled]) |*entry| entry.deinit(allocator);
            allocator.free(entries);
        }

        for (prompt_entries) |entry| {
            entries[filled] = entry;
            filled += 1;
        }
        allocator.free(prompt_entries);
        prompt_entries_owned = false;

        for (tools) |tool| {
            entries[filled] = try skillCenterEntryFromInstalledTool(allocator, job.tools_root, tool);
            filled += 1;
        }

        for (first_party_defs) |definition| {
            entries[filled] = try skillCenterEntryFromFirstPartyDefinition(
                allocator,
                definition,
                !(definition.disableable and disabled_first_party.contains(definition.name)),
            );
            filled += 1;
        }

        std.sort.insertion(skill_center.LibraryEntry, entries, {}, skillCenterEntryLessThan);
        return entries;
    }

    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillLibraryScanJob = @ptrCast(@alignCast(ctx));
        allocator.free(job.root_expr);
        allocator.free(job.local_path);
        allocator.free(job.tools_root);
        allocator.destroy(job);
    }
};

fn skillCenterEntryLessThan(_: void, a: skill_center.LibraryEntry, b: skill_center.LibraryEntry) bool {
    return std.mem.lessThan(u8, a.name(), b.name());
}

fn skillCenterEntryFromInstalledTool(
    allocator: std.mem.Allocator,
    tools_root: []const u8,
    tool: tool_registry.InstalledTool,
) !skill_center.LibraryEntry {
    const name = try allocator.dupe(u8, tool.function_name);
    errdefer allocator.free(name);
    const executable_path = try allocator.dupe(u8, tool.executable_abs);
    errdefer allocator.free(executable_path);
    const skill_path = try std.fs.path.join(allocator, &.{ tools_root, tool.id, "SKILL.md" });
    return .{ .tool = .{
        .name = name,
        .executable_path = executable_path,
        .skill_path = skill_path,
        .enabled = tool.enabled,
        .approval = .ask,
    } };
}

fn skillCenterEntryFromFirstPartyDefinition(
    allocator: std.mem.Allocator,
    definition: first_party_tools.Definition,
    enabled: bool,
) !skill_center.LibraryEntry {
    const name = try allocator.dupe(u8, definition.name);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, definition.description);
    return .{ .first_party_tool = .{
        .name = name,
        .description = description,
        .enabled = enabled,
        .disableable = definition.disableable,
    } };
}

/// Background op: scan a target, return rows for the UI to build an import list.
const SkillImportScanJob = struct {
    target: skill_center.Target, // owned
    conn: ?ssh_connection.SshConnection,
    root_expr: []u8, // owned
    local_path: ?[]u8, // owned raw root when local; null when remote (native path)

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillImportScanJob = @ptrCast(@alignCast(ctx));
        var outcome = skillCenterScanOutcome(allocator, job.root_expr, job.local_path, job.conn, job.target.is_wsl);
        const tgt = job.target.clone(allocator) catch {
            outcome.deinit(allocator);
            return .failed;
        };
        // An unreachable source yields `{ reachable = false, rows = &.{} }`;
        // importScanResult turns it into `.failed` rather than an empty list.
        return skill_center.importScanResult(allocator, &outcome, tgt);
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillImportScanJob = @ptrCast(@alignCast(ctx));
        job.target.deinit(allocator);
        allocator.free(job.root_expr);
        if (job.local_path) |p| allocator.free(p);
        allocator.destroy(job);
    }
};

/// Background op: scan a target for deploy, return rows + the skill identity so
/// the UI can decide noop/direct/confirm.
const SkillDeployScanJob = struct {
    target: skill_center.Target, // owned
    conn: ?ssh_connection.SshConnection,
    root_expr: []u8, // owned
    local_path: ?[]u8, // owned raw root when local; null when remote (native path)
    name: []u8, // owned
    src_hash: ?[]u8, // owned

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillDeployScanJob = @ptrCast(@alignCast(ctx));
        var outcome = skillCenterScanOutcome(allocator, job.root_expr, job.local_path, job.conn, job.target.is_wsl);
        // A genuinely unreachable target (SSH failure) → fail fast, as the old
        // scan-error path did; a reachable-but-empty target deploys via `.direct`.
        if (!outcome.reachable) {
            outcome.deinit(allocator);
            return .failed;
        }
        const tgt = job.target.clone(allocator) catch {
            outcome.deinit(allocator);
            return .failed;
        };
        const name = allocator.dupe(u8, job.name) catch {
            outcome.deinit(allocator);
            var t = tgt;
            t.deinit(allocator);
            return .failed;
        };
        var src_hash: ?[]u8 = null;
        if (job.src_hash) |h| {
            src_hash = allocator.dupe(u8, h) catch {
                outcome.deinit(allocator);
                var t = tgt;
                t.deinit(allocator);
                allocator.free(name);
                return .failed;
            };
        }
        const rows = outcome.rows;
        outcome.rows = &.{};
        return .{ .deploy_scan = .{ .target = tgt, .name = name, .src_hash = src_hash, .rows = rows } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillDeployScanJob = @ptrCast(@alignCast(ctx));
        job.target.deinit(allocator);
        allocator.free(job.root_expr);
        if (job.local_path) |p| allocator.free(p);
        allocator.free(job.name);
        if (job.src_hash) |h| allocator.free(h);
        allocator.destroy(job);
    }
};

/// Background op: run a transfer (library ⇆ target), capturing a stderr summary.
const SkillTransferJob = struct {
    is_import: bool,
    conn: ?ssh_connection.SshConnection,
    is_wsl: bool,
    lib_root: []u8, // owned shell expr (POSIX path)
    tgt_root: []u8, // owned shell expr (POSIX path)
    tgt_is_local: bool,
    name: []u8, // owned
    lib_path: []u8, // owned raw absolute library root (native path)
    tgt_path: ?[]u8, // owned raw absolute target root when local; null when remote
    tgt_software: skill_center.Software, // for resolving the remote root natively

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillTransferJob = @ptrCast(@alignCast(ctx));
        var tctx = SkillTransferCtx{ .conn = job.conn, .is_wsl = job.is_wsl };
        const ok = if (job.is_wsl)
            wslSkillTransfer(allocator, job, &tctx)
        else if (remote_file.localPosixExecSupported()) blk: {
            // POSIX local host: the proven tar-over-scp dance (Linux/macOS).
            const lib_ep = skill_transfer.Endpoint{ .root_expr = job.lib_root, .is_local = true };
            const tgt_ep = skill_transfer.Endpoint{ .root_expr = job.tgt_root, .is_local = job.tgt_is_local };
            const from = if (job.is_import) tgt_ep else lib_ep;
            const to = if (job.is_import) lib_ep else tgt_ep;
            break :blk skill_transfer.transfer(allocator, tctx.ops(), from, to, job.name) == .ok;
        } else nativeSkillTransfer(allocator, job, &tctx);
        var summary: ?[]u8 = null;
        if (!ok) {
            if (tctx.lastErr()) |s| summary = allocator.dupe(u8, s) catch null;
        }
        return .{ .transfer = .{ .is_import = job.is_import, .ok = ok, .err_summary = summary } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillTransferJob = @ptrCast(@alignCast(ctx));
        allocator.free(job.lib_root);
        allocator.free(job.tgt_root);
        allocator.free(job.name);
        allocator.free(job.lib_path);
        if (job.tgt_path) |p| allocator.free(p);
        allocator.destroy(job);
    }
};

/// Transfer a skill to/from the default WSL distro. Both endpoints are visible
/// to a single `wsl.exe` shell — the library on the Windows filesystem reached
/// at `/mnt/<drive>/…`, the target under `$HOME` — so the whole transfer runs
/// inside WSL with no host↔guest file copy: tar-create + extract over `wslExec`
/// (see `SkillTransferCtx` and the both-remote case of `skill_transfer`).
/// `job.lib_path` is a native Windows path that must be converted to its guest
/// `/mnt` form before `tar -C` can read it. Returns true on full success.
fn wslSkillTransfer(allocator: std.mem.Allocator, job: *SkillTransferJob, tctx: *SkillTransferCtx) bool {
    const guest_lib = (platform_wsl.hostPathToGuestPathAlloc(allocator, job.lib_path) catch null) orelse {
        tctx.noteErr("library is not on a mounted drive");
        return false;
    };
    defer allocator.free(guest_lib);
    const lib_root = skill_transfer_cmd.absRootExpr(allocator, guest_lib) catch return false;
    defer allocator.free(lib_root);

    // Both endpoints remote (is_local = false) → skill_transfer skips its copy
    // primitive and runs tar-create + extract entirely over wslExec.
    const lib_ep = skill_transfer.Endpoint{ .root_expr = lib_root, .is_local = false };
    const tgt_ep = skill_transfer.Endpoint{ .root_expr = job.tgt_root, .is_local = false };
    const from = if (job.is_import) tgt_ep else lib_ep;
    const to = if (job.is_import) lib_ep else tgt_ep;
    return skill_transfer.transfer(allocator, tctx.ops(), from, to, job.name) == .ok;
}

/// Transfer a skill without a POSIX shell (native Windows, no WSL):
///   - local↔local: a native `std.fs` directory copy with atomic swap.
///   - local↔remote: `scp -r` to/from a staging dir + an SSH stage/swap, so the
///     local side never needs `tar` or a `/tmp` path. The remote side stays
///     POSIX (its `mkdir`/`mv` run over SSH). Returns true on full success.
fn nativeSkillTransfer(allocator: std.mem.Allocator, job: *SkillTransferJob, tctx: *SkillTransferCtx) bool {
    if (job.conn == null) {
        const tgt_path = job.tgt_path orelse {
            tctx.noteErr("could not resolve target path");
            return false;
        };
        const src = if (job.is_import) tgt_path else job.lib_path;
        const dst = if (job.is_import) job.lib_path else tgt_path;
        skill_local_fs.transferLocalToLocal(allocator, src, dst, job.name) catch {
            tctx.noteErr("local copy failed");
            return false;
        };
        return true;
    }
    var conn = job.conn.?;
    if (job.is_import) return nativeImportFromRemote(allocator, job, &conn, tctx);
    return nativeDeployToRemote(allocator, job, &conn, tctx);
}

/// Resolve the target's ABSOLUTE skills root on the remote (e.g.
/// `/home/user/.claude/skills`) by asking the remote shell to expand `$HOME`.
/// scp must be handed a literal path: its default (SFTP) protocol does NOT
/// shell-expand a `"$HOME"`/quoted remote spec — passing the shell expression
/// would only work via the legacy `-O` fallback on a POSIX login shell, which
/// breaks on modern Windows OpenSSH (SFTP default) and non-POSIX login shells.
/// Caller frees. Null if the home can't be resolved.
fn resolveRemoteSkillRoot(
    allocator: std.mem.Allocator,
    conn: *const ssh_connection.SshConnection,
    software: skill_center.Software,
) ?[]u8 {
    const home = remote_file.sshExecCapture(allocator, conn.*, "printf %s \"$HOME\"") catch return null;
    defer allocator.free(home);
    const trimmed = std.mem.trim(u8, home, " \t\r\n");
    if (trimmed.len == 0) return null;
    // POSIX remote path → always '/' separators, never std.fs.path.join.
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed, software.rootRel() }) catch null;
}

/// Deploy the library skill to a remote target via `scp -r` (no local tar).
fn nativeDeployToRemote(
    allocator: std.mem.Allocator,
    job: *SkillTransferJob,
    conn: *const ssh_connection.SshConnection,
    tctx: *SkillTransferCtx,
) bool {
    const abs_root = resolveRemoteSkillRoot(allocator, conn, job.tgt_software) orelse {
        tctx.noteErr("could not resolve remote home");
        return false;
    };
    defer allocator.free(abs_root);
    const root_expr = skill_transfer_cmd.absRootExpr(allocator, abs_root) catch return false;
    defer allocator.free(root_expr);

    const prep = skill_transfer_cmd.remoteStagePrepCmd(allocator, root_expr) catch return false;
    defer allocator.free(prep);
    if (!SkillTransferCtx.remoteExec(tctx, allocator, prep)) return false;

    const local_src = std.fs.path.join(allocator, &.{ job.lib_path, job.name }) catch return false;
    defer allocator.free(local_src);
    // Clean absolute remote path for scp (works under both the SFTP-default and
    // legacy protocols); the ssh prep above created exactly this dir.
    const remote_stage = std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs_root, skill_transfer_cmd.XFER_STAGING }) catch return false;
    defer allocator.free(remote_stage);
    var spec_buf: [512]u8 = undefined;
    const dst_spec = scp.remoteSpec(&spec_buf, conn, remote_stage);
    var control: scp.TransferControl = .{};
    if (scp.transferDirWithControl(allocator, conn, local_src, dst_spec, &control) != .ok) {
        tctx.noteErr("scp upload failed");
        return false;
    }

    const swap = skill_transfer_cmd.remoteStageSwapCmd(allocator, root_expr, job.name) catch return false;
    defer allocator.free(swap);
    return SkillTransferCtx.remoteExec(tctx, allocator, swap);
}

/// Import a remote skill into the library via `scp -r` into a local staging dir,
/// then a native atomic swap.
fn nativeImportFromRemote(
    allocator: std.mem.Allocator,
    job: *SkillTransferJob,
    conn: *const ssh_connection.SshConnection,
    tctx: *SkillTransferCtx,
) bool {
    const abs_root = resolveRemoteSkillRoot(allocator, conn, job.tgt_software) orelse {
        tctx.noteErr("could not resolve remote home");
        return false;
    };
    defer allocator.free(abs_root);

    skill_local_fs.ensureDirAbsolute(job.lib_path) catch {
        tctx.noteErr("library dir unavailable");
        return false;
    };
    const staging = std.fs.path.join(allocator, &.{ job.lib_path, skill_transfer_cmd.XFER_STAGING }) catch return false;
    defer allocator.free(staging);
    std.fs.deleteTreeAbsolute(staging) catch {};
    skill_local_fs.ensureDirAbsolute(staging) catch {
        tctx.noteErr("local staging failed");
        return false;
    };
    defer std.fs.deleteTreeAbsolute(staging) catch {};

    // Clean absolute remote source path for scp (SFTP-default safe).
    const remote_src = std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs_root, job.name }) catch return false;
    defer allocator.free(remote_src);
    var spec_buf: [512]u8 = undefined;
    const src_spec = scp.remoteSpec(&spec_buf, conn, remote_src);
    var control: scp.TransferControl = .{};
    if (scp.transferDirWithControl(allocator, conn, src_spec, staging, &control) != .ok) {
        tctx.noteErr("scp download failed");
        return false;
    }

    const staged_skill = std.fs.path.join(allocator, &.{ staging, job.name }) catch return false;
    defer allocator.free(staged_skill);
    const final = std.fs.path.join(allocator, &.{ job.lib_path, job.name }) catch return false;
    defer allocator.free(final);
    std.fs.deleteTreeAbsolute(final) catch {};
    std.fs.renameAbsolute(staged_skill, final) catch {
        tctx.noteErr("local install failed");
        return false;
    };
    return true;
}

/// Background op: read one skill's SKILL.md (local or via ssh) for preview.
const SkillPreviewJob = struct {
    conn: ?ssh_connection.SshConnection,
    is_wsl: bool,
    name: []u8, // owned — becomes the preview title
    cmd: []u8, // owned — `cat <root>/'<name>'/'SKILL.md'`
    local_md_path: ?[]u8, // owned absolute SKILL.md path for a LOCAL target (native read)

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillPreviewJob = @ptrCast(@alignCast(ctx));
        // Local target on a non-POSIX host (Windows): read SKILL.md natively;
        // `cat` via localPosixExec is unavailable. Remote/posix/WSL use the shell
        // cmd (WSL via `wsl.exe`, see SkillLocExec).
        const content = if (job.conn == null and !job.is_wsl and !remote_file.localPosixExecSupported()) blk: {
            const p = job.local_md_path orelse return .failed;
            break :blk skill_local_fs.readFileAllocAbsolute(allocator, p, 1024 * 1024) catch return .failed;
        } else blk: {
            var le = SkillLocExec{ .conn = job.conn, .is_wsl = job.is_wsl };
            const host = le.host();
            break :blk host.exec(host.ctx, allocator, job.cmd) catch return .failed;
        };
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
        if (job.local_md_path) |p| allocator.free(p);
        allocator.destroy(job);
    }
};

/// Background op: parse the URL, resolve the default branch if absent, fetch the
/// Git Trees response, and enumerate skills for the checklist.
const SkillInstallEnumerateJob = struct {
    url: []u8, // owned

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillInstallEnumerateJob = @ptrCast(@alignCast(ctx));
        var repo = skill_install.parseGithubUrl(allocator, job.url) catch return .failed;
        // NB: `enumerate` is error-returning so `errdefer` fires on every failure
        // path below (the bare `return .failed` of the plan's code would leak
        // `repo` because a value-return does not trigger errdefer).
        return enumerate(allocator, &repo) catch {
            repo.deinit(allocator);
            return .failed;
        };
    }
    fn enumerate(allocator: std.mem.Allocator, repo: *skill_install.RepoRef) !skill_center.OpResult {
        // Resolve the ref if the URL had none.
        if (repo.ref == null) {
            repo.ref = resolveDefaultBranch(allocator, repo.owner, repo.repo) catch
                try allocator.dupe(u8, "main");
        }

        const api = try skill_install.treeApiUrl(allocator, repo.owner, repo.repo, repo.ref.?);
        defer allocator.free(api);
        const json = try update_install.httpGetAlloc(allocator, api, 8 * 1024 * 1024);
        defer allocator.free(json);

        const res = try skill_install.findSkills(allocator, json, repo.subpath);
        return .{ .install_enumerate = .{ .repo = repo.*, .entries = res.entries, .truncated = res.truncated } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillInstallEnumerateJob = @ptrCast(@alignCast(ctx));
        allocator.free(job.url);
        allocator.destroy(job);
    }
};

/// Background op: download + install the selected skills into the library.
const SkillInstallDownloadJob = struct {
    repo: skill_install.RepoRef, // owned
    entries: []skill_install.SkillEntry, // owned

    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) skill_center.OpResult {
        const job: *SkillInstallDownloadJob = @ptrCast(@alignCast(ctx));
        const r = downloadSelectedSkillsToLibrary(allocator, job.repo, job.entries);
        return .{ .install_done = .{ .installed = r.installed, .overwritten = r.overwritten, .failed = r.failed } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const job: *SkillInstallDownloadJob = @ptrCast(@alignCast(ctx));
        job.repo.deinit(allocator);
        skill_install.freeEntries(allocator, job.entries);
        allocator.destroy(job);
    }
};

/// Best-effort default-branch resolution. Tries the repo API's `default_branch`,
/// then falls back to "master" (the caller defaults to "main" on total failure).
fn resolveDefaultBranch(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8) ![]u8 {
    const api = try skill_install.repoApiUrl(allocator, owner, repo);
    defer allocator.free(api);
    const json = update_install.httpGetAlloc(allocator, api, 1024 * 1024) catch return allocator.dupe(u8, "master");
    defer allocator.free(json);
    return skill_install.parseDefaultBranch(allocator, json) catch allocator.dupe(u8, "master");
}

/// Kick off an async library scan for `session`. UI thread.
pub fn startScan(allocator: std.mem.Allocator, session: *skill_center.Session) void {
    const lib_dir = skillCenterLibraryDir(allocator) orelse {
        session.publishScanFailure(session.scan_generation);
        return;
    };
    defer allocator.free(lib_dir);
    const root_expr = skill_transfer_cmd.absRootExpr(allocator, lib_dir) catch {
        session.publishScanFailure(session.scan_generation);
        return;
    };
    const local_path = allocator.dupe(u8, lib_dir) catch {
        allocator.free(root_expr);
        session.publishScanFailure(session.scan_generation);
        return;
    };
    const tools_root = platform_dirs.toolsDir(allocator) catch {
        allocator.free(root_expr);
        allocator.free(local_path);
        session.publishScanFailure(session.scan_generation);
        return;
    };
    const job = allocator.create(SkillLibraryScanJob) catch {
        allocator.free(root_expr);
        allocator.free(local_path);
        allocator.free(tools_root);
        session.publishScanFailure(session.scan_generation);
        return;
    };
    job.* = .{ .root_expr = root_expr, .local_path = local_path, .tools_root = tools_root };
    session.scanAsync(.{ .ctx = job, .run = SkillLibraryScanJob.run, .destroy = SkillLibraryScanJob.destroy });
}
