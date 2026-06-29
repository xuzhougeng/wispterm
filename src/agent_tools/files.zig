//! Agent file tool adapters.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const agent_file_edit = @import("../agent/file_edit.zig");
const agent_file_copy = @import("../agent/file_copy.zig");
const platform_atomic_file = @import("../platform/atomic_file.zig");
const platform_pty_command = @import("../platform/pty_command.zig");
const platform_wsl = @import("../platform/wsl.zig");
const scp = @import("../ssh/scp.zig");
const terminal_tools = @import("terminal.zig");
const tool_access = @import("access.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;
const ToolSurface = types.ToolSurface;
const ToolSnapshot = types.ToolSnapshot;
const ToolSshConnection = types.SshConnection;

// File tool helpers
// ---------------------------------------------------------------------------

/// Resolve `path` against `working_dir` if relative, then return an owned copy.
fn resolveLocalPath(allocator: std.mem.Allocator, path: []const u8, working_dir: ?[]const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    if (working_dir) |wd| if (wd.len != 0) return std.fs.path.join(allocator, &.{ wd, path });
    return allocator.dupe(u8, path);
}

fn writeLocalFileAtomic(allocator: std.mem.Allocator, resolved: []const u8, content: []const u8) !void {
    _ = allocator;
    try platform_atomic_file.writeFileReplaceSafe(resolved, content);
}

fn renderReadResult(ctx: *ToolContext, path: []const u8, bytes: []const u8, offset: usize, limit: usize) ![]u8 {
    if (bytes.len >= agent_file_edit.MAX_FILE_BYTES) {
        return std.fmt.allocPrint(ctx.allocator, "File {s} is too large (>= {d} bytes). Use offset/limit to read a range.", .{ path, agent_file_edit.MAX_FILE_BYTES });
    }
    if (agent_file_edit.looksBinary(bytes)) {
        return std.fmt.allocPrint(ctx.allocator, "File {s} appears to be binary; refusing to read as text.", .{path});
    }
    const numbered = try agent_file_edit.sliceLinesAlloc(ctx.allocator, bytes, offset, limit);
    return tool_output.truncateOwned(ctx.allocator, ctx.settings, numbered);
}

// ---------------------------------------------------------------------------
// File tool target resolution
// ---------------------------------------------------------------------------

const FileTarget = union(enum) {
    local: ?ToolSurface,
    wsl: ToolSurface,
    remote: struct {
        surface: ToolSurface,
        conn: ToolSshConnection,
    },
    /// Owned error message to return verbatim to the model.
    err: []u8,
};

const CopyEndpoint = union(enum) {
    local: ?ToolSurface,
    wsl: ToolSurface,
    ssh: struct {
        surface: ToolSurface,
        conn: ToolSshConnection,
    },
    err: []u8,
};

/// Resolve a file tool's optional `surface_id` to a local, WSL, or SSH target.
/// A missing surface_id follows the selected terminal context when one exists;
/// otherwise it means local.
fn resolveFileTarget(ctx: *ToolContext, surface_id: ?[]const u8) !FileTarget {
    const sid = surface_id orelse terminal_tools.selectedWriteContext(ctx) orelse return .{ .local = null };
    const snapshot = ctx.tool_snapshot orelse return .{
        .err = try std.fmt.allocPrint(ctx.allocator, "No terminal snapshot is available for surface_id={s}.", .{sid}),
    };
    const surface = terminal_tools.resolveSurfaceId(snapshot, sid, terminal_tools.selectedWriteContext(ctx)) orelse {
        return .{ .err = try terminal_tools.allocNoSurfaceError(ctx.allocator, snapshot, sid) };
    };
    if (surface.is_wsl) return .{ .wsl = surface };
    if (!surface.is_ssh) return .{ .local = surface };
    if (surface.ssh_connection) |conn| return .{ .remote = .{ .surface = surface, .conn = conn } };
    if (ctx.sshConnectionForSurface(surface.id)) |conn| return .{ .remote = .{ .surface = surface, .conn = conn } };
    return .{ .err = try std.fmt.allocPrint(ctx.allocator, "Surface {s} is an SSH terminal but its connection is unavailable.", .{surface.id}) };
}

fn resolveCopyEndpoint(ctx: *ToolContext, surface_id: ?[]const u8) !CopyEndpoint {
    const sid = surface_id orelse return .{ .local = null };
    const snapshot = ctx.tool_snapshot orelse return .{
        .err = try std.fmt.allocPrint(ctx.allocator, "No terminal snapshot is available for surface_id={s}.", .{sid}),
    };
    const surface = terminal_tools.resolveSurfaceId(snapshot, sid, terminal_tools.selectedWriteContext(ctx)) orelse {
        return .{ .err = try terminal_tools.allocNoSurfaceError(ctx.allocator, snapshot, sid) };
    };
    if (surface.is_ssh) {
        if (surface.ssh_connection) |conn| {
            return .{ .ssh = .{ .surface = surface, .conn = conn } };
        }
        if (ctx.sshConnectionForSurface(surface.id)) |conn| {
            return .{ .ssh = .{ .surface = surface, .conn = conn } };
        }
        return .{ .err = try std.fmt.allocPrint(ctx.allocator, "Surface {s} is an SSH terminal but its connection is unavailable.", .{surface.id}) };
    }
    if (surface.is_wsl) return .{ .wsl = surface };
    return .{ .local = surface };
}

fn posixPathIsAbsolute(path: []const u8) bool {
    return path.len > 0 and (path[0] == '/' or path[0] == '~');
}

fn posixJoin(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) ![]u8 {
    if (parent.len == 0) return allocator.dupe(u8, child);
    if (parent[parent.len - 1] == '/') return std.fmt.allocPrint(allocator, "{s}{s}", .{ parent, child });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, child });
}

