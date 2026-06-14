// src/session_persist.zig
const std = @import("std");
const platform_atomic_file = @import("platform/atomic_file.zig");

const log = std.log.scoped(.session_persist);

// On-disk JSON uses std.json's default tagged-union encoding:
// nodes appear as {"leaf": {...}} or {"split": {...}}, not {"kind": ..., ...}.
// Surface kinds appear as {"local_shell": {...}} or {"ssh": {...}}.
// The spec illustrates the conceptual schema; this is the literal wire format.

pub const SCHEMA_VERSION: u32 = 2; // was 1: added LeafSnap.kind + preview

pub const Layout = enum { horizontal, vertical };

pub const SurfaceSnap = union(enum) {
    local_shell: LocalShellSnap,
    ssh: SshSnap,

    pub const LocalShellSnap = struct {
        cwd: ?[]const u8 = null,
        command: ?[]const []const u8 = null,
    };

    pub const SshSnap = struct {
        cwd: ?[]const u8 = null,
        user: []const u8,
        host: []const u8,
        port: u16 = 22,
        // OpenSSH ProxyJump spec ([user@]host[:port], comma-separated for
        // multi-hop). Defaulted so older session files without it still load.
        // Not a secret, so persisting it does not violate invariant I1.
        proxy_jump: []const u8 = "",
        // SECURITY INVARIANT (I1): NO password field. Adding one would
        // cause SSH passwords to be persisted to disk on every close.
    };
};

pub const PreviewSnap = struct {
    kind: @import("markdown_preview.zig").Kind = .markdown,
    path: []const u8 = "",
};

pub const NodeSnap = union(enum) {
    leaf: LeafSnap,
    split: SplitSnap,

    pub const LeafSnap = struct {
        kind: Kind = .terminal,
        surface: SurfaceSnap = .{ .local_shell = .{} }, // valid only when kind == .terminal
        preview: ?PreviewSnap = null, //                   present when kind == .preview
        pub const Kind = enum { terminal, preview };
    };

    pub const SplitSnap = struct {
        layout: Layout,
        ratio: f64,
        left: *NodeSnap,
        right: *NodeSnap,
    };
};

pub const AiHistorySnap = struct {
    source_id: []const u8,
    target_kind: []const u8,
    target_name: []const u8 = "",
};

pub const TabSnap = struct {
    title_override: ?[]const u8 = null,
    focused_leaf: u32 = 0,
    zoomed_leaf: ?u32 = null,
    tree: NodeSnap,
    // When non-null this tab is an AI Chat tab: it is restored by reopening the
    // agent history session of this id (the conversation lives in the persisted
    // agent history store, not in this snapshot), and `tree` is an ignored
    // placeholder. Absent in older snapshots → null → ordinary terminal tab.
    ai_session_id: ?[]const u8 = null,
    ai_history: ?AiHistorySnap = null,
};

pub const Session = struct {
    version: u32 = SCHEMA_VERSION,
    active_tab: u32 = 0,
    tabs: []TabSnap,
    /// SSH profile names of active tmux control-mode sessions (Phase 3d #4c).
    /// tmux is per-connection (one controller → N window-tabs), so these are
    /// persisted once per connection (not as per-tab surface trees); on restore
    /// each re-attaches via the profile (which re-supplies the password). Older
    /// session files omit this; it defaults to empty.
    tmux_profiles: []const []const u8 = &.{},
};

pub fn dumpSessionToString(allocator: std.mem.Allocator, session: Session) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, session, .{});
}

