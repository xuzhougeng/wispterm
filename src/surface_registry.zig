//! Process-wide registry of live Surface pointers.
//!
//! The agent request worker holds raw `*Surface` pointers captured at request
//! start (ToolSurface.ptr) and dereferences them for up to the tool timeout,
//! while the UI thread may free the surface at any moment (close tab / close
//! split). This registry is the liveness guard between the two threads:
//!
//!  - the UI thread `register`s a surface when it is created and
//!    `unregister`s it right before it is freed;
//!  - a worker wraps every dereference in `acquire`/`release`, passing both
//!    the raw pointer and the captured surface id. `acquire` returns true with
//!    the registry lock HELD, and `unregister` takes the same lock, so a
//!    surface can never be freed while a guarded access is in flight — and a
//!    freed surface can never be acquired again. The id check prevents ABA
//!    pointer reuse from validating a stale ToolSurface.ptr.
//!
//! Accesses inside the guarded section must be short (snapshot serialization,
//! queueing PTY input); the lock is global, not per-surface.

const std = @import("std");

/// Upper bound on simultaneously live surfaces (tabs × splits). Registration
/// beyond this is dropped, which fails safe: acquire() then reports the
/// surface as gone and agent tools degrade to an error instead of a deref.
const MAX_SURFACES = 1024;
const MAX_SURFACE_ID_BYTES = 64;

const Entry = struct {
    ptr: *anyopaque,
    id: [MAX_SURFACE_ID_BYTES]u8,
    id_len: usize,

    fn init(ptr: *anyopaque, id: []const u8) Entry {
        var out = Entry{
            .ptr = ptr,
            .id = @splat(0),
            .id_len = @min(id.len, MAX_SURFACE_ID_BYTES),
        };
        @memcpy(out.id[0..out.id_len], id[0..out.id_len]);
        return out;
    }

    fn idSlice(self: *const Entry) []const u8 {
        return self.id[0..self.id_len];
    }

    fn matches(self: *const Entry, ptr: *anyopaque, id: []const u8) bool {
        return self.ptr == ptr and std.mem.eql(u8, self.idSlice(), id);
    }
};

var g_mutex: std.Thread.Mutex = .{};
var g_entries: [MAX_SURFACES]?Entry = @splat(null);

/// Record a live surface pointer (UI thread, surface creation).
pub fn register(ptr: *anyopaque, id: []const u8) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    var free_slot: ?*?Entry = null;
    for (&g_entries) |*entry| {
        if (entry.*) |live| {
            if (live.ptr == ptr) {
                entry.* = Entry.init(ptr, id);
                return;
            }
        }
        if (entry.* == null and free_slot == null) free_slot = entry;
    }
    if (free_slot) |slot| slot.* = Entry.init(ptr, id);
}

/// Drop a surface pointer (UI thread, right before the surface is freed).
/// Blocks while any acquire() holder is inside the guarded section, so the
/// caller may free the surface immediately after this returns.
pub fn unregister(ptr: *anyopaque) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    for (&g_entries) |*entry| {
        if (entry.* != null and entry.*.?.ptr == ptr) {
            entry.* = null;
            return;
        }
    }
}

/// If `ptr` is a live registered surface, returns true with the registry
/// lock held — the caller MUST call release() when done with the surface.
/// Returns false (lock not held) when the surface is gone.
pub fn acquire(ptr: *anyopaque, id: []const u8) bool {
    g_mutex.lock();
    for (g_entries) |entry| {
        if (entry) |live| {
            if (live.matches(ptr, id)) return true;
        }
    }
    g_mutex.unlock();
    return false;
}

/// Release the lock taken by a successful acquire().
pub fn release() void {
    g_mutex.unlock();
}

// ---- Tests ----

// Dummy registration targets with process-unique, stable addresses; stack
// addresses could collide across tests if a test ever leaked an entry.
var test_target_a: u8 = 0;
var test_target_b: u8 = 0;

test "registered pointer can be acquired (and re-acquired after release)" {
    register(&test_target_a, "surface-a");
    defer unregister(&test_target_a);

    try std.testing.expect(acquire(&test_target_a, "surface-a"));
    release();
    try std.testing.expect(acquire(&test_target_a, "surface-a"));
    release();
}

test "unregistered pointer cannot be acquired" {
    try std.testing.expect(!acquire(&test_target_b, "surface-b"));
}

test "unregister makes a pointer unacquirable" {
    register(&test_target_a, "surface-a");
    unregister(&test_target_a);
    try std.testing.expect(!acquire(&test_target_a, "surface-a"));
}

test "registering the same pointer twice does not duplicate the entry" {
    register(&test_target_a, "surface-a");
    register(&test_target_a, "surface-a");
    unregister(&test_target_a);
    try std.testing.expect(!acquire(&test_target_a, "surface-a"));
}

test "reused pointer address does not validate a stale surface id" {
    register(&test_target_a, "old-surface");
    unregister(&test_target_a);

    register(&test_target_a, "new-surface");
    defer unregister(&test_target_a);

    try std.testing.expect(!acquire(&test_target_a, "old-surface"));
    try std.testing.expect(acquire(&test_target_a, "new-surface"));
    release();
}

test "unregister blocks until an in-flight guarded access releases" {
    register(&test_target_a, "surface-a");

    try std.testing.expect(acquire(&test_target_a, "surface-a"));

    var unregistered = std.atomic.Value(bool).init(false);
    const Closure = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            unregister(&test_target_a);
            flag.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Closure.run, .{&unregistered});

    // While we hold the guard the unregistering thread must stay blocked.
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!unregistered.load(.acquire));

    release();
    thread.join();
    try std.testing.expect(unregistered.load(.acquire));
    try std.testing.expect(!acquire(&test_target_a, "surface-a"));
}
