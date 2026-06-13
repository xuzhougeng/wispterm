//! Skill Center v2 model: a local wispterm **library** of skills that the user
//! deploys to / imports from a **target = machine × software**. The library is
//! always local; the panel lists library skills and drives deploy/import through
//! a popup picker. Pure model + a concurrency-safe Session that runs the (local)
//! library scan off the UI thread. UI strings live in i18n; transfer/diff live in
//! sibling modules.
const std = @import("std");
const scan = @import("skill_scan.zig");
const install = @import("skill_install.zig");

/// Target software — a skills root under $HOME on the target machine. Both use
/// the same SKILL.md directory format, so a library skill deploys to either.
pub const Software = enum {
    claude,
    codex,
    pub fn rootRel(self: Software) []const u8 {
        return switch (self) {
            .claude => ".claude/skills",
            .codex => ".codex/skills",
        };
    }
};

/// A deploy/import destination: a machine × a software root.
pub const Target = struct {
    machine_id: []u8, // owned: "local" or "ssh:<profile>"
    machine_label: []u8, // owned display name
    software: Software,
    is_local: bool,

    pub fn dupe(
        allocator: std.mem.Allocator,
        machine_id: []const u8,
        machine_label: []const u8,
        software: Software,
        is_local: bool,
    ) !Target {
        const id = try allocator.dupe(u8, machine_id);
        errdefer allocator.free(id);
        const label = try allocator.dupe(u8, machine_label);
        return .{ .machine_id = id, .machine_label = label, .software = software, .is_local = is_local };
    }
    pub fn clone(self: Target, allocator: std.mem.Allocator) !Target {
        return dupe(allocator, self.machine_id, self.machine_label, self.software, self.is_local);
    }
    pub fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        allocator.free(self.machine_id);
        allocator.free(self.machine_label);
        self.* = undefined;
    }
};

/// One skill in the wispterm library (`<config>/skills/<name>/SKILL.md`).
pub const LibrarySkill = struct {
    name: []u8,
    rel_path: []u8, // relative to the library root, e.g. "<name>/SKILL.md"
    agg_hash: ?[]u8,
    pub fn deinit(self: *LibrarySkill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.rel_path);
        if (self.agg_hash) |h| allocator.free(h);
        self.* = undefined;
    }
};

pub fn freeLibrary(allocator: std.mem.Allocator, lib: []LibrarySkill) void {
    for (lib) |*s| s.deinit(allocator);
    allocator.free(lib);
}

/// Convert owned scan rows (from `skill_scan.scanLocation`) into a LibrarySkill
/// slice. Takes ownership of the rows' backing strings (moves them); frees the
/// rows slice itself. `provider` is ignored (v2 keys by name).
pub fn libraryFromRows(allocator: std.mem.Allocator, rows: []scan.SkillRow) ![]LibrarySkill {
    // Always consumes `rows`: on the alloc-failure path the strings haven't been
    // moved yet, so free them; on success the strings move into `out` and only
    // the rows slice is freed.
    const out = allocator.alloc(LibrarySkill, rows.len) catch |e| {
        scan.freeRows(allocator, rows);
        return e;
    };
    for (rows, 0..) |r, i| {
        out[i] = .{ .name = r.name, .rel_path = r.rel_path, .agg_hash = r.agg_hash };
    }
    allocator.free(rows); // strings moved into `out`
    return out;
}

pub const Decision = enum { direct, confirm, noop };

/// Decide what copying a skill onto a destination implies.
/// `target_present` false → `direct` (nothing to overwrite). Both hashes present
/// and equal → `noop`. Differing, or either hash unknown → `confirm`.
pub fn overwriteDecision(target_present: bool, target_hash: ?[]const u8, src_hash: ?[]const u8) Decision {
    if (!target_present) return .direct;
    const th = target_hash orelse return .confirm;
    const sh = src_hash orelse return .confirm;
    return if (std.mem.eql(u8, th, sh)) .noop else .confirm;
}

// --- Overlay state (interaction) ---

pub const Purpose = enum { deploy, import_ };
pub const Marker = enum { new_, same, differ };

/// Target picker: a flat list of "machine · software" entries to choose from.
pub const PickerState = struct {
    purpose: Purpose,
    skill_name: []u8, // library skill being deployed (deploy); "" for import
    labels: [][]u8, // owned entry labels
    targets: []Target, // parallel, owned
    sel: usize = 0,

    fn deinit(self: *PickerState, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_name);
        for (self.labels) |l| allocator.free(l);
        allocator.free(self.labels);
        for (self.targets) |*t| t.deinit(allocator);
        allocator.free(self.targets);
        self.* = undefined;
    }
};

