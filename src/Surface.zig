/// A terminal surface — the core unit of WispTerm.
/// Each Surface is a fully independent terminal session, owning a PTY,
/// terminal state machine, selection, and OSC title state.
///
/// Modeled after Ghostty's `src/Surface.zig`:
/// - Ghostty: Surface owns terminal, PTY, IO thread, renderer thread
/// - WispTerm (Phase 1): Surface owns terminal, PTY, selection, OSC state
///   (IO thread added in Phase 2, renderer stays in main.zig for now)
///
/// TabState in main.zig becomes a thin wrapper: `{ surface: *Surface }`.
const std = @import("std");
const builtin = @import("builtin");
const ghostty_vt = @import("ghostty-vt");
const Pty = @import("pty.zig").Pty;
const Command = @import("Command.zig");
const renderer = @import("renderer.zig");
const termio = @import("termio.zig");
const Config = @import("config.zig");
const Renderer = @import("renderer/Renderer.zig");
const remote = @import("remote_client.zig");
const threading = @import("platform/threading.zig");
const agent_detector = @import("agent_detector.zig");
const window_backend = @import("platform/window_backend.zig");
const sync_output = @import("sync_output.zig");
const notification = @import("notification.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const surface_registry = @import("surface_registry.zig");
const platform_process = @import("platform/process.zig");
const ssh_connection_mod = @import("ssh_connection.zig");
const clipboard_osc52 = @import("clipboard_osc52.zig");

const Surface = @This();
const io_log = std.log.scoped(.surface_io);

// ============================================================================
// Types
// ============================================================================

/// Selection state for text selection.
/// Rows are stored as absolute scrollback positions (viewport offset + screen row)
/// so the selection stays anchored to the text when scrolling.
pub const Selection = struct {
    /// A click can leave an anchor even when there is no visible selection yet.
    has_anchor: bool = false,
    start_col: usize = 0,
    start_row: usize = 0,
    end_col: usize = 0,
    end_row: usize = 0,
    /// Active selections are rendered and copied; anchor-only clicks are not.
    active: bool = false,
};

pub const Operation = enum {
    event_loop,
    pty_read,
    pty_write,
    pty_resize,
    terminal_resize,
    thread_spawn,
    thread_shutdown,
};

pub const IoFailure = struct {
    operation: Operation,
    error_code: anyerror,
    timestamp_ms: i64,
};

pub const ExitReason = enum {
    eof,
    broken_pipe,
    user_closed,
};

pub const ExitInfo = struct {
    reason: ExitReason,
    status: ?Command.Exit = null,
    timestamp_ms: i64,
};

pub const IoState = union(enum) {
    starting,
    running,
    stopping,
    stopped,
    exited: ExitInfo,
    failed: IoFailure,
};

/// OSC parser state machine — handles sequences split across PTY reads.
const OscParseState = enum { ground, esc, osc_num, osc_semi, osc_title };

const ImageOscParseState = enum {
    ground,
    esc,
    /// Swallow tmux/screen title sequences: ESC k <title> ST.
    screen_title,
    /// Saw ESC inside a screen-title sequence; next byte may be '\' (ST).
    screen_title_esc,
    osc_prefix,
    image_osc,
    image_osc_esc,
    image_overflow,
    image_overflow_esc,
    passthrough_osc,
    passthrough_osc_esc,
    /// Waiting for the ';' that follows "7748" in an agent-state OSC.
    agent_osc_prefix,
    /// Collecting the payload bytes of an OSC 7748 agent-state marker.
    agent_osc,
    /// Saw ESC inside an agent_osc payload; next byte should be '\' (ST).
    agent_osc_esc,
    /// Agent OSC payload overflowed the cap; drain until terminator.
    agent_overflow,
    /// Saw ESC inside agent_overflow; next byte should be '\' (ST).
    agent_overflow_esc,
};

const WISPTERM_IMAGE_OSC_PREFIX = "7747;WispTermImage=";
const WISPTERM_IMAGE_OSC_MAX = 16 * 1024;

/// OSC number prefix shared by image (7747) and agent (7748): the bytes "774".
const WISPTERM_PRIVATE_OSC_SHARED = "774";
/// Maximum agent marker payload size (bytes after "7748;"); sequences longer
/// than this are silently discarded via the overflow states.
const WISPTERM_AGENT_OSC_MAX = 256;

/// Coarse launch environment for terminal-side integrations such as path paste.
pub const LaunchKind = platform_pty_command.LaunchKind;

pub const SshConnection = ssh_connection_mod.SshConnection;

// ============================================================================
// VT stream handler — wraps ghostty's readonly handler to intercept bell
// ============================================================================

/// Custom VT stream handler that delegates to the readonly handler but
/// intercepts the bell action to set a flag on the Surface.
/// This keeps bell detection independent from backend-specific PTY behavior
/// and the readonly handler's raw byte handling.
pub const VtHandler = struct {
    /// The inner readonly handler type, obtained via Terminal.vtHandler's return type.
    const InnerHandler = @typeInfo(@TypeOf(ghostty_vt.Terminal.vtHandler)).@"fn".return_type.?;

    inner: InnerHandler,
    surface: *Surface,

    pub fn init(terminal: *ghostty_vt.Terminal, surface: *Surface) VtHandler {
        var inner = terminal.vtHandler();
        // Answer terminal query sequences by writing the reply back to the PTY.
        // This notably includes the Kitty keyboard protocol query (`CSI ? u`):
        // full-screen TUIs (Claude Code, Codex, …) probe for protocol support
        // and, without a reply, conclude it is unsupported and never enable it —
        // leaving Shift+Enter indistinguishable from Enter. See issue #302.
        inner.effects.write_pty = &writePtyResponse;
        return .{
            .inner = inner,
            .surface = surface,
        };
    }

    /// Forward a terminal-generated response (Kitty keyboard query, DSR, mode
    /// reports, …) to the PTY. Invoked on the IO reader thread while parsing
    /// output; `queuePtyWrite` copies the bytes and hands them to the IO writer
    /// thread, so this is safe from here. The owning Surface is recovered from
    /// the handler's terminal pointer, which aliases `&surface.terminal`.
    fn writePtyResponse(handler: *InnerHandler, data: [:0]const u8) void {
        const surface: *Surface = @fieldParentPtr("terminal", handler.terminal);
        surface.queuePtyWrite(data) catch |err| mailbox_log.warn(
            "dropped terminal query reply ({d} bytes): {s}",
            .{ data.len, @errorName(err) },
        );
    }

    pub fn deinit(self: *VtHandler) void {
        self.inner.deinit();
    }

    pub fn vt(
        self: *VtHandler,
        comptime action: ghostty_vt.StreamAction.Tag,
        value: ghostty_vt.StreamAction.Value(action),
    ) void {
        // Bells, notifications, and clipboard writes are staged here on the IO
        // thread and consumed by the main loop's pre-render-gate sweep. Each
        // posts its own wakeup: background-tab output does not wake the UI
        // (its dirty flag stays latched), so these must not rely on it.
        if (action == .bell) {
            self.surface.bell_pending.store(true, .release);
            window_backend.postWakeup();
            return;
        }

        if (action == .show_desktop_notification) {
            notification.ingest(
                &self.surface.notif_queue,
                value.title,
                value.body,
            );
            window_backend.postWakeup();
            return;
        }

        // OSC 52 clipboard writes: ghostty's read-only handler discards these,
        // so we decode the payload here and hand the text to the main thread,
        // which owns the system clipboard.
        if (action == .clipboard_contents) {
            self.surface.ingestClipboardWrite(value.kind, value.data);
            window_backend.postWakeup();
            return;
        }

        const sync_before = self.surface.terminal.modes.get(.synchronized_output);
        const sync_mode_touched = switch (action) {
            .set_mode,
            .reset_mode,
            .restore_mode,
            => value.mode == .synchronized_output,
            else => false,
        };
        self.inner.vt(action, value);
        const sync_after = self.surface.terminal.modes.get(.synchronized_output);
        if (sync_mode_touched or sync_before != sync_after) {
            self.surface.noteSynchronizedOutputMode(sync_after);
        }
    }
};

/// Our custom stream type using the bell-aware handler.
pub const VtStream = ghostty_vt.Stream(VtHandler);

// ============================================================================
// Core state
// ============================================================================

allocator: std.mem.Allocator,
terminal: ghostty_vt.Terminal,
pty: Pty,
command: Command,
selection: Selection,
render_state: renderer.State,
launch_kind: LaunchKind,
ssh_connection: ?SshConnection,
remote_client: ?*remote.Client,
remote_id: [16]u8,

/// Size information for this surface (screen size, cell size, padding).
/// Used by the renderer to position content correctly.
size: renderer.size.Size = .{},

// ============================================================================
// IO threads (Ghostty two-thread architecture: writer + reader)
// ============================================================================

/// Mailbox for sending messages from main thread to IO writer thread.
mailbox: termio.Mailbox,

/// IO writer thread state (xev event loop, coalesce timer, etc.).
/// Heap-allocated so the pointer stays stable when passed to the thread.
io_thread_state: ?*termio.Thread = null,

/// IO writer thread (xev event loop — handles resize, future messages).
io_writer_thread: ?std.Thread = null,

/// IO reader thread (blocking PTY output loop).
io_reader_thread: ?std.Thread = null,

// ============================================================================
// Per-surface renderer (Ghostty architecture)
// ============================================================================

/// Per-surface renderer with its own cell buffers
surface_renderer: Renderer,

/// Dirty flag — set by the IO thread on new PTY output, consumed by the main
/// render loop's event-driven render gate.
dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

/// Deadline state for DEC synchronized output mode (2026).
sync_output_state: sync_output.State = .{},

/// Set when the PTY process has exited.
exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// Thread-safe terminal IO lifecycle. `exited` remains as the cheap legacy
/// stop flag; this carries the reason surfaced to callers and UI.
io_state_mutex: std.Thread.Mutex = .{},
io_state: IoState = .starting,

/// Set while the IO writer thread is resizing PTY and terminal state.
/// The reader thread still drains PTY output during this window, but
/// delays VT parsing until terminal.resize has caught up to the new grid.
resize_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

// ============================================================================
// Bell state
// ============================================================================

/// Set by the IO thread when BEL (0x07) is detected in PTY output.
/// Cleared by the main thread after handling the bell notification.
bell_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// Timestamp of the last bell notification, for rate limiting (100ms like Ghostty).
last_bell_time: i64 = 0,

// ============================================================================
// Desktop notification state (OSC 9 / OSC 777)
// ============================================================================

/// Notifications pushed by the IO reader thread, drained on the main thread.
notif_queue: notification.Queue = .{},

// ============================================================================
// OSC 52 clipboard write state
// ============================================================================

/// Pending OSC 52 clipboard text, decoded by the IO reader thread and drained
/// by the main thread (which owns the platform clipboard). Latest write wins:
/// a new sequence frees and replaces an undrained one. Owned by `allocator`.
clipboard_write_pending: ?[]u8 = null,
clipboard_write_mutex: std.Thread.Mutex = .{},
/// Last delivered notification's content hash + time, for dedup / rate limit.
last_notif_hash: u64 = 0,
last_notif_time: i64 = 0,

/// Bell indicator opacity (0.0 = hidden, 1.0 = fully visible).
/// Fades in when bell fires, fades out on active tab after hold period.
bell_opacity: f32 = 0,

/// Whether the bell indicator should be showing (drives the fade target).
bell_indicator: bool = false,

/// Timestamp (ms) when the bell indicator was activated, for the 1s hold on active tabs.
bell_indicator_time: i64 = 0,

// ============================================================================
// Scrollbar state (per-surface, macOS-style overlay with fade)
// ============================================================================

scrollbar_opacity: f32 = 0,
scrollbar_show_time: i64 = 0,

// Per-surface resize overlay state (for divider dragging)
resize_overlay_active: bool = false, // Whether to show resize overlay on this surface
resize_overlay_last_cols: u16 = 0, // Last known cols (to detect changes)
resize_overlay_last_rows: u16 = 0, // Last known rows (to detect changes)

// ============================================================================
// Reference counting (for split tree mutations)
// ============================================================================

/// Reference count for split tree management. When a surface is added to
/// a split tree, it gets ref'd. When removed, it gets unref'd. When the
/// ref count reaches 0, the surface is destroyed.
ref_count: u32 = 1,

// ============================================================================
// OSC title fields
// ============================================================================

window_title: [256]u8 = undefined,
window_title_len: usize = 0,

/// User-set title override. When set, this takes priority over automatic titles.
/// Set via double-click on tab or keyboard shortcut. Clear by setting len to 0.
title_override: [256]u8 = undefined,
title_override_len: usize = 0,
osc_state: OscParseState = .ground,
osc_is_title: bool = false,
osc_num: u8 = 0,
osc_buf: [512]u8 = undefined,
osc_buf_len: usize = 0,
osc7_title: [256]u8 = undefined,
osc7_title_len: usize = 0,
got_osc7_this_batch: bool = false,

wispterm_image_osc_state: ImageOscParseState = .ground,
wispterm_image_osc_buf: std.ArrayListUnmanaged(u8) = .empty,

/// Fixed-size payload buffer for OSC 7748 agent-state markers. Sized to
/// WISPTERM_AGENT_OSC_MAX; no heap allocation needed for these small sequences.
wispterm_agent_osc_buf: [WISPTERM_AGENT_OSC_MAX]u8 = undefined,
wispterm_agent_osc_buf_len: usize = 0,

/// True once this surface has received an authoritative OSC 7748 agent-state
/// marker. Reset when the foreground command is no longer a known agent.
agent_osc_active: bool = false,

// Raw CWD path from OSC 7 (Unix-style, e.g., "/home/user/dir")
cwd_path: [512]u8 = undefined,
cwd_path_len: usize = 0,

// Platform launch CWD. Used as a fallback for shells that do not emit OSC 7.
initial_cwd_path: [512]u8 = undefined,
initial_cwd_path_len: usize = 0,

// Lightweight app/agent state. State transitions come from OSC 7748 hook
// markers; app identity may also be seeded from the foreground command.
agent_detection: agent_detector.Detection = .{},

// ============================================================================
// VT stream
// ============================================================================

/// Persistent VT stream for terminal output. This must live across PTY reads so
/// split UTF-8 sequences and escape sequences keep their parser state.
vt_stream: VtStream,

fn initVtStream(self: *Surface) VtStream {
    return VtStream.initAlloc(
        self.terminal.screens.active.alloc,
        VtHandler.init(&self.terminal, self),
    );
}

// ============================================================================
// Lifecycle
// ============================================================================

/// Initialize a new Surface with its own PTY and terminal.
/// If cwd is provided, the shell will start in that directory.
pub fn init(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    shell_cmd: platform_pty_command.CommandLine,
    scrollback_limit: u32,
    cursor_style: Config.CursorStyle,
    cursor_blink: bool,
    cwd: platform_pty_command.Cwd,
) !*Surface {
    const surface = try allocator.create(Surface);
    errdefer allocator.destroy(surface);

    // Initialize terminal
    surface.terminal = ghostty_vt.Terminal.init(allocator, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = scrollback_limit,
        .default_modes = .{ .grapheme_cluster = true },
        .kitty_image_storage_limit = 50 * 1024 * 1024,
        .kitty_image_loading_limits = .all,
    }) catch |err| {
        return err;
    };
    errdefer surface.terminal.deinit(allocator);

    // Set cursor style/blink from config
    surface.terminal.screens.active.cursor.cursor_style = switch (cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    surface.terminal.modes.set(.cursor_blinking, cursor_blink);

    // Open PTY, then ask the PTY backend to attach the child process.
    // Cleanup on any later failure is handled exclusively by errdefer; catch
    // blocks must NOT also deinit manually or resources get torn down twice
    // (double ClosePseudoConsole/CloseHandle = heap corruption on Windows; see
    // issue #65, where a missing PowerShell made command.start fail).
    surface.pty = try Pty.open(.{ .ws_col = cols, .ws_row = rows });
    errdefer surface.pty.deinit();

    surface.command = .{};
    try surface.command.start(&surface.pty, shell_cmd, cwd);
    errdefer surface.command.deinit();

    return finishInit(surface, allocator, cols, rows, platform_pty_command.launchKindForCommand(shell_cmd), cwd);
}

/// Shared constructor tail for `init` (real PTY + child) and `initVirtual`
/// (virtual PTY, no child). The terminal, `pty`, and `command` are already set
/// up by the caller (with their `errdefer`s); this initializes every remaining
/// field and spawns the IO threads. `launch_kind`/`cwd` differ per caller.
fn finishInit(
    surface: *Surface,
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    launch_kind: LaunchKind,
    cwd: platform_pty_command.Cwd,
) !*Surface {
    // Init remaining fields
    surface.allocator = allocator;
    surface.selection = .{};
    surface.render_state = renderer.State.init(&surface.terminal);
    surface.launch_kind = launch_kind;
    surface.ssh_connection = null;
    surface.remote_client = null;
    remote.nextSurfaceId(&surface.remote_id);
    surface.vt_stream = surface.initVtStream();
    errdefer surface.vt_stream.deinit();
    surface.dirty = std.atomic.Value(bool).init(true);
    surface.sync_output_state = .{};
    surface.exited = std.atomic.Value(bool).init(false);
    surface.io_state_mutex = .{};
    surface.io_state = .starting;
    surface.resize_in_progress = std.atomic.Value(bool).init(false);

    // Desktop-notification state. `allocator.create` returns undefined memory
    // and this constructor initializes every field explicitly (struct-default
    // values are NOT applied here), so these must be set or notif_queue's mutex
    // is garbage — the first handleNotification()/Queue.pop() lock then aborts
    // with os_unfair_lock corruption (SIGKILL on the first frame).
    surface.notif_queue = .{};
    surface.last_notif_hash = 0;
    surface.last_notif_time = 0;

    // OSC 52 clipboard write state. Same caveat as notif_queue above: the mutex
    // must be explicitly initialized or its first lock corrupts on garbage memory.
    surface.clipboard_write_pending = null;
    surface.clipboard_write_mutex = .{};

    // Initialize mailbox for main thread → IO writer communication
    surface.mailbox = try termio.Mailbox.init();
    errdefer surface.mailbox.deinit();
    surface.io_thread_state = null;
    surface.io_writer_thread = null;
    surface.io_reader_thread = null;

    // Initialize grid size to match terminal dimensions.
    // This prevents spurious resize on first render when computeSplitLayout
    // calls setScreenSize - without this, the default 80x24 would differ from
    // the actual terminal dimensions, triggering a resize that can corrupt
    // terminal state if the shell has already output content.
    surface.size.grid.cols = cols;
    surface.size.grid.rows = rows;

    // Initialize per-surface renderer (Ghostty architecture)
    surface.surface_renderer = Renderer.init(surface);

    // Init OSC state
    surface.window_title_len = 0;
    surface.title_override_len = 0;
    surface.osc_state = .ground;
    surface.osc_is_title = false;
    surface.osc_num = 0;
    surface.osc_buf_len = 0;
    surface.osc7_title_len = 0;
    surface.got_osc7_this_batch = false;
    surface.wispterm_image_osc_state = .ground;
    surface.wispterm_image_osc_buf = .empty;
    surface.wispterm_agent_osc_buf_len = 0;
    surface.agent_osc_active = false;
    surface.cwd_path_len = 0;
    surface.initial_cwd_path_len = 0;
    surface.agent_detection = .{};
    surface.captureInitialCwd(cwd);

    // Init bell state
    surface.bell_pending = std.atomic.Value(bool).init(false);
    surface.last_bell_time = 0;
    surface.bell_opacity = 0;
    surface.bell_indicator = false;
    surface.bell_indicator_time = 0;

    // Init scrollbar state
    surface.scrollbar_opacity = 0;
    surface.scrollbar_show_time = 0;

    // Init ref count (for split tree ownership)
    surface.ref_count = 1;

    // Initialize IO writer thread state (xev loop, async handles)
    const thread_state = try allocator.create(termio.Thread);
    errdefer allocator.destroy(thread_state);
    thread_state.* = try termio.Thread.init();
    errdefer thread_state.deinit();
    surface.io_thread_state = thread_state;

    // Spawn IO writer thread (xev event loop — handles resize, future messages)
    surface.io_writer_thread = std.Thread.spawn(threading.surface_thread_spawn_config, termio.Thread.threadMain, .{ thread_state, surface }) catch |err| {
        std.debug.print("Failed to spawn IO writer thread: {}\n", .{err});
        surface.failIo(.thread_spawn, err);
        return err;
    };
    errdefer {
        // Stop the writer thread before any deeper cleanup runs.
        if (surface.io_thread_state) |st| st.stop.notify() catch {};
        if (surface.io_writer_thread) |t| t.join();
    }

    // Spawn IO reader thread (blocking PTY output loop)
    surface.io_reader_thread = std.Thread.spawn(threading.surface_thread_spawn_config, termio.ReadThread.threadMain, .{surface}) catch |err| {
        std.debug.print("Failed to spawn IO reader thread: {}\n", .{err});
        surface.failIo(.thread_spawn, err);
        return err;
    };

    surface.setIoRunning();

    // The renderer thread is kept as a future integration point, but the actual
    // snapshot/rebuild path still runs on the main thread today. Starting it now
    // only adds an idle per-surface thread and stack without moving work off the
    // main render loop.

    // Last step (after every fallible init step): the agent request worker may
    // only touch this surface while it stays registered.
    surface_registry.register(surface, surface.remote_id[0..]);

    return surface;
}

/// Build a Surface around a pre-opened *virtual* PTY (`Pty.openVirtual`).
/// Used for tmux control-mode panes: there is no child process — the Phase 2
/// controller feeds pane output into the PTY and reads keystrokes back across
/// the pair's controller side. The caller retains that controller (typically
/// in a `tmux/pane.zig` PaneMap); this Surface owns only the `pty` end.
///
/// `command` is left as `.{}` (pid -1): its `wait()` reports "still running"
/// and its `deinit()` is a no-op, so the no-child pane never looks "exited"
/// until its controller is closed (which gives the reader an EOF).
pub fn initVirtual(
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    pty: Pty,
    scrollback_limit: u32,
    cursor_style: Config.CursorStyle,
    cursor_blink: bool,
) !*Surface {
    const surface = try allocator.create(Surface);
    errdefer allocator.destroy(surface);

    surface.terminal = ghostty_vt.Terminal.init(allocator, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = scrollback_limit,
        .default_modes = .{ .grapheme_cluster = true },
        .kitty_image_storage_limit = 50 * 1024 * 1024,
        .kitty_image_loading_limits = .all,
    }) catch |err| {
        return err;
    };
    errdefer surface.terminal.deinit(allocator);

    surface.terminal.screens.active.cursor.cursor_style = switch (cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    surface.terminal.modes.set(.cursor_blinking, cursor_blink);

    // Adopt the caller's virtual PTY; no child process is launched.
    surface.pty = pty;
    errdefer surface.pty.deinit();
    surface.command = .{};
    errdefer surface.command.deinit();

    return finishInit(surface, allocator, cols, rows, .ssh, null);
}

/// Deinitialize and free a Surface.
/// Stops the IO thread first, then cleans up PTY and terminal.
pub fn deinit(self: *Surface, allocator: std.mem.Allocator) void {
    // 0. Withdraw the surface from the agent-tool liveness registry. This
    // blocks until any in-flight guarded access on the agent request worker
    // finishes, so nothing below can tear state out from under it.
    surface_registry.unregister(self);

    // 1. Release renderer-owned CPU buffers.
    self.surface_renderer.deinit();

    if (self.remote_client) |client| {
        client.unregisterSurface(self.remote_id);
    }

    // 2. Signal both IO threads to stop.
    self.beginStopping();

    // Stop the writer thread (xev event loop) via its stop async
    if (self.io_thread_state) |state| {
        state.stop.notify() catch {};
    }

    // Cancel the reader thread's blocking PTY output read.
    self.pty.cancelOutputRead();

    // Join both threads
    if (self.io_writer_thread) |thread| {
        thread.join();
        self.io_writer_thread = null;
    }
    if (self.io_reader_thread) |thread| {
        thread.join();
        self.io_reader_thread = null;
    }
    self.markStopped();
    self.remote_client = null;

    // Clean up writer thread state and mailbox
    if (self.io_thread_state) |state| {
        state.deinit();
        self.allocator.destroy(state);
        self.io_thread_state = null;
    }
    self.mailbox.deinit();

    // 3. Now safe to tear down everything — no other thread is accessing.
    if (self.clipboard_write_pending) |pending| {
        self.allocator.free(pending);
        self.clipboard_write_pending = null;
    }
    self.wispterm_image_osc_buf.deinit(allocator);
    self.vt_stream.deinit();
    self.command.deinit();
    self.pty.deinit();
    self.terminal.deinit(allocator);
    allocator.destroy(self);
}

/// Increase the reference count of this surface.
/// Used by SplitTree when a surface is added to a new tree.
pub fn ref(self: *Surface) *Surface {
    self.ref_count += 1;
    return self;
}

/// Decrease the reference count of this surface.
/// When the count reaches 0, the surface is destroyed.
/// Used by SplitTree when a surface is removed from a tree.
pub fn unref(self: *Surface, allocator: std.mem.Allocator) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        self.deinit(allocator);
    }
}

