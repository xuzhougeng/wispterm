//! Runtime store + persistence for /loop and /watch tasks. Thin glue over the
//! pure engine (ai_loop_schedule.zig). Owns the in-memory task list, the
//! `loop_tasks.json` file, and the per-frame `tick` that fires due tasks through
//! a wired injector callback. All mutation happens on the UI thread (slash-command
//! handling + tick), guarded by a mutex for defensive safety.
const std = @import("std");
const engine = @import("ai_loop_schedule.zig");
const platform_atomic_file = @import("platform/atomic_file.zig");
const ai_history_time = @import("ai_history/time.zig");

pub const Task = engine.Task;
pub const TaskKind = engine.TaskKind;
pub const ParseError = engine.ParseError;

/// Result the injector reports back so the store knows whether to advance.
pub const InjectOutcome = enum { sent, busy, closed };

/// Resolves a session by id and injects the prompt. Set by the app layer.
pub const Injector = *const fn (session_id: []const u8, prompt: []const u8) InjectOutcome;

/// Session context captured at registration (for binding + list display).
pub const SessionCtx = struct {
    session_id: []const u8,
    model: []const u8 = "",
    title: []const u8 = "",
};

/// Returned to the chat layer to format a confirmation message.
pub const RegisterInfo = struct {
    id: u32,
    kind: TaskKind,
    interval_ms: i64 = 0,
    remaining: u32 = 0,
    daily: bool = false,
    next_fire_ms: i64,
};

/// A read-only copy of a task for listing (owned by the caller's allocator).
pub const TaskView = struct {
    id: u32,
    kind: TaskKind,
    interval_ms: i64,
    remaining: u32,
    daily: bool,
    tod_minutes: i32,
    next_fire_ms: i64,
    session_id: []u8,
    model: []u8,
    title: []u8,
    prompt: []u8,
};

pub fn freeSnapshot(allocator: std.mem.Allocator, views: []TaskView) void {
    freeSnapshotItems(allocator, views);
    allocator.free(views);
}

fn freeSnapshotItems(allocator: std.mem.Allocator, views: []TaskView) void {
    for (views) |v| {
        allocator.free(v.session_id);
        allocator.free(v.model);
        allocator.free(v.title);
        allocator.free(v.prompt);
    }
}

// ---- Module-level globals ----

var g_injector: ?Injector = null;
var g_store: ?*Store = null;

/// Wire the app-layer injector (resolve session by id + inject). Call once at startup.
pub fn setInjector(inj: Injector) void {
    g_injector = inj;
}

/// Register the process-wide store instance the app ticks/queries.
pub fn setActive(store: *Store) void {
    g_store = store;
}

/// Unregister the store (call before deinit to prevent dangling pointer).
pub fn clearActive() void {
    g_store = null;
}

pub fn active() ?*Store {
    return g_store;
}

/// Called once per UI frame from the app layer (UI thread, where tab.g_tabs is
/// populated). No-op until both a store and an injector are wired.
pub fn tick(now_ms: i64) void {
    const store = g_store orelse return;
    const inj = g_injector orelse return;
    const offset_s = ai_history_time.localOffsetSeconds();
    store.tickWith(now_ms, offset_s, inj);
}

// ---- Store ----