fn endpointCwd(ctx: *ToolContext, endpoint: CopyEndpoint) ?[]const u8 {
    return switch (endpoint) {
        .local => |surface| if (surface) |s| if (s.cwd.len > 0) s.cwd else ctx.settings.working_dir else ctx.settings.working_dir,
        .wsl => |surface| if (surface.cwd.len > 0) surface.cwd else null,
        .ssh => |remote| if (remote.surface.cwd.len > 0) remote.surface.cwd else null,
        .err => null,
    };
}

fn fileTargetCwd(ctx: *ToolContext, target: FileTarget) ?[]const u8 {
    return switch (target) {
        .local => |surface| if (surface) |s| if (s.cwd.len > 0) s.cwd else ctx.settings.working_dir else ctx.settings.working_dir,
        .wsl => |surface| if (surface.cwd.len > 0) surface.cwd else null,
        .remote => |remote| if (remote.surface.cwd.len > 0) remote.surface.cwd else null,
        .err => null,
    };
}

fn resolveEndpointPath(ctx: *ToolContext, endpoint: CopyEndpoint, path: []const u8) ![]u8 {
    return switch (endpoint) {
        .local => {
            if (std.fs.path.isAbsolute(path)) return ctx.allocator.dupe(u8, path);
            const cwd = endpointCwd(ctx, endpoint) orelse return error.MissingWorkingDir;
            return std.fs.path.join(ctx.allocator, &.{ cwd, path });
        },
        .wsl, .ssh => {
            if (posixPathIsAbsolute(path)) return ctx.allocator.dupe(u8, path);
            const cwd = endpointCwd(ctx, endpoint) orelse return error.MissingWorkingDir;
            return posixJoin(ctx.allocator, cwd, path);
        },
        .err => unreachable,
    };
}

fn resolveFileTargetPath(ctx: *ToolContext, target: FileTarget, path: []const u8) ![]u8 {
    return switch (target) {
        .local => resolveLocalPath(ctx.allocator, path, fileTargetCwd(ctx, target)),
        .wsl, .remote => {
            if (posixPathIsAbsolute(path)) return ctx.allocator.dupe(u8, path);
            const cwd = fileTargetCwd(ctx, target) orelse return error.MissingWorkingDir;
            return posixJoin(ctx.allocator, cwd, path);
        },
        .err => unreachable,
    };
}

fn defaultDestinationPath(ctx: *ToolContext, dest_endpoint: CopyEndpoint, source_path: []const u8, dest_name: ?[]const u8, dest_path: ?[]const u8) ![]u8 {
    if (dest_path) |path| return resolveEndpointPath(ctx, dest_endpoint, path);
    const name = dest_name orelse agent_file_copy.basename(source_path);
    if (!agent_file_copy.isSafeDestinationName(name)) return error.UnsafeDestinationName;
    return switch (dest_endpoint) {
        .local => |surface| if (surface == null) blk: {
            const wd = ctx.settings.working_dir orelse return error.MissingWorkingDir;
            const plan = try agent_file_copy.planDestination(ctx.allocator, wd, source_path, dest_name);
            break :blk plan.dest_path;
        } else blk: {
            const cwd = endpointCwd(ctx, dest_endpoint) orelse return error.MissingWorkingDir;
            break :blk std.fs.path.join(ctx.allocator, &.{ cwd, name });
        },
        .wsl, .ssh => blk: {
            const cwd = endpointCwd(ctx, dest_endpoint) orelse return error.MissingWorkingDir;
            break :blk posixJoin(ctx.allocator, cwd, name);
        },
        .err => unreachable,
    };
}

