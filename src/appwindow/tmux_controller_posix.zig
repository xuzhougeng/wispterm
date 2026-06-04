//! tmux control-mode connection driver (Phase 3d, POSIX). Owns the
//! `ssh … tmux -CC` transport PTY and a `TmuxBridge`, and is pumped once per
//! frame from the AppWindow main loop (`tickAll`). Single-threaded by design:
//! the macOS main loop polls events non-blocking and renders continuously, so a
//! per-frame non-blocking drain of the transport keeps tmux output flowing
//! without a reader thread — which matters because the bridge mutates the
//! thread-local tab model and creates `Surface`s, both of which must happen on
//! the main thread.
//!
//! Flow per tick: non-blocking read transport → inject the SSH password on the
//! prompt → `Session.feed` (the bridge's EventSink builds tabs/splits/Surfaces
//! and routes %output to each pane's virtual PTY) → drain pane keystrokes →
//! write queued tmux commands back to the transport.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig");
const Pty = @import("../platform/pty.zig").Pty;
const pty_command = @import("../platform/pty_command.zig");
const layout = @import("../tmux/layout.zig");
const bridge_mod = @import("tmux_bridge.zig");
const tab = @import("tab.zig");
const TmuxBridge = bridge_mod.TmuxBridge;

/// Active controllers for this (main) thread. `start`/`tickAll`/`shutdownAll`
/// all run on the main thread, so a thread-local list needs no synchronization.
threadlocal var g_controllers: std.ArrayListUnmanaged(*TmuxController) = .empty;

const INITIAL_BACKOFF_MS: i64 = 500;
const MAX_BACKOFF_MS: i64 = 5000;

