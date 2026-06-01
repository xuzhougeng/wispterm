/// Config is the main configuration struct for WispTerm.
///
/// Follows Ghostty's configuration format: a simple `key = value` text file.
/// Config is loaded from the following locations (in order, later overrides earlier):
///
///   1. Main config file: --config/--config-path, portable wispterm.conf next to the app,
///      or the platform config directory
///   2. CLI flags (--key value)
///
/// The syntax uses Ghostty's format:
///   - `key = value` pairs (whitespace around `=` is optional)
///   - Lines starting with `#` are comments
///   - Blank lines are ignored
///   - Values can be quoted or unquoted
///   - `config-file` key loads additional config files
///
/// Every config key is also a valid CLI flag: `--key value` or `--key=value`.
const Config = @This();

const std = @import("std");
const builtin = @import("builtin");
const ai_agent_config = @import("ai_agent_config.zig");
const keybind = @import("keybind.zig");
const link_open = @import("link_open.zig");
const platform_dirs = @import("platform/dirs.zig");
const platform_editor = @import("platform/editor.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const themes = @import("themes.zig");
const i18n = @import("i18n.zig");

const log = std.log.scoped(.config);

// ============================================================================
// Theme
// ============================================================================

/// RGB color as floats (0.0-1.0)
pub const Color = [3]f32;

pub const Theme = struct {
    palette: [16]Color,
    background: Color,
    foreground: Color,
    cursor_color: Color,
    cursor_text: ?Color,
    selection_background: Color,
    selection_foreground: ?Color,

    /// WispTerm's default theme: a warm, Ayu-inspired dark palette.
    pub fn default() Theme {
        return .{
            .palette = .{
                hexToColor(0x191e2a), // 0: black
                hexToColor(0xff3333), // 1: red
                hexToColor(0xbae67e), // 2: green
                hexToColor(0xffa759), // 3: yellow
                hexToColor(0x73d0ff), // 4: blue
                hexToColor(0xd4bfff), // 5: magenta
                hexToColor(0x95e6cb), // 6: cyan
                hexToColor(0xc7c7c7), // 7: white
                hexToColor(0x5c6773), // 8: bright black
                hexToColor(0xff6565), // 9: bright red
                hexToColor(0xc2d94c), // 10: bright green
                hexToColor(0xffd580), // 11: bright yellow
                hexToColor(0x5ccfe6), // 12: bright blue
                hexToColor(0xffae57), // 13: bright magenta
                hexToColor(0x95e6cb), // 14: bright cyan
                hexToColor(0xffffff), // 15: bright white
            },
            .background = hexToColor(0x1f2430),
            .foreground = hexToColor(0xcbccc6),
            .cursor_color = hexToColor(0xffcc66),
            .cursor_text = hexToColor(0x1f2430),
            .selection_background = hexToColor(0x33415e),
            .selection_foreground = hexToColor(0xf3f4f5),
        };
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Theme {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        return parseThemeContent(content);
    }

    pub fn parseThemeContent(content: []const u8) Theme {
        var theme = Theme.default();

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                if (std.mem.eql(u8, key, "palette")) {
                    if (std.mem.indexOf(u8, value, "=")) |idx_eq| {
                        const idx_str = value[0..idx_eq];
                        const color_str = value[idx_eq + 1 ..];
                        const idx = std.fmt.parseInt(u8, idx_str, 10) catch continue;
                        if (idx < 16) {
                            if (parseColor(color_str)) |color| {
                                theme.palette[idx] = color;
                            }
                        }
                    }
                } else if (std.mem.eql(u8, key, "background")) {
                    if (parseColor(value)) |color| theme.background = color;
                } else if (std.mem.eql(u8, key, "foreground")) {
                    if (parseColor(value)) |color| theme.foreground = color;
                } else if (std.mem.eql(u8, key, "cursor-color")) {
                    if (parseColor(value)) |color| theme.cursor_color = color;
                } else if (std.mem.eql(u8, key, "cursor-text")) {
                    if (parseColor(value)) |color| theme.cursor_text = color;
                } else if (std.mem.eql(u8, key, "selection-background")) {
                    if (parseColor(value)) |color| theme.selection_background = color;
                } else if (std.mem.eql(u8, key, "selection-foreground")) {
                    if (parseColor(value)) |color| theme.selection_foreground = color;
                }
            }
        }

        return theme;
    }
};

// ============================================================================
// Cursor
// ============================================================================

pub const CursorStyle = enum {
    block,
    bar,
    underline,
    block_hollow,
};

pub const RightClickAction = enum {
    ignore,
    copy,
    paste,
    copy_or_paste,

    pub fn parse(s: []const u8) ?RightClickAction {
        if (std.mem.eql(u8, s, "ignore")) return .ignore;
        if (std.mem.eql(u8, s, "copy")) return .copy;
        if (std.mem.eql(u8, s, "paste")) return .paste;
        if (std.mem.eql(u8, s, "copy-or-paste")) return .copy_or_paste;
        return null;
    }

    pub fn name(self: RightClickAction) []const u8 {
        return switch (self) {
            .ignore => "ignore",
            .copy => "copy",
            .paste => "paste",
            .copy_or_paste => "copy-or-paste",
        };
    }
};

pub const UrlOpenMode = link_open.Mode;

// ============================================================================
// Background Image
// ============================================================================

pub const BackgroundImageMode = enum {
    fill, // cover the window, may crop
    fit, // scale to fit, may letterbox
    center, // 1:1, centered, may be cropped or surrounded by clear color
    tile, // repeat at native size

    pub fn parse(s: []const u8) ?BackgroundImageMode {
        if (std.mem.eql(u8, s, "fill")) return .fill;
        if (std.mem.eql(u8, s, "fit")) return .fit;
        if (std.mem.eql(u8, s, "center")) return .center;
        if (std.mem.eql(u8, s, "tile")) return .tile;
        return null;
    }
};

// ============================================================================
// Font Weight
// ============================================================================

pub const FontWeight = enum {
    thin,
    extra_light,
    light,
    regular,
    medium,
    semi_bold,
    bold,
    extra_bold,
    black,

    pub fn value(self: FontWeight) u16 {
        return switch (self) {
            .thin => 100,
            .extra_light => 200,
            .light => 300,
            .regular => 400,
            .medium => 500,
            .semi_bold => 600,
            .bold => 700,
            .extra_bold => 800,
            .black => 900,
        };
    }

    pub fn parse(s: []const u8) ?FontWeight {
        if (std.mem.eql(u8, s, "thin")) return .thin;
        if (std.mem.eql(u8, s, "extra-light") or std.mem.eql(u8, s, "extralight")) return .extra_light;
        if (std.mem.eql(u8, s, "light")) return .light;
        if (std.mem.eql(u8, s, "regular") or std.mem.eql(u8, s, "normal")) return .regular;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "semi-bold") or std.mem.eql(u8, s, "semibold")) return .semi_bold;
        if (std.mem.eql(u8, s, "bold")) return .bold;
        if (std.mem.eql(u8, s, "extra-bold") or std.mem.eql(u8, s, "extrabold")) return .extra_bold;
        if (std.mem.eql(u8, s, "black") or std.mem.eql(u8, s, "heavy")) return .black;
        return null;
    }
};

// ============================================================================
// Config Fields
// ============================================================================

/// Font family name.
@"font-family": []const u8 = "JetBrains Mono",

/// Preferred family for CJK fallback glyphs. Used before generic system fallback.
@"font-family-cjk": ?[]const u8 = null,

/// Comma-separated fallback family priority list. These are tried before
/// generic system-wide fallback scanning.
@"font-family-fallback": ?[]const u8 = null,

/// Font weight/style. Ghostty default: regular (default).
@"font-style": FontWeight = .regular,

/// Font size in points. Ghostty default: 13 (macOS), 12 (other).
@"font-size": u32 = 13,

/// Cursor shape: block, bar, underline, block_hollow.
@"cursor-style": CursorStyle = .block,

/// Whether the cursor should blink.
@"cursor-style-blink": bool = true,

/// Theme name (looked up in themes/ directory) or file path.
theme: ?[]const u8 = null,

