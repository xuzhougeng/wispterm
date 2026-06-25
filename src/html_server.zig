const std = @import("std");
const builtin = @import("builtin");
const Surface = @import("Surface.zig");
const model = @import("html_server_model.zig");
const ssh_tunnel = @import("ssh_tunnel.zig");
const preview_source = @import("input/preview_source.zig");
const preview_diagnostics = @import("preview_diagnostics.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const platform_process = @import("platform/process.zig");
const platform_remote_file = @import("platform/remote_file.zig");

pub const Error = std.mem.Allocator.Error || error{
    NotHtml,
    CwdUnavailable,
    ServerUnavailable,
    SpawnFailed,
    ServerNotReady,
    TunnelFailed,
    PathTooLong,
};

pub const OpenResult = union(enum) {
    url: []u8,
    err: Error,
};

const MAX_SERVERS = 16;
const READY_TIMEOUT_MS = 8000;
const READY_POLL_NS = 50 * std.time.ns_per_ms;
const MAX_ROOT_BYTES = 1024;
const MAX_SSH_DEST_BYTES = 280;

const NODE_SERVER_SOURCE =
    "const http=require('http'),fs=require('fs'),path=require('path');" ++
    "const root=process.cwd();" ++
    "const types={'.html':'text/html; charset=utf-8','.htm':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'application/javascript; charset=utf-8','.mjs':'application/javascript; charset=utf-8','.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.gif':'image/gif','.svg':'image/svg+xml'};" ++
    "http.createServer((req,res)=>{const u=new URL(req.url,'http://127.0.0.1');let p=path.normalize(path.join(root,decodeURIComponent(u.pathname)));if(!p.startsWith(root)){res.writeHead(403);res.end('forbidden');return;}fs.readFile(p,(e,d)=>{if(e){res.writeHead(404);res.end('not found');return;}res.writeHead(200,{'content-type':types[path.extname(p).toLowerCase()]||'application/octet-stream'});res.end(d);});}).listen(Number(process.argv[1]),'127.0.0.1');";

const LOCAL_CANDIDATES = [_]model.ServerKind{
    .python3,
    .py_launcher_python3,
    .python3_via_python,
    .python2,
    .python2_via_python,
    .node_inline,
    .npx_http_server,
};

const Server = struct {
    child: std.process.Child,
    launch_kind: Surface.LaunchKind,
    kind: model.ServerKind,
    port: u16,
    source_surface_id: [16]u8,
    root_buf: [MAX_ROOT_BYTES]u8 = undefined,
    root_len: usize = 0,
    user_buf: [128]u8 = undefined,
    user_len: usize = 0,
    host_buf: [128]u8 = undefined,
    host_len: usize = 0,
    ssh_port_buf: [16]u8 = undefined,
    ssh_port_len: usize = 0,
    proxy_jump_buf: [128]u8 = undefined,
    proxy_jump_len: usize = 0,

    fn init(child: std.process.Child, launch_kind: Surface.LaunchKind, kind: model.ServerKind, port: u16, root_path: []const u8, surface: *const Surface) ?Server {
        if (root_path.len > MAX_ROOT_BYTES) return null;
        var server: Server = .{
            .child = child,
            .launch_kind = launch_kind,
            .kind = kind,
            .port = port,
            .source_surface_id = surface.remote_id,
        };
        server.root_len = copyBounded(server.root_buf[0..], root_path);
        if (surface.ssh_connection) |conn| {
            server.user_len = copyBounded(server.user_buf[0..], conn.user());
            server.host_len = copyBounded(server.host_buf[0..], conn.host());
            server.ssh_port_len = copyBounded(server.ssh_port_buf[0..], conn.port());
            server.proxy_jump_len = copyBounded(server.proxy_jump_buf[0..], conn.proxyJump());
        }
        return server;
    }

    fn root(self: *const Server) []const u8 {
        return self.root_buf[0..self.root_len];
    }

    fn user(self: *const Server) []const u8 {
        return self.user_buf[0..self.user_len];
    }

    fn host(self: *const Server) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    fn sshPort(self: *const Server) []const u8 {
        return self.ssh_port_buf[0..self.ssh_port_len];
    }

    fn proxyJump(self: *const Server) []const u8 {
        return self.proxy_jump_buf[0..self.proxy_jump_len];
    }

    fn matches(self: *const Server, surface: *const Surface, root_path: []const u8) bool {
        if (self.launch_kind != surface.launch_kind) return false;
        if (!std.mem.eql(u8, self.root(), root_path)) return false;
        if (surface.launch_kind != .ssh) return true;

        const conn = surface.ssh_connection orelse return false;
        return std.mem.eql(u8, self.user(), conn.user()) and
            std.mem.eql(u8, self.host(), conn.host()) and
            std.mem.eql(u8, self.sshPort(), conn.port()) and
            std.mem.eql(u8, self.proxyJump(), conn.proxyJump());
    }
};

threadlocal var g_servers: [MAX_SERVERS]?Server = [_]?Server{null} ** MAX_SERVERS;
threadlocal var g_next_port: u16 = 49152;

pub fn deinit() void {
    stopAll();
}

pub fn stopAll() void {
    for (&g_servers) |*slot| stopServer(slot);
}

pub fn stopForSurfaceId(source_surface_id: *const [16]u8) void {
    for (&g_servers) |*slot| {
        const server = if (slot.*) |*server| server else continue;
        if (surfaceIdsEqual(&server.source_surface_id, source_surface_id)) stopServer(slot);
    }
}

pub fn openForSurface(allocator: std.mem.Allocator, surface: *Surface, path: []const u8, ls_prefix: ?[]const u8) OpenResult {
    if (!model.isHtmlPath(path)) return .{ .err = error.NotHtml };
    preview_diagnostics.debug("html-server", &.{
        .{ .key = "stage", .value = "open" },
        .{ .key = "launch", .value = @tagName(surface.launch_kind) },
        .{ .key = "path", .value = path },
        .{ .key = "ls_prefix", .value = ls_prefix orelse "" },
    });
    const resolved = preview_source.resolveTerminalPreviewPath(allocator, surface, path, ls_prefix) catch |err| {
        preview_diagnostics.debug("html-server", &.{
            .{ .key = "stage", .value = "resolve-failed" },
            .{ .key = "path", .value = path },
            .{ .key = "err", .value = @errorName(err) },
        });
        return .{ .err = if (err == error.CwdUnavailable) error.CwdUnavailable else error.PathTooLong };
    };
    defer allocator.free(resolved);

    const root = dirname(resolved);
    preview_diagnostics.debug("html-server", &.{
        .{ .key = "stage", .value = "resolved" },
        .{ .key = "path", .value = path },
        .{ .key = "resolved", .value = resolved },
        .{ .key = "root", .value = root },
    });
    const file_name = basename(resolved);
    if (file_name.len == 0) return .{ .err = error.PathTooLong };
    const port = ensureServerForSurface(allocator, surface, root, file_name) catch |err| return .{ .err = err };
    var url = localUrlForPath(allocator, port, resolved) catch |err| return .{ .err = err };
    preview_diagnostics.debug("html-server", &.{
        .{ .key = "stage", .value = "local-url" },
        .{ .key = "resolved", .value = resolved },
        .{ .key = "url", .value = url },
    });

    if (surface.launch_kind == .ssh) {
        const tunneled = ssh_tunnel.externalUrlForSurface(allocator, url, surface) orelse {
            preview_diagnostics.debug("html-server", &.{
                .{ .key = "stage", .value = "tunnel-failed" },
                .{ .key = "url", .value = url },
            });
            allocator.free(url);
            return .{ .err = error.TunnelFailed };
        };
        preview_diagnostics.debug("html-server", &.{
            .{ .key = "stage", .value = "tunneled-url" },
            .{ .key = "local", .value = url },
            .{ .key = "external", .value = tunneled },
        });
        allocator.free(url);
        url = tunneled;
    }

    return .{ .url = url };
}

fn ensureServerForSurface(allocator: std.mem.Allocator, surface: *Surface, root: []const u8, file_name: []const u8) Error!u16 {
    if (root.len == 0 or root.len > MAX_ROOT_BYTES) return error.PathTooLong;

    pruneExitedServers();
    if (findReusableServerSlot(allocator, surface, root, file_name)) |server_slot| {
        const port = g_servers[server_slot].?.port;
        var port_buf: [16]u8 = undefined;
        const port_s = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch "";
        preview_diagnostics.debug("html-server", &.{
            .{ .key = "stage", .value = "reuse-server" },
            .{ .key = "launch", .value = @tagName(surface.launch_kind) },
            .{ .key = "root", .value = root },
            .{ .key = "port", .value = port_s },
        });
        stopServersExcept(server_slot);
        return port;
    }

    const slot = firstEmptySlot() orelse return error.ServerUnavailable;
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        const port = reserveServerPort() orelse return error.ServerUnavailable;
        var port_buf: [16]u8 = undefined;
        const port_s = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch "";
        preview_diagnostics.debug("html-server", &.{
            .{ .key = "stage", .value = "spawn-attempt" },
            .{ .key = "launch", .value = @tagName(surface.launch_kind) },
            .{ .key = "root", .value = root },
            .{ .key = "port", .value = port_s },
        });
        const started = spawnReadyServerForSurface(allocator, surface, root, file_name, port) catch |err| {
            preview_diagnostics.debug("html-server", &.{
                .{ .key = "stage", .value = "spawn-attempt-failed" },
                .{ .key = "launch", .value = @tagName(surface.launch_kind) },
                .{ .key = "root", .value = root },
                .{ .key = "port", .value = port_s },
                .{ .key = "err", .value = @errorName(err) },
            });
            if (err == error.ServerUnavailable or err == error.SpawnFailed or err == error.ServerNotReady) continue;
            return err;
        };
        preview_diagnostics.debug("html-server", &.{
            .{ .key = "stage", .value = "spawn-ready" },
            .{ .key = "launch", .value = @tagName(surface.launch_kind) },
            .{ .key = "kind", .value = @tagName(started.kind) },
            .{ .key = "root", .value = root },
            .{ .key = "port", .value = port_s },
        });
        const server = Server.init(started.child, surface.launch_kind, started.kind, port, root, surface) orelse {
            var child = started.child;
            stopChild(&child);
            return error.PathTooLong;
        };
        g_servers[slot] = server;
        stopServersExcept(slot);
        return port;
    }
    return error.ServerNotReady;
}