pub fn setSshConnection(
    self: *Surface,
    user: []const u8,
    host: []const u8,
    port: []const u8,
    password: []const u8,
    proxy_jump: []const u8,
    password_auth: bool,
    legacy_algorithms: bool,
) void {
    var conn = SshConnection.fromParts(.{
        .user = user,
        .host = host,
        .port = port,
        .password = password,
        .proxy_jump = proxy_jump,
        .auth_method = if (password_auth) .password else .credentials,
    });
    conn.legacy_algorithms = legacy_algorithms;
    self.setSshConnectionValue(conn);
}

pub fn setSshConnectionValue(self: *Surface, conn: SshConnection) void {
    self.launch_kind = .ssh;
    self.ssh_connection = conn;
}

pub fn currentIoState(self: *Surface) IoState {
    self.io_state_mutex.lock();
    defer self.io_state_mutex.unlock();
    return self.io_state;
}

pub fn acceptsInput(self: *Surface) bool {
    return switch (self.currentIoState()) {
        .running => true,
        else => false,
    };
}

fn setIoRunning(self: *Surface) void {
    self.io_state_mutex.lock();
    defer self.io_state_mutex.unlock();
    if (self.io_state == .starting) self.io_state = .running;
}

pub fn beginStopping(self: *Surface) void {
    self.io_state_mutex.lock();
    defer self.io_state_mutex.unlock();
    switch (self.io_state) {
        .failed, .exited, .stopped => {},
        else => self.io_state = .stopping,
    }
    self.exited.store(true, .release);
}