pub fn loadSessionFromString(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(Session) {
    return std.json.parseFromSlice(Session, allocator, bytes, .{
        .ignore_unknown_fields = true,
        // Copy ALL strings into the Parsed arena. The default (alloc_if_needed)
        // slices escape-free strings straight from `bytes`, which loadSession
        // frees right after — leaving every such string (tab titles, ssh fields,
        // tmux profile names) dangling once the buffer is reused.
        .allocate = .alloc_always,
    });
}

pub const RATIO_MIN: f64 = 0.05;
pub const RATIO_MAX: f64 = 0.95;

/// Clamp ratios into a usable range and clamp out-of-range indices to safe
/// defaults. Apply once after JSON parsing, before handing the Session to
/// the rebuild path. Idempotent.
pub fn normalize(session: *Session) void {
    if (session.tabs.len == 0) return;
    if (session.active_tab >= session.tabs.len) {
        session.active_tab = 0;
    }
    for (session.tabs) |*tab| {
        const leaf_count = countLeaves(&tab.tree);
        if (leaf_count == 0) continue;
        if (tab.focused_leaf >= leaf_count) tab.focused_leaf = 0;
        if (tab.zoomed_leaf) |zl| {
            if (zl >= leaf_count) tab.zoomed_leaf = null;
        }
        clampRatios(&tab.tree);
    }
}

fn clampRatios(node: *NodeSnap) void {
    switch (node.*) {
        .leaf => {},
        .split => |*sp| {
            if (sp.ratio < RATIO_MIN) sp.ratio = RATIO_MIN;
            if (sp.ratio > RATIO_MAX) sp.ratio = RATIO_MAX;
            if (std.math.isNan(sp.ratio)) sp.ratio = 0.5;
            clampRatios(sp.left);
            clampRatios(sp.right);
        },
    }
}

pub fn countLeaves(node: *const NodeSnap) u32 {
    return switch (node.*) {
        .leaf => 1,
        .split => |sp| countLeaves(sp.left) + countLeaves(sp.right),
    };
}

/// Return a pointer to the Nth leaf in pre-order, or null if out of range.
pub fn leafByIndex(root: *const NodeSnap, target: u32) ?*const NodeSnap {
    var idx: u32 = 0;
    return walk(root, target, &idx);
}

fn walk(node: *const NodeSnap, target: u32, idx: *u32) ?*const NodeSnap {
    return switch (node.*) {
        .leaf => blk: {
            if (idx.* == target) break :blk node;
            idx.* += 1;
            break :blk null;
        },
        .split => |sp| blk: {
            if (walk(sp.left, target, idx)) |found| break :blk found;
            if (walk(sp.right, target, idx)) |found| break :blk found;
            break :blk null;
        },
    };
}

/// Return the pre-order leaf index of the given leaf node, or null if not in tree.
pub fn indexOfLeaf(root: *const NodeSnap, target: *const NodeSnap) ?u32 {
    var idx: u32 = 0;
    return findIndex(root, target, &idx);
}

fn findIndex(node: *const NodeSnap, target: *const NodeSnap, idx: *u32) ?u32 {
    return switch (node.*) {
        .leaf => blk: {
            if (node == target) break :blk idx.*;
            idx.* += 1;
            break :blk null;
        },
        .split => |sp| blk: {
            if (findIndex(sp.left, target, idx)) |found| break :blk found;
            if (findIndex(sp.right, target, idx)) |found| break :blk found;
            break :blk null;
        },
    };
}

test "session_persist: empty Session compiles and has expected defaults" {
    const empty: Session = .{ .tabs = &.{} };
    try std.testing.expectEqual(@as(u32, SCHEMA_VERSION), empty.version);
    try std.testing.expectEqual(@as(u32, 0), empty.active_tab);
    try std.testing.expectEqual(@as(usize, 0), empty.tabs.len);
}

test "session_persist: round-trip simple local-shell session via JSON" {
    const allocator = std.testing.allocator;

    const leaf_node = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{
        .cwd = "/home/user",
        .command = null,
    } } } };
    const tabs = [_]TabSnap{.{
        .title_override = null,
        .focused_leaf = 0,
        .zoomed_leaf = null,
        .tree = leaf_node,
    }};
    const original: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    const json = try dumpSessionToString(allocator, original);
    defer allocator.free(json);

    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, SCHEMA_VERSION), parsed.value.version);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.active_tab);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.tabs.len);
    const leaf = switch (parsed.value.tabs[0].tree) {
        .leaf => |l| l,
        .split => return error.UnexpectedSplit,
    };
    const sh = switch (leaf.surface) {
        .local_shell => |s| s,
        .ssh => return error.UnexpectedSsh,
    };
    try std.testing.expectEqualStrings("/home/user", sh.cwd.?);
    try std.testing.expect(sh.command == null);
}