const StartedServer = struct {
    child: std.process.Child,
    kind: model.ServerKind,
};

fn spawnReadyServerForSurface(allocator: std.mem.Allocator, surface: *Surface, root: []const u8, file_name: []const u8, port: u16) Error!StartedServer {
    return switch (surface.launch_kind) {
        .local => spawnReadyLocal(allocator, root, port),
        .wsl => spawnReadyWsl(allocator, root, port),
        .ssh => spawnReadySsh(allocator, surface, root, file_name, port),
    };
}

fn findReusableServerSlot(allocator: std.mem.Allocator, surface: *Surface, root: []const u8, file_name: []const u8) ?usize {
    for (&g_servers, 0..) |*slot, i| {
        const server = if (slot.*) |*server| server else continue;
        if (!server.matches(surface, root)) continue;
        if (childHasExited(&server.child)) {
            stopServer(slot);
            continue;
        }
        if (!serverReachable(allocator, surface, server, file_name)) {
            stopServer(slot);
            continue;
        }
        return i;
    }
    return null;
}

fn serverReachable(allocator: std.mem.Allocator, surface: *Surface, server: *Server, file_name: []const u8) bool {
    return switch (server.launch_kind) {
        .local, .wsl => canConnectToLocalPort(allocator, "127.0.0.1", server.port),
        .ssh => blk: {
            const conn = surface.ssh_connection orelse break :blk false;
            break :blk remotePortReadyOnce(allocator, &conn, server.kind, server.port, file_name);
        },
    };
}