fn wslGuestPathToLocalAlloc(allocator: std.mem.Allocator, guest_path: []const u8) ![]u8 {
    var native_buf: platform_pty_command.CwdBuffer = undefined;
    var utf8_buf: [4096]u8 = undefined;
    const local = platform_wsl.guestPathToLocalPathUtf8(guest_path, &native_buf, &utf8_buf) orelse return error.WslPathUnavailable;
    return allocator.dupe(u8, local);
}

fn localPathForEndpoint(ctx: *ToolContext, endpoint: CopyEndpoint, path: []const u8) ![]u8 {
    return switch (endpoint) {
        .local => ctx.allocator.dupe(u8, path),
        .wsl => wslGuestPathToLocalAlloc(ctx.allocator, path),
        .ssh, .err => unreachable,
    };
}

fn localPathForFileTarget(ctx: *ToolContext, target: FileTarget, path: []const u8) ![]u8 {
    return switch (target) {
        .local => ctx.allocator.dupe(u8, path),
        .wsl => wslGuestPathToLocalAlloc(ctx.allocator, path),
        .remote, .err => unreachable,
    };
}

fn gateForFileTarget(ctx: *ToolContext, target: FileTarget, path: []const u8, is_write: bool) tool_access.Gate {
    return switch (target) {
        .local => tool_access.fileGate(ctx, path, is_write),
        .wsl, .remote => tool_access.remoteFileGate(is_write),
        .err => unreachable,
    };
}

fn ensureLocalParent(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.fs.cwd().makePath(parent);
    }
}

fn openLocalReadFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, .{});
    return std.fs.cwd().openFile(path, .{});
}

fn createLocalWriteFile(path: []const u8) !std.fs.File {
    try ensureLocalParent(path);
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, .{ .truncate = true });
    return std.fs.cwd().createFile(path, .{ .truncate = true });
}

fn copyLocalFileStreaming(source_path: []const u8, dest_path: []const u8) !u64 {
    var src = try openLocalReadFile(source_path);
    defer src.close();
    var dst = try createLocalWriteFile(dest_path);
    defer dst.close();

    var total: u64 = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dst.writeAll(buf[0..n]);
        total += n;
    }
    return total;
}

fn remoteSpecChecked(buf: *[512]u8, conn: *const ToolSshConnection, remote_path: []const u8) ![]const u8 {
    const needed = conn.user().len + 1 + conn.host().len + 1 + remote_path.len;
    if (needed > buf.len) return error.PathTooLong;
    return scp.remoteSpec(buf, conn, remote_path);
}

