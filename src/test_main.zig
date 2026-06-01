//! Test entry point — imports modules containing unit tests.
//! Run with: zig build test

const build_options = @import("build_options");
const std = @import("std");
const app_metadata = @import("app_metadata.zig");
const command_center_state = @import("command_center_state.zig");

comptime {
    @setEvalBranchQuota(8_000_000);

    const source = @embedFile("test_main.zig");
    const concrete_font_backend = "platform/" ++ "directwrite.zig";
    if (std.mem.indexOf(u8, source, concrete_font_backend) != null) {
        @compileError("test_main.zig must import platform/font_backend.zig, not the concrete DirectWrite backend");
    }

    const app_window_source = @embedFile("AppWindow.zig");
    if (std.mem.indexOf(u8, app_window_source, "builtin." ++ "os.tag") != null) {
        @compileError("AppWindow.zig must keep native handle OS switches behind platform/window_backend.zig");
    }
    if (std.mem.indexOf(u8, app_window_source, "W" ++ "M_") != null) {
        @compileError("AppWindow.zig comments and logic must describe platform-neutral event handling, not Win32 messages");
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
        @compileError("AppWindow.zig launch plumbing must use platform_pty_command launch types and allocators");
    }
    // apprt/win32.zig API-surface leak checks live in
    // platform/apprt_win32_guard.zig so this shared/test module does not embed
    // the Windows runtime directly. It is imported below to run those guards.

    const update_install_source = @embedFile("update_install.zig");
    if (std.mem.indexOf(u8, update_install_source, "@import(\"builtin\").os.tag") != null) {
        @compileError("update_install.zig must use platform/update_package.zig for OS package selection");
    }
    const threading_source = @embedFile("threading.zig");
    if (std.mem.indexOf(u8, threading_source, "Windows") != null or
        std.mem.indexOf(u8, threading_source, "surface_thread_stack_size") != null)
    {
        @compileError("threading.zig must get platform-specific thread spawn policy from platform/threading.zig");
    }
    const platform_threading_source = @embedFile("platform/threading.zig");
    if (std.mem.indexOf(u8, platform_threading_source, "Windows") != null) {
        @compileError("platform/threading.zig thread policy comments must describe runtime roles, not Windows implementation defaults");
    }
    if (std.mem.indexOf(u8, update_install_source, "isWindowsDriveQualified") != null or
        std.mem.indexOf(u8, update_install_source, "isIllegalWindowsNameChar") != null or
        std.mem.indexOf(u8, update_install_source, "UnsafeZipEntryName") != null)
    {
        @compileError("update_install.zig must validate archive entry names through platform/update_package.zig");
    }
    if (std.mem.indexOf(u8, update_install_source, "PayloadValidation") != null or
        std.mem.indexOf(u8, update_install_source, "require_webview2_loader") != null or
        std.mem.indexOf(u8, update_install_source, "MissingWebView2Loader") != null or
        std.mem.indexOf(u8, update_install_source, "has_" ++ "webview2_loader") != null or
        std.mem.indexOf(u8, update_install_source, "portable_" ++ "webview2") != null or
        std.mem.indexOf(u8, update_install_source, "WebView2") != null)
    {
        @compileError("update_install.zig must validate release package manifests without WebView2-specific options or errors");
    }
    if (std.mem.indexOf(u8, update_install_source, "windowsPortablePackage") != null) {
        @compileError("update_install.zig tests must use platform-neutral update package scenarios");
    }
    if (std.mem.indexOf(u8, update_install_source, "Backend.windows_portable") != null or
        std.mem.indexOf(u8, update_install_source, "defaultPackageForOs(.windows)") != null)
    {
        @compileError("update_install.zig tests must not assert concrete platform package backends directly");
    }
    if (std.mem.indexOf(u8, update_install_source, "\"wispterm.exe\"") != null or
        std.mem.indexOf(u8, update_install_source, "\"wispterm-updater.exe\"") != null)
    {
        @compileError("update_install.zig tests must get executable payload paths through platform/update_package.zig");
    }

    const local_path_source = @embedFile("platform/local_path.zig");
    if (std.mem.indexOf(u8, local_path_source, "pub fn isAbsoluteOrWindows") != null) {
        @compileError("platform/local_path.zig public APIs must use platform-neutral path role names");
    }
    if (std.mem.indexOf(u8, local_path_source, "windows" ++ "RootLen") != null or
        std.mem.indexOf(u8, local_path_source, "canonical" ++ "WindowsPath") != null or
        std.mem.indexOf(u8, local_path_source, "is" ++ "WindowsAbsolute") != null or
        std.mem.indexOf(u8, local_path_source, "normalize" ++ "WindowsPath") != null or
        std.mem.indexOf(u8, local_path_source, "simple" ++ "WindowsCaseFold") != null or
        std.mem.indexOf(u8, local_path_source, "windows" ++ "CaseInsensitiveUtf8Equal") != null or
        std.mem.indexOf(u8, local_path_source, "windows" ++ "AbsolutePathEqual") != null)
    {
        @compileError("platform/local_path.zig path helpers must describe native path roles instead of Windows-specific helper names");
    }
    const app_source = @embedFile("App.zig");
    if (std.mem.indexOf(u8, app_source, "WebView2") != null or
        std.mem.indexOf(u8, app_source, "webview2") != null or
        std.mem.indexOf(u8, app_source, "wispterm-windows-portable") != null)
    {
        @compileError("App.zig must keep concrete release asset names behind update/release package modules");
    }
    if (std.mem.indexOf(u8, app_source, "[256]u16") != null or
        std.mem.indexOf(u8, app_source, "[260]u16") != null or
        std.mem.indexOf(u8, app_source, "?[]const u16") != null)
    {
        @compileError("App.zig must use platform_pty_command buffer types for launch command and cwd storage");
    }
    if (std.mem.indexOf(u8, app_source, "resolveShellCommandUtf16") != null or
        std.mem.indexOf(u8, app_source, "UTF-16") != null or
        std.mem.indexOf(u8, app_window_source, "resolveShellCommandUtf16") != null or
        std.mem.indexOf(u8, app_window_source, "UTF-16") != null)
    {
        @compileError("App/AppWindow launch APIs must use native command line names, not UTF-16-specific names");
    }

    const shared_pty_sources = .{
        @embedFile("Surface.zig"),
        @embedFile("termio/Thread.zig"),
        @embedFile("termio/ReadThread.zig"),
    };
    for (shared_pty_sources) |pty_source| {
        if (std.mem.indexOf(u8, pty_source, "ConPTY") != null or
            std.mem.indexOf(u8, pty_source, "ResizePseudoConsole") != null or
            std.mem.indexOf(u8, pty_source, "ReadFile") != null or
            std.mem.indexOf(u8, pty_source, "CancelIoEx") != null or
            std.mem.indexOf(u8, pty_source, "OperationAborted") != null or
            std.mem.indexOf(u8, pty_source, "Windows-side") != null)
        {
            @compileError("shared PTY/termio code must describe platform-neutral PTY behavior");
        }
    }

    const update_check_source = @embedFile("update_check.zig");
    if (std.mem.indexOf(u8, update_check_source, "wispterm-windows-portable") != null) {
        @compileError("update_check.zig tests must build concrete release asset names through release_package helpers");
    }
    if (std.mem.indexOf(u8, update_check_source, "ReleasePackage.windowsPortable") != null) {
        @compileError("update_check.zig tests must construct concrete platform packages through platform/update_package.zig");
    }
    if (std.mem.indexOf(u8, update_check_source, "windowsPortablePackage") != null) {
        @compileError("update_check.zig tests must use platform-neutral update package scenarios");
    }
    const release_package_source = @embedFile("release_package.zig");
    if (std.mem.indexOf(u8, release_package_source, "\"wispterm.exe\"") != null or
        std.mem.indexOf(u8, release_package_source, "\"wispterm-updater.exe\"") != null)
    {
        @compileError("release_package.zig must keep concrete executable payload names behind platform/update_package backends");
    }
    if (std.mem.indexOf(u8, release_package_source, "wispterm-windows-portable") != null) {
        @compileError("release_package.zig must keep concrete asset naming behind platform/update_package backends");
    }
    if (std.mem.indexOf(u8, release_package_source, "WindowsPortable") != null or
        std.mem.indexOf(u8, release_package_source, "windows_portable") != null or
        std.mem.indexOf(u8, release_package_source, "windowsPortable") != null)
    {
        @compileError("release_package.zig must use platform-neutral package flavors instead of Windows portable fields");
    }
    if (std.mem.indexOf(u8, release_package_source, "requires" ++ "WebView2Loader") != null or
        std.mem.indexOf(u8, release_package_source, "webview2" ++ "LoaderPath") != null or
        std.mem.indexOf(u8, release_package_source, "webview2_" ++ "loader_path") != null or
        std.mem.indexOf(u8, release_package_source, "portable_" ++ "webview2") != null or
        std.mem.indexOf(u8, release_package_source, "portable_no_" ++ "webview") != null)
    {
        @compileError("release_package.zig public helpers must describe embedded browser payloads, not WebView2-specific APIs");
    }
    if (std.mem.indexOf(u8, update_check_source, "portable_" ++ "webview2") != null or
        std.mem.indexOf(u8, update_check_source, "portable_no_" ++ "webview") != null)
    {
        @compileError("update_check.zig tests must use embedded-browser package flavor names");
    }
    const update_package_source = @embedFile("platform/update_package.zig");
    if (std.mem.indexOf(u8, update_package_source, "has_" ++ "webview2_loader") != null or
        std.mem.indexOf(u8, update_package_source, "portable_" ++ "webview2") != null or
        std.mem.indexOf(u8, update_package_source, "portable_no_" ++ "webview") != null)
    {
        @compileError("platform/update_package.zig public APIs must use embedded-browser package flavor names");
    }
    if (std.mem.indexOf(u8, update_package_source, "windows_portable") != null) {
        @compileError("platform/update_package.zig facade backend names must describe platforms, not concrete package shapes");
    }
    if (std.mem.indexOf(u8, update_package_source, "windows" ++ "_package") != null) {
        @compileError("platform/update_package.zig facade backend aliases must describe package backend roles, not concrete platform package names");
    }
    if (std.mem.indexOf(u8, update_package_source, "isWindowsDriveQualifiedArchiveName") != null or
        std.mem.indexOf(u8, update_package_source, "isIllegalWindowsArchiveNameChar") != null)
    {
        @compileError("platform/update_package.zig archive validation helpers must use archive-safety names, not Windows implementation names");
    }
    const pty_command_source = @embedFile("platform/pty_command.zig");
    if (std.mem.indexOf(u8, pty_command_source, "windows_create_process") != null) {
        @compileError("platform/pty_command.zig facade backend names must describe platforms, not CreateProcess details");
    }
    if (std.mem.indexOf(u8, pty_command_source, "PseudoConsoleHandle") != null) {
        @compileError("platform/pty_command.zig facade must not expose pseudo-console handles");
    }
    if (std.mem.indexOf(u8, pty_command_source, "pub fn shellCommandLooksLikePowerShell") != null or
        std.mem.indexOf(u8, pty_command_source, "pub fn configuredPowerShellCommandForShell") != null)
    {
        @compileError("platform/pty_command.zig public shell APIs must describe local-shell roles, not PowerShell-specific helpers");
    }
    if (std.mem.indexOf(u8, pty_command_source, "appendWindowsQuotedArg") != null) {
        @compileError("platform/pty_command.zig command quoting helpers must describe command-line roles, not Windows implementation names");
    }
    if (std.mem.indexOf(u8, pty_command_source, "Windows" ++ "LocalShell") != null) {
        @compileError("platform/pty_command.zig local-shell helpers must describe native shell roles, not Windows-local helper names");
    }
    if (std.mem.indexOf(u8, pty_command_source, "if (std.mem.indexOf(u8, lower, \"powershell.exe\")") != null or
        std.mem.indexOf(u8, pty_command_source, "friendlyShellTitle(\"C:" ++ "\\\\Windows") != null)
    {
        @compileError("platform/pty_command.zig must delegate concrete native shell title mappings to backend implementations");
    }
    if (std.mem.indexOf(u8, pty_command_source, "if (std.ascii.eqlIgnoreCase(kind, \"powershell\")) return") != null or
        std.mem.indexOf(u8, pty_command_source, "if (!appendAscii(buf, &pos, \"wsl.exe\"))") != null or
        std.mem.indexOf(u8, pty_command_source, "return .{ \"wsl.exe\"") != null or
        std.mem.indexOf(u8, pty_command_source, "std.fmt.bufPrint(buf, \"cmd.exe /k ssh.exe") != null)
    {
        @compileError("platform/pty_command.zig must delegate concrete tab, WSL, and SSH command construction to backend implementations");
    }
    if (std.mem.indexOf(u8, pty_command_source, "std.mem.indexOf(u8, lower, \"ssh.exe\")") != null or
        std.mem.indexOf(u8, pty_command_source, "std.mem.indexOf(u8, lower, \"wsl.exe\")") != null)
    {
        @compileError("platform/pty_command.zig must delegate concrete launch-kind command classification to backend implementations");
    }
    if (std.mem.indexOf(u8, pty_command_source, "\"cmd.exe /k ssh.exe") != null or
        std.mem.indexOf(u8, pty_command_source, "\"wsl.exe ~") != null)
    {
        @compileError("platform/pty_command.zig facade tests must keep concrete Windows SSH/WSL command-line samples in backend implementations");
    }
    const pty_facade_source = @embedFile("platform/pty.zig");
    if (std.mem.indexOf(u8, pty_facade_source, "windows_conpty") != null) {
        @compileError("platform/pty.zig facade backend names must describe platforms, not ConPTY details");
    }
    const platform_facade_backend_detail_checks = .{
        .{ "platform/clipboard.zig", @embedFile("platform/clipboard.zig"), ".win32_clipboard" },
        .{ "platform/clipboard.zig", @embedFile("platform/clipboard.zig"), "_win32.zig" },
        .{ "platform/com.zig", @embedFile("platform/com.zig"), ".windows_ole32" },
        .{ "platform/com.zig", @embedFile("platform/com.zig"), "com_windows_ole32.zig" },
        .{ "platform/config_watcher.zig", @embedFile("platform/config_watcher.zig"), ".windows_read_directory_changes" },
        .{ "platform/console.zig", @embedFile("platform/console.zig"), ".windows_parent_console" },
        .{ "platform/console.zig", @embedFile("platform/console.zig"), ".windows_parent_process" },
        .{ "platform/cursor.zig", @embedFile("platform/cursor.zig"), ".win32" },
        .{ "platform/cursor.zig", @embedFile("platform/cursor.zig"), "_win32.zig" },
        .{ "platform/display.zig", @embedFile("platform/display.zig"), ".win32_monitor" },
        .{ "platform/display.zig", @embedFile("platform/display.zig"), "_win32.zig" },
        .{ "platform/file_dialog.zig", @embedFile("platform/file_dialog.zig"), ".win32_common_dialog" },
        .{ "platform/file_dialog.zig", @embedFile("platform/file_dialog.zig"), "_win32.zig" },
        .{ "platform/font_backend.zig", @embedFile("platform/font_backend.zig"), ".directwrite" },
        .{ "platform/font_backend.zig", @embedFile("platform/font_backend.zig"), "font_backend_directwrite.zig" },
        .{ "platform/font_backend_windows.zig", @embedFile("platform/font_backend_windows.zig"), "@import(\"directwrite.zig\")" },
        .{ "platform/global_hotkey.zig", @embedFile("platform/global_hotkey.zig"), ".win32" },
        .{ "platform/global_hotkey.zig", @embedFile("platform/global_hotkey.zig"), "_win32.zig" },
        .{ "platform/memory.zig", @embedFile("platform/memory.zig"), ".windows_psapi" },
        .{ "platform/memory.zig", @embedFile("platform/memory.zig"), "memory_windows_psapi.zig" },
        .{ "platform/open_url.zig", @embedFile("platform/open_url.zig"), ".windows_shell" },
        .{ "platform/open_url.zig", @embedFile("platform/open_url.zig"), ".posix_command" },
        .{ "platform/remote_transport.zig", @embedFile("platform/remote_transport.zig"), ".winhttp" },
        .{ "platform/remote_transport.zig", @embedFile("platform/remote_transport.zig"), "remote_transport_winhttp.zig" },
        .{ "platform/session_lock.zig", @embedFile("platform/session_lock.zig"), ".windows_mutex" },
        .{ "platform/session_lock.zig", @embedFile("platform/session_lock.zig"), "session_lock_windows_mutex.zig" },
        .{ "platform/session_lock.zig", @embedFile("platform/session_lock.zig"), ".local_process" },
        .{ "platform/text.zig", @embedFile("platform/text.zig"), ".windows_compare_string" },
        .{ "platform/text.zig", @embedFile("platform/text.zig"), "text_windows_compare_string.zig" },
        .{ "platform/text.zig", @embedFile("platform/text.zig"), "windowsOrdinalIgnoreCaseUtf8Equal" },
        .{ "platform/webview.zig", @embedFile("platform/webview.zig"), ".webview2" },
        .{ "platform/webview.zig", @embedFile("platform/webview.zig"), "webview_webview2.zig" },
        .{ "platform/window.zig", @embedFile("platform/window.zig"), ".win32" },
        .{ "platform/window.zig", @embedFile("platform/window.zig"), "_win32.zig" },
        .{ "platform/window_backend.zig", @embedFile("platform/window_backend.zig"), ".win32" },
        .{ "platform/window_backend.zig", @embedFile("platform/window_backend.zig"), "_win32.zig" },
    };
    for (platform_facade_backend_detail_checks) |check| {
        if (std.mem.indexOf(u8, check[1], check[2]) != null) {
            @compileError(check[0] ++ " facade backend names must describe platform roles, not backend implementation details");
        }
    }
    const command_source = @embedFile("Command.zig");
    if (std.mem.indexOf(u8, command_source, "PseudoConsoleHandle") != null or
        std.mem.indexOf(u8, command_source, "pseudo_console") != null)
    {
        @compileError("Command.zig must start commands through the app-facing PTY API, not pseudo-console handles");
    }
    const surface_source = @embedFile("Surface.zig");
    if (std.mem.indexOf(u8, surface_source, "pty.pseudo_console") != null) {
        @compileError("Surface/AppWindow code must not reach into platform PTY pseudo-console handles");
    }

    if (std.mem.indexOf(u8, command_source, "[*:0]const u16") != null or
        std.mem.indexOf(u8, command_source, "[:0]const u16") != null or
        std.mem.indexOf(u8, surface_source, "[*:0]const u16") != null or
        std.mem.indexOf(u8, surface_source, "[:0]const u16") != null)
    {
        @compileError("Surface/Command launch interfaces must use platform_pty_command launch types, not raw Windows UTF-16 pointers");
    }

    const tab_source = @embedFile("appwindow/tab.zig");
    if (std.mem.indexOf(u8, tab_source, "[256]u16") != null or
        std.mem.indexOf(u8, tab_source, "[*:0]const u16") != null or
        std.mem.indexOf(u8, tab_source, "[:0]const u16") != null or
        std.mem.indexOf(u8, tab_source, "[:0]u16") != null or
        std.mem.indexOf(u8, tab_source, "utf8ToUtf16LeAllocZ") != null)
    {
        @compileError("appwindow/tab.zig launch APIs must use platform_pty_command launch types and allocators");
    }

    const input_source = @embedFile("input.zig");
    if (std.mem.indexOf(u8, input_source, "W" ++ "M_") != null or
        std.mem.indexOf(u8, input_source, "Windows generated them") != null)
    {
        @compileError("input.zig comments and logic must describe platform-neutral input events, not Win32 messages");
    }
    if (std.mem.indexOf(u8, input_source, "[260]u16") != null or
        std.mem.indexOf(u8, input_source, "?[]const u16") != null or
        std.mem.indexOf(u8, input_source, "unixPathToWindows") != null or
        std.mem.indexOf(u8, input_source, "unixPathToNativeCwd") != null or
        std.mem.indexOf(u8, input_source, "unixPathToLocalPathUtf8") != null)
    {
        @compileError("input.zig must use platform_wsl/platform_pty_command native cwd helpers");
    }
    if (std.mem.indexOf(u8, input_source, "\"{s}\\\\{s}\"") != null) {
        @compileError("input.zig must build local filesystem paths through platform/local_path.zig");
    }
    const platform_input_source = @embedFile("platform/input_events.zig");
    if (std.mem.indexOf(u8, platform_input_source, "pub const VK_") != null or
        std.mem.indexOf(u8, input_source, "platform_input.VK_") != null or
        std.mem.indexOf(u8, input_source, "const VK_") != null)
    {
        @compileError("shared input APIs must use backend-neutral key_* names instead of Win32 VK aliases");
    }
    const keybind_source = @embedFile("keybind.zig");
    if (std.mem.indexOf(u8, platform_input_source, "vk: KeyCode") != null or
        std.mem.indexOf(u8, input_source, "ev.vk") != null)
    {
        @compileError("shared input events must use key_code naming instead of Win32 VK naming");
    }
    if (std.mem.indexOf(u8, keybind_source, "vk: u32") != null or
        std.mem.indexOf(u8, keybind_source, ".vk") != null or
        std.mem.indexOf(u8, keybind_source, "trigger.vk") != null)
    {
        @compileError("keybind triggers must use key_code naming instead of Win32 VK naming");
    }
    if (std.mem.indexOf(u8, keybind_source, "VK_{X}") != null) {
        @compileError("keybind.zig fallback key labels must not expose Win32 VK terminology");
    }
    const platform_global_hotkey_source = @embedFile("platform/global_hotkey.zig");
    if (std.mem.indexOf(u8, platform_global_hotkey_source, "vk: u32") != null or
        std.mem.indexOf(u8, platform_global_hotkey_source, ".vk") != null or
        std.mem.indexOf(u8, platform_global_hotkey_source, "trigger.vk") != null)
    {
        @compileError("platform/global_hotkey.zig facade must use key_code naming instead of Win32 VK naming");
    }
    const input_clipboard_source = @embedFile("input/clipboard.zig");
    if (std.mem.indexOf(u8, input_clipboard_source, "platform_wsl") != null or
        std.mem.indexOf(u8, input_clipboard_source, "windowsPathToWslPathAlloc") != null)
    {
        @compileError("input/clipboard.zig must ask platform remote-file helpers to adapt local paths for terminal paste targets");
    }
    const platform_wsl_source = @embedFile("platform/wsl.zig");
    if (std.mem.indexOf(u8, platform_wsl_source, "pub fn windowsPathToWslPathAlloc") != null or
        std.mem.indexOf(u8, platform_wsl_source, "pub fn unixPathToWindows") != null or
        std.mem.indexOf(u8, platform_wsl_source, "pub fn unixPathToNativeCwd") != null or
        std.mem.indexOf(u8, platform_wsl_source, "pub fn unixPathToLocalPathUtf8") != null)
    {
        @compileError("platform/wsl.zig public path APIs must describe host/guest roles, not Windows/Unix implementation details");
    }
    const platform_remote_file_source = @embedFile("platform/remote_file.zig");
    if (std.mem.indexOf(u8, platform_remote_file_source, "windowsPathToWslPathAlloc") != null) {
        @compileError("platform/remote_file.zig must use platform-neutral WSL path adapter names");
    }
    const platform_process_source = @embedFile("platform/process.zig");
    if (std.mem.indexOf(u8, platform_process_source, "windows_powershell") != null) {
        @compileError("platform/process.zig local shell variants must describe shell roles, not Windows-specific platform names");
    }
    if (std.mem.indexOf(u8, platform_process_source, "pub const LocalShell =") != null or
        std.mem.indexOf(u8, platform_process_source, "pub fn localShellFallback(") != null or
        std.mem.indexOf(u8, platform_process_source, "pub fn localShellCommandArgv(") != null)
    {
        @compileError("platform/process.zig must expose local-shell fallback argv as one narrow API instead of public shell variant plumbing");
    }

    const browser_panel_source = @embedFile("browser_panel.zig");
    if (std.mem.indexOf(u8, browser_panel_source, "[MAX_URL_BYTES]u16") != null or
        std.mem.indexOf(u8, browser_panel_source, "urlToWide") != null or
        std.mem.indexOf(u8, browser_panel_source, "utf8ToUtf16Le") != null)
    {
        @compileError("browser_panel.zig must use platform_webview URL helpers instead of WebView2 UTF-16 details");
    }
    const system_browser_source = @embedFile("system_browser.zig");
    if (std.mem.indexOf(u8, system_browser_source, "ShellExecute") != null or
        std.mem.indexOf(u8, system_browser_source, "shellExecute") != null or
        std.mem.indexOf(u8, system_browser_source, "Windows-specific") != null)
    {
        @compileError("system_browser.zig must stay backend-neutral and delegate URL opening to platform/open_url.zig");
    }
    const open_url_source = @embedFile("platform/open_url.zig");
    if (std.mem.indexOf(u8, open_url_source, "ShellExecute") != null or
        std.mem.indexOf(u8, open_url_source, "windowsShellExecuteSucceeded") != null)
    {
        @compileError("platform/open_url.zig must keep native browser-open details in concrete backends");
    }

    const session_persist_source = @embedFile("session_persist.zig");
    if (std.mem.indexOf(u8, session_persist_source, "NTFS") != null or
        std.mem.indexOf(u8, session_persist_source, "replace_if_exists") != null or
        std.mem.indexOf(u8, session_persist_source, "std.fs.cwd().atomicFile") != null or
        std.mem.indexOf(u8, session_persist_source, "AtomicFileOptions") != null)
    {
        @compileError("session_persist.zig must write replace-safe files through platform/atomic_file.zig");
    }

    const font_manager_source = @embedFile("font/manager.zig");
    if (std.mem.indexOf(u8, font_manager_source, "utf16LeToUtf8") != null or
        std.mem.indexOf(u8, font_manager_source, "createFontFace") != null or
        std.mem.indexOf(u8, font_manager_source, "getFiles") != null or
        std.mem.indexOf(u8, font_manager_source, "getLoader") != null or
        std.mem.indexOf(u8, font_manager_source, "queryLocalFontFileLoader") != null or
        std.mem.indexOf(u8, font_manager_source, "getReferenceKey") != null or
        std.mem.indexOf(u8, font_manager_source, "getFilePathLengthFromKey") != null or
        std.mem.indexOf(u8, font_manager_source, "getFilePathFromKey") != null)
    {
        @compileError("font/manager.zig must load fallback font paths through platform/font_backend.zig");
    }
    if (std.mem.indexOf(u8, font_manager_source, "g_dpi: u32 = 96") != null or
        std.mem.indexOf(u8, font_manager_source, "Windows to scale a 96-DPI") != null or
        std.mem.indexOf(u8, app_window_source, "96 DPI") != null or
        std.mem.indexOf(u8, app_window_source, "font.g_dpi / 96") != null)
    {
        @compileError("font/AppWindow shared DPI code must get display baseline DPI from platform/display.zig");
    }

    const file_explorer_source = @embedFile("file_explorer.zig");
    if (std.mem.indexOf(u8, file_explorer_source, "else '\\\\'") != null or
        std.mem.indexOf(u8, file_explorer_source, "expandWithBackend(idx, .local, '\\\\')") != null or
        std.mem.indexOf(u8, file_explorer_source, "buf[parent.len] = '\\\\'") != null or
        std.mem.indexOf(u8, file_explorer_source, "\"{s}\\\\{s}\"") != null)
    {
        @compileError("file_explorer.zig must build local filesystem paths through platform/local_path.zig");
    }

    const config_source = @embedFile("config.zig");
    if (std.mem.indexOf(u8, config_source, "shell: []const u8 = \"cmd\"") != null or
        std.mem.indexOf(u8, config_source, "# Shell (cmd, powershell, pwsh, wsl, or a custom path)") != null or
        std.mem.indexOf(u8, config_source, "# shell = cmd") != null or
        std.mem.indexOf(u8, config_source, "profiles\\powershell.conf") != null or
        std.mem.indexOf(u8, config_source, "profiles/pwsh.conf") != null or
        std.mem.indexOf(u8, config_source, "\"pwsh.conf\"") != null)
    {
        @compileError("config.zig must get shell defaults and generated config text from platform/pty_command.zig");
    }

    if (std.mem.indexOf(u8, app_source, "cfg.shell = \"powershell\"") != null or
        std.mem.indexOf(u8, app_source, "next.shell = \"pwsh\"") != null)
    {
        @compileError("App.zig tests must get shell config examples from platform/pty_command.zig");
    }

    const overlays_source = @embedFile("renderer/overlays.zig");
    if (std.mem.indexOf(u8, overlays_source, "cmd / powershell / pwsh / wsl") != null or
        std.mem.indexOf(u8, overlays_source, "fn nextShell") != null)
    {
        @compileError("renderer/overlays.zig must get shell cycling and hint text from platform/pty_command.zig");
    }
    if (std.mem.indexOf(u8, overlays_source, "const SESSION_LAUNCHER_ROW_COUNT = 4") != null or
        std.mem.indexOf(u8, overlays_source, "2 => .wsl") != null or
        std.mem.indexOf(u8, overlays_source, "renderSessionRow(layout, window_height, 2, \"WSL\"") != null)
    {
        @compileError("renderer/overlays.zig must get optional WSL session launcher layout from platform/pty_command.zig");
    }

    const titlebar_source = @embedFile("renderer/titlebar.zig");
    if (std.mem.indexOf(u8, titlebar_source, "Windows Terminal-style caption button") != null or
        std.mem.indexOf(u8, titlebar_source, "Windows Terminal's visual style") != null or
        std.mem.indexOf(u8, titlebar_source, "so Windows\n/// caption hit-testing") != null or
        std.mem.indexOf(u8, titlebar_source, "const caption_btn_w: f32 = 46") != null or
        std.mem.indexOf(u8, titlebar_source, "const top_caption_btn_w: f32 = 46") != null)
    {
        @compileError("renderer/titlebar.zig must get caption button metrics and style text through platform/window.zig");
    }

    const startup_tabs_source = @embedFile("startup_tabs.zig");
    if (std.mem.indexOf(u8, startup_tabs_source, "agent_and_powershell") != null) {
        @compileError("startup_tabs.zig must name the default pair as agent plus local shell, not PowerShell");
    }

    const appwindow_source = @embedFile("AppWindow.zig");
    if (std.mem.indexOf(u8, appwindow_source, "configuredPowerShellSessionDetail") != null or
        std.mem.indexOf(u8, appwindow_source, "spawnConfiguredPowerShellTab") != null or
        std.mem.indexOf(u8, appwindow_source, "spawnDefaultAgentAndPowerShellTabs") != null or
        std.mem.indexOf(u8, appwindow_source, "Failed to spawn default Agent and PowerShell tabs") != null or
        std.mem.indexOf(u8, appwindow_source, "syncDefaultShellCommandFromConfig(\"pwsh\")") != null or
        std.mem.indexOf(u8, appwindow_source, "resolveShellCommandLine(&expected_buf, \"pwsh\")") != null)
    {
        @compileError("AppWindow.zig must use platform-local shell launcher names instead of PowerShell-specific shared identifiers");
    }

    if (std.mem.indexOf(u8, overlays_source, "openPowerShellSession") != null or
        std.mem.indexOf(u8, overlays_source, ".powershell") != null or
        std.mem.indexOf(u8, overlays_source, "configuredPowerShellSessionDetail") != null)
    {
        @compileError("renderer/overlays.zig must use platform-local shell launcher names instead of PowerShell-specific shared identifiers");
    }

    const command_center_source = @embedFile("command_center_state.zig");
    if (std.mem.indexOf(u8, command_center_source, "Choose PowerShell") != null or
        std.mem.indexOf(u8, command_center_source, "WSL") != null or
        std.mem.indexOf(u8, command_center_source, "SESSION_LAUNCHER_ROW_AI_AGENT: usize = 3") != null)
    {
        @compileError("command_center_state.zig must get session launcher labels and rows from platform/pty_command.zig");
    }

    const ai_chat_source = @embedFile("ai_chat.zig");
    if (std.mem.indexOf(u8, ai_chat_source, "toolSchema(\"powershell_exec\"") != null or
        std.mem.indexOf(u8, ai_chat_source, "toolSchema(\"wsl_session_exec\"") != null or
        std.mem.indexOf(u8, ai_chat_source, "std.mem.eql(u8, call.name, \"powershell_exec\")") != null or
        std.mem.indexOf(u8, ai_chat_source, "requestApproval(\"powershell_exec\"") != null or
        std.mem.indexOf(u8, ai_chat_source, "powershellExecTool") != null or
        std.mem.indexOf(u8, ai_chat_source, "@embedFile(\"prompt.md\")") != null or
        std.mem.indexOf(u8, ai_chat_source, "defaultSystemPromptForOs(.windows)") != null or
        std.mem.indexOf(u8, ai_chat_source, "tabNewToolPropertiesJsonForOs(.windows)") != null or
        std.mem.indexOf(u8, ai_chat_source, "tabKindUsageForOs(.windows)") != null or
        std.mem.indexOf(u8, ai_chat_source, ".windows_create_process") != null or
        std.mem.indexOf(u8, ai_chat_source, "Use kind=default, powershell, pwsh, cmd, wsl, or command") != null or
        std.mem.indexOf(u8, ai_chat_source, "Optional explicit Windows command line") != null or
        std.mem.indexOf(u8, ai_chat_source, "Use default, powershell, pwsh, cmd, wsl, or command") != null)
    {
        @compileError("ai_chat.zig must get local command tool names, labels, default prompts, and tab kind text from platform modules");
    }
    if (std.mem.indexOf(u8, ai_chat_source, "localShellFallback(") != null or
        std.mem.indexOf(u8, ai_chat_source, "localShellCommandArgv(") != null)
    {
        @compileError("ai_chat.zig must ask platform/process.zig for fallback argv without handling shell variants directly");
    }
    if (std.mem.indexOf(u8, ai_chat_source, ".title = try allocator.dupe(u8, \"PowerShell\")") != null or
        std.mem.indexOf(u8, ai_chat_source, ".cwd = try allocator.dupe(u8, \"C:\\\\Users\")") != null or
        std.mem.indexOf(u8, ai_chat_source, ".snapshot = try allocator.dupe(u8, \"PS C:\\\\Users>\")") != null or
        std.mem.indexOf(u8, ai_chat_source, ".tool_name = try allocator.dupe(u8, \"powershell_exec\")") != null or
        std.mem.indexOf(u8, ai_chat_source, "running powershell_exec") != null or
        std.mem.indexOf(u8, ai_chat_source, "Get-ChildItem") != null)
    {
        @compileError("ai_chat.zig shared tests must use platform-neutral terminal fixtures unless explicitly testing platform prompt variants");
    }

    const agent_detector_source = @embedFile("agent_detector.zig");
    if (std.mem.indexOf(u8, agent_detector_source, "detect(\"PowerShell\", \"PS C:\\\\Users> ls\")") != null) {
        @compileError("agent_detector.zig generic shell tests must use platform-neutral terminal fixtures");
    }
}