fn spawnReadyLocal(allocator: std.mem.Allocator, root: []const u8, port: u16) Error!StartedServer {
    if (builtin.os.tag != .windows) {
        const kind = probeLocalPosix(allocator) orelse {
            preview_diagnostics.debug("html-server", &.{
                .{ .key = "stage", .value = "probe-failed" },
                .{ .key = "launch", .value = "local" },
                .{ .key = "root", .value = root },
            });
            return error.ServerUnavailable;
        };
        var child = try spawnLocal(allocator, root, kind, port);
        if (waitForLocalPortReady(allocator, port, &child)) return .{ .child = child, .kind = kind };
        stopChild(&child);
        return error.ServerNotReady;
    }

    for (LOCAL_CANDIDATES) |kind| {
        var child = spawnLocal(allocator, root, kind, port) catch continue;
        if (waitForLocalPortReady(allocator, port, &child)) return .{ .child = child, .kind = kind };
        stopChild(&child);
    }
    return error.ServerUnavailable;
}

fn spawnReadyWsl(allocator: std.mem.Allocator, root: []const u8, port: u16) Error!StartedServer {
    const kind = probeWsl(allocator) orelse {
        preview_diagnostics.debug("html-server", &.{
            .{ .key = "stage", .value = "probe-failed" },
            .{ .key = "launch", .value = "wsl" },
            .{ .key = "root", .value = root },
        });
        return error.ServerUnavailable;
    };
    var child = try spawnWsl(allocator, root, kind, port);
    if (waitForLocalPortReady(allocator, port, &child)) return .{ .child = child, .kind = kind };
    stopChild(&child);
    return error.ServerNotReady;
}