pub const Store = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    tasks: std.ArrayListUnmanaged(Task) = .empty,
    next_id: u32 = 1,
    path: []const u8, // owned
    last_scan_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Store {
        var store = Store{
            .allocator = allocator,
            .path = allocator.dupe(u8, path) catch path,
        };
        store.load();
        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.tasks.items) |*t| self.freeTask(t);
        self.tasks.deinit(self.allocator);
        self.allocator.free(self.path);
    }

    fn freeTask(self: *Store, t: *Task) void {
        self.allocator.free(t.session_id);
        self.allocator.free(t.model);
        self.allocator.free(t.title);
        self.allocator.free(t.prompt);
    }

    /// Append a task, duping all string fields and assigning the next id.
    fn appendOwned(self: *Store, src: Task) !u32 {
        var t = src;
        t.session_id = try self.allocator.dupe(u8, src.session_id);
        errdefer self.allocator.free(t.session_id);
        t.model = try self.allocator.dupe(u8, src.model);
        errdefer self.allocator.free(t.model);
        t.title = try self.allocator.dupe(u8, src.title);
        errdefer self.allocator.free(t.title);
        t.prompt = try self.allocator.dupe(u8, src.prompt);
        errdefer self.allocator.free(t.prompt);
        t.id = self.next_id;
        self.next_id += 1;
        try self.tasks.append(self.allocator, t);
        return t.id;
    }

    pub fn registerLoop(self: *Store, arg: []const u8, ctx: SessionCtx, now_ms: i64, offset_s: i32) (ParseError || error{OutOfMemory})!RegisterInfo {
        _ = offset_s; // unused for loop (no time-of-day math needed)
        const p = try engine.parseLoopArgs(arg);
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = try self.appendOwned(.{
            .kind = .loop,
            .session_id = ctx.session_id,
            .model = ctx.model,
            .title = ctx.title,
            .prompt = p.prompt,
            .interval_ms = p.interval_ms,
            .remaining = p.count,
            .next_fire_ms = now_ms + p.interval_ms,
            .created_ms = now_ms,
        });
        self.saveLocked();
        return .{ .id = id, .kind = .loop, .interval_ms = p.interval_ms, .remaining = p.count, .next_fire_ms = now_ms + p.interval_ms };
    }

    pub fn registerWatch(self: *Store, arg: []const u8, ctx: SessionCtx, now_ms: i64, offset_s: i32) (ParseError || error{OutOfMemory})!RegisterInfo {
        const p = try engine.parseWatchArgs(arg, now_ms, offset_s);
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = try self.appendOwned(.{
            .kind = .watch,
            .session_id = ctx.session_id,
            .model = ctx.model,
            .title = ctx.title,
            .prompt = p.prompt,
            .daily = p.daily,
            .tod_minutes = p.tod_minutes,
            .remaining = if (p.daily) 0 else 1,
            .next_fire_ms = p.next_fire_ms,
            .created_ms = now_ms,
        });
        self.saveLocked();
        return .{ .id = id, .kind = .watch, .daily = p.daily, .next_fire_ms = p.next_fire_ms };
    }

    pub fn snapshotForSession(self: *Store, allocator: std.mem.Allocator, session_id: []const u8, kind: TaskKind) ![]TaskView {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out: std.ArrayListUnmanaged(TaskView) = .empty;
        errdefer {
            freeSnapshotItems(allocator, out.items);
            out.deinit(allocator);
        }
        for (self.tasks.items) |t| {
            if (t.kind != kind) continue;
            if (!std.mem.eql(u8, t.session_id, session_id)) continue;
            try appendTaskView(allocator, &out, t);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn snapshotAll(self: *Store, allocator: std.mem.Allocator, kind: TaskKind) ![]TaskView {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out: std.ArrayListUnmanaged(TaskView) = .empty;
        errdefer {
            freeSnapshotItems(allocator, out.items);
            out.deinit(allocator);
        }
        for (self.tasks.items) |t| {
            if (t.kind != kind) continue;
            try appendTaskView(allocator, &out, t);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Remove one task by id within a session. Returns true if removed.
    pub fn stop(self: *Store, session_id: []const u8, id: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.tasks.items.len) : (i += 1) {
            const t = self.tasks.items[i];
            if (t.id == id and std.mem.eql(u8, t.session_id, session_id)) {
                var removed = self.tasks.orderedRemove(i);
                self.freeTask(&removed);
                self.saveLocked();
                return true;
            }
        }
        return false;
    }

    pub fn stopById(self: *Store, id: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.tasks.items.len) : (i += 1) {
            const t = self.tasks.items[i];
            if (t.id == id) {
                var removed = self.tasks.orderedRemove(i);
                self.freeTask(&removed);
                self.saveLocked();
                return true;
            }
        }
        return false;
    }

    /// Remove all tasks of `kind` in a session. Returns the count removed.
    pub fn stopAll(self: *Store, session_id: []const u8, kind: TaskKind) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var removed: u32 = 0;
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            const t = self.tasks.items[i];
            if (t.kind == kind and std.mem.eql(u8, t.session_id, session_id)) {
                var r = self.tasks.orderedRemove(i);
                self.freeTask(&r);
                removed += 1;
            } else i += 1;
        }
        if (removed > 0) self.saveLocked();
        return removed;
    }

    /// Testable core of the per-frame tick. Throttled to once per second.
    pub fn tickWith(self: *Store, now_ms: i64, offset_s: i32, inj: Injector) void {
        if (now_ms - self.last_scan_ms < std.time.ms_per_s) return;
        self.last_scan_ms = now_ms;

        self.mutex.lock();
        defer self.mutex.unlock();
        var changed = false;
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            const t = &self.tasks.items[i];
            if (!engine.isDue(t, now_ms)) {
                i += 1;
                continue;
            }
            switch (inj(t.session_id, t.prompt)) {
                .sent => {
                    engine.advanceAfterFire(t, now_ms, offset_s);
                    changed = true;
                    if (engine.isFinished(t)) {
                        var removed = self.tasks.orderedRemove(i);
                        self.freeTask(&removed);
                        continue; // don't advance i; next task shifted into place
                    }
                },
                .busy, .closed => {
                    // Leave unchanged: stays due, retried on a later tick (no
                    // decrement, no next_fire advance). A daily/one-shot bound to a
                    // closed session fires the instant that session is reopened.
                },
            }
            i += 1;
        }
        if (changed) self.saveLocked();
    }

    // ---- persistence ----

    fn load(self: *Store) void {
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, self.path, 8 * 1024 * 1024) catch return;
        defer self.allocator.free(bytes);
        var parsed = engine.decodeAlloc(self.allocator, bytes) catch return;
        defer parsed.deinit();
        const offset_s = ai_history_time.localOffsetSeconds();
        const now_ms = std.time.milliTimestamp();
        self.next_id = parsed.value.next_id;
        for (parsed.value.tasks) |src| {
            var copy = src;
            engine.recomputeAfterRestart(&copy, now_ms, offset_s);
            if (engine.isFinished(&copy)) continue;
            _ = self.appendOwnedKeepingId(copy) catch {};
        }
    }

    fn appendOwnedKeepingId(self: *Store, src: Task) !void {
        var t = src;
        t.session_id = try self.allocator.dupe(u8, src.session_id);
        errdefer self.allocator.free(t.session_id);
        t.model = try self.allocator.dupe(u8, src.model);
        errdefer self.allocator.free(t.model);
        t.title = try self.allocator.dupe(u8, src.title);
        errdefer self.allocator.free(t.title);
        t.prompt = try self.allocator.dupe(u8, src.prompt);
        errdefer self.allocator.free(t.prompt);
        try self.tasks.append(self.allocator, t); // keeps src.id
        if (t.id >= self.next_id) self.next_id = t.id + 1;
    }

    fn saveLocked(self: *Store) void {
        const model = engine.FileModel{ .version = 1, .next_id = self.next_id, .tasks = self.tasks.items };
        const bytes = engine.encode(self.allocator, model) catch return;
        defer self.allocator.free(bytes);
        platform_atomic_file.writeFileReplaceSafe(self.path, bytes) catch return;
    }
};