/// Import list: the chosen target's skills, marked vs the library.
pub const ImportState = struct {
    target: Target, // owned
    names: [][]u8, // owned target skill names
    markers: []Marker, // parallel
    sel: usize = 0,

    fn deinit(self: *ImportState, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        for (self.names) |n| allocator.free(n);
        allocator.free(self.names);
        allocator.free(self.markers);
        self.* = undefined;
    }
};

/// Pending overwrite confirmation for a deploy/import that would clobber a
/// differing same-name skill.
pub const ConfirmState = struct {
    text: []u8, // owned display message
    is_import: bool,
    target: Target, // owned
    name: []u8, // owned skill name

    fn deinit(self: *ConfirmState, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.target.deinit(allocator);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const Overlay = union(enum) {
    none,
    picker: PickerState,
    import_list: ImportState,
    confirm: ConfirmState,
    busy: []u8, // owned message

    pub fn deinit(self: *Overlay, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .none => {},
            .picker => |*p| p.deinit(allocator),
            .import_list => |*i| i.deinit(allocator),
            .confirm => |*c| c.deinit(allocator),
            .busy => |m| allocator.free(m),
        }
        self.* = .none;
    }
};

/// Build a `cat '<path>'` command for an absolute path (the library skill's
/// SKILL.md). Single-quote-escaped.
pub fn catCommand(allocator: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "cat '");
    for (abs_path) |c| {
        if (c == '\'') try buf.appendSlice(allocator, "'\\''") else try buf.append(allocator, c);
    }
    try buf.append(allocator, '\'');
    return buf.toOwnedSlice(allocator);
}

/// Panel state: the library list, selection, and the active overlay.
pub const PanelModel = struct {
    allocator: std.mem.Allocator,
    library: ?[]LibrarySkill = null,
    sel_row: usize = 0,
    scroll: usize = 0,
    overlay: Overlay = .none,

    pub fn init(allocator: std.mem.Allocator) PanelModel {
        return .{ .allocator = allocator };
    }

    /// Take ownership of a fresh library list; clamp selection.
    pub fn setLibrary(self: *PanelModel, lib: []LibrarySkill) void {
        self.freeLibraryList();
        self.library = lib;
        self.clampSelection();
    }

    fn freeLibraryList(self: *PanelModel) void {
        if (self.library) |l| {
            freeLibrary(self.allocator, l);
            self.library = null;
        }
    }

    fn clampSelection(self: *PanelModel) void {
        const n = if (self.library) |l| l.len else 0;
        if (n == 0) {
            self.sel_row = 0;
        } else if (self.sel_row >= n) {
            self.sel_row = n - 1;
        }
    }

    /// Selected library skill, or null.
    pub fn selected(self: *const PanelModel) ?LibrarySkill {
        const lib = self.library orelse return null;
        if (self.sel_row >= lib.len) return null;
        return lib[self.sel_row];
    }

    /// Replace the overlay (frees the previous one's owned data).
    pub fn setOverlay(self: *PanelModel, ov: Overlay) void {
        self.overlay.deinit(self.allocator);
        self.overlay = ov;
    }
    pub fn clearOverlay(self: *PanelModel) void {
        self.overlay.deinit(self.allocator);
    }

    pub fn deinit(self: *PanelModel) void {
        self.overlay.deinit(self.allocator);
        self.freeLibraryList();
        self.* = undefined;
    }
};

/// Owned unit of background scan work — scans the (local) library off the UI
/// thread and returns an owned `[]LibrarySkill`. `destroy` frees `ctx`.
pub const ScanWork = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, std.mem.Allocator) anyerror![]LibrarySkill,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