/// Path to a Ghostty-compatible custom GLSL shader for post-processing.
@"custom-shader": ?[]const u8 = null,

/// Initial terminal height in cells (min: 4, 0 = auto).
@"window-height": u16 = 0,

/// Initial terminal width in cells (min: 10, 0 = auto).
@"window-width": u16 = 0,

/// Scrollback buffer limit in bytes.
@"scrollback-limit": u32 = 10_000_000,

/// Copy terminal selections to the clipboard when selection completes.
@"copy-on-select": bool = false,

/// Right-click action for terminal surfaces.
@"right-click-action": RightClickAction = .copy,

/// Where Ctrl-clicked web URLs open.
@"url-open-mode": UrlOpenMode = .embedded,

/// Add legacy OpenSSH algorithms for older bastion/servers.
@"ssh-legacy-algorithms": bool = false,

/// Enable agent tools for AI Chat profiles by default.
@"ai-agent-enabled": bool = false,

/// Show native desktop notifications for OSC 9 / OSC 777 sequences (macOS).
/// When false, such sequences are ignored entirely (no toast, no bell badge).
/// Does not affect the plain terminal bell.
@"desktop-notifications": bool = true,

/// Agent command permission mode: confirm (deny until approved UI exists) or full.
@"ai-agent-permission": ai_agent_config.AgentPermission = .confirm,

/// Timeout budget for agent shell/SSH commands.
@"ai-agent-command-timeout-ms": u32 = 60_000,

/// Maximum bytes returned from a single tool result.
@"ai-agent-output-limit": u32 = 16 * 1024,

/// The shell to run in the terminal. Platform aliases are resolved by
/// platform/pty_command.zig; any other value is treated as a raw command path.
shell: []const u8 = platform_pty_command.default_shell_name,

/// Name of the saved AI profile used as the default for startup auto-open,
/// remote auto-open, and the "New Agent" command. Empty falls back to the
/// first saved profile.
@"ai-default-profile": []const u8 = "",

/// UI language. auto follows the system locale. Restart required.
language: i18n.LanguageSetting = .auto,

// ============================================================================
// Remote Access (opt-in foundations)
// ============================================================================

/// Enables outbound remote access connection attempts. Phase 1 only parses
/// this config; no remote control is enabled by this flag yet.
@"remote-enabled": bool = false,

/// Cloudflare-hosted relay URL, for example https://remote.example.com.
@"remote-server-url": ?[]const u8 = null,

/// Expected server public key or certificate fingerprint for pinning.
@"remote-server-fingerprint": ?[]const u8 = null,

/// Optional friendly name shown on the remote access page.
@"remote-device-name": ?[]const u8 = null,

/// Optional fixed remote session key base. When set, the first local WispTerm
/// instance uses it directly and later local instances append _1, _2, ...
@"remote-session-key": ?[]const u8 = null,

/// Enables the embedded WeChat ilink direct path. Independent from
/// remote-enabled and from the Remote server's Weixin bridge binding.
@"weixin-direct-enabled": bool = false,

/// Override for the ilink API base URL. Defaults to the public endpoint.
@"weixin-base-url": ?[]const u8 = null,

/// Deprecated (no-op): AI-reply delivery now waits until the WeChat
/// context_token window (~30 min) closes, then prompts the user to resend.
/// Retained so existing configs keep parsing; the value no longer affects timing.
@"weixin-reply-timeout-ms": u32 = 120000,

/// When set, only this ilink user_id may control the terminal/AI. When empty,
/// the first 1:1 sender after login is auto-bound as owner.
@"weixin-allowed-user": ?[]const u8 = null,

/// When true (with weixin-direct-enabled and a bound owner), also forward agent
/// finish/confirm notifications to the bound WeChat owner. Opt-in; default off.
@"weixin-notify-forward": bool = false,

/// Show a debug FPS overlay in the bottom-right corner.
@"wispterm-debug-fps": bool = false,
@"wispterm-debug-draw-calls": bool = false,
@"wispterm-debug-memory": bool = false,
/// Write rendering/window-geometry diagnostics to
/// `%APPDATA%\wispterm\render-diagnostic.log` (Windows). Equivalent to setting
/// the `WISPTERM_RENDER_DIAGNOSTICS=1` env var, but survives restarts and needs
/// no shell setup — intended for users helping debug resize/DPI render glitches.
@"wispterm-debug-render": bool = false,

// ============================================================================
// Split pane configuration
// ============================================================================

/// Opacity of unfocused split panes (0.15 - 1.0). Lower values make
/// unfocused splits more visible. Matches Ghostty's unfocused-split-opacity.
@"unfocused-split-opacity": f32 = 0.7,

/// Color of the divider line between split panes (hex #RRGGBB).
@"split-divider-color": ?Color = null,

/// When true, moving the mouse into a split pane focuses it.
@"focus-follows-mouse": bool = false,

/// When true, persist tab/split layout to the platform config directory on
/// close, and restore it on next launch (unless CLI args specify otherwise).
/// Default false: the file is neither written nor read when this is off.
@"restore-tabs-on-startup": bool = false,

/// Check GitHub Releases for a newer WispTerm version after startup.
@"auto-update-check": bool = true,

/// Load an additional config file. Can be repeated. Relative paths are
/// resolved relative to the file containing the directive. Prefix with
/// `?` to make optional (missing file is silently ignored).
@"config-file": ?[]const u8 = null,

// ============================================================================
// Color Overrides (applied on top of theme)
// ============================================================================

/// Background color override. Overrides the theme's background color.
/// Specified as hex (#RRGGBB or RRGGBB).
background: ?Color = null,

/// Foreground color override. Overrides the theme's foreground color.
/// Specified as hex (#RRGGBB or RRGGBB).
foreground: ?Color = null,

/// Cursor color override. Overrides the theme's cursor color.
/// Specified as hex (#RRGGBB or RRGGBB).
@"cursor-color": ?Color = null,

/// Cursor text color override. Overrides the theme's cursor text color.
/// Specified as hex (#RRGGBB or RRGGBB).
@"cursor-text": ?Color = null,

/// Selection background color override.
/// Specified as hex (#RRGGBB or RRGGBB).
@"selection-background": ?Color = null,

/// Selection foreground color override.
/// Specified as hex (#RRGGBB or RRGGBB).
@"selection-foreground": ?Color = null,

/// Palette color overrides. Indexed 0-15 for the 16 ANSI colors.
/// Use syntax: palette = N=#RRGGBB (e.g., palette = 0=#000000)
palette_overrides: [16]?Color = .{null} ** 16,

// ============================================================================
// Background Image
// ============================================================================

/// Path to an image file (PNG/JPG/BMP/GIF/...) to draw behind the terminal.
/// When set, the theme background color and per-cell background colors are
/// rendered with `background-opacity` so the image shows through.
@"background-image": ?[]const u8 = null,

/// Opacity applied to the theme background and per-cell background colors
/// (0.0 = fully transparent, 1.0 = fully opaque). Lower values reveal more of
/// the background image. Has no visible effect when `background-image` is unset.
@"background-opacity": f32 = 1.0,

/// How the background image is sized relative to the window.
/// Values: fill (default, cover), fit (letterbox), center, tile.
@"background-image-mode": BackgroundImageMode = .fill,

// ============================================================================
// Window Options
// ============================================================================

/// Force the window title to this value. Programs cannot override it.
title: ?[]const u8 = null,

/// Start the window maximized.
maximize: bool = false,

/// Start the window in fullscreen mode.
fullscreen: bool = false,

/// Start in Quake-style drop-down terminal mode. The toggle shortcut comes
/// from the `toggle_quake` keybind, which is global by default.
@"quake-mode": bool = true,

/// Application-level keyboard shortcuts. Values use Ghostty-style
/// `keybind = trigger=action` syntax; `global:` registers a native hotkey.
keybinds: keybind.Set = keybind.Set.defaults(),

// ============================================================================
// Resolved State (not serialized)
// ============================================================================

/// The resolved theme (from theme file or defaults).
resolved_theme: Theme = Theme.default(),