pub fn markStopped(self: *Surface) void {
    self.io_state_mutex.lock();
    defer self.io_state_mutex.unlock();
    switch (self.io_state) {
        .failed, .exited, .stopped => {},
        else => self.io_state = .stopped,
    }
}

pub fn pollExitStatus(self: *Surface) ?Command.Exit {
    return self.command.wait(false) catch |err| {
        io_log.warn("process exit poll failed err={s}", .{@errorName(err)});
        return null;
    };
}

pub fn markExited(self: *Surface, reason: ExitReason, status: ?Command.Exit) void {
    const info: ExitInfo = .{
        .reason = reason,
        .status = status,
        .timestamp_ms = std.time.milliTimestamp(),
    };
    var should_notify = false;

    self.io_state_mutex.lock();
    switch (self.io_state) {
        .failed, .exited, .stopped => {},
        .stopping => self.io_state = .stopped,
        else => {
            self.io_state = .{ .exited = info };
            should_notify = true;
        },
    }
    self.exited.store(true, .release);
    self.io_state_mutex.unlock();

    if (!should_notify) return;
    io_log.info("surface io exited reason={s}", .{@tagName(reason)});
    self.requestWriterStop();
    self.paintIoStatus(.{ .exited = info });
    window_backend.postWakeup();
}