fn spawnReadySsh(allocator: std.mem.Allocator, surface: *Surface, root: []const u8, file_name: []const u8, port: u16) Error!StartedServer {
    const conn = surface.ssh_connection orelse return error.ServerUnavailable;
    const kind = probeSsh(allocator, &conn) orelse {
        preview_diagnostics.debug("html-server", &.{
            .{ .key = "stage", .value = "probe-failed" },
            .{ .key = "launch", .value = "ssh" },
            .{ .key = "root", .value = root },
            .{ .key = "host", .value = conn.host() },
            .{ .key = "port", .value = conn.port() },
        });
        return error.ServerUnavailable;
    };
    var child = try spawnSsh(allocator, &conn, root, kind, port);
    if (waitForRemotePortReady(allocator, &conn, kind, port, file_name, &child)) return .{ .child = child, .kind = kind };
    stopChild(&child);
    return error.ServerNotReady;
}

fn spawnLocal(allocator: std.mem.Allocator, root: []const u8, kind: model.ServerKind, port: u16) Error!std.process.Child {
    var port_buf: [16]u8 = undefined;
    const port_s = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return error.PathTooLong;
    var py2_script: ?[]u8 = null;
    defer if (py2_script) |script| allocator.free(script);

    var argv_buf: [8][]const u8 = undefined;
    const argv = switch (kind) {
        .python3 => blk: {
            argv_buf[0] = "python3";
            argv_buf[1] = "-m";
            argv_buf[2] = "http.server";
            argv_buf[3] = port_s;
            argv_buf[4] = "--bind";
            argv_buf[5] = "127.0.0.1";
            break :blk argv_buf[0..6];
        },
        .py_launcher_python3 => blk: {
            argv_buf[0] = "py";
            argv_buf[1] = "-3";
            argv_buf[2] = "-m";
            argv_buf[3] = "http.server";
            argv_buf[4] = port_s;
            argv_buf[5] = "--bind";
            argv_buf[6] = "127.0.0.1";
            break :blk argv_buf[0..7];
        },
        .python3_via_python => blk: {
            argv_buf[0] = "python";
            argv_buf[1] = "-m";
            argv_buf[2] = "http.server";
            argv_buf[3] = port_s;
            argv_buf[4] = "--bind";
            argv_buf[5] = "127.0.0.1";
            break :blk argv_buf[0..6];
        },
        .python2 => blk: {
            py2_script = try python2CommandAlloc(allocator, port);
            argv_buf[0] = "python2";
            argv_buf[1] = "-c";
            argv_buf[2] = py2_script.?;
            break :blk argv_buf[0..3];
        },
        .python2_via_python => blk: {
            py2_script = try python2CommandAlloc(allocator, port);
            argv_buf[0] = "python";
            argv_buf[1] = "-c";
            argv_buf[2] = py2_script.?;
            break :blk argv_buf[0..3];
        },
        .node_inline => blk: {
            argv_buf[0] = "node";
            argv_buf[1] = "-e";
            argv_buf[2] = NODE_SERVER_SOURCE;
            argv_buf[3] = port_s;
            break :blk argv_buf[0..4];
        },
        .npx_http_server => blk: {
            argv_buf[0] = "npx";
            argv_buf[1] = "--no-install";
            argv_buf[2] = "http-server";
            argv_buf[3] = ".";
            argv_buf[4] = "-a";
            argv_buf[5] = "127.0.0.1";
            argv_buf[6] = "-p";
            argv_buf[7] = port_s;
            break :blk argv_buf[0..8];
        },
    };

    var child = std.process.Child.init(argv, allocator);
    child.cwd = root;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    child.create_no_window = true;
    child.spawn() catch return error.SpawnFailed;
    return child;
}

fn spawnWsl(allocator: std.mem.Allocator, root: []const u8, kind: model.ServerKind, port: u16) Error!std.process.Child {
    const command = try cdExecCommand(allocator, root, kind, port);
    defer allocator.free(command);

    const argv = platform_pty_command.wslExecArgv(command);
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    child.create_no_window = true;
    child.spawn() catch return error.SpawnFailed;
    return child;
}

fn spawnSsh(allocator: std.mem.Allocator, conn: *const Surface.SshConnection, root: []const u8, kind: model.ServerKind, port: u16) Error!std.process.Child {
    const command = try cdExecCommand(allocator, root, kind, port);
    defer allocator.free(command);
    return spawnSshCommand(allocator, conn, command, .Ignore, .Inherit) orelse error.SpawnFailed;
}