pub fn copyFile(
    ctx: *ToolContext,
    source_path_in: []const u8,
    source_surface_id: ?[]const u8,
    dest_surface_id: ?[]const u8,
    dest_path_in: ?[]const u8,
    dest_name: ?[]const u8,
) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const source_endpoint = try resolveCopyEndpoint(ctx, source_surface_id);
    if (source_endpoint == .err) return source_endpoint.err;
    const dest_endpoint = try resolveCopyEndpoint(ctx, dest_surface_id);
    if (dest_endpoint == .err) return dest_endpoint.err;

    const source_path = resolveEndpointPath(ctx, source_endpoint, source_path_in) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to resolve source path {s}: {s}", .{ source_path_in, @errorName(err) });
    };
    defer ctx.allocator.free(source_path);

    const dest_path = defaultDestinationPath(ctx, dest_endpoint, source_path, dest_name, dest_path_in) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to resolve destination path: {s}", .{@errorName(err)});
    };
    defer ctx.allocator.free(dest_path);

    switch (source_endpoint) {
        .ssh => |src_remote| {
            if (dest_endpoint == .ssh) return ctx.allocator.dupe(u8, "copy_file does not support SSH-to-SSH copies yet. Pull to local wispterm-files first, then push to the destination SSH surface.");
            const local_dest = localPathForEndpoint(ctx, dest_endpoint, dest_path) catch |err| {
                return std.fmt.allocPrint(ctx.allocator, "Failed to map destination path {s}: {s}", .{ dest_path, @errorName(err) });
            };
            defer ctx.allocator.free(local_dest);
            try ensureLocalParent(local_dest);
            var remote_buf: [512]u8 = undefined;
            const remote_src = remoteSpecChecked(&remote_buf, &src_remote.conn, source_path) catch |err| {
                return std.fmt.allocPrint(ctx.allocator, "Failed to build SSH source path: {s}", .{@errorName(err)});
            };
            const result = scp.transfer(ctx.allocator, &src_remote.conn, remote_src, local_dest);
            if (result != .ok) return std.fmt.allocPrint(ctx.allocator, "Failed to copy SSH file {s} to {s}: {s}", .{ source_path, local_dest, @tagName(result) });
            return std.fmt.allocPrint(ctx.allocator, "copied source=ssh:{s} local_path={s}", .{ source_path, local_dest });
        },
        .local, .wsl => {
            const local_source = localPathForEndpoint(ctx, source_endpoint, source_path) catch |err| {
                return std.fmt.allocPrint(ctx.allocator, "Failed to map source path {s}: {s}", .{ source_path, @errorName(err) });
            };
            defer ctx.allocator.free(local_source);

            switch (dest_endpoint) {
                .ssh => |dst_remote| {
                    var remote_buf: [512]u8 = undefined;
                    const remote_dst = remoteSpecChecked(&remote_buf, &dst_remote.conn, dest_path) catch |err| {
                        return std.fmt.allocPrint(ctx.allocator, "Failed to build SSH destination path: {s}", .{@errorName(err)});
                    };
                    const result = scp.transfer(ctx.allocator, &dst_remote.conn, local_source, remote_dst);
                    if (result != .ok) return std.fmt.allocPrint(ctx.allocator, "Failed to copy local file {s} to SSH {s}: {s}", .{ local_source, dest_path, @tagName(result) });
                    return std.fmt.allocPrint(ctx.allocator, "copied source={s} remote_path={s}", .{ local_source, dest_path });
                },
                .local, .wsl => {
                    const local_dest = localPathForEndpoint(ctx, dest_endpoint, dest_path) catch |err| {
                        return std.fmt.allocPrint(ctx.allocator, "Failed to map destination path {s}: {s}", .{ dest_path, @errorName(err) });
                    };
                    defer ctx.allocator.free(local_dest);
                    const bytes = copyLocalFileStreaming(local_source, local_dest) catch |err| {
                        return std.fmt.allocPrint(ctx.allocator, "Failed to copy {s} to {s}: {s}", .{ local_source, local_dest, @errorName(err) });
                    };
                    return switch (dest_endpoint) {
                        .wsl => std.fmt.allocPrint(ctx.allocator, "copied bytes={d} wsl_path={s} local_path={s}", .{ bytes, dest_path, local_dest }),
                        else => std.fmt.allocPrint(ctx.allocator, "copied bytes={d} local_path={s}", .{ bytes, local_dest }),
                    };
                },
                .err => unreachable,
            }
        },
        .err => unreachable,
    }
}

// ---------------------------------------------------------------------------
// read_file tool
// ---------------------------------------------------------------------------

pub fn readFile(ctx: *ToolContext, path: []const u8, surface_id: ?[]const u8, offset: usize, limit: usize) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const target = try resolveFileTarget(ctx, surface_id);
    if (target == .err) return target.err;
    const resolved = resolveFileTargetPath(ctx, target, path) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to resolve {s}: {s}", .{ path, @errorName(err) });
    };
    defer ctx.allocator.free(resolved);

    const gate = gateForFileTarget(ctx, target, resolved, false);
    if (tool_access.approvalRequired(ctx.settings.permission, gate)) {
        const reason = if (gate.blacklisted) "Reads a protected path - confirm to allow" else "Read file";
        if (!ctx.requestApproval("read_file", resolved, reason)) {
            return tool_output.deniedResult(ctx.allocator, resolved, "operator rejected file read");
        }
    }

    if (target == .remote) {
        const bytes = scp.sshReadFile(ctx.allocator, &target.remote.conn, resolved, agent_file_edit.MAX_FILE_BYTES) orelse
            return std.fmt.allocPrint(ctx.allocator, "Failed to read remote file {s}", .{resolved});
        defer ctx.allocator.free(bytes);
        return renderReadResult(ctx, resolved, bytes, offset, limit);
    }
    const local_path = localPathForFileTarget(ctx, target, resolved) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to map {s}: {s}", .{ resolved, @errorName(err) });
    };
    defer ctx.allocator.free(local_path);
    const bytes = std.fs.cwd().readFileAlloc(ctx.allocator, local_path, agent_file_edit.MAX_FILE_BYTES) catch |err| {
        if (err == error.FileTooBig) {
            return std.fmt.allocPrint(ctx.allocator, "File {s} is too large (>= {d} bytes). Use offset/limit to read a range.", .{ resolved, agent_file_edit.MAX_FILE_BYTES });
        }
        return std.fmt.allocPrint(ctx.allocator, "Failed to read {s}: {s}", .{ resolved, @errorName(err) });
    };
    defer ctx.allocator.free(bytes);
    return renderReadResult(ctx, resolved, bytes, offset, limit);
}