pub fn failIo(self: *Surface, operation: Operation, err: anyerror) void {
    const failure: IoFailure = .{
        .operation = operation,
        .error_code = err,
        .timestamp_ms = std.time.milliTimestamp(),
    };
    var should_notify = false;

    self.io_state_mutex.lock();
    switch (self.io_state) {
        .failed, .exited, .stopped => {},
        else => {
            self.io_state = .{ .failed = failure };
            should_notify = true;
        },
    }
    self.exited.store(true, .release);
    self.io_state_mutex.unlock();

    if (!should_notify) return;
    if (builtin.is_test) {
        io_log.warn("surface io failed operation={s} err={s}", .{ @tagName(operation), @errorName(err) });
    } else {
        io_log.err("surface io failed operation={s} err={s}", .{ @tagName(operation), @errorName(err) });
    }
    self.requestWriterStop();
    if (self.io_reader_thread != null) self.pty.cancelOutputRead();
    self.paintIoStatus(.{ .failed = failure });
    window_backend.postWakeup();
}

fn requestWriterStop(self: *Surface) void {
    if (self.io_thread_state) |state| {
        state.stop.notify() catch |err| {
            io_log.warn("failed to notify io writer stop err={s}", .{@errorName(err)});
        };
    }
}

fn paintIoStatus(self: *Surface, state: IoState) void {
    self.render_state.mutex.lock();
    defer self.render_state.mutex.unlock();

    var buf: [256]u8 = undefined;
    const message = switch (state) {
        .failed => |failure| std.fmt.bufPrint(
            &buf,
            "\r\n[WispTerm] Terminal IO failed during {s}: {s}\r\n",
            .{ @tagName(failure.operation), @errorName(failure.error_code) },
        ) catch return,
        .exited => |info| exited: {
            if (info.status) |status| switch (status) {
                .exited => |code| break :exited std.fmt.bufPrint(
                    &buf,
                    "\r\n[WispTerm] Process exited with code {d}.\r\n",
                    .{code},
                ) catch return,
                .unknown => {},
            };
            break :exited std.fmt.bufPrint(&buf, "\r\n[WispTerm] Process exited.\r\n", .{}) catch return;
        },
        else => return,
    };

    self.terminal.printString(message) catch |err| {
        io_log.warn("failed to paint io status err={s}", .{@errorName(err)});
        return;
    };
    self.clearSynchronizedOutputLocked();
}

// ============================================================================
// Size and Resize
// ============================================================================

pub const ResizePolicy = enum {
    coalesced,
    immediate,
};

/// Update the surface size and queue a resize to the IO thread if needed.
/// This is called by the split layout computation to set each surface
/// to its correct dimensions based on the split geometry.
///
/// The main thread updates pixel/grid dimensions in surface.size (needed
/// for layout/rendering), but the actual PTY + terminal resize happens
/// on the IO thread via queueIo() with 25ms coalescing.
///
/// Returns true if the grid dimensions changed (resize was queued).
pub fn setScreenSizeWithPolicy(
    self: *Surface,
    screen_width: u32,
    screen_height: u32,
    cell_width: f32,
    cell_height: f32,
    explicit_padding: renderer.size.Padding,
    resize_policy: ResizePolicy,
) bool {
    // Update screen size
    self.size.screen.width = screen_width;
    self.size.screen.height = screen_height;
    self.size.cell.width = cell_width;
    self.size.cell.height = cell_height;

    // Store explicit padding (used for rendering offset)
    self.size.padding = explicit_padding;

    // Compute grid size from available space (screen minus padding)
    const avail_width = screen_width -| explicit_padding.left -| explicit_padding.right;
    const avail_height = screen_height -| explicit_padding.top -| explicit_padding.bottom;

    const new_cols: u16 = if (avail_width > 0 and cell_width > 0)
        @intFromFloat(@max(1, @as(f32, @floatFromInt(avail_width)) / cell_width))
    else
        1;
    const new_rows: u16 = if (avail_height > 0 and cell_height > 0)
        @intFromFloat(@max(1, @as(f32, @floatFromInt(avail_height)) / cell_height))
    else
        1;

    const changed = (self.size.grid.cols != new_cols or self.size.grid.rows != new_rows);
    self.size.grid.cols = new_cols;
    self.size.grid.rows = new_rows;

    // Queue resize to IO thread if grid dimensions changed
    if (changed) {
        // Terminal rows/cols and pixel dimensions are updated together in
        // the IO thread, under the render-state lock.
        const grid: renderer.size.GridSize = .{ .cols = new_cols, .rows = new_rows };
        // queueIo stores the resize on the mailbox's infallible control lane;
        // a grid change always triggers a UI rebuild regardless of IO state.
        switch (resize_policy) {
            .coalesced => self.queueIo(.{ .resize = grid }),
            .immediate => self.queueIo(.{ .resize_immediate = grid }),
        }
        return true;
    }

    return false;
}

/// Number of notify+yield attempts to give the writer thread a chance to drain
/// a full mailbox before we give up on a write. Bounded so we never spin.
const MAILBOX_FULL_RETRIES = 64;

const mailbox_log = std.log.scoped(.mailbox);

/// Failure modes of queuePtyWrite. A caller MUST handle these — there is no
/// silent-drop path. A fire-and-forget caller may `catch |e| log...` but the
/// outcome is always surfaced.
pub const QueueWriteError = error{
    /// The owning surface is no longer accepting input (stopping/exited/failed);
    /// the PTY process is gone and the IO writer thread is tearing down.
    SurfaceExited,
    /// The payload ring stayed full across the bounded notify+retry window;
    /// the write was NOT delivered and NOT dropped behind the caller's back.
    BackpressureTimeout,
    /// Allocating the heap copy for a large write failed.
    OutOfMemory,
};