fn spawnSshCommand(
    allocator: std.mem.Allocator,
    conn: *const Surface.SshConnection,
    command: []const u8,
    stdout_behavior: std.process.Child.StdIo,
    stderr_behavior: std.process.Child.StdIo,
) ?std.process.Child {
    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |path| allocator.free(path);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.usesPasswordAuth()) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return null;
        env_map = std.process.getEnvMap(allocator) catch return null;
        if (env_map) |*map| {
            platform_process.putSshAskPassEnv(map, askpass_path.?, conn.password()) catch return null;
        }
    }

    var dest_buf: [MAX_SSH_DEST_BYTES]u8 = undefined;
    const dest = sshDestination(&dest_buf, conn) orelse return null;

    var argv_buf: [48][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = platform_pty_command.sshExecutableName();
    argc += 1;
    appendSshOption(&argv_buf, &argc, "StrictHostKeyChecking=accept-new");
    appendSshOption(&argv_buf, &argc, "ConnectTimeout=8");
    appendSshOption(&argv_buf, &argc, "ServerAliveInterval=60");
    appendSshOption(&argv_buf, &argc, "ServerAliveCountMax=3");
    if (conn.usesPasswordAuth()) {
        appendSshOption(&argv_buf, &argc, "PreferredAuthentications=publickey,password,keyboard-interactive");
        appendSshOption(&argv_buf, &argc, "NumberOfPasswordPrompts=1");
    } else {
        appendSshOption(&argv_buf, &argc, "BatchMode=yes");
    }
    if (conn.usesIdentityFile()) {
        argv_buf[argc] = "-i";
        argc += 1;
        argv_buf[argc] = conn.identityFile();
        argc += 1;
    }
    var proxy_opt_buf: [288]u8 = undefined;
    if (conn.proxyJump().len > 0) {
        const opt = std.fmt.bufPrint(&proxy_opt_buf, "ProxyJump={s}", .{conn.proxyJump()}) catch return null;
        appendSshOption(&argv_buf, &argc, opt);
    }
    if (conn.port().len > 0) {
        argv_buf[argc] = "-p";
        argc += 1;
        argv_buf[argc] = conn.port();
        argc += 1;
    }
    argv_buf[argc] = dest;
    argc += 1;
    argv_buf[argc] = command;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = stdout_behavior;
    child.stderr_behavior = stderr_behavior;
    child.create_no_window = true;
    if (env_map) |*map| child.env_map = map;
    child.spawn() catch return null;
    return child;
}

fn cdExecCommand(allocator: std.mem.Allocator, root: []const u8, kind: model.ServerKind, port: u16) Error![]u8 {
    var root_buf: [1024]u8 = undefined;
    const root_expr = platform_remote_file.shellPathExpr(&root_buf, root) orelse return error.PathTooLong;
    const command = serverCommandForKindAlloc(allocator, kind, port) catch return error.OutOfMemory;
    defer allocator.free(command);
    return std.fmt.allocPrint(allocator, "cd {s} && exec {s}", .{ root_expr, command }) catch error.OutOfMemory;
}

fn serverCommandForKindAlloc(allocator: std.mem.Allocator, kind: model.ServerKind, port: u16) ![]u8 {
    return switch (kind) {
        .python3 => std.fmt.allocPrint(allocator, "python3 -m http.server {d} --bind 127.0.0.1", .{port}),
        .py_launcher_python3 => std.fmt.allocPrint(allocator, "py -3 -m http.server {d} --bind 127.0.0.1", .{port}),
        .python3_via_python => std.fmt.allocPrint(allocator, "python -m http.server {d} --bind 127.0.0.1", .{port}),
        .python2 => python2ShellCommandAlloc(allocator, "python2", port),
        .python2_via_python => python2ShellCommandAlloc(allocator, "python", port),
        .node_inline => blk: {
            const source = try shellQuoteAlloc(allocator, NODE_SERVER_SOURCE);
            defer allocator.free(source);
            break :blk try std.fmt.allocPrint(allocator, "node -e {s} {d}", .{ source, port });
        },
        .npx_http_server => std.fmt.allocPrint(allocator, "npx --no-install http-server . -a 127.0.0.1 -p {d}", .{port}),
    };
}

fn python2ShellCommandAlloc(allocator: std.mem.Allocator, executable: []const u8, port: u16) ![]u8 {
    const script = try python2CommandAlloc(allocator, port);
    defer allocator.free(script);
    return std.fmt.allocPrint(allocator, "{s} -c \"{s}\"", .{ executable, script });
}

fn python2CommandAlloc(allocator: std.mem.Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "import SimpleHTTPServer,SocketServer; Handler=SimpleHTTPServer.SimpleHTTPRequestHandler; SocketServer.TCPServer.allow_reuse_address=True; httpd=SocketServer.TCPServer(('127.0.0.1', {d}), Handler); httpd.serve_forever()",
        .{port},
    );
}

fn serverProbeScript() []const u8 {
    return "if command -v python3 >/dev/null 2>&1; then echo python3; exit 0; fi; " ++
        "if command -v python >/dev/null 2>&1; then python - <<'PY'\nimport sys\nprint('python3_via_python' if sys.version_info[0] >= 3 else 'python2_via_python')\nPY\nexit 0; fi; " ++
        "if command -v python2 >/dev/null 2>&1; then echo python2; exit 0; fi; " ++
        "if command -v node >/dev/null 2>&1; then echo node; exit 0; fi; " ++
        "if command -v npx >/dev/null 2>&1 && npx --no-install http-server --version >/dev/null 2>&1; then echo npx_http_server; exit 0; fi; " ++
        "echo none";
}