pub const TmuxController = struct {
    alloc: Allocator,
    pty: Pty,
    command: pty_command.Command,
    bridge: *TmuxBridge,
    /// The `ssh … tmux -CC …` command, kept so a dropped transport can be
    /// re-spawned (reconnect). `-A` re-attaches the same server-side session.
    ssh_cmd: []u8,
    /// SSH profile name this session came from, for session_persist re-attach
    /// across app restarts (empty if started without a profile).
    profile_name: []u8,
    password: [256]u8 = undefined,
    password_len: usize = 0,
    password_sent: bool = false,
    /// Accumulates early transport bytes just until the SSH password prompt is
    /// seen, so the prompt is matched even if it arrives split across reads.
    early: [4096]u8 = undefined,
    early_len: usize = 0,
    /// Set once tmux's control-mode handshake (DCS 1000p) is seen. Outbound
    /// commands are held until then — before it, the transport is still ssh
    /// login / password prompt and tmux is not yet listening, so an early
    /// bootstrap write would be lost.
    handshake_seen: bool = false,
    /// Last client size forwarded to tmux, to avoid redundant refresh-client.
    last_cols: u16 = 0,
    last_rows: u16 = 0,
    /// Transport down (ssh/network dropped); retrying with backoff. Tabs and
    /// surfaces are kept; on reconnect the same session re-attaches and the
    /// bridge reuses the surfaces by pane id, so state is preserved.
    reconnecting: bool = false,
    next_retry_ms: i64 = 0,
    backoff_ms: i64 = INITIAL_BACKOFF_MS,

    fn tick(self: *TmuxController, client_cols: u16, client_rows: u16) void {
        if (self.reconnecting) {
            self.tryReconnect();
            return;
        }
        var buf: [16384]u8 = undefined;
        var reads: usize = 0;
        // Cap reads/frame so a noisy pane can't starve rendering.
        while (reads < 64) : (reads += 1) {
            var fds = [1]std.posix.pollfd{.{ .fd = self.pty.master, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 0) catch {
                self.markDisconnected();
                return;
            };
            if (ready == 0) break;
            if (fds[0].revents & std.posix.POLL.IN != 0) {
                const n = std.posix.read(self.pty.master, &buf) catch {
                    self.markDisconnected();
                    return;
                };
                if (n == 0) {
                    self.markDisconnected(); // EOF: transport closed (ssh/tmux gone)
                    return;
                }
                const chunk = buf[0..n];
                self.maybeInjectPassword(chunk);
                if (!self.handshake_seen and std.mem.indexOf(u8, chunk, "\x1bP1000p") != null) {
                    self.handshake_seen = true;
                    self.backoff_ms = INITIAL_BACKOFF_MS; // real connection — reset backoff
                    std.debug.print("tmux: control-mode handshake seen\n", .{});
                }
                self.bridge.session.feed(chunk) catch {};
            } else if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                self.markDisconnected();
                return;
            } else break;
        }

        // Hold all outbound commands until the control-mode handshake; tmux is
        // not listening during ssh login.
        if (!self.handshake_seen) return;

        self.syncSize(client_cols, client_rows);
        self.bridge.panes.pumpKeystrokes(&self.bridge.session) catch {};
        const cmds = self.bridge.session.pendingCommands();
        if (cmds.len > 0) {
            self.pty.writeInput(cmds) catch {};
            self.bridge.session.clearCommands();
        }
    }

    /// Transport dropped: tear down the dead transport (but keep the bridge /
    /// tabs / surfaces) and schedule a reconnect.
    fn markDisconnected(self: *TmuxController) void {
        if (self.reconnecting) return;
        std.debug.print("tmux: transport lost — reconnecting…\n", .{});
        self.command.deinit();
        self.pty.deinit();
        self.handshake_seen = false;
        self.password_sent = false;
        self.early_len = 0;
        self.last_cols = 0;
        self.last_rows = 0;
        self.bridge.session.resetForReconnect();
        self.reconnecting = true;
        self.next_retry_ms = std.time.milliTimestamp() + self.backoff_ms;
    }

    /// Re-spawn the transport when the backoff elapses. On success the read loop
    /// resumes; the list-windows reply reconciles onto the existing surfaces.
    fn tryReconnect(self: *TmuxController) void {
        if (std.time.milliTimestamp() < self.next_retry_ms) return;

        const owned = pty_command.allocCommandLineFromUtf8(self.alloc, self.ssh_cmd) catch {
            self.scheduleRetry();
            return;
        };
        defer pty_command.freeCommandLine(self.alloc, owned);

        var pty = Pty.open(.{ .ws_col = self.bridge.session.cols, .ws_row = self.bridge.session.rows }) catch {
            self.scheduleRetry();
            return;
        };
        var command: pty_command.Command = .{};
        pty.startCommand(&command, pty_command.commandLineFromOwned(owned), null) catch {
            pty.deinit();
            self.scheduleRetry();
            return;
        };

        self.pty = pty;
        self.command = command;
        self.bridge.session.start() catch {}; // re-queue bootstrap (sent post-handshake)
        self.reconnecting = false;
        std.debug.print("tmux: reconnect transport spawned\n", .{});
    }

    fn scheduleRetry(self: *TmuxController) void {
        self.backoff_ms = @min(self.backoff_ms * 2, MAX_BACKOFF_MS);
        self.next_retry_ms = std.time.milliTimestamp() + self.backoff_ms;
    }

    fn maybeInjectPassword(self: *TmuxController, chunk: []const u8) void {
        if (self.password_sent or self.password_len == 0) return;
        const space = self.early.len - self.early_len;
        const take = @min(space, chunk.len);
        @memcpy(self.early[self.early_len..][0..take], chunk[0..take]);
        self.early_len += take;
        if (std.mem.indexOf(u8, self.early[0..self.early_len], "assword") != null) {
            self.pty.writeInput(self.password[0..self.password_len]) catch {};
            self.pty.writeInput("\n") catch {};
            self.password_sent = true;
        }
    }

    /// Forward the tmux client size (WispTerm's content-area cell grid, which
    /// already excludes the sidebar/padding — AppWindow.term_cols/term_rows) so
    /// tmux lays out its panes to fit what WispTerm renders. Works for any pane
    /// count; re-sent only when it changes.
    fn syncSize(self: *TmuxController, cols: u16, rows: u16) void {
        if (cols == 0 or rows == 0) return;
        if (cols == self.last_cols and rows == self.last_rows) return;
        self.last_cols = cols;
        self.last_rows = rows;
        self.bridge.session.resizeClient(cols, rows) catch {};
    }

    fn destroy(self: *TmuxController) void {
        // Closing the transport PTY sends ssh SIGHUP, which detaches (not kills)
        // the remote tmux session — the persistence we want. Skip the transport
        // teardown if we're mid-reconnect (it's already closed).
        if (!self.reconnecting) {
            self.command.deinit();
            self.pty.deinit();
        }
        self.bridge.destroy();
        self.alloc.free(self.ssh_cmd);
        self.alloc.free(self.profile_name);
        self.alloc.destroy(self);
    }

    fn reviveOrFocus(self: *TmuxController) bool {
        self.bridge.pruneDetachedPanes();
        if (self.bridge.focusFirstTab()) return true;
        self.bridge.session.start() catch return false;
        return true;
    }
};