/// Queue a resize (control-lane) message to the IO writer thread. Infallible:
/// resize uses the mailbox's last-writer-wins control fields, which never
/// occupy a payload slot and can never report `.full`. Writes must NOT go
/// through here — use queuePtyWrite, which surfaces backpressure.
pub fn queueIo(self: *Surface, msg: termio.Message) void {
    switch (msg) {
        .resize => |grid| self.mailbox.setResize(grid),
        .resize_immediate => |grid| self.mailbox.setImmediateResize(grid),
        .write_small, .write_alloc => unreachable, // use queuePtyWrite
    }
    self.mailbox.notify();
}

/// Queue bytes to the PTY input pipe through the IO writer thread.
/// This mirrors Ghostty's write-message boundary so local and remote input
/// share the same PTY write path instead of writing directly to the pipe.
///
/// On a full payload ring we notify the writer and retry a bounded number of
/// times, yielding between attempts to let it drain (the mutex is released
/// between attempts). If it is still full after the bound we RETURN
/// `error.BackpressureTimeout` rather than discarding the bytes and pretending
/// success — the caller decides how loud to be. We NEVER use msg.deinit() to
/// implicitly mean "delivered".
pub fn queuePtyWrite(self: *Surface, data: []const u8) QueueWriteError!void {
    if (!self.acceptsInput()) return error.SurfaceExited;

    const msg = termio.Message.writeReq(self.allocator, data) catch
        return error.OutOfMemory;

    var attempt: usize = 0;
    while (true) {
        switch (self.mailbox.sendWrite(msg)) {
            .queued => {
                self.mailbox.notify();
                return;
            },
            .full => {
                // Wake the writer so it drains, then yield and retry. The mutex
                // is released between attempts (sendWrite locks per call), so
                // the writer's popWrite() can make progress.
                self.mailbox.notify();
                attempt += 1;
                if (attempt >= MAILBOX_FULL_RETRIES) {
                    // The bytes were never enqueued; free our copy and report
                    // the backpressure instead of silently dropping input.
                    msg.deinit();
                    return error.BackpressureTimeout;
                }
                std.Thread.yield() catch {};
            },
        }
    }
}

pub fn attachRemoteClient(self: *Surface, client: ?*remote.Client) void {
    self.remote_client = client;
    if (client) |remote_client| {
        remote_client.registerSurface(self.remote_id, self, remoteWrite);
    }
}

fn remoteWrite(ctx: *anyopaque, data: []const u8) void {
    const surface: *Surface = @ptrCast(@alignCast(ctx));
    surface.queuePtyWrite(data) catch |err| mailbox_log.warn(
        "dropped remote write ({d} bytes): {s}",
        .{ data.len, @errorName(err) },
    );
}

/// Get the padding for rendering. Returns the computed padding
/// which includes both explicit padding and balanced centering.
pub fn getPadding(self: *const Surface) renderer.size.Padding {
    return self.size.padding;
}

// ============================================================================
// Title
// ============================================================================

/// Get the display title for this surface.
pub fn getTitle(self: *const Surface) []const u8 {
    // User override takes highest priority (like Ghostty's title_override)
    if (self.title_override_len > 0)
        return self.title_override[0..self.title_override_len];
    if (self.osc7_title_len > 0)
        return self.osc7_title[0..self.osc7_title_len];
    if (self.window_title_len > 0)
        return self.window_title[0..self.window_title_len];
    return "wispterm";
}

/// Set a manual title override. Pass empty slice to clear.
pub fn setTitleOverride(self: *Surface, title: []const u8) void {
    const len = @min(title.len, self.title_override.len);
    @memcpy(self.title_override[0..len], title[0..len]);
    self.title_override_len = len;
}

/// Set the working directory used for path resolution. Used by the tmux
/// bridge, which sources cwd from `#{pane_current_path}` rather than OSC 7
/// (tmux consumes OSC 7). Truncates to the cwd_path buffer.
pub fn setCwdPath(self: *Surface, path: []const u8) void {
    const n = @min(self.cwd_path.len, path.len);
    @memcpy(self.cwd_path[0..n], path[0..n]);
    self.cwd_path_len = n;
}

/// Note the pane's current foreground command (from tmux `#{pane_current_command}`),
/// classified to an agent App. Two effects:
///  - If the command is no longer an agent (`.none`) and an OSC marker had been
///    driving this surface, release the authoritative latch so the heuristic
///    detector resumes (the agent process has exited back to a shell).
///  - Otherwise, if no app is known yet and the OSC marker isn't driving the
///    surface, seed `agent_detection.app` from the (reliable) process name so the
///    badge identifies the agent even before output heuristics fire.
pub fn noteAgentCommand(self: *Surface, app: agent_detector.App) void {
    if (app == .none) {
        if (self.agent_osc_active) self.agent_osc_active = false;
        return;
    }
    if (!self.agent_osc_active and self.agent_detection.app == .none) {
        self.agent_detection.app = app;
    }
}

/// Get the current working directory path (from OSC 7), or null if not set.
/// Returns a Unix-style path (e.g., "/home/user/dir" or "/mnt/c/Users/...").
pub fn getCwd(self: *const Surface) ?[]const u8 {
    if (self.cwd_path_len > 0)
        return self.cwd_path[0..self.cwd_path_len];
    return null;
}

/// True when the alternate screen buffer is active. Used as a cheap, local
/// signal that a full-screen app (notably an attached `tmux`) is running:
/// plain tmux consumes OSC 7, so the OSC 7-derived cwd goes stale and a live
/// remote pane-cwd query is preferred for path resolution.
pub fn isAltScreenActive(self: *const Surface) bool {
    return self.terminal.screens.active_key == .alternate;
}

/// Get the platform launch directory for shells that do not report OSC 7.
pub fn getInitialCwd(self: *const Surface) ?[]const u8 {
    if (self.initial_cwd_path_len > 0)
        return self.initial_cwd_path[0..self.initial_cwd_path_len];
    return null;
}

/// Best-effort current working directory for resolving relative paths.
/// Tries, in order: the OSC 7-reported cwd; a live query of the shell
/// process's cwd (POSIX proc lookup — covers zsh and other shells that don't
/// emit OSC 7); the launch cwd. Caller owns the returned slice.
pub fn dupeCurrentCwd(self: *const Surface, allocator: std.mem.Allocator) ?[]u8 {
    if (self.getCwd()) |c| return allocator.dupe(u8, c) catch null;
    if (self.command.cwdQueryId()) |pid| {
        if (platform_process.processCwd(allocator, pid)) |live| return live;
    }
    if (self.getInitialCwd()) |c| return allocator.dupe(u8, c) catch null;
    return null;
}

/// Coarse classification for session persistence. Distinct from `LaunchKind`
/// (which separates `local` from `wsl` for path translation) because v1
/// session restore only cares about local-vs-remote — WSL surfaces are
/// classified as `local_shell` and are not faithfully restored. v2 may
/// reuse `LaunchKind` directly when WSL restoration is supported.
pub const SurfaceKind = enum { local_shell, ssh };

/// Classify the surface for session persistence. Currently distinguishes
/// SSH from everything else; browser/markdown surfaces are not handled
/// because they are out of scope for v1 of session restore.
pub fn surfaceKind(self: *const Surface) SurfaceKind {
    if (self.ssh_connection != null) return .ssh;
    return .local_shell;
}

fn captureInitialCwd(self: *Surface, cwd: platform_pty_command.Cwd) void {
    if (platform_pty_command.cwdToUtf8(&self.initial_cwd_path, cwd)) |path| {
        self.initial_cwd_path_len = path.len;
        return;
    }

    const path = std.process.getCwd(&self.initial_cwd_path) catch return;
    self.initial_cwd_path_len = path.len;
}

/// Reset OSC batch state — call before each PTY read batch.
pub fn resetOscBatch(self: *Surface) void {
    self.got_osc7_this_batch = false;
}

/// Decode an OSC 52 clipboard write (IO reader thread) and stage it for the
/// main thread. Read queries / clears / undecodable payloads are dropped.
pub fn ingestClipboardWrite(self: *Surface, kind: u8, data: []const u8) void {
    const action = clipboard_osc52.decode(self.allocator, kind, data) catch return;
    const text = switch (action) {
        .write => |t| t,
        .ignore => return,
    };
    self.clipboard_write_mutex.lock();
    defer self.clipboard_write_mutex.unlock();
    if (self.clipboard_write_pending) |old| self.allocator.free(old);
    self.clipboard_write_pending = text;
}