fn appendTaskView(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(TaskView), t: Task) !void {
    var view = TaskView{
        .id = t.id,
        .kind = t.kind,
        .interval_ms = t.interval_ms,
        .remaining = t.remaining,
        .daily = t.daily,
        .tod_minutes = t.tod_minutes,
        .next_fire_ms = t.next_fire_ms,
        .session_id = try allocator.dupe(u8, t.session_id),
        .model = undefined,
        .title = undefined,
        .prompt = undefined,
    };
    errdefer allocator.free(view.session_id);
    view.model = try allocator.dupe(u8, t.model);
    errdefer allocator.free(view.model);
    view.title = try allocator.dupe(u8, t.title);
    errdefer allocator.free(view.title);
    view.prompt = try allocator.dupe(u8, t.prompt);
    errdefer allocator.free(view.prompt);
    try out.append(allocator, view);
}

// ---- Tests ----

test "register loop, snapshot, stop, persist round-trip" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);

    var store = Store.init(a, path);
    defer store.deinit();

    const info = try store.registerLoop("30m 3 hello", .{ .session_id = "session-7", .model = "glm", .title = "t" }, 1000, 0);
    try std.testing.expectEqual(@as(u32, 1), info.id);
    try std.testing.expectEqual(@as(u32, 3), info.remaining);
    try std.testing.expectEqual(@as(i64, 1000 + 30 * std.time.ms_per_min), info.next_fire_ms);

    const snap = try store.snapshotForSession(a, "session-7", .loop);
    defer freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("hello", snap[0].prompt);

    // Reload from disk into a second store sees the persisted task.
    var store2 = Store.init(a, path);
    defer store2.deinit();
    const snap2 = try store2.snapshotForSession(a, "session-7", .loop);
    defer freeSnapshot(a, snap2);
    try std.testing.expectEqual(@as(usize, 1), snap2.len);

    try std.testing.expect(store2.stop("session-7", 1));
    const snap3 = try store2.snapshotForSession(a, "session-7", .loop);
    defer freeSnapshot(a, snap3);
    try std.testing.expectEqual(@as(usize, 0), snap3.len);
}