/// Structured result of a background skill-center op, produced on the worker
/// thread and consumed on the UI thread. Owns its strings/rows; `deinit` frees
/// them. The UI thread builds overlays/toasts from this — the worker never
/// touches UI state.
pub const OpResult = union(enum) {
    /// import-scan finished: show the import list built from `rows`.
    import_scan: struct { target: Target, rows: []scan.SkillRow },
    /// deploy-scan finished: UI decides noop/direct/confirm from `rows`.
    deploy_scan: struct { target: Target, name: []u8, src_hash: ?[]u8, rows: []scan.SkillRow },
    /// transfer finished: show success/failure toast.
    transfer: struct { is_import: bool, ok: bool, err_summary: ?[]u8 },
    /// preview finished: show the fetched SKILL.md in the markdown preview panel.
    preview: struct { title: []u8, content: []u8 },
    /// install-enumerate finished: show the checklist built from `entries`.
    install_enumerate: struct { repo: install.RepoRef, entries: []install.SkillEntry, truncated: bool },
    /// install-download finished: report counts via toast.
    install_done: struct { installed: usize, overwritten: usize, failed: usize },
    /// generic failure before work could run (e.g. lost connection).
    failed,

    pub fn deinit(self: *OpResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .import_scan => |*v| {
                v.target.deinit(allocator);
                scan.freeRows(allocator, v.rows);
            },
            .deploy_scan => |*v| {
                v.target.deinit(allocator);
                allocator.free(v.name);
                if (v.src_hash) |h| allocator.free(h);
                scan.freeRows(allocator, v.rows);
            },
            .transfer => |*v| {
                if (v.err_summary) |s| allocator.free(s);
            },
            .preview => |*v| {
                allocator.free(v.title);
                allocator.free(v.content);
            },
            .install_enumerate => |*v| {
                v.repo.deinit(allocator);
                install.freeEntries(allocator, v.entries);
            },
            .install_done => {},
            .failed => {},
        }
        self.* = .failed;
    }
};

/// Turn a finished import scan into an `OpResult`. An unreachable source (offline,
/// auth failure, or a non-POSIX local host) becomes `.failed` so the UI shows a
/// connection error instead of an empty import list; a reachable source — even
/// with zero rows — yields `.import_scan` (a legitimately empty list). Takes
/// ownership of `outcome` (moves its rows into the result, or frees them on
/// failure) and of the already-cloned `target` (frees it on failure).
pub fn importScanResult(allocator: std.mem.Allocator, outcome: *scan.ScanOutcome, target: Target) OpResult {
    if (!outcome.reachable) {
        outcome.deinit(allocator);
        var t = target;
        t.deinit(allocator);
        return .failed;
    }
    const rows = outcome.rows;
    outcome.rows = &.{};
    return .{ .import_scan = .{ .target = target, .rows = rows } };
}

/// Owned unit of background op work. `run` returns an `OpResult` (never errors —
/// failures are encoded in the result). `destroy` frees `ctx`.
pub const OpWork = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, std.mem.Allocator) OpResult,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