/// Take ownership of any pending OSC 52 clipboard text (main thread). The
/// caller must free the returned slice with `self.allocator`.
pub fn takeClipboardWrite(self: *Surface) ?[]u8 {
    self.clipboard_write_mutex.lock();
    defer self.clipboard_write_mutex.unlock();
    const text = self.clipboard_write_pending;
    self.clipboard_write_pending = null;
    return text;
}

/// Mark PTY output pending for the render loop. Returns true when this is the
/// first mark since the UI last consumed the flag — the caller should post
/// exactly one wakeup then, instead of flooding the platform event queue with
/// one message per output chunk.
pub fn markOutputDirty(self: *Surface) bool {
    return !self.dirty.swap(true, .release);
}

/// Track DEC synchronized output mode (2026) transitions. This mirrors
/// Ghostty's behavior: rendering waits while the mode is enabled, but a
/// watchdog prevents an application from hiding the terminal indefinitely.
pub fn noteSynchronizedOutputMode(self: *Surface, enabled: bool) void {
    if (enabled) {
        self.sync_output_state.start(std.time.milliTimestamp());
    } else {
        self.sync_output_state.stop();
        self.surface_renderer.force_rebuild = true;
    }
    self.dirty.store(true, .release);
}

/// Clear synchronized output after an external terminal state change such as
/// resize. Caller must hold render_state.mutex.
pub fn clearSynchronizedOutputLocked(self: *Surface) void {
    self.terminal.modes.set(.synchronized_output, false);
    self.sync_output_state.stop();
    self.surface_renderer.force_rebuild = true;
    self.dirty.store(true, .release);
}

/// Return true while a visible frame should be deferred for synchronized
/// output. Caller must hold render_state.mutex.
pub fn synchronizedOutputPendingLocked(self: *Surface) bool {
    return switch (self.sync_output_state.poll(
        self.terminal.modes.get(.synchronized_output),
        std.time.milliTimestamp(),
    )) {
        .inactive => false,
        .pending => true,
        .expired => expired: {
            self.terminal.modes.set(.synchronized_output, false);
            self.surface_renderer.force_rebuild = true;
            self.dirty.store(true, .release);
            break :expired false;
        },
    };
}

/// Feed terminal output to the VT parser, translating WispTerm's private OSC
/// image fallback back into the Ghostty/Kitty APC protocol in stream order.
pub fn feedVtWithWispTermImageFallback(self: *Surface, data: []const u8) void {
    var passthrough_start: usize = 0;

    for (data, 0..) |byte, i| {
        switch (self.wispterm_image_osc_state) {
            .ground => {
                if (byte == 0x1b) {
                    if (i > passthrough_start) {
                        self.vt_stream.nextSlice(data[passthrough_start..i]);
                    }
                    self.wispterm_image_osc_state = .esc;
                    passthrough_start = i + 1;
                }
            },
            .esc => {
                if (byte == ']') {
                    self.wispterm_image_osc_buf.clearRetainingCapacity();
                    self.wispterm_image_osc_state = .osc_prefix;
                    passthrough_start = i + 1;
                } else if (byte == 'k') {
                    // GNU screen/tmux title sequence: ESC k <title> ESC \.
                    // ghostty-vt doesn't implement ESC k yet; forwarding it
                    // lets the title payload (often the running command such
                    // as "ls" or "cd") render as stray pane text.
                    self.wispterm_image_osc_state = .screen_title;
                    passthrough_start = i + 1;
                } else {
                    self.vt_stream.nextSlice("\x1b");
                    self.vt_stream.nextSlice(data[i .. i + 1]);
                    self.wispterm_image_osc_state = .ground;
                    passthrough_start = i + 1;
                }
            },
            .screen_title => switch (byte) {
                0x07 => {
                    self.wispterm_image_osc_state = .ground;
                    passthrough_start = i + 1;
                },
                0x1b => {
                    self.wispterm_image_osc_state = .screen_title_esc;
                    passthrough_start = i + 1;
                },
                else => passthrough_start = i + 1,
            },
            .screen_title_esc => {
                self.wispterm_image_osc_state = if (byte == '\\') .ground else .screen_title;
                passthrough_start = i + 1;
            },
            .osc_prefix => {
                const matched = self.wispterm_image_osc_buf.items.len;
                if (matched < WISPTERM_IMAGE_OSC_PREFIX.len and
                    byte == WISPTERM_IMAGE_OSC_PREFIX[matched])
                {
                    if (!self.appendWispTermImageOscByte(byte)) {
                        self.wispterm_image_osc_buf.clearRetainingCapacity();
                        self.wispterm_image_osc_state = .image_overflow;
                    } else if (self.wispterm_image_osc_buf.items.len == WISPTERM_IMAGE_OSC_PREFIX.len) {
                        self.wispterm_image_osc_buf.clearRetainingCapacity();
                        self.wispterm_image_osc_state = .image_osc;
                    }
                    passthrough_start = i + 1;
                } else if (matched == WISPTERM_PRIVATE_OSC_SHARED.len and byte == '8') {
                    // The first 3 bytes ("774") are shared between image (7747)
                    // and agent (7748) OSCs.  Seeing '8' here means this is the
                    // private agent-state OSC — transition to wait for the ';'.
                    self.wispterm_image_osc_buf.clearRetainingCapacity();
                    self.wispterm_agent_osc_buf_len = 0;
                    self.wispterm_image_osc_state = .agent_osc_prefix;
                    passthrough_start = i + 1;
                } else {
                    self.replayNonImageOscPrefix();
                    self.vt_stream.nextSlice(data[i .. i + 1]);
                    self.wispterm_image_osc_state = switch (byte) {
                        0x07 => .ground,
                        0x1b => .passthrough_osc_esc,
                        else => .passthrough_osc,
                    };
                    passthrough_start = i + 1;
                }
            },
            .agent_osc_prefix => {
                // Waiting for the ';' that completes "7748;" after the shared "774" + "8".
                if (byte == ';') {
                    self.wispterm_image_osc_state = .agent_osc;
                } else {
                    // Not a valid agent OSC — replay "\x1b]7748" + this byte as
                    // passthrough so the VT sees it and the byte is not swallowed.
                    self.vt_stream.nextSlice("\x1b]7748");
                    self.vt_stream.nextSlice(data[i .. i + 1]);
                    self.wispterm_image_osc_state = switch (byte) {
                        0x07 => .ground,
                        0x1b => .passthrough_osc_esc,
                        else => .passthrough_osc,
                    };
                }
                passthrough_start = i + 1;
            },
            .agent_osc => switch (byte) {
                0x07 => {
                    // BEL terminator — complete marker.
                    self.handleWispTermAgentOsc();
                    self.wispterm_image_osc_state = .ground;
                    passthrough_start = i + 1;
                },
                0x1b => {
                    // Possible ST (ESC \) terminator.
                    self.wispterm_image_osc_state = .agent_osc_esc;
                    passthrough_start = i + 1;
                },
                else => {
                    if (self.wispterm_agent_osc_buf_len < WISPTERM_AGENT_OSC_MAX) {
                        self.wispterm_agent_osc_buf[self.wispterm_agent_osc_buf_len] = byte;
                        self.wispterm_agent_osc_buf_len += 1;
                    } else {
                        // Payload exceeded cap — switch to overflow drain.
                        self.wispterm_agent_osc_buf_len = 0;
                        self.wispterm_image_osc_state = .agent_overflow;
                    }
                    passthrough_start = i + 1;
                },
            },
            .agent_osc_esc => {
                if (byte == '\\') {
                    // ST terminator — complete marker.
                    self.handleWispTermAgentOsc();
                    self.wispterm_image_osc_state = .ground;
                } else {
                    // Not a valid ST; treat the ESC + this byte as part of payload.
                    if (self.wispterm_agent_osc_buf_len + 2 <= WISPTERM_AGENT_OSC_MAX) {
                        self.wispterm_agent_osc_buf[self.wispterm_agent_osc_buf_len] = 0x1b;
                        self.wispterm_agent_osc_buf_len += 1;
                        self.wispterm_agent_osc_buf[self.wispterm_agent_osc_buf_len] = byte;
                        self.wispterm_agent_osc_buf_len += 1;
                        self.wispterm_image_osc_state = .agent_osc;
                    } else {
                        self.wispterm_agent_osc_buf_len = 0;
                        self.wispterm_image_osc_state = .agent_overflow;
                    }
                }
                passthrough_start = i + 1;
            },
            .agent_overflow => switch (byte) {
                0x07 => {
                    self.wispterm_image_osc_state = .ground;
                    passthrough_start = i + 1;
                },
                0x1b => {
                    self.wispterm_image_osc_state = .agent_overflow_esc;
                    passthrough_start = i + 1;
                },
                else => passthrough_start = i + 1,
            },
            .agent_overflow_esc => {
                self.wispterm_image_osc_state = if (byte == '\\') .ground else .agent_overflow;
                passthrough_start = i + 1;
            },
            .image_osc => switch (byte) {
                0x07 => {
                    self.handleWispTermImageOsc();
                    self.wispterm_image_osc_state = .ground;
                    passthrough_start = i + 1;
                },
                0x1b => {
                    self.wispterm_image_osc_state = .image_osc_esc;
                    passthrough_start = i + 1;
                },
                else => {
                    if (!self.appendWispTermImageOscByte(byte)) {
                        self.wispterm_image_osc_buf.clearRetainingCapacity();
                        self.wispterm_image_osc_state = .image_overflow;
                    }
                    passthrough_start = i + 1;
                },
            },
            .image_osc_esc => {
                if (byte == '\\') {
                    self.handleWispTermImageOsc();
                    self.wispterm_image_osc_state = .ground;
                } else {
                    if (!self.appendWispTermImageOscByte(0x1b) or
                        !self.appendWispTermImageOscByte(byte))
                    {
                        self.wispterm_image_osc_buf.clearRetainingCapacity();
                        self.wispterm_image_osc_state = .image_overflow;
                    } else {
                        self.wispterm_image_osc_state = .image_osc;
                    }
                }
                passthrough_start = i + 1;
            },
            .image_overflow => switch (byte) {
                0x07 => {
                    self.wispterm_image_osc_state = .ground;
                    passthrough_start = i + 1;
                },
                0x1b => {
                    self.wispterm_image_osc_state = .image_overflow_esc;
                    passthrough_start = i + 1;
                },
                else => passthrough_start = i + 1,
            },
            .image_overflow_esc => {
                self.wispterm_image_osc_state = if (byte == '\\') .ground else .image_overflow;
                passthrough_start = i + 1;
            },
            .passthrough_osc => switch (byte) {
                0x07 => {
                    if (i + 1 > passthrough_start) {
                        self.vt_stream.nextSlice(data[passthrough_start .. i + 1]);
                    }
                    self.wispterm_image_osc_state = .ground;
                    passthrough_start = i + 1;
                },
                0x1b => self.wispterm_image_osc_state = .passthrough_osc_esc,
                else => {},
            },
            .passthrough_osc_esc => {
                if (byte == '\\') {
                    if (i + 1 > passthrough_start) {
                        self.vt_stream.nextSlice(data[passthrough_start .. i + 1]);
                    }
                    self.wispterm_image_osc_state = .ground;
                    passthrough_start = i + 1;
                } else {
                    self.wispterm_image_osc_state = .passthrough_osc;
                }
            },
        }
    }

    switch (self.wispterm_image_osc_state) {
        .ground, .passthrough_osc, .passthrough_osc_esc => {
            if (data.len > passthrough_start) {
                self.vt_stream.nextSlice(data[passthrough_start..]);
            }
        },
        else => {},
    }
}

