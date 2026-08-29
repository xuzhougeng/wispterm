//! Bidirectional dataset transfer between local disk and SSH.
//!
//! Mirrors Wisp Science `transfer_between_contexts` for local↔SSH: one exact
//! file or directory, no globs, no overwrite, recursive directories via
//! `scp -r`, and staging+rename for local downloads. Ghostty has no agent
//! file-transfer tool; this is a WispTerm agent capability on top of the
//! existing OpenSSH helpers in `src/ssh/scp.zig` (the same path File Explorer
//! uses). `copy_file` stays the small-artifact helper.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const platform_wsl = @import("../platform/wsl.zig");
const platform_pty_command = @import("../platform/pty_command.zig");
const scp = @import("../ssh/scp.zig");
const profile_store = @import("../ssh/profile_store.zig");
const terminal_tools = @import("terminal.zig");
const tool_access = @import("access.zig");

const ToolContext = types.ToolContext;
const ToolSurface = types.ToolSurface;
const SshConnection = types.SshConnection;

const STAGING_PREFIX = ".wispterm-xfer-";

pub const TransferFn = *const fn (
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    src: []const u8,
    dst: []const u8,
    control: *scp.TransferControl,
) scp.TransferResult;

pub const ProbeFn = *const fn (
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    path: []const u8,
) ?scp.RemotePathKind;

pub const ProfileLookupFn = *const fn (allocator: std.mem.Allocator, name: []const u8) ?SshConnection;

pub const Deps = struct {
    transfer_file: TransferFn = scp.transferWithControl,
    transfer_dir: TransferFn = scp.transferDirWithControl,
    probe_remote: ProbeFn = scp.probeRemotePath,
    lookup_profile: ProfileLookupFn = defaultLookupProfile,
};

const SurfaceAccess = enum { read, write };

const Endpoint = union(enum) {
    local,
    wsl: ToolSurface,
    ssh: struct {
        conn: SshConnection,
        surface: ?ToolSurface,
        label: []const u8,
    },
    err: []u8,
};

pub fn containsGlob(path: []const u8) bool {
    return std.mem.indexOfAny(u8, path, "*?[") != null;
}

pub fn hasDotDotComponent(path: []const u8) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

pub fn isFilesystemRoot(path: []const u8) bool {
    if (path.len == 0) return true;
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "\\")) return true;
    if (std.mem.eql(u8, path, "~") or std.mem.eql(u8, path, "~/")) return true;
    if (path.len == 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return true;
    if (path.len == 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) return true;
    return false;
}

pub fn trimTrailingSlashes(path: []const u8) []const u8 {
    if (isFilesystemRoot(path)) return path;
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) {
        const prefix = path[0..end];
        if (isFilesystemRoot(prefix)) break;
        end -= 1;
    }
    return path[0..end];
}

pub fn isExactRemotePath(path: []const u8) bool {
    const trimmed = trimTrailingSlashes(path);
    if (trimmed.len == 0 or containsGlob(trimmed) or hasDotDotComponent(trimmed) or isFilesystemRoot(trimmed)) return false;
    return trimmed[0] == '/' or std.mem.startsWith(u8, trimmed, "~/");
}

pub fn isExactLocalPath(path: []const u8) bool {
    const trimmed = trimTrailingSlashes(path);
    if (trimmed.len == 0 or containsGlob(trimmed) or hasDotDotComponent(trimmed) or isFilesystemRoot(trimmed)) return false;
    return std.fs.path.isAbsolute(trimmed);
}

pub fn itemBasename(path: []const u8) []const u8 {
    const trimmed = trimTrailingSlashes(path);
    var start: usize = 0;
    for (trimmed, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') start = i + 1;
    }
    return trimmed[start..];
}

pub fn stagingLeafName(name: []const u8) ?[]const u8 {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return null;
    return name;
}

