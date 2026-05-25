//! Preview path detection, source loading, and terminal preview commands.

const std = @import("std");
const Surface = @import("../Surface.zig");
const file_explorer = @import("../file_explorer.zig");
const markdown_preview = @import("../markdown_preview.zig");
const platform_remote_file = @import("../platform/remote_file.zig");
const scp = @import("../scp.zig");
const ui_perf = @import("../ui_perf.zig");

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn isPreviewImagePath(path: []const u8) bool {
    return markdown_preview.isImagePath(path);
}

pub const SourceKind = union(enum) {
    local,
    wsl,
    remote: Surface.SshConnection,
};

pub fn looksLikePreviewPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) return false;
    if (markdown_preview.detectKind(path) != null) return true;
    if (path[0] == '~') return true;
    if (path.len >= 2 and path[1] == ':') return true;
    if (std.mem.indexOfScalar(u8, path, '/') != null) return true;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return true;
    return endsWithIgnoreCase(path, ".pdf") or isPreviewImagePath(path);
}

fn appendShellQuoted(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try list.append(allocator, '\'');
    for (text) |ch| {
        if (ch == '\'') {
            try list.appendSlice(allocator, "'\\''");
        } else {
            try list.append(allocator, ch);
        }
    }
    try list.append(allocator, '\'');
}

pub fn readLocalPreviewSource(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const perf = ui_perf.begin("preview_source.read_local");
    defer perf.end();

    var file = blk: {
        if (std.fs.path.isAbsolute(path)) {
            break :blk std.fs.openFileAbsolute(path, .{}) catch return error.PreviewFailed;
        }
        break :blk std.fs.cwd().openFile(path, .{}) catch return error.PreviewFailed;
    };
    defer file.close();

    const source = file.readToEndAlloc(allocator, limit + 1) catch return error.PreviewFailed;
    errdefer allocator.free(source);
    if (source.len > limit) return error.PreviewTooLarge;
    return source;
}

fn buildRemotePreviewReadCommand(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var path_buf: [1024]u8 = undefined;
    const path_expr = platform_remote_file.shellPathExpr(&path_buf, path) orelse return error.PreviewFailed;
    return std.fmt.allocPrint(allocator, "head -c {} -- {s}", .{ limit + 1, path_expr });
}

fn readSshPreviewSource(allocator: std.mem.Allocator, conn: *const Surface.SshConnection, path: []const u8, limit: usize) ![]u8 {
    const perf = ui_perf.begin("preview_source.read_ssh");
    defer perf.end();

    const command = buildRemotePreviewReadCommand(allocator, path, limit) catch return error.PreviewFailed;
    defer allocator.free(command);

    const source = scp.sshExec(allocator, conn, command) orelse return error.PreviewFailed;
    errdefer allocator.free(source);
    if (source.len > limit) return error.PreviewTooLarge;
    return source;
}

pub fn readRemotePreviewSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!file_explorer.g_has_ssh_conn) return error.PreviewFailed;
    return readSshPreviewSource(allocator, &file_explorer.g_ssh_conn, path, markdown_preview.MAX_SOURCE_BYTES);
}

pub fn readPreviewSourceForKind(allocator: std.mem.Allocator, source_kind: SourceKind, path: []const u8, kind: markdown_preview.Kind) ![]u8 {
    const limit = markdown_preview.sourceLimit(kind);
    return switch (source_kind) {
        .local => readLocalPreviewSource(allocator, path, limit),
        .wsl => readWslPreviewSource(allocator, path, limit),
        .remote => |conn| readSshPreviewSource(allocator, &conn, path, limit),
    };
}

fn buildWslPreviewReadCommand(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var path_buf: [1024]u8 = undefined;
    const path_expr = platform_remote_file.wslPathExpr(&path_buf, path) orelse return error.PreviewFailed;
    return std.fmt.allocPrint(allocator, "head -c {} -- {s}", .{ limit + 1, path_expr });
}

pub fn readWslPreviewSource(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const perf = ui_perf.begin("preview_source.read_wsl");
    defer perf.end();

    const command = buildWslPreviewReadCommand(allocator, path, limit) catch return error.PreviewFailed;
    defer allocator.free(command);

    const source = platform_remote_file.wslExec(allocator, command) orelse return error.PreviewFailed;
    errdefer allocator.free(source);
    if (source.len > limit) return error.PreviewTooLarge;
    return source;
}