/// Launch `ssh_cmd_utf8` (an `ssh … tmux -CC …` command) in a transport PTY and
/// register a controller for it. `password` (may be empty for key auth) is
/// injected at the SSH prompt. Returns false on any setup failure.
pub fn start(
    alloc: Allocator,
    ssh_cmd_utf8: []const u8,
    password: []const u8,
    profile_name: []const u8,
    cols: u16,
    rows: u16,
    scrollback_limit: u32,
    cursor_style: Config.CursorStyle,
    cursor_blink: bool,
) bool {
    if (profile_name.len > 0) {
        for (g_controllers.items) |controller| {
            if (std.mem.eql(u8, controller.profile_name, profile_name)) {
                if (controller.reviveOrFocus()) {
                    std.debug.print("tmux: profile '{s}' already active; reused controller\n", .{profile_name});
                    return true;
                }
                std.debug.print("tmux: profile '{s}' already active but revive failed\n", .{profile_name});
                return false;
            }
        }
    }

    const owned = pty_command.allocCommandLineFromUtf8(alloc, ssh_cmd_utf8) catch return false;
    defer pty_command.freeCommandLine(alloc, owned);

    std.debug.print("tmux: launching transport: {s}\n", .{ssh_cmd_utf8});
    var pty = Pty.open(.{ .ws_col = cols, .ws_row = rows }) catch return false;
    var command: pty_command.Command = .{};
    // POSIX spawn entry (fork/setsid/exec); populates command.pid for deinit.
    pty.startCommand(&command, pty_command.commandLineFromOwned(owned), null) catch |err| {
        std.debug.print("tmux: startCommand failed: {}\n", .{err});
        pty.deinit();
        return false;
    };

    const bridge = TmuxBridge.create(alloc, cols, rows, scrollback_limit, cursor_style, cursor_blink) catch {
        command.deinit();
        pty.deinit();
        return false;
    };
    // Enqueue the attach bootstrap (refresh-client -C + list-windows); the tick
    // loop writes it to the transport and the list-windows reply builds the tabs.
    bridge.session.start() catch {
        bridge.destroy();
        command.deinit();
        pty.deinit();
        return false;
    };

    const ssh_cmd_dup = alloc.dupe(u8, ssh_cmd_utf8) catch {
        bridge.destroy();
        command.deinit();
        pty.deinit();
        return false;
    };
    const profile_dup = alloc.dupe(u8, profile_name) catch {
        alloc.free(ssh_cmd_dup);
        bridge.destroy();
        command.deinit();
        pty.deinit();
        return false;
    };

    const self = alloc.create(TmuxController) catch {
        alloc.free(profile_dup);
        alloc.free(ssh_cmd_dup);
        bridge.destroy();
        command.deinit();
        pty.deinit();
        return false;
    };
    self.* = .{ .alloc = alloc, .pty = pty, .command = command, .bridge = bridge, .ssh_cmd = ssh_cmd_dup, .profile_name = profile_dup };
    const plen = @min(password.len, self.password.len);
    @memcpy(self.password[0..plen], password[0..plen]);
    self.password_len = plen;

    g_controllers.append(alloc, self) catch {
        self.destroy();
        return false;
    };
    std.debug.print("tmux: controller started ({d} active)\n", .{g_controllers.items.len});
    return true;
}

/// Pump every controller once with the current client cell size (content area,
/// sidebar/padding excluded). Controllers persist across transport drops —
/// they reconnect with backoff rather than being torn down; cleanup is
/// shutdownAll (app quit).
pub fn tickAll(alloc: Allocator, client_cols: u16, client_rows: u16) void {
    _ = alloc;
    for (g_controllers.items) |c| c.tick(client_cols, client_rows);
}

pub fn shutdownAll(alloc: Allocator) void {
    for (g_controllers.items) |c| c.destroy();
    g_controllers.deinit(alloc);
    g_controllers = .empty;
}

pub fn forgetClosedTab(tab_state: *anyopaque) void {
    const t: *tab.TabState = @ptrCast(@alignCast(tab_state));
    for (g_controllers.items) |c| {
        if (c.bridge.forgetTab(t)) return;
    }
}

pub fn anyActive() bool {
    return g_controllers.items.len > 0;
}

/// Unique non-empty SSH profile names of the active tmux controllers, allocated
/// in `alloc` (for session_persist save). Empty slice if none.
pub fn activeProfileNames(alloc: Allocator) []const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (g_controllers.items) |c| {
        if (c.profile_name.len == 0) continue;
        var dup = false;
        for (names.items) |n| {
            if (std.mem.eql(u8, n, c.profile_name)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const copy = alloc.dupe(u8, c.profile_name) catch continue;
        names.append(alloc, copy) catch continue;
    }
    return names.toOwnedSlice(alloc) catch &.{};
}

/// If `surface` is a tmux pane, drive a tmux `split-window` for it (the echoed
/// %layout-change reconciles the new pane) and return true. Returns false if
/// the surface is not a tmux pane, so the caller falls back to a local split.
/// `horizontal` splits side-by-side (`-h`); otherwise stacked (`-v`).
pub fn requestSplit(surface: *anyopaque, horizontal: bool) bool {
    const dir: layout.Dir = if (horizontal) .horizontal else .vertical;
    for (g_controllers.items) |c| {
        if (c.bridge.panes.findIdBySurface(surface)) |pane_id| {
            c.bridge.session.splitPane(pane_id, dir) catch return false;
            return true;
        }
    }
    return false;
}

/// If `surface` is a tmux pane, `kill-pane` it (tmux's %layout-change /
/// %window-close drives removal of the split/tab) and return true.
pub fn requestClosePane(surface: *anyopaque) bool {
    for (g_controllers.items) |c| {
        if (c.bridge.panes.findIdBySurface(surface)) |pane_id| {
            c.bridge.session.killPane(pane_id) catch return false;
            return true;
        }
    }
    return false;
}