/// Concurrency-safe holder for the panel. `mutex` guards `model` + `status`; the
/// worker runs I/O without the lock and takes it only to publish via
/// `finishScan`; `closing` + join-on-deinit give UAF safety.
pub const Session = struct {
    allocator: std.mem.Allocator,
    model: PanelModel,
    mutex: std.Thread.Mutex = .{},
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_generation: u64 = 0,
    scan_thread: ?std.Thread = null,
    op_thread: ?std.Thread = null,
    op_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    op_pending: ?OpResult = null,
    op_wake: ?*const fn () void = null,
    status: []u8 = &.{}, // owned "Scanning…"/"Failed"/""

    pub fn create(allocator: std.mem.Allocator) !*Session {
        const self = try allocator.create(Session);
        self.* = .{ .allocator = allocator, .model = PanelModel.init(allocator) };
        return self;
    }

    pub fn destroy(self: *Session) void {
        const allocator = self.allocator;
        self.closing.store(true, .release);
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        if (self.op_thread) |t| {
            t.join();
            self.op_thread = null;
        }
        if (self.op_pending) |*p| {
            p.deinit(allocator);
            self.op_pending = null;
        }
        self.model.deinit();
        if (self.status.len > 0) allocator.free(self.status);
        self.* = undefined;
        allocator.destroy(self);
    }

    fn setStatusLocked(self: *Session, text: []const u8) void {
        const next = self.allocator.dupe(u8, text) catch return;
        if (self.status.len > 0) self.allocator.free(self.status);
        self.status = next;
    }

    /// Start a background library scan. UI thread only.
    pub fn scanAsync(self: *Session, work: ScanWork) void {
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        self.mutex.lock();
        self.scan_generation +%= 1;
        const generation = self.scan_generation;
        self.setStatusLocked("Scanning…");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, scanThreadMain, .{ self, work, generation }) catch {
            self.mutex.lock();
            if (generation == self.scan_generation) self.setStatusLocked("Failed");
            self.mutex.unlock();
            work.destroy(work.ctx, self.allocator);
            return;
        };
        self.scan_thread = thread;
    }

    /// Publish a library scan result under the lock if current; else discard.
    /// Always consumes ownership of `lib`. Worker-thread only.
    pub fn finishScan(self: *Session, generation: u64, lib: []LibrarySkill) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.scan_generation) {
            self.model.setLibrary(lib);
            self.setStatusLocked("");
        } else {
            freeLibrary(self.allocator, lib);
        }
    }

    pub fn publishScanFailure(self: *Session, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.scan_generation) {
            self.setStatusLocked("Failed");
        }
    }

    /// Test-only: wait for an in-flight worker.
    pub fn joinForTest(self: *Session) void {
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
    }

    /// Start a background op. On ANY false return (busy, or spawn failure) the
    /// caller still owns `work` and is responsible for calling its destroy — we
    /// never destroy it here, so the caller's destroy is the single owner.
    /// Shows `busy_msg` as the visible panel status while the op runs.
    /// UI thread only.
    pub fn startOp(self: *Session, work: OpWork, wake: *const fn () void, busy_msg: []const u8) bool {
        if (self.op_thread != null and !self.op_done.load(.acquire)) {
            return false; // busy — never join-wait a possibly-slow op on the UI thread
        }
        if (self.op_thread) |t| {
            t.join(); // previous op already finished; non-blocking
            self.op_thread = null;
        }
        self.op_wake = wake;
        self.op_done.store(false, .release);

        self.mutex.lock();
        self.setStatusLocked(busy_msg); // visible "Syncing…" in the panel header
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, opThreadMain, .{ self, work }) catch {
            self.op_done.store(true, .release);
            self.mutex.lock();
            self.setStatusLocked(""); // the op never started; clear the busy status
            self.mutex.unlock();
            return false; // caller owns `work` and will destroy it (no double-free)
        };
        self.op_thread = thread;
        return true;
    }

    /// Take the published op result (if any), clearing it. UI thread only.
    pub fn takePendingOp(self: *Session) ?OpResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        const r = self.op_pending;
        self.op_pending = null;
        return r;
    }

    /// Test-only: wait for an in-flight op worker.
    pub fn joinOpForTest(self: *Session) void {
        if (self.op_thread) |t| {
            t.join();
            self.op_thread = null;
        }
    }
};

fn scanThreadMain(session: *Session, work: ScanWork, generation: u64) void {
    defer work.destroy(work.ctx, session.allocator);
    const lib = work.run(work.ctx, session.allocator) catch {
        session.publishScanFailure(generation);
        return;
    };
    session.finishScan(generation, lib);
}

fn opThreadMain(session: *Session, work: OpWork) void {
    defer work.destroy(work.ctx, session.allocator);
    var result = work.run(work.ctx, session.allocator);

    session.mutex.lock();
    const closing = session.closing.load(.acquire);
    if (closing) {
        session.mutex.unlock();
        result.deinit(session.allocator);
    } else {
        if (session.op_pending) |*p| p.deinit(session.allocator); // discard stale (shouldn't happen)
        session.op_pending = result;
        session.setStatusLocked(""); // op finished — clear the "Syncing…" status
        session.mutex.unlock();
    }
    // op_done stays unconditional so destroy/startOp see the thread as finished.
    session.op_done.store(true, .release);
    // Only wake when we actually published — waking during teardown is pointless
    // and risks the woken main loop touching a Session being destroyed.
    if (!closing) {
        if (session.op_wake) |w| w();
    }
}

// --- Tests ---

fn ownedLib(allocator: std.mem.Allocator, names: []const []const u8) ![]LibrarySkill {
    const out = try allocator.alloc(LibrarySkill, names.len);
    for (names, 0..) |n, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, n),
            .rel_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{n}),
            .agg_hash = try allocator.dupe(u8, "h"),
        };
    }
    return out;
}

test "skill_center: overwriteDecision" {
    try std.testing.expectEqual(Decision.direct, overwriteDecision(false, null, "h"));
    try std.testing.expectEqual(Decision.noop, overwriteDecision(true, "h", "h"));
    try std.testing.expectEqual(Decision.confirm, overwriteDecision(true, "h", "x"));
    try std.testing.expectEqual(Decision.confirm, overwriteDecision(true, null, "h"));
    try std.testing.expectEqual(Decision.confirm, overwriteDecision(true, "h", null));
}