pub fn localPathExists(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub const LocalKind = enum { missing, file, directory };

pub fn localPathKind(path: []const u8) LocalKind {
    if (path.len == 0) return .missing;
    var dir = if (std.fs.path.isAbsolute(path))
        std.fs.openDirAbsolute(path, .{}) catch {
            var file = if (std.fs.path.isAbsolute(path))
                std.fs.openFileAbsolute(path, .{}) catch return .missing
            else
                std.fs.cwd().openFile(path, .{}) catch return .missing;
            file.close();
            return .file;
        }
    else
        std.fs.cwd().openDir(path, .{}) catch {
            var file = std.fs.cwd().openFile(path, .{}) catch return .missing;
            file.close();
            return .file;
        };
    dir.close();
    return .directory;
}

fn defaultLookupProfile(allocator: std.mem.Allocator, name: []const u8) ?SshConnection {
    return profile_store.connectionByNameOrHost(allocator, name, false);
}

pub fn run(
    ctx: *ToolContext,
    source_context_id: []const u8,
    source_path_in: []const u8,
    destination_context_id: []const u8,
    destination_path_in: ?[]const u8,
    deps: Deps,
) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const source_path = trimTrailingSlashes(source_path_in);
    if (source_path.len == 0) return ctx.allocator.dupe(u8, "source_path must not be empty.");

    const dest_path_raw = if (destination_path_in) |path| trimTrailingSlashes(path) else null;
    if (dest_path_raw) |path| {
        if (path.len == 0) return ctx.allocator.dupe(u8, "destination_path must not be empty.");
    }

    const source = try resolveEndpoint(ctx, source_context_id, .read, deps);
    if (source == .err) return source.err;
    const dest = try resolveEndpoint(ctx, destination_context_id, .write, deps);
    if (dest == .err) return dest.err;

    return switch (source) {
        .ssh => |src_ssh| switch (dest) {
            .ssh => ctx.allocator.dupe(u8, "transfer_between_contexts does not support SSH-to-SSH copies yet. Download to an exact local path, then upload to the destination server."),
            .local, .wsl => blk: {
                const dest_path = dest_path_raw orelse break :blk ctx.allocator.dupe(u8, "destination_path is required for a local download. Ask the user for an exact new absolute path; do not guess Downloads.");
                if (!isExactRemotePath(source_path)) {
                    break :blk ctx.allocator.dupe(u8, "SSH source_path must be an exact absolute or ~/ path. Globs, '..', and filesystem roots are rejected.");
                }
                if (!isExactLocalPath(dest_path)) {
                    break :blk ctx.allocator.dupe(u8, "Local destination_path must be an exact new absolute path. Globs, relative paths, '..', and filesystem roots are rejected.");
                }
                break :blk downloadToLocal(ctx, src_ssh.conn, src_ssh.label, source_path, dest, dest_path, deps);
            },
            .err => unreachable,
        },
        .local, .wsl => switch (dest) {
            .ssh => |dst_ssh| blk: {
                const dest_path = dest_path_raw orelse break :blk ctx.allocator.dupe(u8, "destination_path is required for an SSH upload. Provide an exact absolute or ~/ remote path.");
                if (!isExactLocalPath(source_path)) {
                    break :blk ctx.allocator.dupe(u8, "Local source_path must be an exact existing absolute path. Globs, relative paths, '..', and filesystem roots are rejected.");
                }
                if (!isExactRemotePath(dest_path)) {
                    break :blk ctx.allocator.dupe(u8, "SSH destination_path must be an exact absolute or ~/ path. Globs, '..', and filesystem roots are rejected.");
                }
                break :blk uploadToSsh(ctx, source, source_path, dst_ssh.conn, dst_ssh.label, dest_path, deps);
            },
            .local, .wsl => ctx.allocator.dupe(u8, "Both ends resolved to the local machine. Use copy_file for a small local artifact, or set one context to an SSH surface/profile."),
            .err => unreachable,
        },
        .err => unreachable,
    };
}

fn resolveEndpoint(ctx: *ToolContext, id: []const u8, access: SurfaceAccess, deps: Deps) !Endpoint {
    if (std.ascii.eqlIgnoreCase(id, "local")) return .local;

    if (ctx.tool_snapshot) |snapshot| {
        if (terminal_tools.resolveSurfaceId(snapshot, id, terminal_tools.selectedWriteContext(ctx))) |surface| {
            return endpointFromSurface(ctx, surface, access);
        }
        for (snapshot.surfaces) |surface| {
            if (std.ascii.eqlIgnoreCase(surface.title, id)) {
                return endpointFromSurface(ctx, surface, access);
            }
        }
        for (snapshot.surfaces) |surface| {
            if (!surface.is_ssh) continue;
            const conn = surface.ssh_connection orelse ctx.sshConnectionForSurface(surface.id);
            if (conn) |ssh_conn| {
                if (std.ascii.eqlIgnoreCase(ssh_conn.host(), id)) {
                    return endpointFromSurface(ctx, surface, access);
                }
            }
        }
    }

    if (deps.lookup_profile(ctx.allocator, id)) |conn| {
        return .{ .ssh = .{ .conn = conn, .surface = null, .label = id } };
    }

    return .{ .err = try std.fmt.allocPrint(
        ctx.allocator,
        "Unknown context '{s}'. Use `local`, an open terminal surface_id from terminal_list, a saved SSH profile name, or that profile's host.",
        .{id},
    ) };
}