fn appendWispTermImageOscByte(self: *Surface, byte: u8) bool {
    if (self.wispterm_image_osc_buf.items.len >= WISPTERM_IMAGE_OSC_MAX) return false;
    self.wispterm_image_osc_buf.append(self.allocator, byte) catch return false;
    return true;
}

fn replayNonImageOscPrefix(self: *Surface) void {
    self.vt_stream.nextSlice("\x1b]");
    if (self.wispterm_image_osc_buf.items.len > 0) {
        self.vt_stream.nextSlice(self.wispterm_image_osc_buf.items);
        self.wispterm_image_osc_buf.clearRetainingCapacity();
    }
}

/// Called when a complete OSC 7748 agent-state marker has been received.
/// The payload (bytes after "7748;") is in wispterm_agent_osc_buf[0..len].
/// If parseMarker succeeds, the Detection is applied and the heuristic is
/// suppressed. The marker is consumed (not forwarded to the VT).
fn handleWispTermAgentOsc(self: *Surface) void {
    const payload = self.wispterm_agent_osc_buf[0..self.wispterm_agent_osc_buf_len];
    self.wispterm_agent_osc_buf_len = 0;
    if (agent_detector.parseMarker(payload)) |det| {
        self.agent_detection = det;
        self.agent_osc_active = true;
    }
}

fn handleWispTermImageOsc(self: *Surface) void {
    defer self.wispterm_image_osc_buf.clearRetainingCapacity();

    const kitty = self.wispterm_image_osc_buf.items;
    if (std.mem.indexOfScalar(u8, kitty, ';') == null) return;

    const seq = self.allocator.alloc(u8, 3 + kitty.len + 2) catch return;
    defer self.allocator.free(seq);

    seq[0] = 0x1b;
    seq[1] = '_';
    seq[2] = 'G';
    @memcpy(seq[3 .. 3 + kitty.len], kitty);
    seq[3 + kitty.len] = 0x1b;
    seq[4 + kitty.len] = '\\';

    self.vt_stream.nextSlice(seq);
}

/// Scan PTY output for OSC 0/1/2/7 title sequences.
/// Handles sequences split across multiple reads via state machine.
pub fn scanForOscTitle(self: *Surface, data: []const u8) void {
    for (data) |byte| {
        switch (self.osc_state) {
            .ground => {
                if (byte == 0x1b) {
                    self.osc_state = .esc;
                }
            },
            .esc => {
                if (byte == ']') {
                    self.osc_state = .osc_num;
                    self.osc_is_title = false;
                } else {
                    self.osc_state = .ground;
                }
            },
            .osc_num => {
                if (byte == '0' or byte == '1' or byte == '2' or byte == '7') {
                    self.osc_is_title = true;
                    self.osc_num = byte;
                    self.osc_state = .osc_semi;
                } else if (byte >= '0' and byte <= '9') {
                    self.osc_is_title = false;
                    self.osc_num = byte;
                    self.osc_state = .osc_semi;
                } else {
                    self.osc_state = .ground;
                }
            },
            .osc_semi => {
                if (byte == ';') {
                    if (self.osc_is_title) {
                        self.osc_buf_len = 0;
                        self.osc_state = .osc_title;
                    } else {
                        self.osc_state = .ground;
                    }
                } else if (byte >= '0' and byte <= '9') {
                    // Multi-digit OSC number, stay in osc_semi
                } else {
                    self.osc_state = .ground;
                }
            },
            .osc_title => {
                if (byte == 0x07) {
                    self.updateTitle(self.osc_buf[0..self.osc_buf_len], self.osc_num);
                    self.osc_state = .ground;
                } else if (byte == 0x1b) {
                    self.updateTitle(self.osc_buf[0..self.osc_buf_len], self.osc_num);
                    self.osc_state = .esc;
                } else if (self.osc_buf_len < self.osc_buf.len) {
                    self.osc_buf[self.osc_buf_len] = byte;
                    self.osc_buf_len += 1;
                }
            },
        }
    }
}

/// Update the surface title from an OSC sequence.
/// Like Ghostty, reject titles that aren't valid UTF-8 — this filters out
/// garbage from random byte streams (e.g. cat /dev/urandom) that happen to
/// form accidental OSC sequences.
fn updateTitle(self: *Surface, title: []const u8, osc_num: u8) void {
    if (title.len == 0) return;
    if (!std.unicode.utf8ValidateSlice(title)) return;

    if (osc_num == '7') {
        // OSC 7: file://host/path — extract the path
        self.got_osc7_this_batch = true;
        const prefix = "file://";
        if (std.mem.startsWith(u8, title, prefix)) {
            const after_prefix = title[prefix.len..];
            if (std.mem.indexOfScalar(u8, after_prefix, '/')) |slash| {
                const path = after_prefix[slash..];

                // Store raw path for CWD inheritance
                const raw_len = @min(path.len, self.cwd_path.len);
                @memcpy(self.cwd_path[0..raw_len], path[0..raw_len]);
                self.cwd_path_len = raw_len;

                // Format for display (with ~ for home)
                const home_prefix = "/home/";
                if (std.mem.startsWith(u8, path, home_prefix)) {
                    const after_home = path[home_prefix.len..];
                    const user_end = std.mem.indexOfScalar(u8, after_home, '/') orelse after_home.len;
                    const home_len = home_prefix.len + user_end;

                    const rest = path[home_len..];
                    self.osc7_title[0] = '~';
                    const rest_len = @min(rest.len, self.osc7_title.len - 1);
                    @memcpy(self.osc7_title[1 .. 1 + rest_len], rest[0..rest_len]);
                    self.osc7_title_len = 1 + rest_len;
                } else {
                    const path_len = @min(path.len, self.osc7_title.len);
                    @memcpy(self.osc7_title[0..path_len], path[0..path_len]);
                    self.osc7_title_len = path_len;
                }
            }
        }
    } else {
        // OSC 0/1/2 — skip if we already got OSC 7 in this same batch
        if (self.got_osc7_this_batch) return;

        const friendly = platform_pty_command.friendlyShellTitle(title);

        // Accept and clear OSC 7 cache
        self.osc7_title_len = 0;
        const friendly_len = @min(friendly.len, self.window_title.len);
        @memcpy(self.window_title[0..friendly_len], friendly[0..friendly_len]);
        self.window_title_len = friendly_len;
    }
}