test "session_persist: AI chat tab round-trips its ai_session_id" {
    const allocator = std.testing.allocator;

    const placeholder = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    const tabs = [_]TabSnap{.{
        .tree = placeholder,
        .ai_session_id = "sess-abc-123",
    }};
    const original: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    const json = try dumpSessionToString(allocator, original);
    defer allocator.free(json);

    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.tabs.len);
    try std.testing.expect(parsed.value.tabs[0].ai_session_id != null);
    try std.testing.expectEqualStrings("sess-abc-123", parsed.value.tabs[0].ai_session_id.?);
}

test "session_persist: AI history tab round-trips its source snapshot" {
    const allocator = std.testing.allocator;

    const placeholder = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    const tabs = [_]TabSnap{.{
        .tree = placeholder,
        .ai_history = .{
            .source_id = "local-codex",
            .target_kind = "local",
            .target_name = "Local",
        },
    }};
    const original: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    const json = try dumpSessionToString(allocator, original);
    defer allocator.free(json);

    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.tabs.len);
    try std.testing.expect(parsed.value.tabs[0].ai_history != null);
    const history = parsed.value.tabs[0].ai_history.?;
    try std.testing.expectEqualStrings("local-codex", history.source_id);
    try std.testing.expectEqualStrings("local", history.target_kind);
}

test "session_persist: tab without ai_session_id defaults to null (back-compat)" {
    const allocator = std.testing.allocator;

    // An older snapshot has no ai_session_id field; it must parse as a terminal
    // tab (ai_session_id == null), not error.
    const json =
        \\{ "version": 1, "active_tab": 0, "tabs": [
        \\  { "focused_leaf": 0, "tree": { "leaf": { "surface": { "local_shell": {} } } } }
        \\] }
    ;
    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.tabs.len);
    try std.testing.expect(parsed.value.tabs[0].ai_session_id == null);
}

test "session_persist: old tab without ai_history defaults to null" {
    const allocator = std.testing.allocator;

    const json =
        \\{"version":1,"active_tab":0,"tabs":[{"tree":{"leaf":{"surface":{"local_shell":{}}}}}]}
    ;
    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.tabs.len);
    try std.testing.expect(parsed.value.tabs[0].ai_history == null);
}

test "session_persist: preview leaf round-trips through JSON" {
    const gpa = std.testing.allocator;
    var tabs = [_]TabSnap{.{ .tree = .{ .leaf = .{
        .kind = .preview,
        .preview = .{ .kind = .markdown, .path = "README.md" },
    } } }};
    const session = Session{ .version = SCHEMA_VERSION, .active_tab = 0, .tabs = &tabs };
    const json = try dumpSessionToString(gpa, session);
    defer gpa.free(json);
    var parsed = try loadSessionFromString(gpa, json);
    defer parsed.deinit();
    const leaf = switch (parsed.value.tabs[0].tree) {
        .leaf => |l| l,
        .split => return error.UnexpectedSplit,
    };
    try std.testing.expectEqual(NodeSnap.LeafSnap.Kind.preview, leaf.kind);
    try std.testing.expect(leaf.preview != null);
    try std.testing.expectEqualStrings("README.md", leaf.preview.?.path);
    try std.testing.expectEqual(@import("markdown_preview.zig").Kind.markdown, leaf.preview.?.kind);
}

test "session_persist: old terminal leaf JSON (no kind field) still parses as terminal" {
    const gpa = std.testing.allocator;
    const old = "{\"version\":1,\"active_tab\":0,\"tabs\":[{\"tree\":{\"leaf\":{\"surface\":{\"local_shell\":{}}}}}]}";
    var parsed = try loadSessionFromString(gpa, old);
    defer parsed.deinit();
    const leaf = switch (parsed.value.tabs[0].tree) {
        .leaf => |l| l,
        .split => return error.UnexpectedSplit,
    };
    try std.testing.expectEqual(NodeSnap.LeafSnap.Kind.terminal, leaf.kind);
    try std.testing.expect(leaf.preview == null);
}

