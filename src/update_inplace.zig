//! Uninterrupted in-place updates for the Windows portable install, after
//! magpie (github.com/yetone/magpie, internal/update + internal/gui/update.go):
//!
//!  1. When a check finds a newer release, its portable zip is downloaded in
//!     the background into `<install>/.update/`, checked against the
//!     release's published SHA-256 digest, and unpacked to
//!     `<install>/.update/<tag>/`. Every exe/dll in it must carry a valid
//!     Authenticode signature, and WispTerm's own must be signed by the same
//!     publisher as the running program.
//!  2. The titlebar then shows an Update pill. Clicking it (after a confirm)
//!     swaps the files in (update_stage.swapIn: running files are renamed
//!     aside, which Windows allows), starts the new program, and waits for it
//!     to say it is up. If it never does, the swap is rolled back and this
//!     program keeps running.
//!  3. Quitting with an update staged installs it, so the next launch is the
//!     new version with nothing interrupted.
//!  4. The next launch removes what was moved aside and the staging folder.
//!
//! Only installs that look like a signed portable release take part: the
//! running wispterm.exe is validly signed and `version.txt` sits beside it.
//! Anything else (a dev build, macOS, Linux) keeps the manual download flow.
const std = @import("std");
const builtin = @import("builtin");
const update_stage = @import("update_stage.zig");
const update_install = @import("update_install.zig");
const update_pill_state = @import("update_pill_state.zig");
const authenticode = @import("platform/authenticode.zig");
const platform_dirs = @import("platform/dirs.zig");

pub const main_exe_name = "wispterm.exe";
/// Set in the new program's environment: where to write "I started".
pub const started_env = "WISPTERM_UPDATE_STARTED";
/// Set in the new program's environment: the pid of the program it replaces.
pub const replaces_env = "WISPTERM_UPDATE_REPLACES";
/// How long the old program waits for the new one to say it started.
const start_wait_ms: u64 = 20_000;
/// How long the new program waits for the old one to exit, so ports and
/// single-owner files (agent control, port forwards) are free.
const predecessor_wait_ms: u32 = 20_000;

pub const Phase = enum {
    /// Nothing staged (or this install cannot update itself).
    idle,
    staging,
    /// Staged and verified; the pill is up.
    ready,
    restarting,
    /// The new program started; this one should quit.
    restarted,
};

/// Something the UI thread should act on, taken once.
pub const Outcome = enum {
    none,
    /// Staged and verified: repaint so the titlebar pill shows.
    ready,
    /// A manual check found the release that is already staged: point the
    /// user at the pill.
    already_ready,
    /// The new version is running: quit now.
    quit,
    stage_failed,
    /// The new version would not start; the old files are back.
    restart_failed,
};