fn endpointFromSurface(ctx: *ToolContext, surface: ToolSurface, access: SurfaceAccess) !Endpoint {
    const access_error = switch (access) {
        .read => try terminal_tools.ensureReadAccess(ctx, surface),
        .write => try terminal_tools.ensureWriteAccess(ctx, surface),
    };
    if (access_error) |message| return .{ .err = message };
    if (surface.is_wsl) return .{ .wsl = surface };
    if (!surface.is_ssh) return .local;
    if (surface.ssh_connection) |conn| {
        return .{ .ssh = .{ .conn = conn, .surface = surface, .label = surface.title } };
    }
    if (ctx.sshConnectionForSurface(surface.id)) |conn| {
        return .{ .ssh = .{ .conn = conn, .surface = surface, .label = surface.title } };
    }
    return .{ .err = try std.fmt.allocPrint(ctx.allocator, "Surface {s} is an SSH terminal but its connection is unavailable.", .{surface.id}) };
}

fn localPathForEndpoint(ctx: *ToolContext, endpoint: Endpoint, path: []const u8) ![]u8 {
    return switch (endpoint) {
        .local => ctx.allocator.dupe(u8, path),
        .wsl => wslGuestPathToLocalAlloc(ctx.allocator, path),
        .ssh, .err => unreachable,
    };
}

fn wslGuestPathToLocalAlloc(allocator: std.mem.Allocator, guest_path: []const u8) ![]u8 {
    var native_buf: platform_pty_command.CwdBuffer = undefined;
    var utf8_buf: [4096]u8 = undefined;
    const local = platform_wsl.guestPathToLocalPathUtf8(guest_path, &native_buf, &utf8_buf) orelse return error.WslPathUnavailable;
    return allocator.dupe(u8, local);
}

fn kindLabel(kind: enum { file, directory }) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "directory",
    };
}

fn removePartial(path: []const u8) void {
    if (path.len == 0) return;
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteTreeAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteTree(path) catch {};
    }
}

fn ensureLocalParent(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.fs.cwd().makePath(parent);
    }
}

fn joinParent(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ parent, name });
}

fn remoteSpecChecked(buf: *[512]u8, conn: *const SshConnection, remote_path: []const u8) ![]const u8 {
    const needed = conn.user().len + 1 + conn.host().len + 1 + remote_path.len;
    if (needed > buf.len) return error.PathTooLong;
    return scp.remoteSpec(buf, conn, remote_path);
}