comptime {
    _ = @import("ai_chat.zig");
    _ = @import("ai_chat_skills.zig");
    _ = @import("ai_chat_types.zig");
    _ = @import("ai_chat_protocol.zig");
    _ = @import("agent_history.zig");
    _ = @import("ai_chat_composer_layout.zig");
    _ = @import("ai_chat_input_text.zig");
    _ = @import("ai_chat_composer.zig");
    _ = @import("agent_detector.zig");
    _ = @import("App.zig");
    _ = @import("AppWindow.zig");
    _ = @import("appwindow/flush_scheduler.zig");
    _ = @import("appwindow/tab.zig");
    _ = @import("appwindow/thread_message.zig");
    _ = @import("scp.zig");
    _ = if (build_options.webview) @import("browser_panel.zig") else @import("browser_panel_stub.zig");
    _ = @import("browser_url.zig");
    _ = @import("build_guards.zig");
    _ = @import("command_center_state.zig");
    _ = @import("command_palette_model.zig");
    _ = @import("config.zig");
    _ = @import("i18n.zig");
    _ = @import("config_watcher.zig");
    _ = @import("file_backend.zig");
    _ = @import("file_explorer.zig");
    _ = @import("input.zig");
    _ = @import("input/clipboard.zig");
    _ = @import("input/click_tracker.zig");
    _ = @import("input/command_dispatch.zig");
    _ = @import("input/hit_test.zig");
    _ = @import("input/key.zig");
    _ = @import("input/preview_source.zig");
    _ = @import("input_shortcuts.zig");
    _ = @import("keybind.zig");
    _ = @import("kitty_graphics_unit.zig");
    _ = @import("link_open.zig");
    _ = @import("markdown_preview.zig");
    _ = @import("markdown_text.zig");
    _ = @import("memory_debug.zig");
    _ = @import("wispterm_docs.zig");
    _ = @import("platform/atomic_file.zig");
    _ = @import("platform/clipboard.zig");
    _ = @import("platform/com.zig");
    _ = @import("platform/console.zig");
    _ = @import("platform/config_watcher.zig");
    _ = @import("platform/cursor.zig");
    _ = @import("platform/display.zig");
    _ = @import("platform/dirs.zig");
    _ = @import("platform/editor.zig");
    _ = @import("platform/file_dialog.zig");
    _ = @import("platform/font_backend.zig");
    _ = @import("platform/global_hotkey.zig");
    _ = @import("platform/input_events.zig");
    _ = @import("platform/agent_prompt.zig");
    _ = @import("platform/apprt_win32_guard.zig");
    _ = @import("renderer/gpu/gl_backend_guard.zig");
    _ = @import("platform/local_path.zig");
    _ = @import("platform/memory.zig");
    _ = @import("platform/notifications.zig");
    _ = @import("platform/open_url.zig");
    _ = @import("platform/process.zig");
    _ = @import("platform/pty.zig");
    _ = @import("platform/pty_command.zig");
    _ = @import("platform/remote_file.zig");
    _ = @import("platform/remote_transport.zig");
    _ = @import("platform/session_lock.zig");
    _ = @import("platform/text.zig");
    _ = @import("platform/thread_control.zig");
    _ = @import("platform/threading.zig");
    _ = @import("platform/update_package.zig");
    _ = @import("platform/webview.zig");
    _ = @import("platform/window.zig");
    _ = @import("platform/window_backend.zig");
    _ = @import("platform/window_state.zig");
    _ = @import("platform/wsl.zig");
    _ = @import("preview_token.zig");
    _ = @import("quick_terminal.zig");
    _ = @import("remote_client.zig");
    _ = @import("remote_snapshot.zig");
    _ = @import("weixin/types.zig");
    _ = @import("weixin/state_store.zig");
    _ = @import("weixin/binding.zig");
    _ = @import("weixin/control.zig");
    _ = @import("weixin/agent.zig");
    _ = @import("weixin/reply_progress.zig");
    _ = @import("weixin/ilink_codec.zig");
    _ = @import("weixin/ilink_client.zig");
    _ = @import("weixin/poller.zig");
    _ = @import("weixin/controller.zig");
    _ = @import("weixin/qr_code.zig");
    _ = @import("weixin/qr_panel.zig");
    _ = @import("renderer/overlay_keys.zig");
    _ = @import("renderer/overlays.zig");
    _ = @import("selection_unit.zig");
    _ = @import("session_persist.zig");
    _ = @import("skill_registry.zig");
    _ = @import("command_registry.zig");
    _ = @import("scrollbar_model.zig");
    _ = @import("ai_chat_scrollbar_model.zig");
    _ = @import("ssh_prompt.zig");
    _ = @import("ssh_tunnel.zig");
    _ = @import("startup_tabs.zig");
    _ = @import("system_browser.zig");
    _ = @import("split_tree.zig");
    _ = @import("ui_perf.zig");
    _ = @import("update_check.zig");
    _ = @import("update_install.zig");
    _ = @import("skill_update.zig");
}

test "app version metadata is exposed for CLI and command center" {
    try std.testing.expectEqualStrings("WispTerm", app_metadata.name);
    try std.testing.expect(app_metadata.version.len > 0);

    var buf: [64]u8 = undefined;
    const line = try app_metadata.versionLine(&buf);
    try std.testing.expectEqualStrings("WispTerm " ++ app_metadata.version, line);
}

test "command center browser entries do not expose backend implementation names" {
    for (command_center_state.command_entries) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.detail, "WebView2") == null);
    }
}
