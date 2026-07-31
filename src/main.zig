//! WispTerm entry point.
//!
//! Handles CLI args and special commands, then creates an App which
//! manages one or more AppWindow instances. Most terminal logic lives
//! in AppWindow.zig.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig");
const App = @import("App.zig");
const memory_digest_scheduler = @import("memory_digest/scheduler.zig");
const image_decoder = @import("image_decoder.zig");
const app_metadata = @import("app_metadata.zig");
const platform_console = @import("platform/console.zig");
const font_backend = @import("platform/font_backend.zig");
const render_diagnostics = @import("render_diagnostics.zig");
const window_backend = @import("platform/window_backend.zig");
const gpu = @import("renderer/gpu/gpu.zig");
const i18n = @import("i18n.zig");
const ai_chat = @import("assistant/conversation/session.zig");
const build_options = @import("build_options");
const diag_log = @import("diag_log.zig");
const single_instance = @import("platform/single_instance.zig");
const platform_pty_command = @import("platform/pty_command.zig");

/// Diagnostic builds (-Ddebug-console) route std.log to the on-disk debug log;
/// normal builds keep std defaults (zero cost).
pub const std_options: std.Options = if (build_options.debug_console)
    .{ .logFn = diag_log.logFn, .log_level = .debug }
else
    .{};

/// Diagnostic builds write a crash report before aborting; normal builds use the
/// default panic.
pub const panic = if (build_options.debug_console)
    std.debug.FullPanic(diag_log.panicFn)
else
    std.debug.FullPanic(std.debug.defaultPanic);

// ============================================================================
// Font Discovery Test Functions (use --list-fonts or --test-font-discovery)
// ============================================================================

fn prepareCliConsole() void {
    platform_console.prepareCliConsole();
}

/// macOS-only: .app bundles launched by launchd inherit cwd "/", which then
/// leaks into every new shell session (initial_cwd, getActiveCwd, PTY
/// inherited cwd). Reroot to $HOME so newly spawned tabs/splits land where
/// the user expects, while leaving wispterm alone when it was invoked from a
/// real shell with a meaningful cwd.
///
/// Wrapped in a comptime os.tag check so Windows builds skip the whole body
/// — std.posix.getenv is a @compileError on Windows (env strings are
/// WTF-16, not UTF-8), and an unguarded reference here breaks the Windows
/// release build.
fn rerootCwdFromBundleRootIfNeeded() void {
    if (builtin.os.tag == .macos) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.process.getCwd(&buf) catch return;
        if (!std.mem.eql(u8, cwd, "/")) return;
        const home = std.posix.getenv("HOME") orelse return;
        std.posix.chdir(home) catch {};
    }
}

fn listSystemFonts(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.print("Listing system fonts...\nBackend: {s}\n\n", .{font_backend.discoveryDisplayName()});

    var discovery = font_backend.FontDiscovery.init() catch |err| {
        try writer.print("{s}: {}\n", .{ font_backend.discoveryInitErrorPrefix(), err });
        return err;
    };
    defer discovery.deinit();

    const families = try discovery.listFontFamilies(allocator);
    defer {
        for (families) |f| allocator.free(f);
        allocator.free(families);
    }

    try writer.print("Found {} font families:\n", .{families.len});
    for (families, 0..) |family, i| {
        try writer.print("  {d:4}. {s}\n", .{ i + 1, family });
    }
}