fn transferWithCancel(
    ctx: *ToolContext,
    conn: *const SshConnection,
    src: []const u8,
    dst: []const u8,
    recursive: bool,
    deps: Deps,
) scp.TransferResult {
    var control: scp.TransferControl = .{};
    const Watch = struct {
        ctx: *ToolContext,
        control: *scp.TransferControl,
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(self: *@This()) void {
            while (!self.stop.load(.acquire)) {
                if (self.ctx.isCancelled()) {
                    self.control.cancel();
                    return;
                }
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
    };
    var watch = Watch{ .ctx = ctx, .control = &control };
    const thread = std.Thread.spawn(.{}, Watch.run, .{&watch}) catch {
        return if (recursive)
            deps.transfer_dir(ctx.allocator, conn, src, dst, &control)
        else
            deps.transfer_file(ctx.allocator, conn, src, dst, &control);
    };
    const result = if (recursive)
        deps.transfer_dir(ctx.allocator, conn, src, dst, &control)
    else
        deps.transfer_file(ctx.allocator, conn, src, dst, &control);
    watch.stop.store(true, .release);
    thread.join();
    return result;
}

fn downloadToLocal(
    ctx: *ToolContext,
    conn: SshConnection,
    source_label: []const u8,
    remote_path: []const u8,
    dest_endpoint: Endpoint,
    dest_path_in: []const u8,
    deps: Deps,
) ![]u8 {
    const local_dest = localPathForEndpoint(ctx, dest_endpoint, dest_path_in) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to map destination path {s}: {s}", .{ dest_path_in, @errorName(err) });
    };
    defer ctx.allocator.free(local_dest);

    if (localPathExists(local_dest)) {
        return std.fmt.allocPrint(ctx.allocator, "Local destination already exists: {s}. transfer_between_contexts never overwrites.", .{local_dest});
    }

    const leaf = stagingLeafName(itemBasename(local_dest)) orelse {
        return ctx.allocator.dupe(u8, "destination_path must end in a safe file or directory name.");
    };
    const parent = std.fs.path.dirname(local_dest) orelse {
        return ctx.allocator.dupe(u8, "destination_path has no parent directory.");
    };

    const remote_kind = deps.probe_remote(ctx.allocator, &conn, remote_path) orelse {
        return std.fmt.allocPrint(ctx.allocator, "Failed to probe SSH path {s} on {s}.", .{ remote_path, source_label });
    };
    const recursive = switch (remote_kind) {
        .directory => true,
        .file => false,
        .missing => return std.fmt.allocPrint(ctx.allocator, "SSH source does not exist: {s}", .{remote_path}),
    };
    const kind_name = kindLabel(if (recursive) .directory else .file);

    const gate = switch (dest_endpoint) {
        .local => tool_access.fileGate(ctx, local_dest, true),
        .wsl => tool_access.remoteFileGate(true),
        else => unreachable,
    };
    if (tool_access.approvalRequired(ctx.settings.permission, gate)) {
        const reason = try std.fmt.allocPrint(ctx.allocator, "Download {s} {s}:{s} -> {s}", .{ kind_name, source_label, remote_path, local_dest });
        defer ctx.allocator.free(reason);
        if (!ctx.requestApproval("transfer_between_contexts", local_dest, reason)) {
            return ctx.allocator.dupe(u8, "operator rejected transfer");
        }
    }

    var staging_name_buf: [256]u8 = undefined;
    const staging_leaf = std.fmt.bufPrint(&staging_name_buf, "{s}{s}", .{ STAGING_PREFIX, leaf }) catch {
        return ctx.allocator.dupe(u8, "destination name is too long to stage.");
    };
    const staging = joinParent(ctx.allocator, parent, staging_leaf) catch {
        return ctx.allocator.dupe(u8, "Failed to build staging path.");
    };
    defer ctx.allocator.free(staging);
    if (localPathExists(staging)) removePartial(staging);

    ensureLocalParent(local_dest) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to create destination parent for {s}: {s}", .{ local_dest, @errorName(err) });
    };

    var remote_buf: [512]u8 = undefined;
    const remote_src = remoteSpecChecked(&remote_buf, &conn, remote_path) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to build SSH source path: {s}", .{@errorName(err)});
    };

    const progress = try std.fmt.allocPrint(
        ctx.allocator,
        "Transferring {s} ssh:{s}:{s} -> local:{s}",
        .{ kind_name, source_label, remote_path, local_dest },
    );
    defer ctx.allocator.free(progress);
    ctx.emitProgress(progress);

    const result = transferWithCancel(ctx, &conn, remote_src, staging, recursive, deps);
    if (result != .ok) {
        removePartial(staging);
        if (result == .cancelled or ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
        return std.fmt.allocPrint(ctx.allocator, "Failed to download ssh:{s}:{s} to {s}: {s}", .{ source_label, remote_path, local_dest, @tagName(result) });
    }
    if (ctx.isCancelled()) {
        removePartial(staging);
        return ctx.allocator.dupe(u8, "Canceled.");
    }
    if (!localPathExists(staging)) {
        return std.fmt.allocPrint(ctx.allocator, "Download reported success but staging path is missing: {s}", .{staging});
    }

    std.fs.renameAbsolute(staging, local_dest) catch |err| {
        removePartial(staging);
        return std.fmt.allocPrint(ctx.allocator, "Downloaded into staging but failed to move to {s}: {s}", .{ local_dest, @errorName(err) });
    };

    return std.fmt.allocPrint(
        ctx.allocator,
        "transferred kind={s} source=ssh:{s}:{s} destination=local:{s}",
        .{ kind_name, source_label, remote_path, local_dest },
    );
}