test "session_persist: round-trip nested split with SSH leaf" {
    const allocator = std.testing.allocator;

    var ssh_leaf = NodeSnap{ .leaf = .{ .surface = .{ .ssh = .{
        .cwd = "/var/log",
        .user = "root",
        .host = "srvA.example.com",
        .port = 2222,
    } } } };
    var local_leaf = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{
        .cwd = "C:\\Users\\xzg",
        .command = null,
    } } } };
    const split = NodeSnap{ .split = .{
        .layout = .horizontal,
        .ratio = 0.6,
        .left = &ssh_leaf,
        .right = &local_leaf,
    } };
    const tabs = [_]TabSnap{.{
        .title_override = "work",
        .focused_leaf = 1,
        .zoomed_leaf = null,
        .tree = split,
    }};
    const original: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    const json = try dumpSessionToString(allocator, original);
    defer allocator.free(json);

    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    const sp = switch (parsed.value.tabs[0].tree) {
        .split => |s| s,
        .leaf => return error.UnexpectedLeaf,
    };
    try std.testing.expectEqual(Layout.horizontal, sp.layout);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), sp.ratio, 0.0001);
    const ssh = switch (sp.left.*) {
        .leaf => |l| switch (l.surface) {
            .ssh => |s| s,
            .local_shell => return error.UnexpectedShell,
        },
        .split => return error.UnexpectedSplit,
    };
    try std.testing.expectEqualStrings("root", ssh.user);
    try std.testing.expectEqualStrings("srvA.example.com", ssh.host);
    try std.testing.expectEqual(@as(u16, 2222), ssh.port);
    try std.testing.expectEqualStrings("/var/log", ssh.cwd.?);
    try std.testing.expectEqualStrings("work", parsed.value.tabs[0].title_override.?);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.tabs[0].focused_leaf);
}

test "session_persist: SSH leaf round-trips its proxy jump host" {
    const allocator = std.testing.allocator;

    const leaf = NodeSnap{ .leaf = .{ .surface = .{ .ssh = .{
        .user = "root",
        .host = "internal.box",
        .port = 22,
        .proxy_jump = "admin@bastion.example.com:2200",
    } } } };
    const tabs = [_]TabSnap{.{ .focused_leaf = 0, .tree = leaf }};
    const original: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    const json = try dumpSessionToString(allocator, original);
    defer allocator.free(json);

    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    const ssh = switch (parsed.value.tabs[0].tree) {
        .leaf => |l| switch (l.surface) {
            .ssh => |s| s,
            .local_shell => return error.UnexpectedShell,
        },
        .split => return error.UnexpectedSplit,
    };
    try std.testing.expectEqualStrings("admin@bastion.example.com:2200", ssh.proxy_jump);
}

test "session_persist: SSH leaf without a proxy jump field defaults to empty" {
    const allocator = std.testing.allocator;

    // Older session files predate the proxy_jump field; they must still load.
    const json =
        \\{ "active_tab": 0, "tabs": [ { "title_override": null, "focused_leaf": 0,
        \\  "zoomed_leaf": null, "ai_session_id": null,
        \\  "tree": { "leaf": { "surface": { "ssh": {
        \\    "cwd": null, "user": "root", "host": "legacy.box", "port": 22 } } } } } ] }
    ;
    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    const ssh = switch (parsed.value.tabs[0].tree) {
        .leaf => |l| switch (l.surface) {
            .ssh => |s| s,
            .local_shell => return error.UnexpectedShell,
        },
        .split => return error.UnexpectedSplit,
    };
    try std.testing.expectEqualStrings("", ssh.proxy_jump);
}

test "session_persist: corrupt JSON returns error" {
    const allocator = std.testing.allocator;
    const bad_inputs = [_][]const u8{
        "",
        "{ broken",
        "not json at all",
        "{\"version\": \"not a number\"}",
        "[1,2,3]",
    };
    for (bad_inputs) |bad| {
        if (loadSessionFromString(allocator, bad)) |*ok| {
            var pm = ok.*;
            pm.deinit();
            std.debug.print("expected error for input: {s}\n", .{bad});
            return error.ExpectedFailure;
        } else |_| {
            // any error is acceptable
        }
    }
}

test "session_persist: parses JSON with extra unknown fields" {
    const allocator = std.testing.allocator;
    const future_json =
        \\{
        \\  "version": 1,
        \\  "active_tab": 0,
        \\  "future_thing": "hello",
        \\  "tabs": [
        \\    {
        \\      "title_override": null,
        \\      "focused_leaf": 0,
        \\      "zoomed_leaf": null,
        \\      "extra_per_tab": 42,
        \\      "tree": { "leaf": { "surface": { "local_shell": { "cwd": null, "command": null } } } }
        \\    }
        \\  ]
        \\}
    ;
    var parsed = try loadSessionFromString(allocator, future_json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.tabs.len);
}

