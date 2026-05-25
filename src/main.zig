//! Phantty entry point.
//!
//! Handles CLI args and special commands, then creates an App which
//! manages one or more AppWindow instances. Most terminal logic lives
//! in AppWindow.zig.

const std = @import("std");
const Config = @import("config.zig");
const App = @import("App.zig");
const image_decoder = @import("image_decoder.zig");
const app_metadata = @import("app_metadata.zig");
const platform_console = @import("platform/console.zig");
const font_backend = @import("platform/font_backend.zig");

// ============================================================================
// Font Discovery Test Functions (use --list-fonts or --test-font-discovery)
// ============================================================================

fn prepareCliConsole() void {
    platform_console.prepareCliConsole();
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

    std.debug.print("Phantty starting...\n", .{});
    image_decoder.install();

    // Load configuration: defaults → config file → CLI flags
    const cfg = try Config.load(allocator);
    defer cfg.deinit(allocator);

    if (cfg.config_path) |path| {
        std.debug.print("Config loaded from: {s}\n", .{path});
    } else {
        std.debug.print("No config file found, using defaults\n", .{});
    }

    // Create the App and run (first window on main thread, spawned windows on separate threads)
    var app = try App.init(allocator, cfg);
    defer app.deinit();

    // App now lives at a stable address; start the WeChat direct bridge (no-op
    // unless weixin-direct-enabled and remote is inactive).
    app.startWeixin(&cfg);

    try app.run();

    std.debug.print("Phantty exiting...\n", .{});
}