fn uploadToSsh(
    ctx: *ToolContext,
    source_endpoint: Endpoint,
    source_path_in: []const u8,
    conn: SshConnection,
    dest_label: []const u8,
    remote_dest: []const u8,
    deps: Deps,
) ![]u8 {
    const local_source = localPathForEndpoint(ctx, source_endpoint, source_path_in) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to map source path {s}: {s}", .{ source_path_in, @errorName(err) });
    };
    defer ctx.allocator.free(local_source);

    const local_kind = localPathKind(local_source);
    const recursive = switch (local_kind) {
        .directory => true,
        .file => false,
        .missing => return std.fmt.allocPrint(ctx.allocator, "Local source does not exist: {s}", .{local_source}),
    };
    const kind_name = kindLabel(if (recursive) .directory else .file);

    const remote_kind = deps.probe_remote(ctx.allocator, &conn, remote_dest) orelse {
        return std.fmt.allocPrint(ctx.allocator, "Failed to probe SSH path {s} on {s}.", .{ remote_dest, dest_label });
    };
    if (remote_kind != .missing) {
        return std.fmt.allocPrint(ctx.allocator, "SSH destination already exists: {s}. transfer_between_contexts never overwrites.", .{remote_dest});
    }

    const gate = tool_access.remoteFileGate(true);
    if (tool_access.approvalRequired(ctx.settings.permission, gate)) {
        const reason = try std.fmt.allocPrint(ctx.allocator, "Upload {s} {s} -> {s}:{s}", .{ kind_name, local_source, dest_label, remote_dest });
        defer ctx.allocator.free(reason);
        if (!ctx.requestApproval("transfer_between_contexts", remote_dest, reason)) {
            return ctx.allocator.dupe(u8, "operator rejected transfer");
        }
    }

    var remote_buf: [512]u8 = undefined;
    const remote_dst = remoteSpecChecked(&remote_buf, &conn, remote_dest) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to build SSH destination path: {s}", .{@errorName(err)});
    };

    const progress = try std.fmt.allocPrint(
        ctx.allocator,
        "Transferring {s} local:{s} -> ssh:{s}:{s}",
        .{ kind_name, local_source, dest_label, remote_dest },
    );
    defer ctx.allocator.free(progress);
    ctx.emitProgress(progress);

    const result = transferWithCancel(ctx, &conn, local_source, remote_dst, recursive, deps);
    if (result == .cancelled or ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    if (result != .ok) {
        return std.fmt.allocPrint(ctx.allocator, "Failed to upload {s} to ssh:{s}:{s}: {s}", .{ local_source, dest_label, remote_dest, @tagName(result) });
    }
    return std.fmt.allocPrint(
        ctx.allocator,
        "transferred kind={s} source=local:{s} destination=ssh:{s}:{s}",
        .{ kind_name, local_source, dest_label, remote_dest },
    );
}

fn fakeApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}
fn fakeCancelled(_: *anyopaque) bool {
    return false;
}

fn dummyCtx(allocator: std.mem.Allocator, working_dir: ?[]const u8) ToolContext {
    return .{
        .allocator = allocator,
        .ctx = @ptrFromInt(1),
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null, .working_dir = working_dir },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
}

fn lookupCpu(_: std.mem.Allocator, name: []const u8) ?SshConnection {
    if (!std.ascii.eqlIgnoreCase(name, "cpu-box") and !std.ascii.eqlIgnoreCase(name, "10.0.0.9")) return null;
    return SshConnection.fromParts(.{
        .user = "alice",
        .host = "10.0.0.9",
        .port = "22",
    });
}

fn lookupCpuAndGpu(allocator: std.mem.Allocator, name: []const u8) ?SshConnection {
    if (lookupCpu(allocator, name)) |conn| return conn;
    if (!std.ascii.eqlIgnoreCase(name, "gpu-box")) return null;
    return SshConnection.fromParts(.{
        .user = "alice",
        .host = "gpu.example",
        .port = "22",
    });
}