/// Path to the loaded config file (for diagnostics), or null.
config_path: ?[]const u8 = null,

/// Strings allocated during config loading that must be freed.
_owned_strings: std.ArrayListUnmanaged([]const u8) = .empty,

// ============================================================================
// Cleanup
// ============================================================================

/// Free any memory owned by this Config.
pub fn deinit(self: *const Config, allocator: std.mem.Allocator) void {
    if (self.config_path) |path| {
        allocator.free(path);
    }
    for (self._owned_strings.items) |s| {
        allocator.free(s);
    }
    // We need a mutable copy to deinit the list itself
    var list = self._owned_strings;
    list.deinit(allocator);
}

// ============================================================================
// Loading
// ============================================================================

/// Load config from the default file location and CLI args.
/// Order: defaults → config file → CLI flags (last wins).
pub fn load(allocator: std.mem.Allocator) !Config {
    var self = Config{};
    errdefer self.deinit(allocator);

    // 1. Try loading from config file
    if (configFilePath(allocator)) |path| {
        self.config_path = path;
        self.loadFile(allocator, path) catch |err| {
            log.warn("failed to load config file {s}: {}", .{ path, err });
        };
    } else |_| {}

    // 2. Override with CLI args (highest priority)
    try self.loadCliArgs(allocator);

    // 3. Resolve theme
    if (self.theme) |theme_name| {
        self.resolveTheme(allocator, theme_name);
    }

    // 4. Apply color overrides on top of resolved theme
    self.applyColorOverrides();

    return self;
}

/// Default config file path: `<config-dir>/config`.
pub fn defaultConfigFilePath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.configFilePath(allocator);
}

/// Active main config file path.
/// Priority: CLI --config/--config-path, portable wispterm.conf next to the app,
/// then the default config path.
pub fn configFilePath(allocator: std.mem.Allocator) ![]const u8 {
    if (try mainConfigPathArgFromProcess(allocator)) |explicit_path| {
        return explicit_path;
    }

    if (try platform_dirs.portableConfigFilePath(allocator)) |portable_path| {
        if (pathExists(portable_path)) return portable_path;
        allocator.free(portable_path);
    }

    return defaultConfigFilePath(allocator);
}

/// Default session-state file path: `<config-dir>/session.json`.
pub fn sessionFilePath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.sessionFilePath(allocator);
}

/// Print the path that would be used for the config file.
pub fn printConfigPath(allocator: std.mem.Allocator) void {
    writeConfigPath(allocator, std.fs.File.stdout().deprecatedWriter()) catch {};
}

pub fn writeConfigPath(allocator: std.mem.Allocator, writer: anytype) !void {
    if (configFilePath(allocator)) |path| {
        defer allocator.free(path);
        try writer.print("Config file: {s}\n", .{path});
    } else |_| {
        try writer.writeAll("Config file: (could not determine path)\n");
    }
}

fn mainConfigPathArgFromProcess(allocator: std.mem.Allocator) !?[]const u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    return mainConfigPathArg(allocator, args);
}

fn mainConfigPathArg(allocator: std.mem.Allocator, args: []const []const u8) !?[]const u8 {
    var result: ?[]const u8 = null;
    errdefer if (result) |path| allocator.free(path);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "--config-path")) {
            if (i + 1 >= args.len) continue;
            i += 1;
            if (args[i].len == 0) continue;
            if (result) |path| allocator.free(path);
            result = try allocator.dupe(u8, args[i]);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--config=")) {
            const value = arg["--config=".len..];
            if (value.len == 0) continue;
            if (result) |path| allocator.free(path);
            result = try allocator.dupe(u8, value);
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--config-path=")) {
            const value = arg["--config-path=".len..];
            if (value.len == 0) continue;
            if (result) |path| allocator.free(path);
            result = try allocator.dupe(u8, value);
            continue;
        }
    }

    return result;
}

fn selectConfigFilePath(
    allocator: std.mem.Allocator,
    explicit_path: ?[]const u8,
    portable_path: ?[]const u8,
    default_path: []const u8,
) ![]const u8 {
    if (explicit_path) |path| {
        return try allocator.dupe(u8, path);
    }
    if (portable_path) |path| {
        if (pathExists(path)) {
            return try allocator.dupe(u8, path);
        }
    }
    return try allocator.dupe(u8, default_path);
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ============================================================================
// String Ownership
// ============================================================================

/// Duplicate a string and track it for cleanup in deinit.
fn dupeString(self: *Config, allocator: std.mem.Allocator, value: []const u8) ?[]const u8 {
    const duped = allocator.dupe(u8, value) catch return null;
    self._owned_strings.append(allocator, duped) catch {
        allocator.free(duped);
        return null;
    };
    return duped;
}

// ============================================================================
// File Parsing
// ============================================================================

/// Load config values from a file. Values override current state.
fn loadFile(self: *Config, allocator: std.mem.Allocator, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const dir = std.fs.path.dirname(path) orelse ".";

    self.parseContent(allocator, content, dir);
}

/// Parse config file content. `base_dir` is used to resolve relative
/// `config-file` paths.
fn parseContent(self: *Config, allocator: std.mem.Allocator, content: []const u8, base_dir: []const u8) void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const raw_value = stripInlineComment(std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t"));
            // Strip optional quotes
            const value = stripQuotes(raw_value);

            self.applyKeyValue(allocator, key, value, base_dir);
        }
    }
}