// ---------------------------------------------------------------------------
// write_file tool
// ---------------------------------------------------------------------------

pub fn writeFile(ctx: *ToolContext, path: []const u8, content: []const u8, surface_id: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const target = try resolveFileTarget(ctx, surface_id);
    if (target == .err) return target.err;
    const resolved = resolveFileTargetPath(ctx, target, path) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to resolve {s}: {s}", .{ path, @errorName(err) });
    };
    defer ctx.allocator.free(resolved);
    const gate = gateForFileTarget(ctx, target, resolved, true);

    // Do not disclose a protected file's existing content in the diff.
    var old_content: []u8 = &[_]u8{};
    var owns_old = false;
    defer if (owns_old) ctx.allocator.free(old_content);
    if (!gate.blacklisted) {
        if (target == .remote) {
            if (scp.sshReadFile(ctx.allocator, &target.remote.conn, resolved, agent_file_edit.MAX_FILE_BYTES)) |bytes| {
                old_content = bytes;
                owns_old = true;
            }
        } else {
            const local_path = localPathForFileTarget(ctx, target, resolved) catch null;
            if (local_path) |p| {
                defer ctx.allocator.free(p);
                if (std.fs.cwd().readFileAlloc(ctx.allocator, p, agent_file_edit.MAX_FILE_BYTES)) |bytes| {
                    old_content = bytes;
                    owns_old = true;
                } else |_| {}
            }
        }
    }

    const diff = try agent_file_edit.unifiedDiffAlloc(ctx.allocator, resolved, old_content, content);
    defer ctx.allocator.free(diff);
    ctx.emitNote(diff);

    if (tool_access.approvalRequired(ctx.settings.permission, gate)) {
        const reason = try std.fmt.allocPrint(ctx.allocator, "Write {s}", .{resolved});
        defer ctx.allocator.free(reason);
        if (!ctx.requestApproval("write_file", resolved, reason)) {
            return tool_output.deniedResult(ctx.allocator, resolved, "operator rejected file write");
        }
    }

    if (target == .remote) {
        if (!scp.sshWriteFile(ctx.allocator, &target.remote.conn, resolved, content)) {
            return std.fmt.allocPrint(ctx.allocator, "Failed to write remote file {s}", .{resolved});
        }
    } else {
        const local_path = localPathForFileTarget(ctx, target, resolved) catch |err| {
            return std.fmt.allocPrint(ctx.allocator, "Failed to map {s}: {s}", .{ resolved, @errorName(err) });
        };
        defer ctx.allocator.free(local_path);
        writeLocalFileAtomic(ctx.allocator, local_path, content) catch |err| {
            return std.fmt.allocPrint(ctx.allocator, "Failed to write {s}: {s}", .{ resolved, @errorName(err) });
        };
    }
    return std.fmt.allocPrint(ctx.allocator, "Wrote {d} bytes to {s}", .{ content.len, resolved });
}

// ---------------------------------------------------------------------------
// edit_file tool
// ---------------------------------------------------------------------------

pub fn editFile(ctx: *ToolContext, path: []const u8, old_string: []const u8, new_string: []const u8, replace_all: bool, surface_id: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const target = try resolveFileTarget(ctx, surface_id);
    if (target == .err) return target.err;
    const resolved = resolveFileTargetPath(ctx, target, path) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to resolve {s}: {s}", .{ path, @errorName(err) });
    };
    defer ctx.allocator.free(resolved);

    const gate = gateForFileTarget(ctx, target, resolved, true);
    if (target == .remote) {
        switch (try tryRemoteEditFile(ctx, &target.remote.conn, resolved, old_string, new_string, replace_all, gate)) {
            .done => |out| return out,
            .fallback => {},
        }
    }

    return legacyEditFile(ctx, target, resolved, old_string, new_string, replace_all, gate);
}

const RemoteEditAttempt = union(enum) {
    done: []u8,
    fallback,
};