test "session_persist: I1 — serialized SSH leaf contains no 'password' substring" {
    const allocator = std.testing.allocator;

    const leaf = NodeSnap{ .leaf = .{ .surface = .{ .ssh = .{
        .cwd = "/etc",
        .user = "admin",
        .host = "vault.example.com",
        .port = 22,
    } } } };
    const tabs = [_]TabSnap{.{ .focused_leaf = 0, .tree = leaf }};
    const session: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    const json = try dumpSessionToString(allocator, session);
    defer allocator.free(json);

    if (std.mem.indexOf(u8, json, "password") != null) {
        std.debug.print("\n[I1 violation] serialized JSON contained 'password':\n{s}\n", .{json});
        return error.PasswordSerialized;
    }
    if (std.mem.indexOf(u8, json, "secret") != null) return error.SecretSerialized;
}

test "session_persist: normalize() clamps ratios and indices" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": 1,
        \\  "active_tab": 999,
        \\  "tabs": [
        \\    {
        \\      "focused_leaf": 999,
        \\      "zoomed_leaf": 999,
        \\      "tree": {
        \\        "split": {
        \\          "layout": "horizontal",
        \\          "ratio": -0.5,
        \\          "left":  { "leaf": { "surface": { "local_shell": { "cwd": null, "command": null } } } },
        \\          "right": { "leaf": { "surface": { "local_shell": { "cwd": null, "command": null } } } }
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;
    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    normalize(&parsed.value);

    try std.testing.expectEqual(@as(u32, 0), parsed.value.active_tab);
    const tab0 = parsed.value.tabs[0];
    try std.testing.expectEqual(@as(u32, 0), tab0.focused_leaf);
    try std.testing.expect(tab0.zoomed_leaf == null);
    const sp = switch (tab0.tree) {
        .split => |s| s,
        .leaf => return error.UnexpectedLeaf,
    };
    try std.testing.expect(sp.ratio >= 0.05 and sp.ratio <= 0.95);
}

test "session_persist: normalize() clamps ratio above 1" {
    const allocator = std.testing.allocator;
    const json =
        \\{ "version": 1, "active_tab": 0, "tabs": [
        \\  { "focused_leaf": 0, "zoomed_leaf": null, "tree": {
        \\    "split": { "layout": "vertical", "ratio": 5.0,
        \\      "left":  { "leaf": { "surface": { "local_shell": {} } } },
        \\      "right": { "leaf": { "surface": { "local_shell": {} } } }
        \\  } } } ] }
    ;
    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();
    normalize(&parsed.value);
    const sp = switch (parsed.value.tabs[0].tree) {
        .split => |s| s,
        else => return error.UnexpectedLeaf,
    };
    try std.testing.expect(sp.ratio <= 0.95);
}

test "session_persist: leafByIndexPreOrder walks pre-order" {
    var l1 = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var l2 = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var l3 = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var inner = NodeSnap{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = &l1, .right = &l2 } };
    var root = NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = &inner, .right = &l3 } };

    try std.testing.expectEqual(@as(u32, 3), countLeaves(&root));
    try std.testing.expectEqual(@as(?*const NodeSnap, &l1), leafByIndex(&root, 0));
    try std.testing.expectEqual(@as(?*const NodeSnap, &l2), leafByIndex(&root, 1));
    try std.testing.expectEqual(@as(?*const NodeSnap, &l3), leafByIndex(&root, 2));
    try std.testing.expectEqual(@as(?*const NodeSnap, null), leafByIndex(&root, 3));
}

test "session_persist: indexOfLeafBySurfaceAddress finds leaf in pre-order" {
    var l1 = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{ .cwd = "/A" } } } };
    var l2 = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{ .cwd = "/B" } } } };
    var root = NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = &l1, .right = &l2 } };

    try std.testing.expectEqual(@as(?u32, 0), indexOfLeaf(&root, &l1));
    try std.testing.expectEqual(@as(?u32, 1), indexOfLeaf(&root, &l2));
}