fn probeLocalPosix(allocator: std.mem.Allocator) ?model.ServerKind {
    var child = std.process.Child.init(&.{ "sh", "-lc", serverProbeScript() }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    child.spawn() catch return null;
    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return null;
    };
    const output = stdout.readToEndAlloc(allocator, 4096) catch {
        _ = child.wait() catch {};
        return null;
    };
    defer allocator.free(output);
    const term = child.wait() catch return null;
    if (!termOk(term)) return null;
    return probeOutputToKind(output);
}

fn probeWsl(allocator: std.mem.Allocator) ?model.ServerKind {
    const output = platform_remote_file.wslExec(allocator, serverProbeScript()) orelse return null;
    defer allocator.free(output);
    return probeOutputToKind(output);
}

fn probeSsh(allocator: std.mem.Allocator, conn: *const Surface.SshConnection) ?model.ServerKind {
    const output = platform_remote_file.sshExecCapture(allocator, conn, serverProbeScript()) catch return null;
    defer allocator.free(output);
    return probeOutputToKind(output);
}

fn probeOutputToKind(output: []const u8) ?model.ServerKind {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "python3")) return .python3;
    if (std.mem.eql(u8, trimmed, "python3_via_python")) return .python3_via_python;
    if (std.mem.eql(u8, trimmed, "python2")) return .python2;
    if (std.mem.eql(u8, trimmed, "python2_via_python")) return .python2_via_python;
    if (std.mem.eql(u8, trimmed, "node")) return .node_inline;
    if (std.mem.eql(u8, trimmed, "npx_http_server")) return .npx_http_server;
    return null;
}