pub const StageRequest = struct {
    tag: []const u8,
    asset_name: []const u8,
    asset_url: []const u8,
    asset_digest: []const u8,
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    phase: Phase = .idle,
    outcome: Outcome = .none,
    thread: ?std.Thread = null,
    wake: *const fn () void,

    /// Lazily detected: null until `supported` first runs.
    detected: ?bool = null,
    exe_path: []u8 = &.{},
    install_dir: []u8 = &.{},

    tag_buf: [32]u8 = undefined,
    tag_len: usize = 0,
    asset_name_buf: [128]u8 = undefined,
    asset_name_len: usize = 0,
    asset_url_buf: [512]u8 = undefined,
    asset_url_len: usize = 0,
    digest: [32]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, wake: *const fn () void) Controller {
        return .{ .allocator = allocator, .wake = wake };
    }

    pub fn deinit(self: *Controller) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.phase == .staging) {
                // A download can take minutes and cannot be interrupted:
                // quitting must not wait for it. The process is exiting, so
                // the worker is detached and keeps its buffers; the next
                // launch removes the partial download.
                if (self.thread) |t| t.detach();
                self.thread = null;
                return;
            }
        }
        self.joinThread();
        if (self.exe_path.len > 0) self.allocator.free(self.exe_path);
        if (self.install_dir.len > 0) self.allocator.free(self.install_dir);
        self.* = undefined;
    }

    fn joinThread(self: *Controller) void {
        const t = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const t = self.thread;
            self.thread = null;
            break :blk t;
        };
        if (t) |thread| thread.join();
    }

    /// Whether this install can replace itself. The first call checks the
    /// running program's signature, so call it off the hot path.
    pub fn supported(self: *Controller) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.detected) |d| return d;
        const ok = self.detectLocked() catch false;
        self.detected = ok;
        return ok;
    }

    fn detectLocked(self: *Controller) !bool {
        if (builtin.os.tag != .windows) return false;
        const exe = try std.fs.selfExePathAlloc(self.allocator);
        var keep = false;
        defer if (!keep) self.allocator.free(exe);
        if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(exe), main_exe_name)) return false;
        const dir_path = std.fs.path.dirname(exe) orelse return false;

        var install = try std.fs.openDirAbsolute(dir_path, .{});
        defer install.close();
        install.access("version.txt", .{}) catch return false;
        var subject_buf: [authenticode.subject_buffer_len]u8 = undefined;
        if (authenticode.signerSubject(exe, &subject_buf) == null) return false;
        // Not ours to write (Program Files): the manual flow applies.
        install.makePath(update_stage.staging_dir_name) catch return false;

        self.install_dir = try self.allocator.dupe(u8, dir_path);
        self.exe_path = exe;
        keep = true;
        return true;
    }

    pub fn currentPhase(self: *Controller) Phase {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.phase;
    }

    /// Hand `req` to the in-place updater: download and verify it in the
    /// background, unless that release is already staged or an update is
    /// already under way. True when the updater has it (the caller must not
    /// fall back to the Downloads flow); false when this install cannot
    /// update itself or the request is unusable (no digest).
    pub fn startStaging(self: *Controller, req: StageRequest) bool {
        if (!self.supported()) return false;
        const digest = update_stage.parseSha256Digest(req.asset_digest) orelse return false;
        if (!update_stage.isSafeTag(req.tag)) return false;
        if (std.mem.indexOfAny(u8, req.asset_name, "/\\:") != null) return false;
        if (req.tag.len > self.tag_buf.len or req.asset_name.len > self.asset_name_buf.len or
            req.asset_url.len > self.asset_url_buf.len) return false;

        self.joinFinishedThread();
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (self.phase) {
            .staging, .restarting, .restarted => return true,
            .ready => if (std.mem.eql(u8, self.tag_buf[0..self.tag_len], req.tag)) return true,
            .idle => {},
        }
        if (self.thread != null) return true;
        @memcpy(self.tag_buf[0..req.tag.len], req.tag);
        self.tag_len = req.tag.len;
        @memcpy(self.asset_name_buf[0..req.asset_name.len], req.asset_name);
        self.asset_name_len = req.asset_name.len;
        @memcpy(self.asset_url_buf[0..req.asset_url.len], req.asset_url);
        self.asset_url_len = req.asset_url.len;
        self.digest = digest;
        self.phase = .staging;
        update_pill_state.setReady(false);
        self.thread = std.Thread.spawn(.{}, stageThreadMain, .{self}) catch {
            self.phase = .idle;
            return false;
        };
        return true;
    }

    fn joinFinishedThread(self: *Controller) void {
        const t = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.phase == .staging or self.phase == .restarting) return;
            const t = self.thread;
            self.thread = null;
            break :blk t;
        };
        if (t) |thread| thread.join();
    }

    /// A manual check: when a release is already staged, say so (once).
    pub fn noteManualCheck(self: *Controller) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.phase == .ready) self.outcome = .already_ready;
    }

    /// Copy the staged release's tag into `buf` while the pill is up.
    pub fn readyVersion(self: *Controller, buf: []u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.phase != .ready or self.tag_len > buf.len) return null;
        @memcpy(buf[0..self.tag_len], self.tag_buf[0..self.tag_len]);
        return buf[0..self.tag_len];
    }

    /// Take what the UI thread should do next (once).
    pub fn takeOutcome(self: *Controller) Outcome {
        self.mutex.lock();
        defer self.mutex.unlock();
        const o = self.outcome;
        self.outcome = .none;
        return o;
    }

    /// Swap the staged release in and restart into it, in the background.
    /// The UI learns the result through `takeOutcome`: `.quit` once the new
    /// program is up, `.restart_failed` when it was rolled back.
    pub fn startRestart(self: *Controller) bool {
        self.joinFinishedThread();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.phase != .ready or self.thread != null) return false;
        self.phase = .restarting;
        update_pill_state.setReady(false);
        self.thread = std.Thread.spawn(.{}, restartThreadMain, .{self}) catch {
            self.phase = .ready;
            update_pill_state.setReady(true);
            return false;
        };
        return true;
    }

    /// Called as the app quits: install a staged update so the next launch
    /// is the new version. Nothing waits to roll back here, so the swap runs
    /// only when fully staged and verified.
    pub fn installOnExit(self: *Controller) void {
        if (self.currentPhase() != .ready) return;
        self.joinThread();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.phase != .ready) return;
        var journal = self.swapLocked() catch |err| {
            std.debug.print("Update: install on exit failed: {}\n", .{err});
            return;
        };
        journal.deinit();
        self.phase = .idle;
        std.debug.print("Update: installed {s}; the next launch runs it\n", .{self.tag_buf[0..self.tag_len]});
    }

    fn stageThreadMain(self: *Controller) void {
        const ok = if (self.stage()) true else |err| blk: {
            std.debug.print("Update: staging failed: {}\n", .{err});
            break :blk false;
        };
        self.mutex.lock();
        if (ok) {
            self.phase = .ready;
            self.outcome = .ready;
        } else {
            self.phase = .idle;
            self.outcome = .stage_failed;
        }
        self.mutex.unlock();
        update_pill_state.setReady(ok);
        self.wake();
    }

    /// Download, checksum, unpack, verify signatures. Runs on the worker; the
    /// request fields are only written while phase is not .staging.
    fn stage(self: *Controller) !void {
        const tag = self.tag_buf[0..self.tag_len];
        const asset_name = self.asset_name_buf[0..self.asset_name_len];
        const url = self.asset_url_buf[0..self.asset_url_len];

        var install = try std.fs.openDirAbsolute(self.install_dir, .{});
        defer install.close();
        try install.makePath(update_stage.staging_dir_name);
        var staging = try install.openDir(update_stage.staging_dir_name, .{ .iterate = true });
        defer staging.close();

        // A release staged earlier and never installed is replaced.
        staging.deleteTree(tag) catch {};
        staging.deleteFile(asset_name) catch {};

        const zip_path = try std.fs.path.join(self.allocator, &.{ self.install_dir, update_stage.staging_dir_name, asset_name });
        defer self.allocator.free(zip_path);
        try update_install.downloadAsset(self.allocator, url, zip_path);
        defer staging.deleteFile(asset_name) catch {};
        try update_stage.verifySha256(staging, asset_name, self.digest);

        try staging.makePath(tag);
        var staged = try staging.openDir(tag, .{ .iterate = true });
        defer staged.close();
        errdefer staging.deleteTree(tag) catch {};
        try update_stage.extractZip(staging, asset_name, staged);
        staged.access(main_exe_name, .{}) catch return error.UpdateMissingProgram;

        try self.verifySignatures(staged, tag);
    }

    /// Every exe/dll in the release must be validly signed; WispTerm's own
    /// (named wispterm*) by the publisher of the running program. Bundled
    /// Microsoft binaries (conpty.dll, OpenConsole.exe, WebView2Loader.dll)
    /// keep Microsoft's signature.
    fn verifySignatures(self: *Controller, staged: std.fs.Dir, tag: []const u8) !void {
        const files = try update_stage.listStagedFiles(self.allocator, staged, main_exe_name);
        defer update_stage.freePaths(self.allocator, files);
        for (files) |rel| {
            if (!isPortableExecutable(rel)) continue;
            const abs = try std.fs.path.join(self.allocator, &.{ self.install_dir, update_stage.staging_dir_name, tag, rel });
            defer self.allocator.free(abs);
            if (isOwnBinary(rel)) {
                try authenticode.requireSameSigner(self.exe_path, abs);
            } else {
                var buf: [authenticode.subject_buffer_len]u8 = undefined;
                if (authenticode.signerSubject(abs, &buf) == null) return error.UpdateUnsigned;
            }
        }
    }

    fn swapLocked(self: *Controller) !update_stage.Journal {
        var install = try std.fs.openDirAbsolute(self.install_dir, .{ .iterate = true });
        defer install.close();
        const staged_rel = try std.fs.path.join(self.allocator, &.{ update_stage.staging_dir_name, self.tag_buf[0..self.tag_len] });
        defer self.allocator.free(staged_rel);
        var staged = try install.openDir(staged_rel, .{ .iterate = true });
        defer staged.close();
        return update_stage.swapIn(self.allocator, staged, install, main_exe_name);
    }

    fn restartThreadMain(self: *Controller) void {
        const ok = if (self.restart()) true else |err| blk: {
            std.debug.print("Update: restart failed: {}\n", .{err});
            break :blk false;
        };
        self.mutex.lock();
        if (ok) {
            self.phase = .restarted;
            self.outcome = .quit;
        } else {
            // The staged files were consumed by the swap and rolled back;
            // the next check stages the release again.
            self.phase = .idle;
            self.outcome = .restart_failed;
        }
        self.mutex.unlock();
        self.wake();
    }

    fn restart(self: *Controller) !void {
        var journal = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk try self.swapLocked();
        };
        defer journal.deinit();
        errdefer {
            var install = std.fs.openDirAbsolute(self.install_dir, .{}) catch null;
            if (install) |*dir| {
                journal.rollback(dir.*) catch |err| std.debug.print("Update: rollback incomplete: {}\n", .{err});
                dir.close();
            }
        }
        try launchAndAwait(self.allocator, self.exe_path);
    }
};