/// Escape a path so that wrapping it in single quotes (`'...'`) produces a
/// single shell argument. Inside single quotes, only the closing quote needs
/// special handling: `'` becomes `'\''` (close, escape, reopen).
/// The caller is responsible for adding the surrounding single quotes.
pub fn shellSingleQuoteEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    for (input) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

test "session_persist: shellSingleQuoteEscape handles common paths" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "/var/log", .want = "/var/log" },
        .{ .in = "/home/x'z", .want = "/home/x'\\''z" },
        .{ .in = "/tmp/with space", .want = "/tmp/with space" },
        .{ .in = "/p/with\"$\\back", .want = "/p/with\"$\\back" },
        .{ .in = "", .want = "" },
    };
    for (cases) |c| {
        const got = try shellSingleQuoteEscape(allocator, c.in);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

/// Serialize and replace-safely write the session to `path`.
/// On any I/O failure, log a warning and return the error; callers in the
/// close path swallow the error.
pub fn dumpSession(allocator: std.mem.Allocator, path: []const u8, session: Session) !void {
    const json = try dumpSessionToString(allocator, session);
    defer allocator.free(json);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            log.warn("failed to create session dir {s}: {}", .{ dir, err });
            return err;
        };
    }

    try platform_atomic_file.writeFileReplaceSafe(path, json);
}

/// Read and parse the session file. Returns null on any failure (missing,
/// corrupt, empty), and renames a corrupt file to `path.bak` so the next
/// launch starts clean. Callers own the returned `std.json.Parsed` and must
/// call `.deinit()`.
pub fn loadSession(
    allocator: std.mem.Allocator,
    path: []const u8,
) !?std.json.Parsed(Session) {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            log.warn("failed to read {s}: {}", .{ path, err });
            return null;
        },
    };
    defer allocator.free(bytes);

    const parsed = loadSessionFromString(allocator, bytes) catch |err| {
        log.warn("session.json corrupt ({}); renaming to .bak", .{err});
        const bak = std.mem.concat(allocator, u8, &.{ path, ".bak" }) catch return null;
        defer allocator.free(bak);
        std.fs.cwd().rename(path, bak) catch |rerr| {
            log.warn("failed to rename {s} to .bak: {}", .{ path, rerr });
        };
        return null;
    };
    if (parsed.value.tabs.len == 0) {
        var p = parsed;
        p.deinit();
        return null;
    }
    return parsed;
}

test "session_persist: dumpSession writes atomically and loadSession reads back" {
    const allocator = std.testing.allocator;

    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const realpath = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(realpath);
    const path = try std.fs.path.join(allocator, &.{ realpath, "sess.json" });
    defer allocator.free(path);

    const leaf = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{ .cwd = "/x" } } } };
    const tabs = [_]TabSnap{.{ .focused_leaf = 0, .tree = leaf }};
    const session: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    try dumpSession(allocator, path, session);

    var loaded = try loadSession(allocator, path);
    defer {
        if (loaded) |*l| {
            var lm = l.*;
            lm.deinit();
        }
    }
    try std.testing.expect(loaded != null);
    try std.testing.expectEqual(@as(usize, 1), loaded.?.value.tabs.len);

    // Verify no .tmp leftover
    const tmp_path = try std.mem.concat(allocator, u8, &.{ path, ".tmp" });
    defer allocator.free(tmp_path);
    const tmp_exists = blk: {
        std.fs.cwd().access(tmp_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!tmp_exists);
}

test "session_persist: corrupt file is renamed to .bak and loadSession returns null" {
    const allocator = std.testing.allocator;
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    const realpath = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(realpath);
    const path = try std.fs.path.join(allocator, &.{ realpath, "sess.json" });
    defer allocator.free(path);

    {
        const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("{ totally broken");
    }

    const result = try loadSession(allocator, path);
    try std.testing.expect(result == null);

    const bak = try std.mem.concat(allocator, u8, &.{ path, ".bak" });
    defer allocator.free(bak);
    try std.fs.cwd().access(bak, .{}); // should exist; throws if missing

    const orig_exists = blk: {
        std.fs.cwd().access(path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!orig_exists);
}