fn testFontDiscovery(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.print("Testing font discovery...\n\n", .{});

    var discovery = font_backend.FontDiscovery.init() catch |err| {
        try writer.print("{s}: {}\n", .{ font_backend.discoveryInitErrorPrefix(), err });
        return err;
    };
    defer discovery.deinit();

    // Test fonts to look for
    const test_fonts = [_][]const u8{
        "JetBrains Mono",
        "Cascadia Code",
        "Consolas",
        "Courier New",
        "Arial",
        "Segoe UI",
        "NonExistentFont12345",
    };

    for (test_fonts) |font_name| {
        try writer.print("Looking for '{s}'... ", .{font_name});

        if (discovery.findFontFilePath(allocator, font_name, .NORMAL, .NORMAL)) |maybe_result| {
            if (maybe_result) |result| {
                var r = result;
                defer r.deinit();
                try writer.writeAll("FOUND\n");
                try writer.print("  Path: {s}\n", .{result.path});
                try writer.print("  Face index: {}\n\n", .{result.face_index});
            } else {
                try writer.writeAll("NOT FOUND\n\n");
            }
        } else |err| {
            try writer.print("ERROR: {}\n\n", .{err});
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Handle special commands before loading full config
    const cli_command_mode =
        Config.hasCommand(allocator, "help") or
        Config.hasCommand(allocator, "h") or
        Config.hasCommand(allocator, "version") or
        Config.hasCommand(allocator, "v") or
        Config.hasCommand(allocator, "list-fonts") or
        Config.hasCommand(allocator, "list-themes") or
        Config.hasCommand(allocator, "test-font-discovery") or
        Config.hasCommand(allocator, "show-config-path");
    if (cli_command_mode) prepareCliConsole();

    if (Config.hasCommand(allocator, "help") or Config.hasCommand(allocator, "h")) {
        Config.printHelp();
        return;
    }
    if (Config.hasCommand(allocator, "version") or Config.hasCommand(allocator, "v")) {
        try app_metadata.printVersion(std.fs.File.stdout().deprecatedWriter());
        return;
    }
    if (Config.hasCommand(allocator, "list-fonts")) {
        try listSystemFonts(allocator, std.fs.File.stdout().deprecatedWriter());
        return;
    }
    if (Config.hasCommand(allocator, "list-themes")) {
        Config.listThemes();
        return;
    }
    if (Config.hasCommand(allocator, "test-font-discovery")) {
        try testFontDiscovery(allocator, std.fs.File.stdout().deprecatedWriter());
        return;
    }
    if (Config.hasCommand(allocator, "show-config-path")) {
        Config.printConfigPath(allocator);
        return;
    }

    // In-app GPU render benchmark: needs a real window + GPU context, so it
    // runs through the normal App/AppWindow startup with a flag that makes
    // AppWindow substitute a virtual benchmark surface and drive the loop.
    if (Config.hasCommand(allocator, "benchmark")) {
        @import("benchmark/driver.zig").enabled = true;
    }

    if (build_options.debug_console) {
        diag_log.init();
        diag_log.installCrashHandlers();
        std.log.info("diagnostic build start version={s}", .{build_options.app_version});
    }
    defer if (build_options.debug_console) diag_log.close();

    std.debug.print("WispTerm starting...\n", .{});
    rerootCwdFromBundleRootIfNeeded();
    image_decoder.install();

    // Load configuration: defaults → config file → CLI flags
    const cfg = try Config.load(allocator);
    defer cfg.deinit(allocator);

    if (cfg.config_path) |path| {
        std.debug.print("Config loaded from: {s}\n", .{path});
    } else {
        std.debug.print("No config file found, using defaults\n", .{});
    }

    // Single-instance check: if enabled and a previous instance owns the mutex,
    // forward the CLI directory (or our working directory) to it and exit.
    const single_instance_role: ?single_instance.Role = if (cfg.@"single-instance") blk: {
        switch (try single_instance.acquire(allocator)) {
            .second => {
                std.debug.print("Another WispTerm instance is running — forwarding directory...\n", .{});
                if (single_instance.forwardCwd(allocator, cfg.cli_cwd)) {
                    std.debug.print("Forwarded directory. Exiting.\n", .{});
                    return;
                }
                std.debug.print("Could not reach the running instance. Retrying acquire...\n", .{});
                // The first instance may have crashed after we detected the
                // mutex but before we connected. Re-acquire: if the mutex is
                // now free, become the new first instance; otherwise fall
                // through without IPC (the first instance is alive but its
                // server is unreachable).
                switch (single_instance.acquire(allocator) catch .second) {
                    .first => {
                        std.debug.print("Previous instance gone — becoming first instance.\n", .{});
                        break :blk .first;
                    },
                    .second => {
                        std.debug.print("Starting anyway (IPC unreachable).\n", .{});
                        break :blk null;
                    },
                }
            },
            .first => break :blk .first,
        }
    } else null;
    var g_single_instance_server: ?*single_instance.Server = null;

    // Apply memory-digest scheduler settings from the initial config load.
    // AppWindow.init only copies individual fields out of App (not the whole
    // Config), so this is the one place that sees the full Config before
    // window setup; applyReloadedConfig covers every later hot-reload.
    memory_digest_scheduler.updateSettings(.{
        .enabled = cfg.@"memory-digest-enabled",
        .profile_name = cfg.@"memory-digest-profile",
        .run_after = cfg.@"memory-digest-run-after",
        .scan_remote = cfg.@"memory-digest-scan-remote",
        .backfill_days = cfg.@"memory-digest-backfill-days",
        .max_chars = cfg.@"memory-digest-max-chars",
        .input_budget_chars = cfg.@"memory-digest-input-budget-chars",
    });

    // Resolve UI language (explicit config > system locale > en) before any
    // window/UI renders. Restart-applied (no live switch in v1).
    i18n.applyConfig(allocator, cfg.language);

    // Honor the config opt-in for render diagnostics before any window/GL
    // exists, so the very first WM_SIZE/WM_DPICHANGED events are captured.
    render_diagnostics.enableFromConfig(cfg.@"wispterm-debug-render");

    // Present-path selection must be decided before the first window is
    // created (the presenter is built right after the GL context).
    const use_legacy_gl_dx_present = cfg.@"wispterm-d3d-present" and gpu.active != .d3d11;
    window_backend.setFlipPresentEnabled(use_legacy_gl_dx_present);

    // Bring-up crash fuse: presenter init runs driver code (wglDX*NV, D3D11)
    // that broken ICDs crash in instead of failing — which previously meant
    // the app never opened again on those machines. Leave a marker before
    // the first attempt; AppWindow clears it after the first survived
    // present. Finding our own marker at startup = last bring-up died →
    // stop trying the D3D path for this app version (an upgrade retries).
    if (comptime builtin.os.tag == .windows) {
        if (use_legacy_gl_dx_present) {
            const window_state = @import("platform/window_state.zig");
            const dxgi_core = @import("platform/dxgi_core.zig");
            var stored_buf: [dxgi_core.bringup_marker_max_len]u8 = undefined;
            const stored = window_state.d3dBringup(allocator, &stored_buf);
            var marker_buf: [dxgi_core.bringup_marker_max_len]u8 = undefined;
            switch (dxgi_core.bringupFuseDecision(stored, app_metadata.version)) {
                .blocked => {
                    window_backend.setFlipPresentEnabled(false);
                    render_diagnostics.log("dx-present bring-up fuse tripped (\"{s}\") — GDI for this version", .{stored});
                    std.debug.print("Win32: last DXGI present bring-up did not survive; using SwapBuffers for v{s}\n", .{app_metadata.version});
                    if (dxgi_core.bringupMarkerIsProbing(stored)) {
                        if (dxgi_core.bringupBlockedMarker(&marker_buf, app_metadata.version)) |m|
                            window_state.recordD3dBringup(allocator, m)
                        else |_| {}
                    }
                },
                .attempt => {
                    if (dxgi_core.bringupProbingMarker(&marker_buf, app_metadata.version)) |m|
                        window_state.recordD3dBringup(allocator, m)
                    else |_| {}
                },
            }
        }
    }

    // Create the App and run (first window on main thread, spawned windows on separate threads)
    var app = try App.init(allocator, cfg);
    defer ai_chat.deinitAccessRules();
    defer ai_chat.deinitMcpTools(allocator);
    defer app.deinit();
    ai_chat.loadAccessRules(allocator);
    // Build the MCP tool catalog from <configDir>/mcp.json + the disk catalog
    // cache. No MCP server is spawned at startup — discovery happens in the
    // panel "Test" probe or on first mcp_activate (see mcp_catalog.zig).
    ai_chat.reloadMcpTools(allocator);

    // If a CLI directory argument was provided and we are not a second-instance
    // forwarder, resolve it against the CWD and set as initial CWD for the first tab.
    if (cfg.cli_cwd) |dir| {
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = std.fs.realpath(dir, &resolved_buf) catch dir;
        var cwd_buf: platform_pty_command.CwdBuffer = undefined;
        if (platform_pty_command.cwdFromUtf8(&cwd_buf, resolved)) |cwd_ptr| {
            const len = std.mem.sliceTo(cwd_ptr, 0).len;
            @memcpy(app.next_window_cwd[0..len], cwd_ptr[0..len]);
            app.next_window_cwd[len] = 0;
            app.next_window_cwd_len = len;
        }
    }

    // App now lives at a stable address; start app-owned background services
    // before opening the first window.
    app.startPortForwarding(&cfg);

    // Start the WeChat direct bridge (no-op unless weixin-direct-enabled is set).
    app.startWeixin(&cfg);

    // Start the Feishu long-connection channel (no-op unless feishu-enabled is set).
    app.startFeishu(&cfg);

    // Start the local agent terminal control API (no-op unless agent-control-enabled).
    app.startAgentControl(&cfg);

    // Ensure the config directory exists before starting the single-instance IPC
    // server (which writes its discovery file there).
    Config.ensureConfigExists(allocator);

    // Start the single-instance IPC server (no-op unless single-instance is enabled
    // and this is the first instance).
    if (single_instance_role == .first) {
        g_single_instance_server = single_instance.Server.start(allocator) catch |err| blk: {
            std.debug.print("single-instance server failed to start: {}\n", .{err});
            break :blk null;
        };
        if (g_single_instance_server) |srv| {
            single_instance.setActiveServer(srv);
            std.debug.print("single-instance IPC server started\n", .{});
        }
    }

    try app.run();

    // Cleanup single-instance IPC server
    if (g_single_instance_server) |srv| {
        srv.destroy();
    }
    if (single_instance_role != null) {
        single_instance.release(allocator);
    }

    std.debug.print("WispTerm exiting...\n", .{});
}