fn isPortableExecutable(rel: []const u8) bool {
    const ext = std.fs.path.extension(rel);
    return std.ascii.eqlIgnoreCase(ext, ".exe") or std.ascii.eqlIgnoreCase(ext, ".dll");
}

fn isOwnBinary(rel: []const u8) bool {
    const base = std.fs.path.basename(rel);
    return base.len >= "wispterm".len and std.ascii.eqlIgnoreCase(base[0.."wispterm".len], "wispterm");
}

/// Start `exe` (the new version, now in place) and wait until it writes the
/// started marker. Error when it exits first or stays silent too long; it is
/// then ended, and the caller rolls back.
fn launchAndAwait(allocator: std.mem.Allocator, exe: []const u8) !void {
    const pid = currentPid();
    var marker_buf: [std.fs.max_path_bytes]u8 = undefined;
    const marker = try markerPath(allocator, &marker_buf, pid);
    std.fs.deleteFileAbsolute(marker) catch {};
    defer std.fs.deleteFileAbsolute(marker) catch {};

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put(started_env, marker);
    var pid_buf: [16]u8 = undefined;
    try env.put(replaces_env, try std.fmt.bufPrint(&pid_buf, "{d}", .{pid}));

    const cwd = std.fs.path.dirname(exe);
    var child = std.process.Child.init(&.{exe}, allocator);
    child.env_map = &env;
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var waited: u64 = 0;
    while (waited < start_wait_ms) : (waited += 50) {
        if (std.fs.accessAbsolute(marker, .{})) |_| return else |_| {}
        if (childExited(&child)) {
            if (std.fs.accessAbsolute(marker, .{})) |_| return else |_| {}
            return error.NewVersionExited;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    _ = child.kill() catch {};
    return error.NewVersionSilent;
}

fn markerPath(allocator: std.mem.Allocator, buf: []u8, pid: u32) ![]const u8 {
    const tmp = try platform_dirs.tempDir(allocator);
    defer allocator.free(tmp);
    var name_buf: [48]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "wispterm-update-started-{d}", .{pid});
    const joined = try std.fs.path.join(allocator, &.{ tmp, name });
    defer allocator.free(joined);
    if (joined.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..joined.len], joined);
    return buf[0..joined.len];
}

fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

fn childExited(child: *std.process.Child) bool {
    if (builtin.os.tag != .windows) return false;
    const WAIT_OBJECT_0: u32 = 0;
    return std.os.windows.kernel32.WaitForSingleObject(child.id, 0) == WAIT_OBJECT_0;
}

/// Startup half of the relaunch, called early in main on every launch:
/// tell the program that started us that we are up, wait for it to exit,
/// and clean up after the last update.
pub fn onStartup(allocator: std.mem.Allocator) void {
    if (builtin.os.tag != .windows) return;
    reportStarted(allocator);
    awaitPredecessor(allocator);
    cleanupInstall(allocator);
}

fn reportStarted(allocator: std.mem.Allocator) void {
    const marker = std.process.getEnvVarOwned(allocator, started_env) catch return;
    defer allocator.free(marker);
    clearEnv(started_env);
    if (!std.fs.path.isAbsolute(marker)) return;
    var f = std.fs.createFileAbsolute(marker, .{}) catch return;
    defer f.close();
    var buf: [16]u8 = undefined;
    f.writeAll(std.fmt.bufPrint(&buf, "{d}", .{currentPid()}) catch return) catch {};
}

fn awaitPredecessor(allocator: std.mem.Allocator) void {
    const value = std.process.getEnvVarOwned(allocator, replaces_env) catch return;
    defer allocator.free(value);
    clearEnv(replaces_env);
    const pid = std.fmt.parseInt(u32, value, 10) catch return;
    if (pid == 0) return;
    const win = struct {
        const SYNCHRONIZE: u32 = 0x00100000;
        extern "kernel32" fn OpenProcess(access: u32, inherit: std.os.windows.BOOL, pid: u32) callconv(.winapi) ?std.os.windows.HANDLE;
    };
    const handle = win.OpenProcess(win.SYNCHRONIZE, std.os.windows.FALSE, pid) orelse return;
    defer std.os.windows.CloseHandle(handle);
    _ = std.os.windows.kernel32.WaitForSingleObject(handle, predecessor_wait_ms);
}