fn localUrlForPath(allocator: std.mem.Allocator, port: u16, path: []const u8) Error![]u8 {
    const name = basename(path);
    if (name.len == 0) return error.PathTooLong;
    return model.buildHttpUrl(allocator, "127.0.0.1", port, name) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn shellQuoteAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (text) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn waitForLocalPortReady(allocator: std.mem.Allocator, port: u16, child: *std.process.Child) bool {
    const deadline = std.time.milliTimestamp() + READY_TIMEOUT_MS;
    while (std.time.milliTimestamp() < deadline) {
        if (canConnectToLocalPort(allocator, "127.0.0.1", port)) return true;
        if (childHasExited(child)) return false;
        std.Thread.sleep(READY_POLL_NS);
    }
    return false;
}

fn waitForRemotePortReady(allocator: std.mem.Allocator, conn: *const Surface.SshConnection, kind: model.ServerKind, port: u16, file_name: []const u8, child: *std.process.Child) bool {
    const deadline = std.time.milliTimestamp() + READY_TIMEOUT_MS;
    while (std.time.milliTimestamp() < deadline) {
        if (remotePortReadyOnce(allocator, conn, kind, port, file_name)) return true;
        if (childHasExited(child)) return false;
        std.Thread.sleep(READY_POLL_NS);
    }
    return false;
}

fn remotePortReadyOnce(allocator: std.mem.Allocator, conn: *const Surface.SshConnection, kind: model.ServerKind, port: u16, file_name: []const u8) bool {
    const command = remoteReadyCommandAlloc(allocator, kind, port, file_name) catch return false;
    defer allocator.free(command);
    var child = spawnSshCommand(allocator, conn, command, .Ignore, .Ignore) orelse return false;
    const term = child.wait() catch return false;
    return termOk(term);
}

fn remoteReadyCommandAlloc(allocator: std.mem.Allocator, kind: model.ServerKind, port: u16, file_name: []const u8) ![]u8 {
    return switch (kind) {
        .python3 => pythonReadyCommandAlloc(allocator, "python3", port, file_name),
        .py_launcher_python3 => pythonReadyCommandAlloc(allocator, "py -3", port, file_name),
        .python3_via_python => pythonReadyCommandAlloc(allocator, "python", port, file_name),
        .python2 => pythonReadyCommandAlloc(allocator, "python2", port, file_name),
        .python2_via_python => pythonReadyCommandAlloc(allocator, "python", port, file_name),
        .node_inline, .npx_http_server => nodeReadyCommandAlloc(allocator, port, file_name),
    };
}

fn pythonReadyCommandAlloc(allocator: std.mem.Allocator, executable: []const u8, port: u16, file_name: []const u8) ![]u8 {
    const encoded = try model.percentEncodeSegment(allocator, file_name);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(
        allocator,
        "{s} - <<'PY'\nimport socket, sys\ntry:\n    s=socket.socket()\n    s.settimeout(1)\n    s.connect(('127.0.0.1', {d}))\n    s.sendall(b'GET /{s} HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\nConnection: close\\r\\n\\r\\n')\n    data=b''\n    while len(data) < 512:\n        chunk=s.recv(512-len(data))\n        if not chunk:\n            break\n        data += chunk\n    s.close()\n    status=data.split(b'\\r\\n',1)[0].split(b'\\n',1)[0]\n    sys.exit(0 if status.startswith(b'HTTP/') and b' 200 ' in status else 1)\nexcept Exception:\n    sys.exit(1)\nPY",
        .{ executable, port, encoded },
    );
}

fn nodeReadyCommandAlloc(allocator: std.mem.Allocator, port: u16, file_name: []const u8) ![]u8 {
    const encoded = try model.percentEncodeSegment(allocator, file_name);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(
        allocator,
        "node -e \"var http=require('http');var req=http.get({{host:'127.0.0.1',port:{d},path:'/{s}',timeout:1000}},function(res){{process.exit(res.statusCode===200?0:1)}});req.on('timeout',function(){{req.destroy();process.exit(1)}});req.on('error',function(){{process.exit(1)}});\"",
        .{ port, encoded },
    );
}

fn canConnectToLocalPort(allocator: std.mem.Allocator, local_host: []const u8, local_port: u16) bool {
    if (std.mem.eql(u8, local_host, "127.0.0.1") or std.mem.eql(u8, local_host, "localhost")) {
        const address = std.net.Address.parseIp4("127.0.0.1", local_port) catch return false;
        var stream = std.net.tcpConnectToAddress(address) catch {
            if (!std.mem.eql(u8, local_host, "localhost")) return false;
            return canConnectToLocalHostName(allocator, local_host, local_port);
        };
        stream.close();
        return true;
    }
    return canConnectToLocalHostName(allocator, local_host, local_port);
}

fn canConnectToLocalHostName(allocator: std.mem.Allocator, local_host: []const u8, local_port: u16) bool {
    var stream = std.net.tcpConnectToHost(allocator, local_host, local_port) catch return false;
    stream.close();
    return true;
}

fn stopServer(slot: *?Server) void {
    if (slot.*) |*server| {
        stopChild(&server.child);
        slot.* = null;
    }
}

fn stopChild(child: *std.process.Child) void {
    if (childHasExited(child)) {
        _ = child.wait() catch {};
    } else {
        _ = child.kill() catch {};
    }
}

fn pruneExitedServers() void {
    for (&g_servers) |*slot| {
        const server = if (slot.*) |*server| server else continue;
        if (childHasExited(&server.child)) stopServer(slot);
    }
}

fn stopServersExcept(keep_slot: usize) void {
    for (&g_servers, 0..) |*slot, i| {
        if (shouldStopServerSlot(i, keep_slot)) stopServer(slot);
    }
}

fn shouldStopServerSlot(slot_index: usize, keep_slot: usize) bool {
    return slot_index != keep_slot;
}

fn surfaceIdsEqual(a: *const [16]u8, b: *const [16]u8) bool {
    return std.mem.eql(u8, a.*[0..], b.*[0..]);
}

fn childHasExited(child: *std.process.Child) bool {
    return switch (platform_process.childExited(child.id, 0)) {
        .running => false,
        .exited, .gone => {
            if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
            return true;
        },
    };
}

fn firstEmptySlot() ?usize {
    for (&g_servers, 0..) |*slot, i| {
        if (slot.* == null) return i;
    }
    return null;
}

fn reserveServerPort() ?u16 {
    var attempts: usize = 0;
    while (attempts < 16_384) : (attempts += 1) {
        const candidate = g_next_port;
        g_next_port = if (g_next_port == 65535) 49152 else g_next_port + 1;
        if (isLocalPortAvailable(candidate)) return candidate;
    }
    return reserveLocalPort();
}

fn reserveLocalPort() ?u16 {
    const address = std.net.Address.parseIp4("127.0.0.1", 0) catch return null;
    var server = address.listen(.{}) catch return null;
    const port = server.listen_address.getPort();
    server.deinit();
    return if (port == 0) null else port;
}

fn isLocalPortAvailable(port: u16) bool {
    const address = std.net.Address.parseIp4("127.0.0.1", port) catch return false;
    var server = address.listen(.{}) catch return false;
    server.deinit();
    return true;
}

fn basename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') start = i + 1;
    }
    return path[start..];
}

fn dirname(path: []const u8) []const u8 {
    var end: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') end = i;
    }
    if (end == 0) return ".";
    return path[0..end];
}

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}