test "snapshotAll and stopById support global copilot task management" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);

    var store = Store.init(a, path);
    defer store.deinit();

    const first = try store.registerLoop("30m 3 check ci", .{ .session_id = "old-copilot", .model = "m1", .title = "Old Copilot" }, 1000, 0);
    const second = try store.registerLoop("1h 2 report", .{ .session_id = "other-chat", .model = "m2", .title = "Other Chat" }, 1000, 0);
    const watch = try store.registerWatch("09:00 daily report", .{ .session_id = "old-copilot", .model = "m1", .title = "Old Copilot" }, 1000, 0);

    const all_loops = try store.snapshotAll(a, .loop);
    defer freeSnapshot(a, all_loops);
    try std.testing.expectEqual(@as(usize, 2), all_loops.len);
    try std.testing.expectEqual(first.id, all_loops[0].id);
    try std.testing.expectEqualStrings("old-copilot", all_loops[0].session_id);
    try std.testing.expectEqualStrings("Old Copilot", all_loops[0].title);
    try std.testing.expectEqualStrings("check ci", all_loops[0].prompt);
    try std.testing.expectEqual(second.id, all_loops[1].id);

    try std.testing.expect(store.stopById(first.id));

    const old_loops = try store.snapshotForSession(a, "old-copilot", .loop);
    defer freeSnapshot(a, old_loops);
    try std.testing.expectEqual(@as(usize, 0), old_loops.len);

    const old_watches = try store.snapshotForSession(a, "old-copilot", .watch);
    defer freeSnapshot(a, old_watches);
    try std.testing.expectEqual(@as(usize, 1), old_watches.len);
    try std.testing.expectEqual(watch.id, old_watches[0].id);
}

// Test injector that records calls and returns a scripted outcome.
const TestInjector = struct {
    var outcome: InjectOutcome = .sent;
    var calls: u32 = 0;
    var last_prompt_buf: [256]u8 = undefined;
    var last_prompt_len: usize = 0;
    fn inject(session_id: []const u8, prompt: []const u8) InjectOutcome {
        _ = session_id;
        calls += 1;
        last_prompt_len = @min(prompt.len, last_prompt_buf.len);
        @memcpy(last_prompt_buf[0..last_prompt_len], prompt[0..last_prompt_len]);
        return outcome;
    }
};

test "tick fires due loop task, advances, and skips when busy" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);

    var store = Store.init(a, path);
    defer store.deinit();

    // next_fire = 1000 + 30m; we tick at a time well past it.
    _ = try store.registerLoop("30m 2 do-it", .{ .session_id = "s" }, 1000, 0);
    const fire_at = 1000 + 30 * std.time.ms_per_min + 5;

    // Busy => skip, no decrement, still 1 task with remaining 2.
    TestInjector.outcome = .busy;
    TestInjector.calls = 0;
    store.tickWith(fire_at, 0, TestInjector.inject);
    try std.testing.expectEqual(@as(u32, 1), TestInjector.calls);
    {
        const snap = try store.snapshotForSession(a, "s", .loop);
        defer freeSnapshot(a, snap);
        try std.testing.expectEqual(@as(u32, 2), snap[0].remaining);
    }

    // Sent => decrement to 1, prompt forwarded.
    TestInjector.outcome = .sent;
    TestInjector.calls = 0;
    store.tickWith(fire_at + std.time.ms_per_s, 0, TestInjector.inject); // +1s to bypass the 1s throttle
    try std.testing.expectEqual(@as(u32, 1), TestInjector.calls);
    try std.testing.expectEqualStrings("do-it", TestInjector.last_prompt_buf[0..TestInjector.last_prompt_len]);
    {
        const snap = try store.snapshotForSession(a, "s", .loop);
        defer freeSnapshot(a, snap);
        try std.testing.expectEqual(@as(u32, 1), snap[0].remaining);
    }
}

test "setActive/clearActive/active module globals" {
    // Verify the module-level store pointer is absent by default and round-trips.
    clearActive();
    try std.testing.expectEqual(@as(?*Store, null), active());

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);
    var store = Store.init(a, path);
    defer store.deinit();

    setActive(&store);
    try std.testing.expect(active() != null);
    clearActive();
    try std.testing.expectEqual(@as(?*Store, null), active());
}