pub fn basenameForPreview(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') start = i + 1;
    }
    return path[start..];
}

fn isUnixAbsoluteOrHome(path: []const u8) bool {
    return path.len > 0 and (path[0] == '/' or path[0] == '~');
}

fn joinUnixPreviewPath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (isUnixAbsoluteOrHome(path)) return allocator.dupe(u8, path);
    if (cwd.len == 0) return allocator.dupe(u8, path);
    if (std.mem.eql(u8, cwd, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{path});
    const base = std.mem.trimRight(u8, cwd, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, path });
}

fn resolveUnixTerminalPath(
    allocator: std.mem.Allocator,
    cwd: ?[]const u8,
    path: []const u8,
    require_cwd_for_relative: bool,
) ![]u8 {
    if (isUnixAbsoluteOrHome(path)) return allocator.dupe(u8, path);
    const current = cwd orelse {
        if (require_cwd_for_relative) return error.CwdUnavailable;
        return allocator.dupe(u8, path);
    };
    if (current.len == 0 and require_cwd_for_relative) return error.CwdUnavailable;
    return joinUnixPreviewPath(allocator, current, path);
}

test "preview_source: ssh relative paths require a reported cwd" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.CwdUnavailable, resolveUnixTerminalPath(allocator, null, "pp.pep.fa", true));

    const absolute = try resolveUnixTerminalPath(allocator, null, "/srv/project/data/sample.fa", true);
    defer allocator.free(absolute);
    try std.testing.expectEqualStrings("/srv/project/data/sample.fa", absolute);

    const home = try resolveUnixTerminalPath(allocator, null, "~/sample.fa", true);
    defer allocator.free(home);
    try std.testing.expectEqualStrings("~/sample.fa", home);

    const relative = try resolveUnixTerminalPath(allocator, "/srv/project/data", "sample.fa", true);
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("/srv/project/data/sample.fa", relative);
}

pub fn resolveTerminalPreviewPath(allocator: std.mem.Allocator, surface: *Surface, path: []const u8) ![]u8 {
    return switch (surface.launch_kind) {
        .wsl => try resolveUnixTerminalPath(allocator, surface.getCwd() orelse "~", path, false),
        .ssh => try resolveUnixTerminalPath(allocator, surface.getCwd(), path, true),
        .local => blk: {
            if (std.fs.path.isAbsolute(path) or (path.len >= 2 and path[1] == ':')) {
                break :blk try allocator.dupe(u8, path);
            }
            const cwd = surface.getInitialCwd() orelse {
                break :blk try allocator.dupe(u8, path);
            };
            break :blk try std.fs.path.join(allocator, &.{ cwd, path });
        },
    };
}

pub fn readTerminalPreviewSource(allocator: std.mem.Allocator, surface: *Surface, path: []const u8) ![]u8 {
    return switch (surface.launch_kind) {
        .wsl => readWslPreviewSource(allocator, path, markdown_preview.MAX_SOURCE_BYTES),
        .ssh => blk: {
            const conn = surface.ssh_connection orelse {
                std.debug.print("Markdown preview over SSH needs Phantty SSH connection metadata; manual ssh sessions are not supported yet\n", .{});
                return error.PreviewFailed;
            };
            break :blk try readSshPreviewSource(allocator, &conn, path, markdown_preview.MAX_SOURCE_BYTES);
        },
        .local => readLocalPreviewSource(allocator, path, markdown_preview.MAX_SOURCE_BYTES),
    };
}

pub fn buildPreviewCommand(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var cmd: std.ArrayListUnmanaged(u8) = .empty;

    if (endsWithIgnoreCase(path, ".pdf")) {
        cmd.appendSlice(allocator, "pdfcat ") catch {
            cmd.deinit(allocator);
            return null;
        };
    } else if (isPreviewImagePath(path)) {
        cmd.appendSlice(allocator, "imgcat ") catch {
            cmd.deinit(allocator);
            return null;
        };
    } else {
        cmd.appendSlice(allocator, "less ") catch {
            cmd.deinit(allocator);
            return null;
        };
    }
    appendShellQuoted(&cmd, allocator, path) catch {
        cmd.deinit(allocator);
        return null;
    };
    cmd.append(allocator, '\r') catch {
        cmd.deinit(allocator);
        return null;
    };
    return cmd.toOwnedSlice(allocator) catch {
        cmd.deinit(allocator);
        return null;
    };
}