test "skill_center: setLibrary clamps selection" {
    const a = std.testing.allocator;
    var m = PanelModel.init(a);
    defer m.deinit();
    m.setLibrary(try ownedLib(a, &.{ "x", "y", "z" }));
    m.sel_row = 2;
    try std.testing.expectEqual(@as(usize, 3), m.library.?.len);
    m.setLibrary(try ownedLib(a, &.{"x"})); // shrink → clamp
    try std.testing.expectEqual(@as(usize, 0), m.sel_row);
    try std.testing.expectEqualStrings("x", m.selected().?.name);
}

test "skill_center: overlay set/clear frees owned data (no leak)" {
    const a = std.testing.allocator;
    var m = PanelModel.init(a);
    defer m.deinit();

    // picker overlay with owned labels + targets
    var labels = try a.alloc([]u8, 2);
    labels[0] = try a.dupe(u8, "local · Claude Code");
    labels[1] = try a.dupe(u8, "web · Codex");
    var targets = try a.alloc(Target, 2);
    targets[0] = try Target.dupe(a, "local", "local", .claude, true);
    targets[1] = try Target.dupe(a, "ssh:web", "web", .codex, false);
    m.setOverlay(.{ .picker = .{ .purpose = .deploy, .skill_name = try a.dupe(u8, "pdf"), .labels = labels, .targets = targets } });
    try std.testing.expect(m.overlay == .picker);

    // replace with a confirm overlay → picker freed
    m.setOverlay(.{ .confirm = .{
        .text = try a.dupe(u8, "overwrite?"),
        .is_import = false,
        .target = try Target.dupe(a, "ssh:web", "web", .codex, false),
        .name = try a.dupe(u8, "pdf"),
    } });
    try std.testing.expect(m.overlay == .confirm);
    m.clearOverlay();
    try std.testing.expect(m.overlay == .none);
}

test "skill_center: libraryFromRows moves ownership" {
    const a = std.testing.allocator;
    const rows = try a.alloc(scan.SkillRow, 1);
    rows[0] = .{ .provider = .claude, .name = try a.dupe(u8, "pdf"), .rel_path = try a.dupe(u8, "pdf/SKILL.md"), .agg_hash = try a.dupe(u8, "h") };
    const lib = try libraryFromRows(a, rows);
    defer freeLibrary(a, lib);
    try std.testing.expectEqual(@as(usize, 1), lib.len);
    try std.testing.expectEqualStrings("pdf", lib[0].name);
    try std.testing.expectEqualStrings("h", lib[0].agg_hash.?);
}

test "skill_center: catCommand quotes an absolute path" {
    const a = std.testing.allocator;
    const cmd = try catCommand(a, "/cfg/skills/pdf/SKILL.md");
    defer a.free(cmd);
    try std.testing.expectEqualStrings("cat '/cfg/skills/pdf/SKILL.md'", cmd);
}

test "skill_center: Session.finishScan publishes then discards stale (no leak)" {
    const a = std.testing.allocator;
    const session = try Session.create(a);
    defer session.destroy();

    session.scan_generation +%= 1;
    session.finishScan(session.scan_generation, try ownedLib(a, &.{ "a", "b" }));
    try std.testing.expect(session.model.library != null);
    try std.testing.expectEqual(@as(usize, 2), session.model.library.?.len);

    session.scan_generation = 9;
    session.finishScan(3, try ownedLib(a, &.{"stale"})); // discarded + freed
    try std.testing.expectEqual(@as(usize, 2), session.model.library.?.len);
}

const OpTestCtx = struct {
    a: std.mem.Allocator,
    result_ok: bool,
    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) OpResult {
        const self: *OpTestCtx = @ptrCast(@alignCast(ctx));
        _ = allocator;
        return .{ .transfer = .{ .is_import = false, .ok = self.result_ok, .err_summary = null } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *OpTestCtx = @ptrCast(@alignCast(ctx));
        allocator.destroy(self);
    }
};

fn noopWake() void {}

test "startOp runs work and publishes a pending result" {
    const a = std.testing.allocator;
    const session = try Session.create(a);
    defer session.destroy();

    const ctx = try a.create(OpTestCtx);
    ctx.* = .{ .a = a, .result_ok = true };
    try std.testing.expect(session.startOp(.{ .ctx = ctx, .run = OpTestCtx.run, .destroy = OpTestCtx.destroy }, noopWake, "syncing"));
    session.joinOpForTest();

    var pending = session.takePendingOp() orelse return error.NoPending;
    defer pending.deinit(a);
    try std.testing.expect(pending == .transfer);
    try std.testing.expect(pending.transfer.ok);
    // consumed: a second take is empty
    try std.testing.expectEqual(@as(?OpResult, null), session.takePendingOp());
}