fn tryRemoteEditFile(
    ctx: *ToolContext,
    conn: *const ToolSshConnection,
    resolved: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
    gate: tool_access.Gate,
) !RemoteEditAttempt {
    var check = scp.sshRemoteEditCheck(ctx.allocator, conn, resolved, old_string, new_string, replace_all, !gate.blacklisted);
    switch (check) {
        .unavailable => return .fallback,
        .edit_error => |msg| return .{ .done = msg },
        .failed => |msg| return .{ .done = msg },
        .ok => |ok| {
            defer check.deinit(ctx.allocator);
            if (gate.blacklisted) {
                const note = try std.fmt.allocPrint(ctx.allocator, "edit_file {s}: protected path - diff hidden ({d} change(s))", .{ resolved, ok.occurrences });
                defer ctx.allocator.free(note);
                ctx.emitNote(note);
            } else {
                ctx.emitNote(ok.diff);
            }

            if (tool_access.approvalRequired(ctx.settings.permission, gate)) {
                const reason = try std.fmt.allocPrint(ctx.allocator, "Edit {s} ({d} change(s))", .{ resolved, ok.occurrences });
                defer ctx.allocator.free(reason);
                if (!ctx.requestApproval("edit_file", resolved, reason)) {
                    return .{ .done = try tool_output.deniedResult(ctx.allocator, resolved, "operator rejected file edit") };
                }
            }

            const apply = scp.sshRemoteEditApply(ctx.allocator, conn, resolved, old_string, new_string, replace_all);
            switch (apply) {
                .unavailable => return .{ .done = try std.fmt.allocPrint(ctx.allocator, "wispterm-filetool disappeared before applying {s}; retry the edit to use the legacy fallback.", .{resolved}) },
                .ok => |occurrences| return .{ .done = try std.fmt.allocPrint(ctx.allocator, "Edited {s} ({d} change(s)).", .{ resolved, occurrences }) },
                .edit_error => |msg| return .{ .done = msg },
                .failed => |msg| return .{ .done = msg },
            }
        },
    }
}

fn legacyEditFile(ctx: *ToolContext, target: FileTarget, resolved: []const u8, old_string: []const u8, new_string: []const u8, replace_all: bool, gate: tool_access.Gate) ![]u8 {
    var old_content: []u8 = undefined;
    if (target == .remote) {
        old_content = scp.sshReadFile(ctx.allocator, &target.remote.conn, resolved, agent_file_edit.MAX_FILE_BYTES) orelse
            return std.fmt.allocPrint(ctx.allocator, "Failed to read remote file {s} for editing", .{resolved});
    } else {
        const local_path = localPathForFileTarget(ctx, target, resolved) catch |err| {
            return std.fmt.allocPrint(ctx.allocator, "Failed to map {s}: {s}", .{ resolved, @errorName(err) });
        };
        defer ctx.allocator.free(local_path);
        old_content = std.fs.cwd().readFileAlloc(ctx.allocator, local_path, agent_file_edit.MAX_FILE_BYTES) catch |err|
            return std.fmt.allocPrint(ctx.allocator, "Failed to read {s}: {s}", .{ resolved, @errorName(err) });
    }
    defer ctx.allocator.free(old_content);

    const outcome = agent_file_edit.applyEdit(ctx.allocator, old_content, old_string, new_string, replace_all) catch |err| {
        return switch (err) {
            error.EmptyOld => ctx.allocator.dupe(u8, "old_string must not be empty."),
            error.NotFound => std.fmt.allocPrint(ctx.allocator, "old_string not found in {s}.", .{resolved}),
            error.NotUnique => std.fmt.allocPrint(ctx.allocator, "old_string is not unique in {s}; pass replace_all=true or add more context.", .{resolved}),
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    defer ctx.allocator.free(outcome.new_content);

    // Do not disclose a protected file's content in the diff; show a redacted note.
    if (gate.blacklisted) {
        const note = try std.fmt.allocPrint(ctx.allocator, "edit_file {s}: protected path - diff hidden ({d} change(s))", .{ resolved, outcome.occurrences });
        defer ctx.allocator.free(note);
        ctx.emitNote(note);
    } else {
        const diff = try agent_file_edit.unifiedDiffAlloc(ctx.allocator, resolved, old_content, outcome.new_content);
        defer ctx.allocator.free(diff);
        ctx.emitNote(diff);
    }

    if (tool_access.approvalRequired(ctx.settings.permission, gate)) {
        const reason = try std.fmt.allocPrint(ctx.allocator, "Edit {s} ({d} change(s))", .{ resolved, outcome.occurrences });
        defer ctx.allocator.free(reason);
        if (!ctx.requestApproval("edit_file", resolved, reason)) {
            return tool_output.deniedResult(ctx.allocator, resolved, "operator rejected file edit");
        }
    }

    if (target == .remote) {
        if (!scp.sshWriteFile(ctx.allocator, &target.remote.conn, resolved, outcome.new_content)) {
            return std.fmt.allocPrint(ctx.allocator, "Failed to write remote file {s}", .{resolved});
        }
    } else {
        const local_path = localPathForFileTarget(ctx, target, resolved) catch |err| {
            return std.fmt.allocPrint(ctx.allocator, "Failed to map {s}: {s}", .{ resolved, @errorName(err) });
        };
        defer ctx.allocator.free(local_path);
        writeLocalFileAtomic(ctx.allocator, local_path, outcome.new_content) catch |err|
            return std.fmt.allocPrint(ctx.allocator, "Failed to write {s}: {s}", .{ resolved, @errorName(err) });
    }
    return std.fmt.allocPrint(ctx.allocator, "Edited {s} ({d} change(s)).", .{ resolved, outcome.occurrences });
}

fn fakeApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}
fn fakeCancelled(_: *anyopaque) bool {
    return false;
}

fn twoSurfaceSnapshotForTest(allocator: std.mem.Allocator) !ToolSnapshot {
    var surfaces = try allocator.alloc(ToolSurface, 2);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "aaa"),
        .title = try allocator.dupe(u8, "shell"),
        .cwd = try allocator.dupe(u8, "/"),
        .snapshot = try allocator.dupe(u8, "$ "),
        .tab_index = 0,
        .focused = false,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    surfaces[1] = .{
        .id = try allocator.dupe(u8, "bbb"),
        .title = try allocator.dupe(u8, "codex"),
        .cwd = try allocator.dupe(u8, "/"),
        .snapshot = try allocator.dupe(u8, "> "),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .codex,
        .agent_state = .none,
        .agent_confidence = 50,
        .ptr = @ptrFromInt(2),
    };
    return .{ .surfaces = surfaces, .active_tab = 0 };
}

