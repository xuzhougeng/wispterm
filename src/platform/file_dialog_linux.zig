//! Linux file-dialog backend: drives the `zenity` command-line tool which
//! speaks to the GTK/GNOME file-chooser portal and works across many desktop
//! environments (GNOME, KDE via xdg-portal, XFCE, …).
//!
//! If zenity is absent or the user cancels, the functions return null (same
//! contract as the unsupported backend).

const std = @import("std");

pub const Owner = struct {
    native_window: ?usize = null,
};

pub const Filter = struct {
    name: []const u8,
    pattern: []const u8,
};

pub const OpenRequest = struct {
    owner: Owner = .{},
    title: []const u8,
    filters: []const Filter,
};

pub const SaveRequest = struct {
    owner: Owner = .{},
    title: []const u8,
    initial_dir: ?[]const u8 = null,
    default_filename: ?[]const u8 = null,
    default_extension: ?[]const u8 = null,
    filters: []const Filter,
};

pub fn windowOwner(native_window: usize) Owner {
    return .{ .native_window = native_window };
}

/// Open a file-chooser dialog via zenity and return the selected path,
/// or null if the user cancelled or zenity is unavailable.
/// The returned slice is allocated with `allocator`; caller must free it.
pub fn openFile(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.append(a, "zenity") catch return null;
    argv.append(a, "--file-selection") catch return null;
    argv.append(a, "--title") catch return null;
    argv.append(a, request.title) catch return null;

    // Add file filters: zenity accepts one --file-filter per filter entry.
    for (request.filters) |filter| {
        argv.append(a, "--file-filter") catch return null;
        // Format: "Name | pattern" e.g. "Text Files | *.txt"
        const filter_str = std.fmt.allocPrint(a, "{s} | {s}", .{ filter.name, filter.pattern }) catch return null;
        argv.append(a, filter_str) catch return null;
    }

    return runZenityDialog(allocator, a, argv.items);
}

/// Open a save-file dialog via zenity and return the chosen path,
/// or null if the user cancelled or zenity is unavailable.
/// The returned slice is allocated with `allocator`; caller must free it.
pub fn saveFile(allocator: std.mem.Allocator, request: SaveRequest) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.append(a, "zenity") catch return null;
    argv.append(a, "--file-selection") catch return null;
    argv.append(a, "--save") catch return null;
    argv.append(a, "--confirm-overwrite") catch return null;
    argv.append(a, "--title") catch return null;
    argv.append(a, request.title) catch return null;

    if (request.default_filename) |fname| {
        argv.append(a, "--filename") catch return null;
        argv.append(a, fname) catch return null;
    }

    for (request.filters) |filter| {
        argv.append(a, "--file-filter") catch return null;
        const filter_str = std.fmt.allocPrint(a, "{s} | {s}", .{ filter.name, filter.pattern }) catch return null;
        argv.append(a, filter_str) catch return null;
    }

    return runZenityDialog(allocator, a, argv.items);
}

/// Spawn zenity with the given argv, capture its stdout, strip the trailing
/// newline, and return the path.  Returns null on cancel (exit 1) or error.
/// `result_allocator` is used for the returned path slice; `child_allocator`
/// is used for the Child process internals (may be an arena).
fn runZenityDialog(result_allocator: std.mem.Allocator, child_allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    var child = std.process.Child.init(argv, child_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    // Read stdout (the chosen path, terminated by a newline).
    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };

    // zenity paths are typically short; 4 KiB is more than enough.
    var buf: [4096]u8 = undefined;
    const n = stdout.read(&buf) catch {
        _ = child.wait() catch {};
        return null;
    };

    const term = child.wait() catch return null;
    // zenity exits 0 on selection, 1 on cancel/close.
    switch (term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    if (n == 0) return null;

    // Strip trailing newline.
    const raw = buf[0..n];
    const path = std.mem.trimRight(u8, raw, "\n\r");
    if (path.len == 0) return null;

    return result_allocator.dupe(u8, path) catch null;
}