/// Keep the markers out of the environment our shells inherit.
fn clearEnv(comptime name: []const u8) void {
    if (builtin.os.tag != .windows) return;
    const wide = std.unicode.utf8ToUtf16LeStringLiteral(name);
    _ = std.os.windows.kernel32.SetEnvironmentVariableW(wide, null);
}

/// Remove what the last update moved aside and the staging folder. Only when
/// a staging folder exists, so ordinary launches do not walk the install.
fn cleanupInstall(allocator: std.mem.Allocator) void {
    const exe = std.fs.selfExePathAlloc(allocator) catch return;
    defer allocator.free(exe);
    const dir_path = std.fs.path.dirname(exe) orelse return;
    var install = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer install.close();
    install.access(update_stage.staging_dir_name, .{}) catch return;
    update_stage.removeAsideFiles(allocator, install);
    update_stage.removeStaging(install);
}

test "update_inplace: own binaries and portable executables" {
    try std.testing.expect(isOwnBinary("wispterm.exe"));
    try std.testing.expect(isOwnBinary("WispTerm-ssh-askpass.exe"));
    try std.testing.expect(isOwnBinary("shell-integration/1.45.0/wispterm-shell-extension.dll"));
    try std.testing.expect(!isOwnBinary("conpty.dll"));
    try std.testing.expect(isPortableExecutable("OpenConsole.exe"));
    try std.testing.expect(isPortableExecutable("x/WebView2Loader.DLL"));
    try std.testing.expect(!isPortableExecutable("version.txt"));
}

fn noWake() void {}

test "update_inplace: unsupported installs refuse to stage" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var c = Controller.init(std.testing.allocator, noWake);
    defer c.deinit();
    try std.testing.expect(!c.supported());
    try std.testing.expect(!c.startStaging(.{
        .tag = "v9.9.9",
        .asset_name = "wispterm-windows-portable-v9.9.9.zip",
        .asset_url = "https://example.test/x.zip",
        .asset_digest = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    }));
    try std.testing.expectEqual(Phase.idle, c.currentPhase());
    try std.testing.expectEqual(Outcome.none, c.takeOutcome());
}