test "startOp rejects a second op while one is in flight" {
    const a = std.testing.allocator;
    const session = try Session.create(a);
    defer session.destroy();

    // Manually mark an op in flight without spawning real work, to test the guard.
    session.op_done.store(false, .release);
    session.op_thread = try std.Thread.spawn(.{}, struct {
        fn f() void {}
    }.f, .{});

    const ctx = try a.create(OpTestCtx);
    ctx.* = .{ .a = a, .result_ok = true };
    const accepted = session.startOp(.{ .ctx = ctx, .run = OpTestCtx.run, .destroy = OpTestCtx.destroy }, noopWake, "syncing");
    try std.testing.expect(!accepted); // busy → rejected
    // we own ctx since it was rejected; free it
    OpTestCtx.destroy(@ptrCast(ctx), a);
    // let the dummy thread be joinable at destroy
    session.op_done.store(true, .release);
}

test "importScanResult: unreachable source becomes failed (not an empty import list)" {
    const a = std.testing.allocator;
    var outcome = scan.ScanOutcome{ .reachable = false, .rows = &.{} };
    const tgt = try Target.dupe(a, "ssh:box", "box", .claude, false);
    var result = importScanResult(a, &outcome, tgt); // takes ownership of outcome + tgt
    defer result.deinit(a);
    try std.testing.expect(result == .failed);
}

test "importScanResult: reachable source carries its rows into import_scan" {
    const a = std.testing.allocator;
    const rows = try scan.parseLocationOutput(a, "pdf\tpdf/SKILL.md\tabc\n");
    var outcome = scan.ScanOutcome{ .reachable = true, .rows = rows };
    const tgt = try Target.dupe(a, "ssh:box", "box", .claude, false);
    var result = importScanResult(a, &outcome, tgt);
    defer result.deinit(a);
    try std.testing.expect(result == .import_scan);
    try std.testing.expectEqual(@as(usize, 1), result.import_scan.rows.len);
    try std.testing.expectEqualStrings("pdf", result.import_scan.rows[0].name);
}

test "importScanResult: reachable-but-empty source still opens an import list" {
    // Local targets are reachable=true even with zero skills — an empty scan must
    // open an (empty) import list, not be misread as a connection failure.
    const a = std.testing.allocator;
    var outcome = scan.ScanOutcome{ .reachable = true, .rows = &.{} };
    const tgt = try Target.dupe(a, "local", "Local", .claude, true);
    var result = importScanResult(a, &outcome, tgt);
    defer result.deinit(a);
    try std.testing.expect(result == .import_scan);
    try std.testing.expectEqual(@as(usize, 0), result.import_scan.rows.len);
}

test "OpResult.preview deinit frees title and content" {
    const a = std.testing.allocator;
    var r: OpResult = .{ .preview = .{
        .title = try a.dupe(u8, "roundtable"),
        .content = try a.dupe(u8, "# SKILL\nbody"),
    } };
    r.deinit(a); // must free both; testing allocator catches a leak
    try std.testing.expect(r == .failed); // deinit resets to .failed
}

test "skill_center: OpResult.install_enumerate deinit frees repo and entries" {
    const a = std.testing.allocator;
    var repo = try install.parseGithubUrl(a, "https://github.com/o/r/tree/main/skills");
    errdefer repo.deinit(a);
    var entries = try a.alloc(install.SkillEntry, 1);
    {
        var files = try a.alloc([]u8, 1);
        files[0] = try a.dupe(u8, "skills/foo/SKILL.md");
        entries[0] = .{ .name = try a.dupe(u8, "foo"), .root_path = try a.dupe(u8, "skills/foo"), .files = files };
    }
    var r: OpResult = .{ .install_enumerate = .{ .repo = repo, .entries = entries, .truncated = false } };
    r.deinit(a); // testing allocator catches a leak
    try std.testing.expect(r == .failed);
}

test "skill_center: OpResult.install_done deinit is a no-op" {
    const a = std.testing.allocator;
    var r: OpResult = .{ .install_done = .{ .installed = 3, .overwritten = 1, .failed = 0 } };
    r.deinit(a);
    try std.testing.expect(r == .failed);
}