test "read_file returns numbered lines for a local file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "r.txt", .data = "one\ntwo\n" });
    const abs = try tmp.dir.realpathAlloc(a, "r.txt");
    defer a.free(abs);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try readFile(&ctx, abs, null, 0, 0);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "     1\tone\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "     2\ttwo\n") != null);
}

test "file tool resolution uses ssh connection carried by the request snapshot" {
    const a = std.testing.allocator;
    const conn = ToolSshConnection.fromParts(.{
        .user = "alice",
        .host = "example.test",
        .port = "2222",
        .proxy_jump = "jump.example.test",
    });
    var surfaces = try a.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = try a.dupe(u8, "ssh-surface"),
        .title = try a.dupe(u8, "SSH"),
        .cwd = try a.dupe(u8, "/home/alice"),
        .snapshot = try a.dupe(u8, "$ "),
        .tab_index = 0,
        .focused = true,
        .is_ssh = true,
        .is_wsl = false,
        .ssh_connection = conn,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    const snapshot = ToolSnapshot{ .surfaces = surfaces, .active_tab = 0 };
    defer snapshot.deinit(a);

    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = snapshot,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const target = try resolveFileTarget(&ctx, "ssh-surface");
    switch (target) {
        .remote => |remote| {
            try std.testing.expectEqualStrings("ssh-surface", remote.surface.id);
            try std.testing.expectEqualStrings("alice", remote.conn.user());
            try std.testing.expectEqualStrings("example.test", remote.conn.host());
            try std.testing.expectEqualStrings("2222", remote.conn.port());
            try std.testing.expectEqualStrings("jump.example.test", remote.conn.proxyJump());
        },
        .err => |msg| {
            defer a.free(msg);
            return error.TestExpectedEqual;
        },
        else => return error.TestExpectedEqual,
    }

    const endpoint = try resolveCopyEndpoint(&ctx, "ssh-surface");
    switch (endpoint) {
        .ssh => |remote| {
            try std.testing.expectEqualStrings("ssh-surface", remote.surface.id);
            try std.testing.expectEqualStrings("alice", remote.conn.user());
            try std.testing.expectEqualStrings("example.test", remote.conn.host());
        },
        .err => |msg| {
            defer a.free(msg);
            return error.TestExpectedEqual;
        },
        else => return error.TestExpectedEqual,
    }
}