fn sshDestination(buf: *[MAX_SSH_DEST_BYTES]u8, conn: *const Surface.SshConnection) ?[]const u8 {
    const user = conn.user();
    const host = conn.host();
    const len = user.len + 1 + host.len;
    if (len > buf.len) return null;
    @memcpy(buf[0..user.len], user);
    buf[user.len] = '@';
    @memcpy(buf[user.len + 1 ..][0..host.len], host);
    return buf[0..len];
}

fn appendSshOption(argv_buf: *[48][]const u8, argc: *usize, option: []const u8) void {
    argv_buf[argc.*] = "-o";
    argc.* += 1;
    argv_buf[argc.*] = option;
    argc.* += 1;
}

fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

test "html_server: public open API shape stays stable" {
    const info = @typeInfo(@TypeOf(openForSurface)).@"fn";
    try std.testing.expectEqual(@as(usize, 4), info.params.len);
    try std.testing.expect(info.return_type.? == OpenResult);
}

test "html_server: public stop API shape stays stable" {
    const info = @typeInfo(@TypeOf(stopAll)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), info.params.len);
    try std.testing.expect(info.return_type.? == void);
}

test "html_server: public surface stop API shape stays stable" {
    const info = @typeInfo(@TypeOf(stopForSurfaceId)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), info.params.len);
    try std.testing.expect(info.params[0].type.? == *const [16]u8);
    try std.testing.expect(info.return_type.? == void);
}

test "html_server: stale server cleanup keeps the current slot" {
    try std.testing.expect(!shouldStopServerSlot(3, 3));
    try std.testing.expect(shouldStopServerSlot(2, 3));
    try std.testing.expect(shouldStopServerSlot(4, 3));
}

test "html_server: surface ownership compares the full source id" {
    var first = [_]u8{0} ** 16;
    var second = first;
    second[15] = 1;

    try std.testing.expect(surfaceIdsEqual(&first, &first));
    try std.testing.expect(!surfaceIdsEqual(&first, &second));
}

test "html_server: non-html model check rejects markdown" {
    try std.testing.expect(!model.isHtmlPath("README.md"));
    try std.testing.expect(model.isHtmlPath("index.html"));
}

test "html_server: command builder emits python and node server commands" {
    const py3 = try serverCommandForKindAlloc(std.testing.allocator, .python3, 49152);
    defer std.testing.allocator.free(py3);
    try std.testing.expect(std.mem.indexOf(u8, py3, "python3 -m http.server 49152 --bind 127.0.0.1") != null);

    const py2 = try serverCommandForKindAlloc(std.testing.allocator, .python2, 49153);
    defer std.testing.allocator.free(py2);
    try std.testing.expect(std.mem.indexOf(u8, py2, "SimpleHTTPServer") != null);
    try std.testing.expect(std.mem.indexOf(u8, py2, "49153") != null);

    const node = try serverCommandForKindAlloc(std.testing.allocator, .node_inline, 49154);
    defer std.testing.allocator.free(node);
    try std.testing.expect(std.mem.indexOf(u8, node, "node -e") != null);
    try std.testing.expect(std.mem.indexOf(u8, node, "49154") != null);
}

test "html_server: server probe order prefers python before node" {
    const script = serverProbeScript();
    const python3 = std.mem.indexOf(u8, script, "echo python3").?;
    const python = std.mem.indexOf(u8, script, "command -v python ").?;
    const python2 = std.mem.indexOf(u8, script, "command -v python2").?;
    const node = std.mem.indexOf(u8, script, "command -v node").?;
    const npx = std.mem.indexOf(u8, script, "command -v npx").?;
    try std.testing.expect(python3 < python);
    try std.testing.expect(python < python2);
    try std.testing.expect(python2 < node);
    try std.testing.expect(node < npx);
    try std.testing.expectEqual(model.ServerKind.python3, probeOutputToKind("python3\n").?);
    try std.testing.expectEqual(model.ServerKind.node_inline, probeOutputToKind("node\n").?);
    try std.testing.expectEqual(@as(?model.ServerKind, null), probeOutputToKind("none\n"));
}

test "html_server: remote ready probe verifies an HTTP response" {
    const command = try remoteReadyCommandAlloc(std.testing.allocator, .python3, 49152, "report.html");
    defer std.testing.allocator.free(command);

    try std.testing.expect(std.mem.indexOf(u8, command, "GET /report.html HTTP/1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "status.startswith(b'HTTP/')") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "b' 200 ' in status") != null);
}

test "html_server: remote ready probe percent-encodes requested html path" {
    const command = try remoteReadyCommandAlloc(std.testing.allocator, .python3, 49152, "a b#c.html");
    defer std.testing.allocator.free(command);

    try std.testing.expect(std.mem.indexOf(u8, command, "GET /a%20b%23c.html HTTP/1.0") != null);
}