/// Apply a single key = value pair to the config.
fn applyKeyValue(self: *Config, allocator: std.mem.Allocator, key: []const u8, value: []const u8, base_dir: []const u8) void {
    if (std.mem.eql(u8, key, "font-family")) {
        self.@"font-family" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "font-family-cjk")) {
        self.@"font-family-cjk" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "font-family-fallback")) {
        self.@"font-family-fallback" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "font-style")) {
        if (FontWeight.parse(value)) |w| {
            self.@"font-style" = w;
        } else {
            log.warn("unknown font-style: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "font-size")) {
        self.@"font-size" = std.fmt.parseInt(u32, value, 10) catch {
            log.warn("invalid font-size: {s}", .{value});
            return;
        };
    } else if (std.mem.eql(u8, key, "cursor-style")) {
        if (std.mem.eql(u8, value, "block")) {
            self.@"cursor-style" = .block;
        } else if (std.mem.eql(u8, value, "bar")) {
            self.@"cursor-style" = .bar;
        } else if (std.mem.eql(u8, value, "underline")) {
            self.@"cursor-style" = .underline;
        } else if (std.mem.eql(u8, value, "block_hollow")) {
            self.@"cursor-style" = .block_hollow;
        } else {
            log.warn("unknown cursor-style: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "cursor-style-blink")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"cursor-style-blink" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"cursor-style-blink" = false;
        } else {
            log.warn("invalid cursor-style-blink: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "theme")) {
        self.theme = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "custom-shader")) {
        self.@"custom-shader" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "window-height")) {
        const v = std.fmt.parseInt(u16, value, 10) catch {
            log.warn("invalid window-height: {s}", .{value});
            return;
        };
        self.@"window-height" = @max(4, v);
    } else if (std.mem.eql(u8, key, "window-width")) {
        const v = std.fmt.parseInt(u16, value, 10) catch {
            log.warn("invalid window-width: {s}", .{value});
            return;
        };
        self.@"window-width" = @max(10, v);
    } else if (std.mem.eql(u8, key, "scrollback-limit")) {
        self.@"scrollback-limit" = std.fmt.parseInt(u32, value, 10) catch {
            log.warn("invalid scrollback-limit: {s}", .{value});
            return;
        };
    } else if (std.mem.eql(u8, key, "copy-on-select")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"copy-on-select" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"copy-on-select" = false;
        } else {
            log.warn("invalid copy-on-select: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "right-click-action")) {
        if (RightClickAction.parse(value)) |action| {
            self.@"right-click-action" = action;
        } else {
            log.warn("invalid right-click-action: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "language")) {
        if (i18n.LanguageSetting.parse(value)) |setting| {
            self.language = setting;
        } else {
            log.warn("invalid language: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "url-open-mode")) {
        if (UrlOpenMode.parse(value)) |mode| {
            self.@"url-open-mode" = mode;
        } else {
            log.warn("invalid url-open-mode: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "ssh-legacy-algorithms")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"ssh-legacy-algorithms" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"ssh-legacy-algorithms" = false;
        } else {
            log.warn("invalid ssh-legacy-algorithms: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "ai-agent-enabled")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"ai-agent-enabled" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"ai-agent-enabled" = false;
        } else {
            log.warn("invalid ai-agent-enabled: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "ai-agent-permission")) {
        if (ai_agent_config.AgentPermission.parse(value)) |permission| {
            self.@"ai-agent-permission" = permission;
        } else {
            log.warn("invalid ai-agent-permission: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "ai-agent-command-timeout-ms")) {
        self.@"ai-agent-command-timeout-ms" = std.fmt.parseInt(u32, value, 10) catch {
            log.warn("invalid ai-agent-command-timeout-ms: {s}", .{value});
            return;
        };
    } else if (std.mem.eql(u8, key, "ai-agent-output-limit")) {
        self.@"ai-agent-output-limit" = std.fmt.parseInt(u32, value, 10) catch {
            log.warn("invalid ai-agent-output-limit: {s}", .{value});
            return;
        };
    } else if (std.mem.eql(u8, key, "shell")) {
        self.shell = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "ai-default-profile")) {
        self.@"ai-default-profile" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "remote-enabled")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"remote-enabled" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"remote-enabled" = false;
        } else {
            log.warn("invalid remote-enabled: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "remote-server-url")) {
        self.@"remote-server-url" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "remote-server-fingerprint")) {
        self.@"remote-server-fingerprint" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "remote-device-name")) {
        self.@"remote-device-name" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "remote-session-key")) {
        self.@"remote-session-key" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "weixin-direct-enabled")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"weixin-direct-enabled" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"weixin-direct-enabled" = false;
        } else {
            log.warn("invalid weixin-direct-enabled: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "weixin-base-url")) {
        self.@"weixin-base-url" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "weixin-reply-timeout-ms")) {
        self.@"weixin-reply-timeout-ms" = std.fmt.parseInt(u32, value, 10) catch {
            log.warn("invalid weixin-reply-timeout-ms: {s}", .{value});
            return;
        };
    } else if (std.mem.eql(u8, key, "weixin-allowed-user")) {
        self.@"weixin-allowed-user" = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "weixin-notify-forward")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"weixin-notify-forward" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"weixin-notify-forward" = false;
        } else {
            log.warn("invalid weixin-notify-forward: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "wispterm-debug-fps")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"wispterm-debug-fps" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"wispterm-debug-fps" = false;
        } else {
            log.warn("invalid wispterm-debug-fps: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "wispterm-debug-draw-calls")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"wispterm-debug-draw-calls" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"wispterm-debug-draw-calls" = false;
        } else {
            log.warn("invalid wispterm-debug-draw-calls: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "wispterm-debug-memory")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"wispterm-debug-memory" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"wispterm-debug-memory" = false;
        } else {
            log.warn("invalid wispterm-debug-memory: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "unfocused-split-opacity")) {
        if (std.fmt.parseFloat(f32, value)) |opacity| {
            self.@"unfocused-split-opacity" = @max(0.15, @min(1.0, opacity));
        } else |_| {
            log.warn("invalid unfocused-split-opacity: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "split-divider-color")) {
        if (parseColor(value)) |color| {
            self.@"split-divider-color" = color;
        } else {
            log.warn("invalid split-divider-color: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "focus-follows-mouse")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"focus-follows-mouse" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"focus-follows-mouse" = false;
        } else {
            log.warn("invalid focus-follows-mouse: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "restore-tabs-on-startup")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"restore-tabs-on-startup" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"restore-tabs-on-startup" = false;
        } else {
            log.warn("invalid restore-tabs-on-startup: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "auto-update-check")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"auto-update-check" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"auto-update-check" = false;
        } else {
            log.warn("invalid auto-update-check: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "config-file")) {
        self.loadConfigFileDirective(allocator, value, base_dir);
    } else if (std.mem.eql(u8, key, "background")) {
        if (parseColor(value)) |color| {
            self.background = color;
        } else {
            log.warn("invalid background color: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "foreground")) {
        if (parseColor(value)) |color| {
            self.foreground = color;
        } else {
            log.warn("invalid foreground color: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "cursor-color")) {
        if (parseColor(value)) |color| {
            self.@"cursor-color" = color;
        } else {
            log.warn("invalid cursor-color: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "cursor-text")) {
        if (parseColor(value)) |color| {
            self.@"cursor-text" = color;
        } else {
            log.warn("invalid cursor-text: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "selection-background")) {
        if (parseColor(value)) |color| {
            self.@"selection-background" = color;
        } else {
            log.warn("invalid selection-background: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "selection-foreground")) {
        if (parseColor(value)) |color| {
            self.@"selection-foreground" = color;
        } else {
            log.warn("invalid selection-foreground: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "palette")) {
        // Syntax: palette = N=COLOR (e.g., palette = 0=#000000)
        if (std.mem.indexOf(u8, value, "=")) |eq_idx| {
            const idx_str = value[0..eq_idx];
            const color_str = value[eq_idx + 1 ..];
            const idx = std.fmt.parseInt(u8, idx_str, 10) catch {
                log.warn("invalid palette index: {s}", .{idx_str});
                return;
            };
            if (idx >= 16) {
                log.warn("palette index out of range (0-15): {}", .{idx});
                return;
            }
            if (parseColor(color_str)) |color| {
                self.palette_overrides[idx] = color;
            } else {
                log.warn("invalid palette color: {s}", .{color_str});
            }
        } else {
            log.warn("invalid palette syntax, expected N=COLOR: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "background-image")) {
        if (value.len == 0) {
            self.@"background-image" = null;
        } else {
            self.@"background-image" = self.dupeString(allocator, value) orelse return;
        }
    } else if (std.mem.eql(u8, key, "background-opacity")) {
        if (std.fmt.parseFloat(f32, value)) |opacity| {
            self.@"background-opacity" = @max(0.0, @min(1.0, opacity));
        } else |_| {
            log.warn("invalid background-opacity: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "background-image-mode")) {
        if (BackgroundImageMode.parse(value)) |m| {
            self.@"background-image-mode" = m;
        } else {
            log.warn("invalid background-image-mode (expected fill|fit|center|tile): {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "title")) {
        self.title = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "maximize")) {
        if (std.mem.eql(u8, value, "true")) {
            self.maximize = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.maximize = false;
        } else {
            log.warn("invalid maximize value: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "fullscreen")) {
        if (std.mem.eql(u8, value, "true")) {
            self.fullscreen = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.fullscreen = false;
        } else {
            log.warn("invalid fullscreen value: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "quake-mode")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"quake-mode" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"quake-mode" = false;
        } else {
            log.warn("invalid quake-mode value: {s}", .{value});
        }
    } else if (std.mem.eql(u8, key, "keybind")) {
        self.keybinds.apply(value) catch |err| {
            log.warn("invalid keybind '{s}': {}", .{ value, err });
        };
    } else {
        // Silently ignore unknown keys (theme files reuse the same format
        // and may contain keys we don't handle, like palette).
    }
}

/// Handle the `config-file` directive: load an additional config file.
fn loadConfigFileDirective(self: *Config, allocator: std.mem.Allocator, raw_path: []const u8, base_dir: []const u8) void {
    if (raw_path.len == 0) return;

    // Optional prefix: `?` means ignore if missing
    const optional = raw_path[0] == '?';
    const path_str = if (optional) raw_path[1..] else raw_path;
    if (path_str.len == 0) return;

    // Resolve relative paths against the containing file's directory
    const resolved = if (std.fs.path.isAbsolute(path_str))
        allocator.dupe(u8, path_str) catch return
    else
        std.fs.path.join(allocator, &.{ base_dir, path_str }) catch return;
    defer allocator.free(resolved);

    self.loadFile(allocator, resolved) catch |err| {
        if (!optional) {
            log.warn("failed to load config-file '{s}': {}", .{ resolved, err });
        }
    };
}

// ============================================================================
// CLI Argument Parsing
// ============================================================================

/// Parse CLI args and apply them to the config (highest priority).
fn loadCliArgs(self: *Config, allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Skip non-flag arguments
        if (arg.len < 2 or arg[0] != '-') continue;

        // Handle --key=value form
        if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
            const flag = stripDashes(arg[0..eq_pos]);
            if (isMainConfigPathFlag(flag)) continue;
            const value = arg[eq_pos + 1 ..];
            self.applyKeyValue(allocator, flag, value, ".");
            continue;
        }

        // Handle --key value form (and short aliases)
        const flag = stripDashes(arg);

        // Special commands (not config keys, handled by main)
        if (isSpecialCommand(flag)) continue;
        if (isMainConfigPathFlag(flag)) {
            if (i + 1 < args.len) {
                i += 1;
            } else {
                log.warn("flag --{s} requires a value", .{flag});
            }
            continue;
        }

        // Short aliases and backward-compatible renames
        const resolved_flag = if (std.mem.eql(u8, flag, "f") or std.mem.eql(u8, flag, "font"))
            "font-family"
        else if (std.mem.eql(u8, flag, "shader"))
            "custom-shader"
        else
            flag;

        // Consume next arg as value
        if (i + 1 < args.len) {
            i += 1;
            self.applyKeyValue(allocator, resolved_flag, args[i], ".");
        } else {
            log.warn("flag --{s} requires a value", .{flag});
        }
    }
}

fn isMainConfigPathFlag(flag: []const u8) bool {
    return std.mem.eql(u8, flag, "config") or
        std.mem.eql(u8, flag, "config-path");
}

pub fn isSpecialCommand(flag: []const u8) bool {
    return std.mem.eql(u8, flag, "list-fonts") or
        std.mem.eql(u8, flag, "list-themes") or
        std.mem.eql(u8, flag, "test-font-discovery") or
        std.mem.eql(u8, flag, "help") or
        std.mem.eql(u8, flag, "h") or
        std.mem.eql(u8, flag, "version") or
        std.mem.eql(u8, flag, "v") or
        std.mem.eql(u8, flag, "show-config-path");
}

/// Check if CLI args contain a specific command flag (e.g. --list-fonts).
pub fn hasCommand(allocator: std.mem.Allocator, command: []const u8) bool {
    const args = std.process.argsAlloc(allocator) catch return false;
    defer std.process.argsFree(allocator, args);

    for (args[1..]) |arg| {
        const flag = stripDashes(arg);
        if (std.mem.eql(u8, flag, command)) return true;
    }
    return false;
}

// ============================================================================
// Theme Resolution
// ============================================================================

/// Resolve a theme by name or path. Search order (like Ghostty):
///   1. Absolute path → load directly
///   2. User themes:  <config-dir>/themes/<name>
///   3. Embedded themes compiled into the binary
fn resolveTheme(self: *Config, allocator: std.mem.Allocator, theme_name: []const u8) void {
    // 1. Absolute path — load directly
    if (std.fs.path.isAbsolute(theme_name)) {
        if (Theme.loadFromFile(allocator, theme_name)) |theme| {
            self.resolved_theme = theme;
            log.info("loaded theme from absolute path: {s}", .{theme_name});
            return;
        } else |_| {}
        log.warn("theme file not found: {s}", .{theme_name});
        return;
    }

    // 2. User themes: <config-dir>/themes/<name>
    if (platform_dirs.themeFilePath(allocator, theme_name)) |path| {
        defer allocator.free(path);
        if (Theme.loadFromFile(allocator, path)) |theme| {
            self.resolved_theme = theme;
            log.info("loaded theme '{s}' from user dir: {s}", .{ theme_name, path });
            return;
        } else |_| {}
    } else |_| {}

    // 3. Embedded themes compiled into the binary
    if (themes.get(theme_name)) |data| {
        self.resolved_theme = Theme.parseThemeContent(data);
        log.info("loaded embedded theme: {s}", .{theme_name});
        return;
    }

    log.warn("theme not found: {s}", .{theme_name});
}

/// Apply top-level color overrides to the resolved theme.
/// Called after theme resolution so user overrides take precedence.
fn applyColorOverrides(self: *Config) void {
    if (self.background) |color| {
        self.resolved_theme.background = color;
    }
    if (self.foreground) |color| {
        self.resolved_theme.foreground = color;
    }
    if (self.@"cursor-color") |color| {
        self.resolved_theme.cursor_color = color;
    }
    if (self.@"cursor-text") |color| {
        self.resolved_theme.cursor_text = color;
    }
    if (self.@"selection-background") |color| {
        self.resolved_theme.selection_background = color;
    }
    if (self.@"selection-foreground") |color| {
        self.resolved_theme.selection_foreground = color;
    }
    // Apply palette overrides
    for (self.palette_overrides, 0..) |maybe_color, i| {
        if (maybe_color) |color| {
            self.resolved_theme.palette[i] = color;
        }
    }
}

// ============================================================================
// Help
// ============================================================================

pub fn listThemes() void {
    writeThemes(std.fs.File.stdout().deprecatedWriter()) catch {};
}

pub fn writeThemes(writer: anytype) !void {
    try writer.print("Available built-in themes ({} total):\n\n", .{themes.entries.len});
    for (&themes.entries) |*entry| {
        try writer.print("  {s}\n", .{entry.name});
    }
    try writer.writeAll("\nUser themes in <config-dir>\\themes\\ take priority.\n");
    try writer.writeAll("Set with: theme = <name>\n");
}

pub fn printHelp() void {
    writeHelp(std.fs.File.stdout().deprecatedWriter()) catch {};
}

pub fn writeHelp(writer: anytype) !void {
    try writer.writeAll(
        \\WispTerm - A terminal emulator
        \\
        \\Usage: wispterm [options]
        \\
        \\Options:
        \\  --config <path>              Use this file as the main config
        \\  --config-path <path>         Alias for --config
        \\  --font-family <name>         Font family (default: embedded fallback)
        \\  -f <name>                    Alias for --font-family
        \\  --font-family-cjk <name>     Preferred font for Chinese/Japanese/Korean glyphs
        \\  --font-family-fallback <csv> Comma-separated fallback family priority list
        \\  --font-style <style>         Font weight (default: regular)
        \\                               Values: thin, extra-light, light, regular, medium,
        \\                                       semi-bold, bold, extra-bold, black
        \\  --font-size <pt>             Font size in points (default: 13)
        \\  --cursor-style <style>       Cursor shape (default: "block")
        \\                               Values: block, bar, underline, block_hollow
        \\  --cursor-style-blink <bool>  Enable cursor blinking (default: true)
        \\  --theme <name|path>          Theme name or file path
        \\  --custom-shader <path>       Ghostty-compatible GLSL post-processing shader
        \\  --window-height <rows>       Initial height in cells (default: 0=auto, min: 4)
        \\  --window-width <cols>        Initial width in cells (default: 0=auto, min: 10)
        \\  --scrollback-limit <bytes>   Scrollback buffer size (default: 10000000)
        \\  --copy-on-select <bool>      Copy terminal selection when mouse selection completes
        \\  --right-click-action <mode>  ignore | copy | paste | copy-or-paste
        \\  --url-open-mode <mode>       embedded | system-browser
        \\  --language <lang>            UI language: auto | en | zh-CN (default: auto)
        \\  --ssh-legacy-algorithms <bool> Enable legacy ssh-rsa/ssh-dss OpenSSH options
        \\  --ai-agent-enabled <bool>    Enable AI Chat agent tools by default
        \\  --ai-agent-permission <mode> Agent tool permission: confirm | full
        \\  --ai-agent-command-timeout-ms <ms> Agent command timeout budget
        \\  --ai-agent-output-limit <bytes> Max bytes returned by each tool
        \\  --auto-update-check <bool>  Check GitHub Releases after startup
        \\  --config-file <path>         Include another config file (prefix ? for optional)
        \\  --keybind <binding>          Configure a shortcut, e.g. global:ctrl+backquote=toggle_quake
        \\  --remote-enabled <bool>      Enable opt-in remote access foundation
        \\  --remote-server-url <url>    Cloudflare relay URL
        \\  --remote-server-fingerprint <fp> Expected relay fingerprint
        \\  --remote-device-name <name>  Friendly device name for remote access
        \\  --remote-session-key <key>   Fixed remote key base; later instances append _1, _2
        \\  --weixin-direct-enabled <bool> Enable embedded WeChat ilink direct path
        \\  --weixin-base-url <url>      Override ilink API base URL
        \\  --weixin-reply-timeout-ms <n> Deprecated (no-op); AI-reply window is ~30 min
        \\  --weixin-allowed-user <id>   Restrict control to one ilink user_id
        \\  --weixin-notify-forward <bool> Forward agent notifications to the bound WeChat owner
        \\  --quake-mode <bool>          Enable Quake-style drop-down mode (default: true)
        \\
        \\Color Options (override theme):
        \\  --background <color>         Background color (#RRGGBB or RRGGBB)
        \\  --foreground <color>         Foreground/text color
        \\  --cursor-color <color>       Cursor color
        \\  --cursor-text <color>        Text color under cursor
        \\  --selection-background <color>  Selection background color
        \\  --selection-foreground <color>  Selection text color
        \\  --palette <N=color>          Set ANSI color N (0-15), e.g. --palette 1=#ff0000
        \\  --background-image <path>    Image file to render behind the terminal
        \\  --background-opacity <0..1>  Opacity of theme/cell backgrounds (default: 1.0)
        \\  --background-image-mode <m>  fill | fit | center | tile (default: fill)
        \\
        \\Window Options:
        \\  --title <text>               Force window title (programs cannot override)
        \\  --maximize <bool>            Start maximized (default: false)
        \\  --fullscreen <bool>          Start in fullscreen (default: false)
        \\
        \\Debug:
        \\  --wispterm-debug-fps <bool>   Show FPS overlay (default: false)
        \\  --wispterm-debug-draw-calls <bool> Show draw call count overlay (default: false)
        \\  --wispterm-debug-memory <bool> Print periodic memory attribution (default: false)
        \\
        \\Commands:
        \\  --version, -v                Print the WispTerm version and exit
        \\  --show-config-path           Print the config file path and exit
        \\  --list-fonts                 List all available system fonts
        \\  --list-themes                List all available themes
        \\  --test-font-discovery        Test font discovery for common fonts
        \\  --help, -h                   Show this help message
        \\
        \\Config priority: --config/--config-path, portable wispterm.conf next to the app, then the platform config directory
        \\User themes: <config-dir>\themes\
        \\
        \\Config file uses Ghostty's key = value format. Example:
        \\
        \\  font-family = Cascadia Code
        \\  font-family-cjk = Sarasa Mono SC
        \\  font-family-fallback = Sarasa Mono SC, Noto Sans Mono CJK SC, Microsoft YaHei UI
        \\  font-size = 16
        \\  theme = Catppuccin Mocha
        \\  cursor-style = bar
        \\  background = #1a1b26
        \\  foreground = #c0caf5
        \\  palette = 1=#f7768e
        \\  keybind = ctrl+shift+p=toggle_command_palette
        \\  keybind = global:ctrl+backquote=toggle_quake
        \\
        \\Examples:
        \\  wispterm --font-family "Cascadia Code"
        \\  wispterm --font-family "JetBrains Mono" --font-style bold
        \\  wispterm --cursor-style bar --cursor-style-blink=false
        \\  wispterm --background "#1a1b26" --foreground "#c0caf5"
        \\  wispterm --theme poimandres
        \\  wispterm --window-height 40 --window-width 120
    );
    try writer.print("  wispterm --config {s}\n\n", .{platform_pty_command.config_profile_example_path});
}

// ============================================================================
// Ensure config exists on startup
// ============================================================================

/// Ensure the config directory and file exist. Called at startup so the
/// file watcher can observe the directory from the very beginning.
/// If the config file doesn't exist yet, it is created with the default
/// template (same one used by the open_config keybind).
pub fn ensureConfigExists(allocator: std.mem.Allocator) void {
    const path = configFilePath(allocator) catch return;
    defer allocator.free(path);

    // Create parent directory recursively
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch return;
    }

    // Create config file with default template if it doesn't exist
    if (std.fs.cwd().createFile(path, .{ .exclusive = true })) |file| {
        file.writeAll(default_config_template) catch {};
        file.close();
        log.info("created default config file: {s}", .{path});
    } else |_| {}
}

// ============================================================================
// Open / Edit Config (`open_config` keybind)
// ============================================================================

/// Ensure the config file exists (create with default template if not)
/// and open it in the platform text editor.
pub fn openConfigInEditor(allocator: std.mem.Allocator) void {
    std.debug.print("[config] openConfigInEditor called\n", .{});

    const path = configFilePath(allocator) catch |err| {
        std.debug.print("[config] ERROR: cannot determine config path: {}\n", .{err});
        return;
    };
    defer allocator.free(path);
    std.debug.print("[config] config path: {s}\n", .{path});

    // Create parent directory recursively
    if (std.fs.path.dirname(path)) |dir| {
        std.debug.print("[config] creating directory: {s}\n", .{dir});
        std.fs.cwd().makePath(dir) catch |err| {
            std.debug.print("[config] ERROR: failed to create directory: {}\n", .{err});
            return;
        };
    }

    // Create config file with default template if it doesn't exist
    if (std.fs.cwd().createFile(path, .{ .exclusive = true })) |file| {
        file.writeAll(default_config_template) catch {};
        file.close();
        std.debug.print("[config] created default config file\n", .{});
    } else |err| switch (err) {
        error.PathAlreadyExists => {
            std.debug.print("[config] config file already exists\n", .{});
        },
        else => {
            std.debug.print("[config] ERROR: failed to create config file: {}\n", .{err});
            return;
        },
    }

    std.debug.print("[config] opening editor with path: {s}\n", .{path});
    if (!platform_editor.openTextFile(allocator, .{ .path = path })) {
        std.debug.print("[config] ERROR: failed to open config editor\n", .{});
        return;
    }

    std.debug.print("[config] editor opened successfully\n", .{});
}

/// Update or append a single `key = value` line in the main config file.
/// This is used by the built-in Settings page; the file watcher applies the
/// change through the normal hot-reload path.
pub fn setConfigValue(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    ensureConfigExists(allocator);

    const path = try configFilePath(allocator);
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    defer if (content.len > 0) allocator.free(content);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var replaced = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (!replaced and configLineMatchesKey(line, key)) {
            try out.writer(allocator).print("{s} = {s}\n", .{ key, value });
            replaced = true;
        } else if (line.len > 0) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }

    if (!replaced) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        try out.writer(allocator).print("{s} = {s}\n", .{ key, value });
    }

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(out.items);
}

/// Remove active `key = value` lines from the main config file. Comments are left
/// intact, so the generated template remains useful after UI changes.
pub fn removeConfigKeys(allocator: std.mem.Allocator, keys: []const []const u8) !void {
    ensureConfigExists(allocator);

    const path = try configFilePath(allocator);
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    defer if (content.len > 0) allocator.free(content);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        var should_remove = false;
        for (keys) |key| {
            if (configLineMatchesKey(line, key)) {
                should_remove = true;
                break;
            }
        }
        if (!should_remove and line.len > 0) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(out.items);
}

fn configLineMatchesKey(line: []const u8, key: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse return false;
    const lhs = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
    return std.mem.eql(u8, lhs, key);
}

const default_config_template =
    \\# WispTerm Configuration
    \\# Ghostty-compatible key = value format
    \\# See: wispterm --help
    \\# Main config path priority: --config/--config-path, portable wispterm.conf next to the app,
    \\# then the platform config directory.
    \\
    \\# Font
    \\# font-family = JetBrains Mono
    \\# font-family-cjk = Sarasa Mono SC
    \\# font-family-fallback = Sarasa Mono SC, Noto Sans Mono CJK SC, Microsoft YaHei UI
    \\# font-style = regular
    \\# font-size = 13
    \\
    \\# Cursor
    \\# cursor-style = block
    \\# cursor-style-blink = true
    \\# cursor-color = #ffcc66
    \\# cursor-text = #1f2430
    \\
    \\# Theme (name or file path)
    \\# Common choices: Catppuccin Mocha, TokyoNight Night, GitHub Light Default, Xcode Light
    \\# theme =
    \\
    \\# Color overrides (override theme colors)
    \\# background = #1f2430
    \\# foreground = #cbccc6
    \\# selection-background = #33415e
    \\# selection-foreground = #f3f4f5
    \\# palette = 0=#191e2a
    \\# palette = 1=#ff3333
    \\
    \\# Background image (PNG/JPG/BMP/GIF). Lower background-opacity to reveal it.
    \\# background-image = C:\Users\me\wallpapers\dunes.jpg
    \\# background-opacity = 0.7
    \\# background-image-mode = fill   # fill | fit | center | tile
    \\
    \\# Custom post-processing shader (GLSL)
    \\# custom-shader =
    \\
    \\# Window
    \\# window-height = 28
    \\# window-width = 110
    \\# title =
    \\# maximize = false
    \\# fullscreen = false
    \\# quake-mode = true   # toggle_quake controls the top drop-down window
    \\
    \\# Restore the previous tab/split layout (and working dirs) on next launch.
    \\# Saved to session.json on close; off by default (file neither read nor written).
    \\# restore-tabs-on-startup = false
    \\
    \\# Keyboard shortcuts
    \\# Syntax: keybind = [global:]modifier+key=action
    \\# keybind = ctrl+shift+p=toggle_command_palette
    \\# keybind = global:ctrl+backquote=toggle_quake
    \\# keybind = alt+f10=toggle_command_palette
    \\# keybind = clear   # remove all defaults before adding custom bindings
    \\
    \\
++ platform_pty_command.shell_setting_comment ++
    \\
++ platform_pty_command.default_shell_assignment_comment ++
    \\
    \\
    \\# Remote access foundation (disabled by default)
    \\# remote-session-key is the browser pairing key, not the web admin login password.
    \\# remote-enabled = false
    \\# remote-server-url =
    \\# remote-server-fingerprint =
    \\# remote-device-name =
    \\# remote-session-key =
    \\
    \\# Scrollback buffer size in bytes (default: 10MB)
    \\# scrollback-limit = 10000000
    \\
    \\# Terminal mouse/clipboard behavior
    \\# copy-on-select = false
    \\# right-click-action = copy   # ignore | copy | paste | copy-or-paste
    \\# url-open-mode = embedded    # embedded | system-browser
    \\
    \\# UI language (auto follows the system locale; restart required)
    \\# language = auto             # auto | en | zh-CN
    \\
    \\# SSH compatibility for older bastions/servers.
    \\# Adds ssh-rsa/ssh-dss and legacy KEX/cipher options to profile/helper SSH.
    \\# ssh-legacy-algorithms = false
    \\
    \\# AI Chat agent tools (disabled by default)
    \\# ai-agent-enabled = false
    \\# ai-agent-permission = confirm   # confirm | full
    \\# ai-agent-command-timeout-ms = 60000
    \\# ai-agent-output-limit = 16384
    \\
    \\# Updates
    \\# auto-update-check = true
    \\
    \\# Debug
    \\# wispterm-debug-fps = false
    \\# wispterm-debug-draw-calls = false
    \\# wispterm-debug-memory = false
    \\
    \\# Load additional config files
    \\# config-file = ?optional/extra-config
    \\
;

// ============================================================================
// Utilities
// ============================================================================

fn stripDashes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '-' and s[1] == '-') return s[2..];
    if (s.len >= 1 and s[0] == '-') return s[1..];
    return s;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn stripInlineComment(s: []const u8) []const u8 {
    var in_quotes = false;
    var escaped = false;
    for (s, 0..) |ch, i| {
        if (in_quotes and ch == '\\' and !escaped) {
            escaped = true;
            continue;
        }
        if (ch == '"' and !escaped) {
            in_quotes = !in_quotes;
        } else if (ch == '#' and !in_quotes and i > 0 and std.ascii.isWhitespace(s[i - 1])) {
            return std.mem.trimRight(u8, s[0..i], " \t");
        }
        escaped = false;
    }
    return s;
}

pub fn hexToColor(hex: u24) Color {
    const r: f32 = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0;
    return .{ r, g, b };
}

pub fn parseColor(s: []const u8) ?Color {
    const hex_str = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex_str.len != 6) return null;

    const hex = std.fmt.parseInt(u24, hex_str, 16) catch return null;
    return hexToColor(hex);
}

test "config: sessionFilePath sits next to configFilePath" {
    const allocator = std.testing.allocator;
    const session = sessionFilePath(allocator) catch return; // skip if no env
    defer allocator.free(session);
    try std.testing.expect(std.mem.endsWith(u8, session, "session.json"));
    try std.testing.expect(std.mem.indexOf(u8, session, "wispterm") != null);
}

test "config: explicit main config path beats portable and default paths" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &dir_buf);
    const portable_path = try std.fs.path.join(allocator, &.{ dir_path, "wispterm.conf" });
    defer allocator.free(portable_path);
    const default_path = try std.fs.path.join(allocator, &.{ dir_path, "appdata", "config" });
    defer allocator.free(default_path);
    const explicit_path = try std.fs.path.join(allocator, &.{ dir_path, "profiles", "shell.conf" });
    defer allocator.free(explicit_path);

    var portable_file = try tmp.dir.createFile("wispterm.conf", .{});
    portable_file.close();

    const selected = try selectConfigFilePath(allocator, explicit_path, portable_path, default_path);
    defer allocator.free(selected);
    try std.testing.expectEqualStrings(explicit_path, selected);
}

test "config: portable config next to exe beats default config when present" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &dir_buf);
    const portable_path = try std.fs.path.join(allocator, &.{ dir_path, "wispterm.conf" });
    defer allocator.free(portable_path);
    const default_path = try std.fs.path.join(allocator, &.{ dir_path, "appdata", "config" });
    defer allocator.free(default_path);

    var portable_file = try tmp.dir.createFile("wispterm.conf", .{});
    portable_file.close();

    const selected = try selectConfigFilePath(allocator, null, portable_path, default_path);
    defer allocator.free(selected);
    try std.testing.expectEqualStrings(portable_path, selected);
}

test "config: default config is used when explicit and portable paths are absent" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &dir_buf);
    const portable_path = try std.fs.path.join(allocator, &.{ dir_path, "wispterm.conf" });
    defer allocator.free(portable_path);
    const default_path = try std.fs.path.join(allocator, &.{ dir_path, "appdata", "config" });
    defer allocator.free(default_path);

    const selected = try selectConfigFilePath(allocator, null, portable_path, default_path);
    defer allocator.free(selected);
    try std.testing.expectEqualStrings(default_path, selected);
}

test "config: main config path arg supports --config and --config-path" {
    const allocator = std.testing.allocator;

    const config_arg = try mainConfigPathArg(allocator, &.{ "wispterm", "--config", "profiles/shell.conf" });
    defer if (config_arg) |path| allocator.free(path);
    try std.testing.expectEqualStrings("profiles/shell.conf", config_arg.?);

    const config_path_arg = try mainConfigPathArg(allocator, &.{ "wispterm", "--config-path=profiles/alt-shell.conf" });
    defer if (config_path_arg) |path| allocator.free(path);
    try std.testing.expectEqualStrings("profiles/alt-shell.conf", config_path_arg.?);
}

test "config: help text is writable to a caller-provided writer" {
    const allocator = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try writeHelp(out.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "Usage: wispterm [options]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "--config <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "--config-file <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, platform_pty_command.config_profile_example_path) != null);
}

test "config: shell defaults and template come from platform pty command" {
    const cfg = Config{};
    try std.testing.expectEqualStrings(platform_pty_command.defaultShellName(), cfg.shell);
    try std.testing.expect(std.mem.indexOf(u8, default_config_template, platform_pty_command.shellSettingComment()) != null);
    try std.testing.expect(std.mem.indexOf(u8, default_config_template, platform_pty_command.defaultShellAssignmentComment()) != null);
}

test "config: font weight exposes backend-neutral values" {
    try std.testing.expectEqual(@as(u16, 100), FontWeight.thin.value());
    try std.testing.expectEqual(@as(u16, 400), FontWeight.regular.value());
    try std.testing.expectEqual(@as(u16, 700), FontWeight.bold.value());
    try std.testing.expectEqual(@as(u16, 900), FontWeight.black.value());
}

test "config: restore-tabs-on-startup parses true/false" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};

    // Default is false.
    try std.testing.expectEqual(false, cfg.@"restore-tabs-on-startup");

    // Set to true.
    cfg.applyKeyValue(allocator, "restore-tabs-on-startup", "true", ".");
    try std.testing.expectEqual(true, cfg.@"restore-tabs-on-startup");

    // Set back to false.
    cfg.applyKeyValue(allocator, "restore-tabs-on-startup", "false", ".");
    try std.testing.expectEqual(false, cfg.@"restore-tabs-on-startup");

    // Invalid value leaves the previous state untouched (still false).
    cfg.applyKeyValue(allocator, "restore-tabs-on-startup", "maybe", ".");
    try std.testing.expectEqual(false, cfg.@"restore-tabs-on-startup");
}

test "config: auto update check option parses true false" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};

    try std.testing.expectEqual(true, cfg.@"auto-update-check");

    cfg.applyKeyValue(allocator, "auto-update-check", "false", ".");
    try std.testing.expectEqual(false, cfg.@"auto-update-check");

    cfg.applyKeyValue(allocator, "auto-update-check", "true", ".");
    try std.testing.expectEqual(true, cfg.@"auto-update-check");

    cfg.applyKeyValue(allocator, "auto-update-check", "maybe", ".");
    try std.testing.expectEqual(true, cfg.@"auto-update-check");
}

test "config: quake mode defaults enabled and parses true false" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};

    try std.testing.expectEqual(true, cfg.@"quake-mode");

    cfg.applyKeyValue(allocator, "quake-mode", "false", ".");
    try std.testing.expectEqual(false, cfg.@"quake-mode");

    cfg.applyKeyValue(allocator, "quake-mode", "true", ".");
    try std.testing.expectEqual(true, cfg.@"quake-mode");

    cfg.applyKeyValue(allocator, "quake-mode", "maybe", ".");
    try std.testing.expectEqual(true, cfg.@"quake-mode");
}

test "config: inline comments after values are ignored" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};
    defer cfg.deinit(allocator);

    cfg.parseContent(
        allocator,
        "background-image-mode = fit   # fill | fit | center | tile\n" ++
            "background = #112233   # color comment\n" ++
            "title = \"hello # not a comment\"\n",
        ".",
    );

    try std.testing.expectEqual(BackgroundImageMode.fit, cfg.@"background-image-mode");
    try std.testing.expectEqual(hexToColor(0x112233), cfg.background.?);
    try std.testing.expectEqualStrings("hello # not a comment", cfg.title.?);
}

test "config: keybind directives override default action bindings" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};
    const is_macos = builtin.target.os.tag == .macos;

    // Command palette default is Cmd+Shift+P on macOS, Ctrl+Shift+P elsewhere.
    try std.testing.expectEqual(keybind.Action.toggle_command_palette, cfg.keybinds.lookupApp(.{
        .mods = if (is_macos) .{ .win = true, .shift = true } else .{ .ctrl = true, .shift = true },
        .key_code = 'P',
    }).?);

    cfg.applyKeyValue(allocator, "keybind", "alt+f10=toggle_command_palette", ".");

    try std.testing.expect(cfg.keybinds.lookupApp(.{
        .mods = if (is_macos) .{ .win = true, .shift = true } else .{ .ctrl = true, .shift = true },
        .key_code = 'P',
    }) == null);
    try std.testing.expectEqual(keybind.Action.toggle_command_palette, cfg.keybinds.lookupApp(.{
        .mods = .{ .alt = true },
        .key_code = 0x79,
    }).?);
}

test "config: ai agent options parse" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};

    try std.testing.expectEqual(false, cfg.@"ai-agent-enabled");
    try std.testing.expectEqual(ai_agent_config.AgentPermission.confirm, cfg.@"ai-agent-permission");

    cfg.applyKeyValue(allocator, "ai-agent-enabled", "true", ".");
    cfg.applyKeyValue(allocator, "ai-agent-permission", "full", ".");
    cfg.applyKeyValue(allocator, "ai-agent-command-timeout-ms", "120000", ".");
    cfg.applyKeyValue(allocator, "ai-agent-output-limit", "4096", ".");

    try std.testing.expectEqual(true, cfg.@"ai-agent-enabled");
    try std.testing.expectEqual(ai_agent_config.AgentPermission.full, cfg.@"ai-agent-permission");
    try std.testing.expectEqual(@as(u32, 120000), cfg.@"ai-agent-command-timeout-ms");
    try std.testing.expectEqual(@as(u32, 4096), cfg.@"ai-agent-output-limit");
}

test "config: copy and right click options parse" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};

    try std.testing.expectEqual(false, cfg.@"copy-on-select");
    try std.testing.expectEqual(RightClickAction.copy, cfg.@"right-click-action");
    try std.testing.expectEqual(UrlOpenMode.embedded, cfg.@"url-open-mode");

    cfg.applyKeyValue(allocator, "copy-on-select", "true", ".");
    cfg.applyKeyValue(allocator, "right-click-action", "copy-or-paste", ".");
    cfg.applyKeyValue(allocator, "url-open-mode", "system-browser", ".");

    try std.testing.expectEqual(true, cfg.@"copy-on-select");
    try std.testing.expectEqual(RightClickAction.copy_or_paste, cfg.@"right-click-action");
    try std.testing.expectEqual(UrlOpenMode.system_browser, cfg.@"url-open-mode");

    cfg.applyKeyValue(allocator, "url-open-mode", "default-browser", ".");
    try std.testing.expectEqual(UrlOpenMode.system_browser, cfg.@"url-open-mode");

    cfg.applyKeyValue(allocator, "url-open-mode", "embedded", ".");
    try std.testing.expectEqual(UrlOpenMode.embedded, cfg.@"url-open-mode");
}

test "config: ssh legacy algorithm option parses" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};

    try std.testing.expectEqual(false, cfg.@"ssh-legacy-algorithms");
    cfg.applyKeyValue(allocator, "ssh-legacy-algorithms", "true", ".");
    try std.testing.expectEqual(true, cfg.@"ssh-legacy-algorithms");
}

test "config: remote session key parses" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.@"remote-session-key" == null);

    cfg.applyKeyValue(allocator, "remote-session-key", "fixed-password", ".");
    try std.testing.expectEqualStrings("fixed-password", cfg.@"remote-session-key".?);
}

test "config: version flags are special commands" {
    try std.testing.expect(isSpecialCommand("version"));
    try std.testing.expect(isSpecialCommand("v"));
}

test "config: ai-default-profile parses" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("", cfg.@"ai-default-profile");
    cfg.applyKeyValue(allocator, "ai-default-profile", "GPT-4o", ".");
    try std.testing.expectEqualStrings("GPT-4o", cfg.@"ai-default-profile");
}

test "config: language parses auto/en/zh-CN and rejects invalid" {
    const allocator = std.testing.allocator;
    var cfg = Config{};
    defer cfg.deinit(allocator);

    // 默认应为 auto
    try std.testing.expect(cfg.language == .auto);

    cfg.applyKeyValue(allocator, "language", "zh-CN", ".");
    try std.testing.expect(cfg.language == .zh_CN);

    cfg.applyKeyValue(allocator, "language", "en", ".");
    try std.testing.expect(cfg.language == .en);

    // 非法值保持上一次有效值（en），仅告警
    cfg.applyKeyValue(allocator, "language", "klingon", ".");
    try std.testing.expect(cfg.language == .en);

    cfg.applyKeyValue(allocator, "language", "auto", ".");
    try std.testing.expect(cfg.language == .auto);
}