fn probeDir(_: std.mem.Allocator, _: *const SshConnection, _: []const u8) ?scp.RemotePathKind {
    return .directory;
}

fn probeFile(_: std.mem.Allocator, _: *const SshConnection, _: []const u8) ?scp.RemotePathKind {
    return .file;
}

fn probeMissing(_: std.mem.Allocator, _: *const SshConnection, _: []const u8) ?scp.RemotePathKind {
    return .missing;
}

fn unusedTransfer(_: std.mem.Allocator, _: *const SshConnection, _: []const u8, _: []const u8, _: *scp.TransferControl) scp.TransferResult {
    return .failed;
}

fn writeStagingDir(_: std.mem.Allocator, _: *const SshConnection, _: []const u8, dst: []const u8, _: *scp.TransferControl) scp.TransferResult {
    std.fs.cwd().makePath(dst) catch return .failed;
    var dir = std.fs.openDirAbsolute(dst, .{}) catch return .failed;
    defer dir.close();
    dir.writeFile(.{ .sub_path = "hello.txt", .data = "hello" }) catch return .failed;
    return .ok;
}

fn writeStagingFile(_: std.mem.Allocator, _: *const SshConnection, _: []const u8, dst: []const u8, _: *scp.TransferControl) scp.TransferResult {
    if (std.fs.path.dirname(dst)) |parent| {
        if (parent.len > 0) std.fs.cwd().makePath(parent) catch return .failed;
    }
    var file = std.fs.createFileAbsolute(dst, .{}) catch return .failed;
    defer file.close();
    file.writeAll("payload") catch return .failed;
    return .ok;
}

fn succeedUpload(_: std.mem.Allocator, _: *const SshConnection, _: []const u8, _: []const u8, _: *scp.TransferControl) scp.TransferResult {
    return .ok;
}

test "transfer path rules reject globs, roots, and dot-dot" {
    try std.testing.expect(containsGlob("/data/*.tif"));
    try std.testing.expect(hasDotDotComponent("/data/../etc/passwd"));
    try std.testing.expect(isFilesystemRoot("/"));
    try std.testing.expect(isFilesystemRoot("C:\\"));
    try std.testing.expect(isFilesystemRoot("~/"));
    try std.testing.expect(isExactRemotePath("/data6/ofo_data/test_file/osrc"));
    try std.testing.expect(isExactRemotePath("~/workspace/out"));
    try std.testing.expect(!isExactRemotePath("/data/*.tif"));
    try std.testing.expect(!isExactRemotePath("/"));
    try std.testing.expect(!isExactRemotePath("relative/path"));
    if (std.fs.path.isAbsolute("/tmp/osrc")) {
        try std.testing.expect(isExactLocalPath("/tmp/osrc"));
    } else {
        try std.testing.expect(isExactLocalPath("C:\\Users\\me\\Downloads\\osrc"));
    }
    try std.testing.expect(!isExactLocalPath("Downloads/osrc"));
    try std.testing.expectEqualStrings("osrc", itemBasename("/data/osrc/"));
    try std.testing.expectEqualStrings("osrc", stagingLeafName("osrc").?);
    try std.testing.expect(stagingLeafName("..") == null);
}

test "transfer_between_contexts requires a local destination path" {
    const a = std.testing.allocator;
    var ctx = dummyCtx(a, null);
    const out = try run(&ctx, "cpu-box", "/data/osrc", "local", null, .{
        .lookup_profile = lookupCpu,
        .probe_remote = probeDir,
        .transfer_dir = unusedTransfer,
        .transfer_file = unusedTransfer,
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Ask the user") != null);
}

test "transfer_between_contexts rejects SSH-to-SSH" {
    const a = std.testing.allocator;
    var ctx = dummyCtx(a, null);
    const out = try run(&ctx, "cpu-box", "/data/osrc", "gpu-box", "/data/osrc", .{
        .lookup_profile = lookupCpuAndGpu,
        .probe_remote = probeDir,
        .transfer_dir = unusedTransfer,
        .transfer_file = unusedTransfer,
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "SSH-to-SSH") != null);
}

test "transfer_between_contexts rejects local-to-local" {
    const a = std.testing.allocator;
    var ctx = dummyCtx(a, null);
    const out = try run(&ctx, "local", "/tmp/osrc", "local", "/tmp/osrc-copy", .{});
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "local machine") != null);
}

