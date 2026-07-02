//! Runtime source-guard test entry point.
//! Keeps the app test guard coverage out of Zig comptime evaluation.

const std = @import("std");

fn readSource(allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "src/{s}", .{rel_path});
    defer allocator.free(path);
    return try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
}

fn guardFailed(message: []const u8) error{SourceGuardFailed} {
    std.debug.print("source guard failed: {s}\n", .{message});
    return error.SourceGuardFailed;
}

test "app source guards" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, "test_main.zig");
    defer allocator.free(source);
    const concrete_font_backend = "platform/" ++ "directwrite.zig";
    if (std.mem.indexOf(u8, source, concrete_font_backend) != null) {
        return guardFailed("test_main.zig must import platform/font_backend.zig, not the concrete DirectWrite backend");
    }

    const app_window_source = try readSource(allocator, "AppWindow.zig");
    defer allocator.free(app_window_source);
    if (std.mem.indexOf(u8, app_window_source, "builtin." ++ "os.tag") != null) {
        return guardFailed("AppWindow.zig must keep native handle OS switches behind platform/window_backend.zig");
    }
    if (std.mem.indexOf(u8, app_window_source, "W" ++ "M_") != null) {
        return guardFailed("AppWindow.zig comments and logic must describe platform-neutral event handling, not Win32 messages");
    }
    if (std.mem.indexOf(u8, app_window_source, "[260]u16") != null or
        std.mem.indexOf(u8, app_window_source, "[256]u16") != null or
        std.mem.indexOf(u8, app_window_source, "[*:0]const u16") != null or
        std.mem.indexOf(u8, app_window_source, "utf8PathToCwdPtr") != null or
        std.mem.indexOf(u8, app_window_source, "unixPathToWindows") != null or
        std.mem.indexOf(u8, app_window_source, "unixPathToNativeCwd") != null or
        std.mem.indexOf(u8, app_window_source, "unixPathToLocalPathUtf8") != null or
        std.mem.indexOf(u8, app_window_source, "utf16LeToUtf8") != null or
        std.mem.indexOf(u8, app_window_source, "utf8ToUtf16Le(cwd_buf") != null or
        std.mem.indexOf(u8, app_window_source, "utf8ToUtf16LeAllocZ") != null)
    {
        return guardFailed("AppWindow.zig launch plumbing must use platform_pty_command launch types and allocators");
    }
    // apprt/win32.zig API-surface leak checks live in
    // platform/apprt_win32_guard.zig so this shared/test module does not embed
    // the Windows runtime directly. It is imported below to run those guards.

    const update_install_source = try readSource(allocator, "update_install.zig");
    defer allocator.free(update_install_source);
    if (std.mem.indexOf(u8, update_install_source, "@import(\"builtin\").os.tag") != null) {
        return guardFailed("update_install.zig must use platform/update_package.zig for OS package selection");
    }
    const platform_threading_source = try readSource(allocator, "platform/threading.zig");
    defer allocator.free(platform_threading_source);
    if (std.mem.indexOf(u8, platform_threading_source, "Windows") != null) {
        return guardFailed("platform/threading.zig thread policy comments must describe runtime roles, not Windows implementation defaults");
    }
    if (std.mem.indexOf(u8, update_install_source, "isWindowsDriveQualified") != null or
        std.mem.indexOf(u8, update_install_source, "isIllegalWindowsNameChar") != null or
        std.mem.indexOf(u8, update_install_source, "UnsafeZipEntryName") != null)
    {
        return guardFailed("update_install.zig must validate archive entry names through platform/update_package.zig");
    }
    if (std.mem.indexOf(u8, update_install_source, "PayloadValidation") != null or
        std.mem.indexOf(u8, update_install_source, "require_webview2_loader") != null or
        std.mem.indexOf(u8, update_install_source, "MissingWebView2Loader") != null or
        std.mem.indexOf(u8, update_install_source, "has_" ++ "webview2_loader") != null or
        std.mem.indexOf(u8, update_install_source, "portable_" ++ "webview2") != null or
        std.mem.indexOf(u8, update_install_source, "WebView2") != null)
    {
        return guardFailed("update_install.zig must validate release package manifests without WebView2-specific options or errors");
    }
    if (std.mem.indexOf(u8, update_install_source, "windowsPortablePackage") != null) {
        return guardFailed("update_install.zig tests must use platform-neutral update package scenarios");
    }
    if (std.mem.indexOf(u8, update_install_source, "Backend.windows_portable") != null or
        std.mem.indexOf(u8, update_install_source, "defaultPackageForOs(.windows)") != null)
    {
        return guardFailed("update_install.zig tests must not assert concrete platform package backends directly");
    }
    if (std.mem.indexOf(u8, update_install_source, "\"wispterm.exe\"") != null or
        std.mem.indexOf(u8, update_install_source, "\"wispterm-updater.exe\"") != null)
    {
        return guardFailed("update_install.zig tests must get executable payload paths through platform/update_package.zig");
    }

    const local_path_source = try readSource(allocator, "platform/local_path.zig");
    defer allocator.free(local_path_source);
    if (std.mem.indexOf(u8, local_path_source, "pub fn isAbsoluteOrWindows") != null) {
        return guardFailed("platform/local_path.zig public APIs must use platform-neutral path role names");
    }
    if (std.mem.indexOf(u8, local_path_source, "windows" ++ "RootLen") != null or
        std.mem.indexOf(u8, local_path_source, "canonical" ++ "WindowsPath") != null or
        std.mem.indexOf(u8, local_path_source, "is" ++ "WindowsAbsolute") != null or
        std.mem.indexOf(u8, local_path_source, "normalize" ++ "WindowsPath") != null or
        std.mem.indexOf(u8, local_path_source, "simple" ++ "WindowsCaseFold") != null or
        std.mem.indexOf(u8, local_path_source, "windows" ++ "CaseInsensitiveUtf8Equal") != null or
        std.mem.indexOf(u8, local_path_source, "windows" ++ "AbsolutePathEqual") != null)
    {
        return guardFailed("platform/local_path.zig path helpers must describe native path roles instead of Windows-specific helper names");
    }
    const app_source = try readSource(allocator, "App.zig");
    defer allocator.free(app_source);
    if (std.mem.indexOf(u8, app_source, "WebView2") != null or
        std.mem.indexOf(u8, app_source, "webview2") != null or
        std.mem.indexOf(u8, app_source, "wispterm-windows-portable") != null)
    {
        return guardFailed("App.zig must keep concrete release asset names behind update/release package modules");
    }
    if (std.mem.indexOf(u8, app_source, "[256]u16") != null or
        std.mem.indexOf(u8, app_source, "[260]u16") != null or
        std.mem.indexOf(u8, app_source, "?[]const u16") != null)
    {
        return guardFailed("App.zig must use platform_pty_command buffer types for launch command and cwd storage");
    }
    if (std.mem.indexOf(u8, app_source, "resolveShellCommandUtf16") != null or
        std.mem.indexOf(u8, app_source, "UTF-16") != null or
        std.mem.indexOf(u8, app_window_source, "resolveShellCommandUtf16") != null or
        std.mem.indexOf(u8, app_window_source, "UTF-16") != null)
    {
        return guardFailed("App/AppWindow launch APIs must use native command line names, not UTF-16-specific names");
    }

    const profile_codec_source = try readSource(allocator, "renderer/overlays/profile_codec.zig");
    defer allocator.free(profile_codec_source);
    if (std.mem.indexOf(u8, profile_codec_source, "pub const SSH_FIELD_COUNT = 8") == null or
        std.mem.indexOf(u8, profile_codec_source, "auth_method = 6") == null or
        std.mem.indexOf(u8, profile_codec_source, "identity_file = 7") == null or
        std.mem.indexOf(u8, profile_codec_source, "port_forward") != null)
    {
        return guardFailed("ssh_hosts profile schema must only add server auth fields; port forwarding must not extend it");
    }

    const ssh_tunnel_source = try readSource(allocator, "ssh/tunnel.zig");
    defer allocator.free(ssh_tunnel_source);
    if (std.mem.indexOf(u8, ssh_tunnel_source, "\"-L\"") == null or
        std.mem.indexOf(u8, ssh_tunnel_source, "\"-R\"") != null)
    {
        return guardFailed("Existing URL SSH tunnel code must remain local-forwarding only");
    }

    const shared_pty_source_paths = [_][]const u8{
        "Surface.zig",
        "termio/Thread.zig",
        "termio/ReadThread.zig",
    };
    for (shared_pty_source_paths) |pty_source_path| {
        const pty_source = try readSource(allocator, pty_source_path);
        defer allocator.free(pty_source);
        if (std.mem.indexOf(u8, pty_source, "ConPTY") != null or
            std.mem.indexOf(u8, pty_source, "ResizePseudoConsole") != null or
            std.mem.indexOf(u8, pty_source, "ReadFile") != null or
            std.mem.indexOf(u8, pty_source, "CancelIoEx") != null or
            std.mem.indexOf(u8, pty_source, "OperationAborted") != null or
            std.mem.indexOf(u8, pty_source, "Windows-side") != null)
        {
            return guardFailed("shared PTY/termio code must describe platform-neutral PTY behavior");
        }
    }

    const termio_thread_source = try readSource(allocator, "termio/Thread.zig");
    defer allocator.free(termio_thread_source);
    if (std.mem.indexOf(u8, termio_thread_source, "self.loop.run(.until_done) catch {};") != null or
        std.mem.indexOf(u8, termio_thread_source, "surface.pty.writeInput(data) catch {};") != null or
        std.mem.indexOf(u8, termio_thread_source, "surface.pty.setSize(.{ .ws_col = grid.cols, .ws_row = grid.rows }) catch {};") != null or
        std.mem.indexOf(u8, termio_thread_source, "surface.terminal.resize(surface.allocator, grid.cols, grid.rows) catch {};") != null)
    {
        return guardFailed("termio Thread IO errors must route through Surface.failIo instead of catch {}");
    }

    const termio_read_source = try readSource(allocator, "termio/ReadThread.zig");
    defer allocator.free(termio_read_source);
    if (std.mem.indexOf(u8, termio_read_source, "surface.exited.store(true, .release);") != null) {
        return guardFailed("ReadThread exits must route through Surface IoState helpers so UI wakeups and reasons stay consistent");
    }

    const update_check_source = try readSource(allocator, "update_check.zig");
    defer allocator.free(update_check_source);
    if (std.mem.indexOf(u8, update_check_source, "wispterm-windows-portable") != null) {
        return guardFailed("update_check.zig tests must build concrete release asset names through release_package helpers");
    }
    if (std.mem.indexOf(u8, update_check_source, "ReleasePackage.windowsPortable") != null) {
        return guardFailed("update_check.zig tests must construct concrete platform packages through platform/update_package.zig");
    }
    if (std.mem.indexOf(u8, update_check_source, "windowsPortablePackage") != null) {
        return guardFailed("update_check.zig tests must use platform-neutral update package scenarios");
    }
    const release_package_source = try readSource(allocator, "release_package.zig");
    defer allocator.free(release_package_source);
    if (std.mem.indexOf(u8, release_package_source, "\"wispterm.exe\"") != null or
        std.mem.indexOf(u8, release_package_source, "\"wispterm-updater.exe\"") != null)
    {
        return guardFailed("release_package.zig must keep concrete executable payload names behind platform/update_package backends");
    }
    if (std.mem.indexOf(u8, release_package_source, "wispterm-windows-portable") != null) {
        return guardFailed("release_package.zig must keep concrete asset naming behind platform/update_package backends");
    }
    if (std.mem.indexOf(u8, release_package_source, "WindowsPortable") != null or
        std.mem.indexOf(u8, release_package_source, "windows_portable") != null or
        std.mem.indexOf(u8, release_package_source, "windowsPortable") != null)
    {
        return guardFailed("release_package.zig must use platform-neutral package flavors instead of Windows portable fields");
    }
    if (std.mem.indexOf(u8, release_package_source, "requires" ++ "WebView2Loader") != null or
        std.mem.indexOf(u8, release_package_source, "webview2" ++ "LoaderPath") != null or
        std.mem.indexOf(u8, release_package_source, "webview2_" ++ "loader_path") != null or
        std.mem.indexOf(u8, release_package_source, "portable_" ++ "webview2") != null or
        std.mem.indexOf(u8, release_package_source, "portable_no_" ++ "webview") != null)
    {
        return guardFailed("release_package.zig public helpers must describe embedded browser payloads, not WebView2-specific APIs");
    }
    if (std.mem.indexOf(u8, update_check_source, "portable_" ++ "webview2") != null or
        std.mem.indexOf(u8, update_check_source, "portable_no_" ++ "webview") != null)
    {
        return guardFailed("update_check.zig tests must use embedded-browser package flavor names");
    }
    const update_package_source = try readSource(allocator, "platform/update_package.zig");
    defer allocator.free(update_package_source);
    if (std.mem.indexOf(u8, update_package_source, "has_" ++ "webview2_loader") != null or
        std.mem.indexOf(u8, update_package_source, "portable_" ++ "webview2") != null or
        std.mem.indexOf(u8, update_package_source, "portable_no_" ++ "webview") != null)
    {
        return guardFailed("platform/update_package.zig public APIs must use embedded-browser package flavor names");
    }
    if (std.mem.indexOf(u8, update_package_source, "windows_portable") != null) {
        return guardFailed("platform/update_package.zig facade backend names must describe platforms, not concrete package shapes");
    }
    if (std.mem.indexOf(u8, update_package_source, "windows" ++ "_package") != null) {
        return guardFailed("platform/update_package.zig facade backend aliases must describe package backend roles, not concrete platform package names");
    }
    if (std.mem.indexOf(u8, update_package_source, "isWindowsDriveQualifiedArchiveName") != null or
        std.mem.indexOf(u8, update_package_source, "isIllegalWindowsArchiveNameChar") != null)
    {
        return guardFailed("platform/update_package.zig archive validation helpers must use archive-safety names, not Windows implementation names");
    }
    const pty_command_source = try readSource(allocator, "platform/pty_command.zig");
    defer allocator.free(pty_command_source);
    if (std.mem.indexOf(u8, pty_command_source, "windows_create_process") != null) {
        return guardFailed("platform/pty_command.zig facade backend names must describe platforms, not CreateProcess details");
    }
    if (std.mem.indexOf(u8, pty_command_source, "PseudoConsoleHandle") != null) {
        return guardFailed("platform/pty_command.zig facade must not expose pseudo-console handles");
    }
    if (std.mem.indexOf(u8, pty_command_source, "pub fn shellCommandLooksLikePowerShell") != null or
        std.mem.indexOf(u8, pty_command_source, "pub fn configuredPowerShellCommandForShell") != null)
    {
        return guardFailed("platform/pty_command.zig public shell APIs must describe local-shell roles, not PowerShell-specific helpers");
    }
    if (std.mem.indexOf(u8, pty_command_source, "appendWindowsQuotedArg") != null) {
        return guardFailed("platform/pty_command.zig command quoting helpers must describe command-line roles, not Windows implementation names");
    }
    if (std.mem.indexOf(u8, pty_command_source, "Windows" ++ "LocalShell") != null) {
        return guardFailed("platform/pty_command.zig local-shell helpers must describe native shell roles, not Windows-local helper names");
    }
    if (std.mem.indexOf(u8, pty_command_source, "if (std.mem.indexOf(u8, lower, \"powershell.exe\")") != null or
        std.mem.indexOf(u8, pty_command_source, "friendlyShellTitle(\"C:" ++ "\\\\Windows") != null)
    {
        return guardFailed("platform/pty_command.zig must delegate concrete native shell title mappings to backend implementations");
    }
    if (std.mem.indexOf(u8, pty_command_source, "if (std.ascii.eqlIgnoreCase(kind, \"powershell\")) return") != null or
        std.mem.indexOf(u8, pty_command_source, "if (!appendAscii(buf, &pos, \"wsl.exe\"))") != null or
        std.mem.indexOf(u8, pty_command_source, "return .{ \"wsl.exe\"") != null or
        std.mem.indexOf(u8, pty_command_source, "std.fmt.bufPrint(buf, \"cmd.exe /c ssh.exe") != null)
    {
        return guardFailed("platform/pty_command.zig must delegate concrete tab, WSL, and SSH command construction to backend implementations");
    }
    if (std.mem.indexOf(u8, pty_command_source, "std.mem.indexOf(u8, lower, \"ssh.exe\")") != null or
        std.mem.indexOf(u8, pty_command_source, "std.mem.indexOf(u8, lower, \"wsl.exe\")") != null)
    {
        return guardFailed("platform/pty_command.zig must delegate concrete launch-kind command classification to backend implementations");
    }
    if (std.mem.indexOf(u8, pty_command_source, "\"cmd.exe /c ssh.exe") != null or
        std.mem.indexOf(u8, pty_command_source, "\"wsl.exe ~") != null)
    {
        return guardFailed("platform/pty_command.zig facade tests must keep concrete Windows SSH/WSL command-line samples in backend implementations");
    }
    const pty_facade_source = try readSource(allocator, "platform/pty.zig");
    defer allocator.free(pty_facade_source);
    if (std.mem.indexOf(u8, pty_facade_source, "windows_conpty") != null) {
        return guardFailed("platform/pty.zig facade backend names must describe platforms, not ConPTY details");
    }
    const platform_facade_backend_detail_checks = [_]struct { path: []const u8, needle: []const u8 }{
        .{ .path = "platform/clipboard.zig", .needle = ".win32_clipboard" },
        .{ .path = "platform/clipboard.zig", .needle = "_win32.zig" },
        .{ .path = "platform/com.zig", .needle = ".windows_ole32" },
        .{ .path = "platform/com.zig", .needle = "com_windows_ole32.zig" },
        .{ .path = "platform/config_watcher.zig", .needle = ".windows_read_directory_changes" },
        .{ .path = "platform/console.zig", .needle = ".windows_parent_console" },
        .{ .path = "platform/console.zig", .needle = ".windows_parent_process" },
        .{ .path = "platform/cursor.zig", .needle = ".win32" },
        .{ .path = "platform/cursor.zig", .needle = "_win32.zig" },
        .{ .path = "platform/display.zig", .needle = ".win32_monitor" },
        .{ .path = "platform/display.zig", .needle = "_win32.zig" },
        .{ .path = "platform/file_dialog.zig", .needle = ".win32_common_dialog" },
        .{ .path = "platform/file_dialog.zig", .needle = "_win32.zig" },
        .{ .path = "platform/font_backend.zig", .needle = ".directwrite" },
        .{ .path = "platform/font_backend.zig", .needle = "font_backend_directwrite.zig" },
        .{ .path = "platform/font_backend_windows.zig", .needle = "@import(\"directwrite.zig\")" },
        .{ .path = "platform/global_hotkey.zig", .needle = ".win32" },
        .{ .path = "platform/global_hotkey.zig", .needle = "_win32.zig" },
        .{ .path = "platform/memory.zig", .needle = ".windows_psapi" },
        .{ .path = "platform/memory.zig", .needle = "memory_windows_psapi.zig" },
        .{ .path = "platform/open_url.zig", .needle = ".windows_shell" },
        .{ .path = "platform/open_url.zig", .needle = ".posix_command" },
        .{ .path = "platform/remote_transport.zig", .needle = ".winhttp" },
        .{ .path = "platform/remote_transport.zig", .needle = "remote_transport_winhttp.zig" },
        .{ .path = "platform/session_lock.zig", .needle = ".windows_mutex" },
        .{ .path = "platform/session_lock.zig", .needle = "session_lock_windows_mutex.zig" },
        .{ .path = "platform/session_lock.zig", .needle = ".local_process" },
        .{ .path = "platform/text.zig", .needle = ".windows_compare_string" },
        .{ .path = "platform/text.zig", .needle = "text_windows_compare_string.zig" },
        .{ .path = "platform/text.zig", .needle = "windowsOrdinalIgnoreCaseUtf8Equal" },
        .{ .path = "platform/webview.zig", .needle = ".webview2" },
        .{ .path = "platform/webview.zig", .needle = "webview_webview2.zig" },
        .{ .path = "platform/window.zig", .needle = ".win32" },
        .{ .path = "platform/window.zig", .needle = "_win32.zig" },
        .{ .path = "platform/window_backend.zig", .needle = ".win32" },
        .{ .path = "platform/window_backend.zig", .needle = "_win32.zig" },
    };
    for (platform_facade_backend_detail_checks) |check| {
        const facade_source = try readSource(allocator, check.path);
        defer allocator.free(facade_source);
        if (std.mem.indexOf(u8, facade_source, check.needle) != null) {
            std.debug.print("source guard failed: {s} facade backend names must describe platform roles, not backend implementation details\n", .{check.path});
            return error.SourceGuardFailed;
        }
    }
    const command_source = try readSource(allocator, "Command.zig");
    defer allocator.free(command_source);
    if (std.mem.indexOf(u8, command_source, "PseudoConsoleHandle") != null or
        std.mem.indexOf(u8, command_source, "pseudo_console") != null)
    {
        return guardFailed("Command.zig must start commands through the app-facing PTY API, not pseudo-console handles");
    }
    const surface_source = try readSource(allocator, "Surface.zig");
    defer allocator.free(surface_source);
    if (std.mem.indexOf(u8, surface_source, "pty.pseudo_console") != null) {
        return guardFailed("Surface/AppWindow code must not reach into platform PTY pseudo-console handles");
    }

    if (std.mem.indexOf(u8, command_source, "[*:0]const u16") != null or
        std.mem.indexOf(u8, command_source, "[:0]const u16") != null or
        std.mem.indexOf(u8, surface_source, "[*:0]const u16") != null or
        std.mem.indexOf(u8, surface_source, "[:0]const u16") != null)
    {
        return guardFailed("Surface/Command launch interfaces must use platform_pty_command launch types, not raw Windows UTF-16 pointers");
    }

    const tab_source = try readSource(allocator, "appwindow/tab.zig");
    defer allocator.free(tab_source);
    if (std.mem.indexOf(u8, tab_source, "[256]u16") != null or
        std.mem.indexOf(u8, tab_source, "[*:0]const u16") != null or
        std.mem.indexOf(u8, tab_source, "[:0]const u16") != null or
        std.mem.indexOf(u8, tab_source, "[:0]u16") != null or
        std.mem.indexOf(u8, tab_source, "utf8ToUtf16LeAllocZ") != null)
    {
        return guardFailed("appwindow/tab.zig launch APIs must use platform_pty_command launch types and allocators");
    }

    const input_source = try readSource(allocator, "input.zig");
    defer allocator.free(input_source);
    if (std.mem.indexOf(u8, input_source, "W" ++ "M_") != null or
        std.mem.indexOf(u8, input_source, "Windows generated them") != null)
    {
        return guardFailed("input.zig comments and logic must describe platform-neutral input events, not Win32 messages");
    }
    if (std.mem.indexOf(u8, input_source, "[260]u16") != null or
        std.mem.indexOf(u8, input_source, "?[]const u16") != null or
        std.mem.indexOf(u8, input_source, "unixPathToWindows") != null or
        std.mem.indexOf(u8, input_source, "unixPathToNativeCwd") != null or
        std.mem.indexOf(u8, input_source, "unixPathToLocalPathUtf8") != null)
    {
        return guardFailed("input.zig must use platform_wsl/platform_pty_command native cwd helpers");
    }
    if (std.mem.indexOf(u8, input_source, "\"{s}\\\\{s}\"") != null) {
        return guardFailed("input.zig must build local filesystem paths through platform/local_path.zig");
    }
    const platform_input_source = try readSource(allocator, "platform/input_events.zig");
    defer allocator.free(platform_input_source);
    if (std.mem.indexOf(u8, platform_input_source, "pub const VK_") != null or
        std.mem.indexOf(u8, input_source, "platform_input.VK_") != null or
        std.mem.indexOf(u8, input_source, "const VK_") != null)
    {
        return guardFailed("shared input APIs must use backend-neutral key_* names instead of Win32 VK aliases");
    }
    const keybind_source = try readSource(allocator, "keybind.zig");
    defer allocator.free(keybind_source);
    if (std.mem.indexOf(u8, platform_input_source, "vk: KeyCode") != null or
        std.mem.indexOf(u8, input_source, "ev.vk") != null)
    {
        return guardFailed("shared input events must use key_code naming instead of Win32 VK naming");
    }
    if (std.mem.indexOf(u8, keybind_source, "vk: u32") != null or
        std.mem.indexOf(u8, keybind_source, ".vk") != null or
        std.mem.indexOf(u8, keybind_source, "trigger.vk") != null)
    {
        return guardFailed("keybind triggers must use key_code naming instead of Win32 VK naming");
    }
    if (std.mem.indexOf(u8, keybind_source, "VK_{X}") != null) {
        return guardFailed("keybind.zig fallback key labels must not expose Win32 VK terminology");
    }
    const platform_global_hotkey_source = try readSource(allocator, "platform/global_hotkey.zig");
    defer allocator.free(platform_global_hotkey_source);
    if (std.mem.indexOf(u8, platform_global_hotkey_source, "vk: u32") != null or
        std.mem.indexOf(u8, platform_global_hotkey_source, ".vk") != null or
        std.mem.indexOf(u8, platform_global_hotkey_source, "trigger.vk") != null)
    {
        return guardFailed("platform/global_hotkey.zig facade must use key_code naming instead of Win32 VK naming");
    }
    const input_clipboard_source = try readSource(allocator, "input/clipboard.zig");
    defer allocator.free(input_clipboard_source);
    if (std.mem.indexOf(u8, input_clipboard_source, "platform_wsl") != null or
        std.mem.indexOf(u8, input_clipboard_source, "windowsPathToWslPathAlloc") != null)
    {
        return guardFailed("input/clipboard.zig must ask platform remote-file helpers to adapt local paths for terminal paste targets");
    }
    // Image-preview drag-to-pan wiring guard: the behavior was silently lost
    // once before (the #185 right-dock → pane migration) because it lived only
    // in mouse glue. The state machine is unit-tested in
    // input/preview_image_drag.zig; these checks pin the input.zig call sites
    // that route mouse press/move/release into it.
    if (std.mem.indexOf(u8, input_source, "g_preview_image_drag.begin(") == null) {
        return guardFailed("input.zig mouse-down must start the image-preview pan drag via PreviewImageDrag.begin");
    }
    if (std.mem.indexOf(u8, input_source, "g_preview_image_drag.move(") == null) {
        return guardFailed("input.zig mouse-move must pan the image preview via PreviewImageDrag.move");
    }
    if (std.mem.indexOf(u8, input_source, "g_preview_image_drag.release(") == null) {
        return guardFailed("input.zig must drop the image-preview pan drag via PreviewImageDrag.release on mouse-up/cancel");
    }
    const platform_wsl_source = try readSource(allocator, "platform/wsl.zig");
    defer allocator.free(platform_wsl_source);
    if (std.mem.indexOf(u8, platform_wsl_source, "pub fn windowsPathToWslPathAlloc") != null or
        std.mem.indexOf(u8, platform_wsl_source, "pub fn unixPathToWindows") != null or
        std.mem.indexOf(u8, platform_wsl_source, "pub fn unixPathToNativeCwd") != null or
        std.mem.indexOf(u8, platform_wsl_source, "pub fn unixPathToLocalPathUtf8") != null)
    {
        return guardFailed("platform/wsl.zig public path APIs must describe host/guest roles, not Windows/Unix implementation details");
    }
    const platform_remote_file_source = try readSource(allocator, "platform/remote_file.zig");
    defer allocator.free(platform_remote_file_source);
    if (std.mem.indexOf(u8, platform_remote_file_source, "windowsPathToWslPathAlloc") != null) {
        return guardFailed("platform/remote_file.zig must use platform-neutral WSL path adapter names");
    }
    const platform_process_source = try readSource(allocator, "platform/process.zig");
    defer allocator.free(platform_process_source);
    if (std.mem.indexOf(u8, platform_process_source, "windows_powershell") != null) {
        return guardFailed("platform/process.zig local shell variants must describe shell roles, not Windows-specific platform names");
    }
    if (std.mem.indexOf(u8, platform_process_source, "pub const LocalShell =") != null or
        std.mem.indexOf(u8, platform_process_source, "pub fn localShellFallback(") != null or
        std.mem.indexOf(u8, platform_process_source, "pub fn localShellCommandArgv(") != null)
    {
        return guardFailed("platform/process.zig must expose local-shell fallback argv as one narrow API instead of public shell variant plumbing");
    }

    const browser_panel_source = try readSource(allocator, "browser/panel.zig");
    defer allocator.free(browser_panel_source);
    if (std.mem.indexOf(u8, browser_panel_source, "[MAX_URL_BYTES]u16") != null or
        std.mem.indexOf(u8, browser_panel_source, "urlToWide") != null or
        std.mem.indexOf(u8, browser_panel_source, "utf8ToUtf16Le") != null)
    {
        return guardFailed("browser/panel.zig must use platform_webview URL helpers instead of WebView2 UTF-16 details");
    }
    const open_url_source = try readSource(allocator, "platform/open_url.zig");
    defer allocator.free(open_url_source);
    if (std.mem.indexOf(u8, open_url_source, "ShellExecute") != null or
        std.mem.indexOf(u8, open_url_source, "windowsShellExecuteSucceeded") != null)
    {
        return guardFailed("platform/open_url.zig must keep native browser-open details in concrete backends");
    }

    const session_persist_source = try readSource(allocator, "session_persist.zig");
    defer allocator.free(session_persist_source);
    if (std.mem.indexOf(u8, session_persist_source, "NTFS") != null or
        std.mem.indexOf(u8, session_persist_source, "replace_if_exists") != null or
        std.mem.indexOf(u8, session_persist_source, "std.fs.cwd().atomicFile") != null or
        std.mem.indexOf(u8, session_persist_source, "AtomicFileOptions") != null)
    {
        return guardFailed("session_persist.zig must write replace-safe files through platform/atomic_file.zig");
    }

    const font_manager_source = try readSource(allocator, "font/manager.zig");
    defer allocator.free(font_manager_source);
    if (std.mem.indexOf(u8, font_manager_source, "utf16LeToUtf8") != null or
        std.mem.indexOf(u8, font_manager_source, "createFontFace") != null or
        std.mem.indexOf(u8, font_manager_source, "getFiles") != null or
        std.mem.indexOf(u8, font_manager_source, "getLoader") != null or
        std.mem.indexOf(u8, font_manager_source, "queryLocalFontFileLoader") != null or
        std.mem.indexOf(u8, font_manager_source, "getReferenceKey") != null or
        std.mem.indexOf(u8, font_manager_source, "getFilePathLengthFromKey") != null or
        std.mem.indexOf(u8, font_manager_source, "getFilePathFromKey") != null)
    {
        return guardFailed("font/manager.zig must load fallback font paths through platform/font_backend.zig");
    }
    if (std.mem.indexOf(u8, font_manager_source, "g_dpi: u32 = 96") != null or
        std.mem.indexOf(u8, font_manager_source, "Windows to scale a 96-DPI") != null or
        std.mem.indexOf(u8, app_window_source, "96 DPI") != null or
        std.mem.indexOf(u8, app_window_source, "font.g_dpi / 96") != null)
    {
        return guardFailed("font/AppWindow shared DPI code must get display baseline DPI from platform/display.zig");
    }

    const file_explorer_source = try readSource(allocator, "file_explorer.zig");
    defer allocator.free(file_explorer_source);
    if (std.mem.indexOf(u8, file_explorer_source, "else '\\\\'") != null or
        std.mem.indexOf(u8, file_explorer_source, "expandWithBackend(idx, .local, '\\\\')") != null or
        std.mem.indexOf(u8, file_explorer_source, "buf[parent.len] = '\\\\'") != null or
        std.mem.indexOf(u8, file_explorer_source, "\"{s}\\\\{s}\"") != null)
    {
        return guardFailed("file_explorer.zig must build local filesystem paths through platform/local_path.zig");
    }

    const config_source = try readSource(allocator, "config.zig");
    defer allocator.free(config_source);
    if (std.mem.indexOf(u8, config_source, "shell: []const u8 = \"cmd\"") != null or
        std.mem.indexOf(u8, config_source, "# Shell (cmd, powershell, pwsh, wsl, or a custom path)") != null or
        std.mem.indexOf(u8, config_source, "# shell = cmd") != null or
        std.mem.indexOf(u8, config_source, "profiles\\powershell.conf") != null or
        std.mem.indexOf(u8, config_source, "profiles/pwsh.conf") != null or
        std.mem.indexOf(u8, config_source, "\"pwsh.conf\"") != null)
    {
        return guardFailed("config.zig must get shell defaults and generated config text from platform/pty_command.zig");
    }

    if (std.mem.indexOf(u8, app_source, "cfg.shell = \"powershell\"") != null or
        std.mem.indexOf(u8, app_source, "next.shell = \"pwsh\"") != null)
    {
        return guardFailed("App.zig tests must get shell config examples from platform/pty_command.zig");
    }

    const overlays_source = try readSource(allocator, "renderer/overlays.zig");
    defer allocator.free(overlays_source);
    if (std.mem.indexOf(u8, overlays_source, "cmd / powershell / pwsh / wsl") != null or
        std.mem.indexOf(u8, overlays_source, "fn nextShell") != null)
    {
        return guardFailed("renderer/overlays.zig must get shell cycling and hint text from platform/pty_command.zig");
    }
    if (std.mem.indexOf(u8, overlays_source, "const SESSION_LAUNCHER_ROW_COUNT = 4") != null or
        std.mem.indexOf(u8, overlays_source, "2 => .wsl") != null or
        std.mem.indexOf(u8, overlays_source, "renderSessionRow(layout, window_height, 2, \"WSL\"") != null)
    {
        return guardFailed("renderer/overlays.zig must get optional WSL session launcher layout from platform/pty_command.zig");
    }
    if (std.mem.indexOf(u8, overlays_source, ".codex") != null or
        std.mem.indexOf(u8, overlays_source, ".claude") != null or
        std.mem.indexOf(u8, overlays_source, ".reasonix") != null or
        std.mem.indexOf(u8, overlays_source, "parseMetadata") != null)
    {
        return guardFailed("renderer/overlays.zig must only launch AI History sources; provider scanning belongs in ai_history modules");
    }

    const titlebar_source = try readSource(allocator, "renderer/titlebar.zig");
    defer allocator.free(titlebar_source);
    if (std.mem.indexOf(u8, titlebar_source, "Windows Terminal-style caption button") != null or
        std.mem.indexOf(u8, titlebar_source, "Windows Terminal's visual style") != null or
        std.mem.indexOf(u8, titlebar_source, "so Windows\n/// caption hit-testing") != null or
        std.mem.indexOf(u8, titlebar_source, "const caption_btn_w: f32 = 46") != null or
        std.mem.indexOf(u8, titlebar_source, "const top_caption_btn_w: f32 = 46") != null)
    {
        return guardFailed("renderer/titlebar.zig must get caption button metrics and style text through platform/window.zig");
    }

    const startup_tabs_source = try readSource(allocator, "startup_tabs.zig");
    defer allocator.free(startup_tabs_source);
    if (std.mem.indexOf(u8, startup_tabs_source, "agent_and_powershell") != null) {
        return guardFailed("startup_tabs.zig must name the default pair as agent plus local shell, not PowerShell");
    }

    const appwindow_source = try readSource(allocator, "AppWindow.zig");
    defer allocator.free(appwindow_source);
    if (std.mem.indexOf(u8, appwindow_source, "configuredPowerShellSessionDetail") != null or
        std.mem.indexOf(u8, appwindow_source, "spawnConfiguredPowerShellTab") != null or
        std.mem.indexOf(u8, appwindow_source, "spawnDefaultAgentAndPowerShellTabs") != null or
        std.mem.indexOf(u8, appwindow_source, "Failed to spawn default Agent and PowerShell tabs") != null or
        std.mem.indexOf(u8, appwindow_source, "syncDefaultShellCommandFromConfig(\"pwsh\")") != null or
        std.mem.indexOf(u8, appwindow_source, "resolveShellCommandLine(&expected_buf, \"pwsh\")") != null)
    {
        return guardFailed("AppWindow.zig must use platform-local shell launcher names instead of PowerShell-specific shared identifiers");
    }

    if (std.mem.indexOf(u8, overlays_source, "openPowerShellSession") != null or
        std.mem.indexOf(u8, overlays_source, ".powershell") != null or
        std.mem.indexOf(u8, overlays_source, "configuredPowerShellSessionDetail") != null)
    {
        return guardFailed("renderer/overlays.zig must use platform-local shell launcher names instead of PowerShell-specific shared identifiers");
    }

    const command_center_source = try readSource(allocator, "command/center_state.zig");
    defer allocator.free(command_center_source);
    if (std.mem.indexOf(u8, command_center_source, "Choose PowerShell") != null or
        std.mem.indexOf(u8, command_center_source, "WSL") != null or
        std.mem.indexOf(u8, command_center_source, "SESSION_LAUNCHER_ROW_AI_AGENT: usize = 3") != null)
    {
        return guardFailed("command/center_state.zig must get session launcher labels and rows from platform/pty_command.zig");
    }

    const ai_chat_source = try readSource(allocator, "assistant/conversation/session.zig");
    defer allocator.free(ai_chat_source);
    const ai_chat_request_source = try readSource(allocator, "assistant/conversation/request.zig");
    defer allocator.free(ai_chat_request_source);
    const agent_tools_source = try readSource(allocator, "agent_tools/mod.zig");
    defer allocator.free(agent_tools_source);
    const agent_tools_exec_source = try readSource(allocator, "agent_tools/exec.zig");
    defer allocator.free(agent_tools_exec_source);
    if (std.mem.indexOf(u8, ai_chat_source, "toolSchema(\"powershell_exec\"") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "toolSchema(\"powershell_exec\"") != null or
        std.mem.indexOf(u8, agent_tools_source, "toolSchema(\"powershell_exec\"") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "toolSchema(\"powershell_exec\"") != null or
        std.mem.indexOf(u8, ai_chat_source, "toolSchema(\"wsl_session_exec\"") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "toolSchema(\"wsl_session_exec\"") != null or
        std.mem.indexOf(u8, agent_tools_source, "toolSchema(\"wsl_session_exec\"") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "toolSchema(\"wsl_session_exec\"") != null or
        std.mem.indexOf(u8, ai_chat_source, "std.mem.eql(u8, call.name, \"powershell_exec\")") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "std.mem.eql(u8, call.name, \"powershell_exec\")") != null or
        std.mem.indexOf(u8, agent_tools_source, "std.mem.eql(u8, call.name, \"powershell_exec\")") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "std.mem.eql(u8, call.name, \"powershell_exec\")") != null or
        std.mem.indexOf(u8, ai_chat_source, "requestApproval(\"powershell_exec\"") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "requestApproval(\"powershell_exec\"") != null or
        std.mem.indexOf(u8, agent_tools_source, "requestApproval(\"powershell_exec\"") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "requestApproval(\"powershell_exec\"") != null or
        std.mem.indexOf(u8, ai_chat_source, "powershellExecTool") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "powershellExecTool") != null or
        std.mem.indexOf(u8, agent_tools_source, "powershellExecTool") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "powershellExecTool") != null or
        std.mem.indexOf(u8, ai_chat_source, "@embedFile(\"prompt.md\")") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "@embedFile(\"prompt.md\")") != null or
        std.mem.indexOf(u8, agent_tools_source, "@embedFile(\"prompt.md\")") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "@embedFile(\"prompt.md\")") != null or
        std.mem.indexOf(u8, ai_chat_source, "defaultSystemPromptForOs(.windows)") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "defaultSystemPromptForOs(.windows)") != null or
        std.mem.indexOf(u8, agent_tools_source, "defaultSystemPromptForOs(.windows)") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "defaultSystemPromptForOs(.windows)") != null or
        std.mem.indexOf(u8, ai_chat_source, "tabNewToolPropertiesJsonForOs(.windows)") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "tabNewToolPropertiesJsonForOs(.windows)") != null or
        std.mem.indexOf(u8, agent_tools_source, "tabNewToolPropertiesJsonForOs(.windows)") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "tabNewToolPropertiesJsonForOs(.windows)") != null or
        std.mem.indexOf(u8, ai_chat_source, "tabKindUsageForOs(.windows)") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "tabKindUsageForOs(.windows)") != null or
        std.mem.indexOf(u8, agent_tools_source, "tabKindUsageForOs(.windows)") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "tabKindUsageForOs(.windows)") != null or
        std.mem.indexOf(u8, ai_chat_source, ".windows_create_process") != null or
        std.mem.indexOf(u8, ai_chat_request_source, ".windows_create_process") != null or
        std.mem.indexOf(u8, agent_tools_source, ".windows_create_process") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, ".windows_create_process") != null or
        std.mem.indexOf(u8, ai_chat_source, "Use kind=default, powershell, pwsh, cmd, wsl, or command") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "Use kind=default, powershell, pwsh, cmd, wsl, or command") != null or
        std.mem.indexOf(u8, agent_tools_source, "Use kind=default, powershell, pwsh, cmd, wsl, or command") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "Use kind=default, powershell, pwsh, cmd, wsl, or command") != null or
        std.mem.indexOf(u8, ai_chat_source, "Optional explicit Windows command line") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "Optional explicit Windows command line") != null or
        std.mem.indexOf(u8, agent_tools_source, "Optional explicit Windows command line") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "Optional explicit Windows command line") != null or
        std.mem.indexOf(u8, ai_chat_source, "Use default, powershell, pwsh, cmd, wsl, or command") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "Use default, powershell, pwsh, cmd, wsl, or command") != null or
        std.mem.indexOf(u8, agent_tools_source, "Use default, powershell, pwsh, cmd, wsl, or command") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "Use default, powershell, pwsh, cmd, wsl, or command") != null)
    {
        return guardFailed("assistant/conversation/session.zig must get local command tool names, labels, default prompts, and tab kind text from platform modules");
    }
    if (std.mem.indexOf(u8, ai_chat_source, "localShellFallback(") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "localShellFallback(") != null or
        std.mem.indexOf(u8, agent_tools_source, "localShellFallback(") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "localShellFallback(") != null or
        std.mem.indexOf(u8, ai_chat_source, "localShellCommandArgv(") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "localShellCommandArgv(") != null or
        std.mem.indexOf(u8, agent_tools_source, "localShellCommandArgv(") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "localShellCommandArgv(") != null)
    {
        return guardFailed("assistant/conversation/session.zig must ask platform/process.zig for fallback argv without handling shell variants directly");
    }
    if (std.mem.indexOf(u8, ai_chat_source, ".title = try allocator.dupe(u8, \"PowerShell\")") != null or
        std.mem.indexOf(u8, ai_chat_request_source, ".title = try allocator.dupe(u8, \"PowerShell\")") != null or
        std.mem.indexOf(u8, agent_tools_source, ".title = try allocator.dupe(u8, \"PowerShell\")") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, ".title = try allocator.dupe(u8, \"PowerShell\")") != null or
        std.mem.indexOf(u8, ai_chat_source, ".cwd = try allocator.dupe(u8, \"C:\\\\Users\")") != null or
        std.mem.indexOf(u8, ai_chat_request_source, ".cwd = try allocator.dupe(u8, \"C:\\\\Users\")") != null or
        std.mem.indexOf(u8, agent_tools_source, ".cwd = try allocator.dupe(u8, \"C:\\\\Users\")") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, ".cwd = try allocator.dupe(u8, \"C:\\\\Users\")") != null or
        std.mem.indexOf(u8, ai_chat_source, ".snapshot = try allocator.dupe(u8, \"PS C:\\\\Users>\")") != null or
        std.mem.indexOf(u8, ai_chat_request_source, ".snapshot = try allocator.dupe(u8, \"PS C:\\\\Users>\")") != null or
        std.mem.indexOf(u8, agent_tools_source, ".snapshot = try allocator.dupe(u8, \"PS C:\\\\Users>\")") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, ".snapshot = try allocator.dupe(u8, \"PS C:\\\\Users>\")") != null or
        std.mem.indexOf(u8, ai_chat_source, ".tool_name = try allocator.dupe(u8, \"powershell_exec\")") != null or
        std.mem.indexOf(u8, ai_chat_request_source, ".tool_name = try allocator.dupe(u8, \"powershell_exec\")") != null or
        std.mem.indexOf(u8, agent_tools_source, ".tool_name = try allocator.dupe(u8, \"powershell_exec\")") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, ".tool_name = try allocator.dupe(u8, \"powershell_exec\")") != null or
        std.mem.indexOf(u8, ai_chat_source, "running powershell_exec") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "running powershell_exec") != null or
        std.mem.indexOf(u8, agent_tools_source, "running powershell_exec") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "running powershell_exec") != null or
        std.mem.indexOf(u8, ai_chat_source, "Get-ChildItem") != null or
        std.mem.indexOf(u8, ai_chat_request_source, "Get-ChildItem") != null or
        std.mem.indexOf(u8, agent_tools_source, "Get-ChildItem") != null or
        std.mem.indexOf(u8, agent_tools_exec_source, "Get-ChildItem") != null)
    {
        return guardFailed("assistant/conversation/session.zig shared tests must use platform-neutral terminal fixtures unless explicitly testing platform prompt variants");
    }

    const agent_detector_source = try readSource(allocator, "terminal_agents/detector.zig");
    defer allocator.free(agent_detector_source);
    if (std.mem.indexOf(u8, agent_detector_source, "detect(\"PowerShell\", \"PS C:\\\\Users> ls\")") != null) {
        return guardFailed("terminal_agents/detector.zig generic shell tests must use platform-neutral terminal fixtures");
    }
}