test "file tool resolution defaults to the selected WSL surface" {
    const a = std.testing.allocator;
    var surfaces = try a.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = try a.dupe(u8, "wsl-surface"),
        .title = try a.dupe(u8, "WSL"),
        .cwd = try a.dupe(u8, "/data1/home/xzg/test"),
        .snapshot = try a.dupe(u8, "$ "),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = true,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    const snapshot = ToolSnapshot{ .surfaces = surfaces, .active_tab = 0 };
    defer snapshot.deinit(a);

    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = snapshot,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    terminal_tools.setWriteContext(&ctx, "wsl-surface");

    const target = try resolveFileTarget(&ctx, null);
    switch (target) {
        .wsl => |surface| try std.testing.expectEqualStrings("wsl-surface", surface.id),
        else => return error.TestExpectedEqual,
    }
}

test "file tool paths resolve relative to selected remote cwd" {
    const a = std.testing.allocator;
    const conn = ToolSshConnection.fromParts(.{
        .user = "alice",
        .host = "example.test",
        .port = "2222",
    });
    var surfaces = try a.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = try a.dupe(u8, "ssh-surface"),
        .title = try a.dupe(u8, "SSH"),
        .cwd = try a.dupe(u8, "/data1/home/xzg/test"),
        .snapshot = try a.dupe(u8, "$ "),
        .tab_index = 0,
        .focused = true,
        .is_ssh = true,
        .is_wsl = false,
        .ssh_connection = conn,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    const snapshot = ToolSnapshot{ .surfaces = surfaces, .active_tab = 0 };
    defer snapshot.deinit(a);

    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = snapshot,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    terminal_tools.setWriteContext(&ctx, "ssh-surface");

    const target = try resolveFileTarget(&ctx, null);
    const resolved = try resolveFileTargetPath(&ctx, target, "demo.txt");
    defer a.free(resolved);
    try std.testing.expectEqualStrings("/data1/home/xzg/test/demo.txt", resolved);
}

test "write_file creates a local file in full permission mode" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_abs);
    const file_abs = try std.fs.path.join(a, &.{ dir_abs, "w.txt" });
    defer a.free(file_abs);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try writeFile(&ctx, file_abs, "hello\n", null);
    defer a.free(out);
    const written = try tmp.dir.readFileAlloc(a, "w.txt", 1024);
    defer a.free(written);
    try std.testing.expectEqualStrings("hello\n", written);
}

test "write_file can truncate to an empty file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "t.txt", .data = "old content" });
    const abs = try tmp.dir.realpathAlloc(a, "t.txt");
    defer a.free(abs);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try writeFile(&ctx, abs, "", null);
    defer a.free(out);
    const after = try tmp.dir.readFileAlloc(a, "t.txt", 1024);
    defer a.free(after);
    try std.testing.expectEqualStrings("", after);
}

test "edit_file applies a unique replacement to a local file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "e.txt", .data = "alpha\nbeta\ngamma\n" });
    const abs = try tmp.dir.realpathAlloc(a, "e.txt");
    defer a.free(abs);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try editFile(&ctx, abs, "beta", "BETA", false, null);
    defer a.free(out);
    const after = try tmp.dir.readFileAlloc(a, "e.txt", 1024);
    defer a.free(after);
    try std.testing.expectEqualStrings("alpha\nBETA\ngamma\n", after);
}

test "edit_file SSH path tries wispterm-filetool before legacy fallback" {
    const source = @embedFile("files.zig");
    const start = std.mem.indexOf(u8, source, "pub fn editFile") orelse return error.MissingEditFile;
    const body = source[start..];
    const end = std.mem.indexOf(u8, body, "fn fakeApprove") orelse return error.MissingEditFileEnd;
    const edit_body = body[0..end];
    try std.testing.expect(std.mem.indexOf(u8, edit_body, "tryRemoteEditFile") != null);
    try std.testing.expect(std.mem.indexOf(u8, edit_body, "legacyEditFile") != null);
    try std.testing.expect(std.mem.indexOf(u8, edit_body, "sshRemoteEditCheck") != null);
}

test "read_file with an unknown surface_id returns a no-surface error" {
    const a = std.testing.allocator;
    const snapshot = try twoSurfaceSnapshotForTest(a);
    defer snapshot.deinit(a);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = snapshot,
        .settings = .{ .permission = .full, .access_rules = null },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try readFile(&ctx, "/tmp/whatever.txt", "no-such-surface", 0, 0);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "No terminal surface matches") != null);
}