test "transfer_between_contexts rejects an existing local destination" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "osrc", .data = "already" });
    const dest = try tmp.dir.realpathAlloc(a, "osrc");
    defer a.free(dest);

    var ctx = dummyCtx(a, null);
    const out = try run(&ctx, "cpu-box", "/data/osrc", "local", dest, .{
        .lookup_profile = lookupCpu,
        .probe_remote = probeDir,
        .transfer_dir = unusedTransfer,
        .transfer_file = unusedTransfer,
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "already exists") != null);
}

test "transfer_between_contexts downloads a directory through staging then rename" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const dest = try std.fs.path.join(a, &.{ root, "osrc" });
    defer a.free(dest);

    var ctx = dummyCtx(a, root);
    const out = try run(&ctx, "cpu-box", "/data6/ofo_data/test_file/osrc", "local", dest, .{
        .lookup_profile = lookupCpu,
        .probe_remote = probeDir,
        .transfer_dir = writeStagingDir,
        .transfer_file = unusedTransfer,
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "kind=directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, dest) != null);

    const hello = try tmp.dir.readFileAlloc(a, "osrc/hello.txt", 64);
    defer a.free(hello);
    try std.testing.expectEqualStrings("hello", hello);
    const leftover_staging = try std.fs.path.join(a, &.{ root, ".wispterm-xfer-osrc" });
    defer a.free(leftover_staging);
    try std.testing.expect(!localPathExists(leftover_staging));
}

test "transfer_between_contexts downloads a file through staging then rename" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const dest = try std.fs.path.join(a, &.{ root, "counts.tsv" });
    defer a.free(dest);

    var ctx = dummyCtx(a, root);
    const out = try run(&ctx, "cpu-box", "/data/counts.tsv", "local", dest, .{
        .lookup_profile = lookupCpu,
        .probe_remote = probeFile,
        .transfer_file = writeStagingFile,
        .transfer_dir = unusedTransfer,
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "kind=file") != null);
    const body = try tmp.dir.readFileAlloc(a, "counts.tsv", 64);
    defer a.free(body);
    try std.testing.expectEqualStrings("payload", body);
}

test "transfer_between_contexts uploads a local file when the remote dest is missing" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "plot.png", .data = "png" });
    const src = try tmp.dir.realpathAlloc(a, "plot.png");
    defer a.free(src);

    var ctx = dummyCtx(a, null);
    const out = try run(&ctx, "local", src, "cpu-box", "/data/plot.png", .{
        .lookup_profile = lookupCpu,
        .probe_remote = probeMissing,
        .transfer_file = succeedUpload,
        .transfer_dir = unusedTransfer,
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "kind=file") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ssh:cpu-box:/data/plot.png") != null);
}

test "transfer_between_contexts rejects an existing remote destination" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "plot.png", .data = "png" });
    const src = try tmp.dir.realpathAlloc(a, "plot.png");
    defer a.free(src);

    var ctx = dummyCtx(a, null);
    const out = try run(&ctx, "local", src, "cpu-box", "/data/plot.png", .{
        .lookup_profile = lookupCpu,
        .probe_remote = probeFile,
        .transfer_file = unusedTransfer,
        .transfer_dir = unusedTransfer,
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "already exists") != null);
}

test "transfer_between_contexts rejects glob remote sources" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const dest = try std.fs.path.join(a, &.{ root, "out" });
    defer a.free(dest);

    var ctx = dummyCtx(a, root);
    const out = try run(&ctx, "cpu-box", "/data/*.tif", "local", dest, .{
        .lookup_profile = lookupCpu,
        .probe_remote = probeDir,
        .transfer_dir = unusedTransfer,
        .transfer_file = unusedTransfer,
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Globs") != null);
}

test "transfer_between_contexts reports an unknown context" {
    const a = std.testing.allocator;
    var ctx = dummyCtx(a, null);
    const out = try run(&ctx, "no-such-host", "/data/osrc", "local", "/tmp/osrc", .{
        .lookup_profile = lookupCpu,
        .probe_remote = probeDir,
        .transfer_dir = unusedTransfer,
        .transfer_file = unusedTransfer,
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Unknown context") != null);
}