test "Surface exposes init and initVirtual (forces analysis of the shared finishInit refactor)" {
    // Address-of forces full semantic analysis + codegen of both constructors,
    // and therefore of the shared finishInit they call. Without this, an unused
    // initVirtual could carry a refactor bug that the headless suite never sees.
    _ = &init;
    _ = &initVirtual;

    const info = @typeInfo(@TypeOf(initVirtual)).@"fn";
    // allocator, cols, rows, pty, scrollback_limit, cursor_style, cursor_blink
    try std.testing.expectEqual(@as(usize, 7), info.params.len);
    try std.testing.expect(info.params[3].type.? == Pty);
}

// Build just enough of a Surface to drive the VT stream and capture the bytes
// the terminal writes back to the PTY (no real PTY or IO threads).
fn vtResponseHarness(surface: *Surface) !void {
    surface.allocator = std.testing.allocator;
    surface.terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    surface.mailbox = try termio.Mailbox.init();
    surface.vt_stream = surface.initVtStream();
    surface.io_state_mutex = .{};
    surface.io_state = .running;
    surface.exited = std.atomic.Value(bool).init(false);
}

fn vtResponseHarnessDeinit(surface: *Surface) void {
    surface.vt_stream.deinit();
    surface.mailbox.deinit();
    surface.terminal.deinit(std.testing.allocator);
}

fn expectPtyResponse(surface: *Surface, expected: []const u8) !void {
    // The popped message owns the bytes; assert while it is still in scope so
    // the slice into write_small.data stays valid.
    const msg = surface.mailbox.popWrite() orelse return error.NoPtyResponse;
    switch (msg) {
        .write_small => |*w| try std.testing.expectEqualStrings(expected, w.data[0..w.len]),
        else => return error.UnexpectedMessage,
    }
}

test "kitty keyboard query is answered back to the PTY (issue #302)" {
    var surface: Surface = undefined;
    try vtResponseHarness(&surface);
    defer vtResponseHarnessDeinit(&surface);

    // crossterm/Claude Code probe support with `CSI ? u`. With no flags pushed
    // yet the terminal must report 0 so the app knows the protocol exists.
    surface.vt_stream.nextSlice("\x1b[?u");
    try expectPtyResponse(&surface, "\x1b[?0u");

    // After the app pushes the disambiguate flag, the query reflects it — this
    // is the round-trip that makes the app actually turn the protocol on.
    surface.vt_stream.nextSlice("\x1b[>1u");
    surface.vt_stream.nextSlice("\x1b[?u");
    try expectPtyResponse(&surface, "\x1b[?1u");
}

// queuePtyWrite needs surface.allocator, surface.mailbox, and the IO lifecycle
// state (acceptsInput gates writes), so a tiny harness is enough to exercise its
// outcome contract. io_state must be .running for writes to be accepted.
fn writeOutcomeHarness(surface: *Surface) !void {
    surface.allocator = std.testing.allocator;
    surface.mailbox = try termio.Mailbox.init();
    surface.exited = std.atomic.Value(bool).init(false);
    surface.io_state_mutex = .{};
    surface.io_state = .running;
}

fn writeOutcomeHarnessDeinit(surface: *Surface) void {
    surface.mailbox.deinit();
}

test "queuePtyWrite returns SurfaceExited when the surface stops accepting input" {
    var surface: Surface = undefined;
    try writeOutcomeHarness(&surface);
    defer writeOutcomeHarnessDeinit(&surface);

    surface.io_state = .stopped; // acceptsInput() is true only while .running
    try std.testing.expectError(error.SurfaceExited, surface.queuePtyWrite("hello"));
}

test "queuePtyWrite returns BackpressureTimeout when the payload ring stays full" {
    var surface: Surface = undefined;
    try writeOutcomeHarness(&surface);
    defer writeOutcomeHarnessDeinit(&surface);

    // Saturate the payload ring directly so every queuePtyWrite retry sees a
    // full ring (no writer thread is draining it in this harness).
    while (true) {
        var small: termio.Message.WriteSmall = .{ .len = 1 };
        small.data[0] = 'x';
        if (surface.mailbox.sendWrite(.{ .write_small = small }) == .full) break;
    }

    // The write is neither delivered nor silently dropped — it is reported.
    try std.testing.expectError(error.BackpressureTimeout, surface.queuePtyWrite("y"));

    // The original queued writes are untouched: the full ring evicted nothing.
    var drained: usize = 0;
    while (surface.mailbox.popWrite()) |msg| {
        msg.deinit();
        drained += 1;
    }
    try std.testing.expect(drained > 0);
}

test "queuePtyWrite enqueues a write onto the payload ring on success" {
    var surface: Surface = undefined;
    try writeOutcomeHarness(&surface);
    defer writeOutcomeHarnessDeinit(&surface);

    try surface.queuePtyWrite("ok");

    const msg = surface.mailbox.popWrite() orelse return error.MissingMessage;
    defer msg.deinit();
    switch (msg) {
        .write_small => |*w| try std.testing.expectEqualStrings("ok", w.data[0..w.len]),
        else => return error.UnexpectedMessage,
    }
}

fn ioStateHarness(surface: *Surface) !void {
    surface.allocator = std.testing.allocator;
    surface.terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    surface.render_state = renderer.State.init(&surface.terminal);
    surface.surface_renderer = Renderer.init(surface);
    surface.io_state_mutex = .{};
    surface.io_state = .running;
    surface.exited = std.atomic.Value(bool).init(false);
    surface.dirty = std.atomic.Value(bool).init(false);
    surface.io_thread_state = null;
    surface.io_writer_thread = null;
    surface.io_reader_thread = null;
}

fn ioStateHarnessDeinit(surface: *Surface) void {
    surface.surface_renderer.deinit();
    surface.terminal.deinit(std.testing.allocator);
}

test "Surface failIo records first failure, wakes rendering, and blocks input" {
    var surface: Surface = undefined;
    try ioStateHarness(&surface);
    defer ioStateHarnessDeinit(&surface);

    try std.testing.expect(surface.acceptsInput());

    surface.failIo(.pty_write, error.BrokenPipe);
    try std.testing.expect(!surface.acceptsInput());
    try std.testing.expect(surface.exited.load(.acquire));
    try std.testing.expect(surface.dirty.load(.acquire));

    switch (surface.currentIoState()) {
        .failed => |failure| {
            try std.testing.expectEqual(Operation.pty_write, failure.operation);
            try std.testing.expectEqual(error.BrokenPipe, failure.error_code);
        },
        else => return error.ExpectedFailedState,
    }

    surface.failIo(.pty_resize, error.ResizeFailed);
    switch (surface.currentIoState()) {
        .failed => |failure| {
            try std.testing.expectEqual(Operation.pty_write, failure.operation);
            try std.testing.expectEqual(error.BrokenPipe, failure.error_code);
        },
        else => return error.ExpectedFailedState,
    }
}

test "Surface markExited preserves a normal exit as non-failure and blocks input" {
    var surface: Surface = undefined;
    try ioStateHarness(&surface);
    defer ioStateHarnessDeinit(&surface);

    surface.markExited(.eof, .{ .exited = 0 });

    try std.testing.expect(!surface.acceptsInput());
    try std.testing.expect(surface.exited.load(.acquire));
    switch (surface.currentIoState()) {
        .exited => |info| {
            try std.testing.expectEqual(ExitReason.eof, info.reason);
            try std.testing.expectEqual(@as(?Command.Exit, .{ .exited = 0 }), info.status);
        },
        else => return error.ExpectedExitedState,
    }
}
