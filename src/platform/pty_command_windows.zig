const std = @import("std");
const windows = std.os.windows;

const PseudoConsoleHandle = windows.HANDLE;
pub const CommandLineBuffer = [256]u16;
pub const CwdBuffer = [260]u16;
pub const CwdUnit = u16;
pub const CwdSlice = []const CwdUnit;
pub const CommandLine = [:0]const u16;
pub const Cwd = ?[*:0]const u16;
pub const OwnedCommandLine = [:0]u16;
pub const OwnedCwd = [:0]u16;

/// Coarse launch context used by platform-neutral terminal integrations.
pub const LaunchKind = enum {
    local,
    wsl,
    ssh,
};

pub const SshCommandOptions = struct {
    user: []const u8,
    host: []const u8,
    port: []const u8 = "",
    password_auth: bool = false,
    legacy_algorithms: bool = false,
    proxy_jump: []const u8 = "",
    remote_command: []const u8 = "",
};

const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;

const wait_object_0: DWORD = 0x00000000;
const wait_timeout: DWORD = 0x00000102;
const infinite: DWORD = 0xFFFFFFFF;
const extended_startupinfo_present: DWORD = 0x00080000;
const create_unicode_environment: DWORD = 0x00000400;
const proc_thread_attribute_pseudoconsole: usize = 0x00020016;

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *usize,
) callconv(.winapi) BOOL;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: ?*anyopaque,
    dwFlags: DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.winapi) BOOL;

extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: ?*anyopaque) callconv(.winapi) void;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOEXW,
    lpProcessInformation: *windows.PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;

extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;

pub fn allocCommandLineFromUtf8(allocator: std.mem.Allocator, command: []const u8) !OwnedCommandLine {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, command);
}

pub fn freeCommandLine(allocator: std.mem.Allocator, command: OwnedCommandLine) void {
    allocator.free(command);
}

pub fn commandLineFromOwned(command: OwnedCommandLine) CommandLine {
    return command;
}

pub fn commandLineDisplay(command: CommandLine, out: []u8) []const u8 {
    const len = std.unicode.utf16LeToUtf8(out, command) catch return "";
    return out[0..len];
}

pub fn allocCwdFromUtf8(allocator: std.mem.Allocator, cwd: []const u8) !OwnedCwd {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, cwd);
}

pub fn freeCwd(allocator: std.mem.Allocator, cwd: OwnedCwd) void {
    allocator.free(cwd);
}

pub fn cwdFromOwned(cwd: OwnedCwd) Cwd {
    return cwd.ptr;
}

fn isUnsupportedShellCwd(path: []const u16) bool {
    if (path.len < 2) return false;
    if (path[0] != '\\' or path[1] != '\\') return false;
    return !(path.len >= 4 and path[2] == '?' and path[3] == '\\');
}

pub fn cwdFromBuffer(cwd_buf: *CwdBuffer, len: usize) Cwd {
    if (len >= cwd_buf.len) return null;
    if (isUnsupportedShellCwd(cwd_buf[0..len])) return null;
    cwd_buf[len] = 0;
    return @ptrCast(cwd_buf);
}

pub fn cwdFromUtf8(cwd_buf: *CwdBuffer, cwd: []const u8) Cwd {
    const len = std.unicode.utf8ToUtf16Le(cwd_buf[0 .. cwd_buf.len - 1], cwd) catch return null;
    return cwdFromBuffer(cwd_buf, len);
}

fn copyShellLiteral(out_buf: *CommandLineBuffer, lit: []const u16) usize {
    const len = @min(lit.len, out_buf.len - 1);
    @memcpy(out_buf[0..len], lit[0..len]);
    out_buf[len] = 0;
    return len;
}

pub fn resolveShellCommandLine(out_buf: *CommandLineBuffer, cmd: []const u8) usize {
    if (std.mem.eql(u8, cmd, "cmd")) {
        return copyShellLiteral(out_buf, std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe"));
    } else if (std.mem.eql(u8, cmd, "powershell")) {
        return copyShellLiteral(out_buf, std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe"));
    } else if (std.mem.eql(u8, cmd, "pwsh")) {
        return copyShellLiteral(out_buf, std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe"));
    } else if (std.mem.eql(u8, cmd, "wsl")) {
        return copyShellLiteral(out_buf, std.unicode.utf8ToUtf16LeStringLiteral("wsl.exe"));
    }

    const len = std.unicode.utf8ToUtf16Le(out_buf[0 .. out_buf.len - 1], cmd) catch 0;
    out_buf[len] = 0;
    return len;
}

fn commandLineLowerAscii(command: CommandLine, out: *[512]u8) []const u8 {
    const len = @min(command.len, out.len);
    for (command[0..len], 0..) |unit, i| {
        const ch: u8 = if (unit < 0x80) @intCast(unit) else ' ';
        out[i] = std.ascii.toLower(ch);
    }
    return out[0..len];
}

fn shellExecutableTokenAscii(raw: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = raw.len;

    while (end > start and raw[end - 1] == 0) : (end -= 1) {}
    while (start < end and (raw[start] == ' ' or raw[start] == '\t')) : (start += 1) {}
    if (start >= end) return raw[start..end];

    if (raw[start] == '"') {
        start += 1;
        var quote_end = start;
        while (quote_end < end and raw[quote_end] != '"') : (quote_end += 1) {}
        return raw[start..quote_end];
    }

    var exe_end = start;
    while (exe_end + 4 <= end) : (exe_end += 1) {
        if (std.mem.eql(u8, raw[exe_end .. exe_end + 4], ".exe")) {
            const after_exe = exe_end + 4;
            if (after_exe == end or raw[after_exe] == ' ' or raw[after_exe] == '\t') {
                return raw[start..after_exe];
            }
        }
    }

    var token_end = start;
    while (token_end < end and raw[token_end] != ' ' and raw[token_end] != '\t') : (token_end += 1) {}
    return raw[start..token_end];
}

fn shellBasenameAscii(raw: []const u8) []const u8 {
    const token = shellExecutableTokenAscii(raw);
    var start: usize = 0;
    for (token, 0..) |unit, idx| {
        if (unit == '\\' or unit == '/') start = idx + 1;
    }
    return token[start..];
}

fn shellCommandLooksLikePwsh(shell_cmd: CommandLine) bool {
    var lower_buf: [512]u8 = undefined;
    const lower = commandLineLowerAscii(shell_cmd, &lower_buf);
    const base = shellBasenameAscii(lower);
    return std.mem.eql(u8, base, "pwsh.exe") or std.mem.eql(u8, base, "pwsh");
}

pub fn shellCommandLooksLikeConfiguredLocalShell(shell_cmd: CommandLine) bool {
    var lower_buf: [512]u8 = undefined;
    const lower = commandLineLowerAscii(shell_cmd, &lower_buf);
    const base = shellBasenameAscii(lower);
    return shellCommandLooksLikePwsh(shell_cmd) or
        std.mem.eql(u8, base, "powershell.exe") or
        std.mem.eql(u8, base, "powershell");
}

pub fn configuredLocalShellCommandForShell(shell_cmd: CommandLine) []const u8 {
    if (shellCommandLooksLikePwsh(shell_cmd)) return "pwsh.exe";
    return "powershell.exe";
}

/// Always-present shell to fall back to when the preferred local shell
/// (PowerShell/pwsh) cannot be launched — e.g. PowerShell removed from PATH
/// (issue #65). cmd.exe ships with every Windows install.
pub fn guaranteedLocalShellCommand() []const u8 {
    return "cmd.exe";
}

pub fn tabCommandForKind(kind: []const u8, current_shell: CommandLine) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(kind, "powershell")) return configuredLocalShellCommandForShell(current_shell);
    if (std.ascii.eqlIgnoreCase(kind, "pwsh")) return "pwsh.exe -NoLogo -NoProfile";
    if (std.ascii.eqlIgnoreCase(kind, "cmd")) return "cmd.exe";
    if (std.ascii.eqlIgnoreCase(kind, "wsl")) return "wsl.exe ~";
    return error.InvalidTabKind;
}

fn appendAscii(buf: []u8, pos: *usize, text: []const u8) bool {
    if (pos.* + text.len > buf.len) return false;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
    return true;
}

fn appendCommandLineQuotedArg(buf: []u8, pos: *usize, arg: []const u8) bool {
    if (pos.* >= buf.len) return false;
    buf[pos.*] = '"';
    pos.* += 1;
    for (arg) |ch| {
        if (ch == '"') {
            if (!appendAscii(buf, pos, "\\\"")) return false;
        } else {
            if (pos.* >= buf.len) return false;
            buf[pos.*] = ch;
            pos.* += 1;
        }
    }
    if (pos.* >= buf.len) return false;
    buf[pos.*] = '"';
    pos.* += 1;
    return true;
}

threadlocal var g_wsl_available_cached: bool = false;
threadlocal var g_wsl_available_value: bool = false;

/// Whether WSL has at least one installed distribution.
///
/// Detected by reading the per-user `Lxss` registry key that WSL populates when
/// a distro is registered — NOT by spawning `wsl.exe`. On a machine that only
/// has the System32 `wsl.exe` stub (WSL feature not installed), running any
/// `wsl.exe` subcommand pops an interactive "press a key to install WSL" window
/// and blocks for up to 60s, which would freeze app startup. The registry probe
/// is silent, non-blocking, and spawns no process. Cached after the first call.
pub fn wslAvailable() bool {
    if (g_wsl_available_cached) return g_wsl_available_value;
    g_wsl_available_cached = true;
    g_wsl_available_value = probeWslInstalledDistro();
    return g_wsl_available_value;
}

fn probeWslInstalledDistro() bool {
    const advapi32 = windows.advapi32;
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss");
    var hkey: windows.HKEY = undefined;
    if (advapi32.RegOpenKeyExW(windows.HKEY_CURRENT_USER, subkey, 0, windows.KEY_READ, &hkey) != 0) {
        return false;
    }
    defer _ = advapi32.RegCloseKey(hkey);
    // `DefaultDistribution` (a distro GUID) exists only while at least one distro
    // is registered; WSL removes it once the last distro is unregistered. Passing
    // null data/size queries the value's mere existence.
    const value_name = std.unicode.utf8ToUtf16LeStringLiteral("DefaultDistribution");
    return advapi32.RegQueryValueExW(hkey, value_name, null, null, null, null) == 0;
}

pub fn wslInteractiveCommand(buf: []u8, cwd: ?[]const u8) ?[]const u8 {
    var pos: usize = 0;
    if (!appendAscii(buf, &pos, "wsl.exe")) return null;

    if (cwd) |path| {
        if (path.len > 0) {
            if (!appendAscii(buf, &pos, " --cd ")) return null;
            if (!appendCommandLineQuotedArg(buf, &pos, path)) return null;
            return buf[0..pos];
        }
    }

    if (!appendAscii(buf, &pos, " ~")) return null;
    return buf[0..pos];
}

pub fn wslShellCommand(buf: []u8, command: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (!appendAscii(buf, &pos, "wsl.exe --exec sh -lc ")) return null;
    if (!appendCommandLineQuotedArg(buf, &pos, command)) return null;
    return buf[0..pos];
}

pub fn wslExecArgv(command: []const u8) [5][]const u8 {
    return .{ "wsl.exe", "--exec", "sh", "-lc", command };
}

pub fn localShellInitialCommand(buf: []u8, current_shell: CommandLine, command: []const u8) ?[]const u8 {
    if (!shellCommandLooksLikeConfiguredLocalShell(current_shell)) return null;
    var pos: usize = 0;
    if (!appendAscii(buf, &pos, configuredLocalShellCommandForShell(current_shell))) return null;
    if (!appendAscii(buf, &pos, " -NoLogo -NoExit -Command ")) return null;
    if (!appendCommandLineQuotedArg(buf, &pos, command)) return null;
    return buf[0..pos];
}

pub fn sshLauncherDetail() []const u8 {
    return "ssh.exe";
}

pub fn wslLauncherDetail() []const u8 {
    return "wsl.exe ~";
}

pub fn sshExecutableName() []const u8 {
    return "ssh.exe";
}

pub fn scpExecutableName() []const u8 {
    return "scp.exe";
}

pub fn sshInteractiveCommand(buf: []u8, options: SshCommandOptions) ?[]const u8 {
    // ServerAlive* prevents long-idle interactive sessions from hanging behind
    // NAT/firewall drops while preserving the existing OpenSSH invocation shape.
    const auth_flags = if (options.password_auth)
        "-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no "
    else
        "-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 ";
    const legacy_flags = if (options.legacy_algorithms)
        "-o HostkeyAlgorithms=+ssh-rsa,ssh-dss -o PubkeyAcceptedAlgorithms=+ssh-rsa,ssh-dss -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1 -o Ciphers=+aes128-cbc,3des-cbc "
    else
        "";
    var proxy_buf: [320]u8 = undefined;
    const proxy_flags = if (options.proxy_jump.len > 0)
        (std.fmt.bufPrint(&proxy_buf, "-o ProxyJump={s} ", .{options.proxy_jump}) catch return null)
    else
        "";

    const base = (if (options.port.len > 0)
        std.fmt.bufPrint(buf, "cmd.exe /k ssh.exe -tt {s}{s}{s}-p {s} {s}@{s}", .{ auth_flags, legacy_flags, proxy_flags, options.port, options.user, options.host }) catch null
    else
        std.fmt.bufPrint(buf, "cmd.exe /k ssh.exe -tt {s}{s}{s}{s}@{s}", .{ auth_flags, legacy_flags, proxy_flags, options.user, options.host }) catch null) orelse return null;
    var pos = base.len;
    if (options.remote_command.len > 0) {
        if (!appendAscii(buf, &pos, " ")) return null;
        if (!appendCommandLineQuotedArg(buf, &pos, options.remote_command)) return null;
    }
    return buf[0..pos];
}

pub fn sshControlCommand(buf: []u8, options: SshCommandOptions) ?[]const u8 {
    // Hidden controller transport: launch ssh.exe directly so process exit
    // means the transport is really gone. Interactive SSH tabs keep the cmd.exe
    // wrapper above so the user sees a normal shell after ssh exits.
    const auth_flags = if (options.password_auth)
        "-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 "
    else
        "-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o BatchMode=yes ";
    const legacy_flags = if (options.legacy_algorithms)
        "-o HostkeyAlgorithms=+ssh-rsa,ssh-dss -o PubkeyAcceptedAlgorithms=+ssh-rsa,ssh-dss -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1 -o Ciphers=+aes128-cbc,3des-cbc "
    else
        "";
    var proxy_buf: [320]u8 = undefined;
    const proxy_flags = if (options.proxy_jump.len > 0)
        (std.fmt.bufPrint(&proxy_buf, "-o ProxyJump={s} ", .{options.proxy_jump}) catch return null)
    else
        "";

    const base = (if (options.port.len > 0)
        std.fmt.bufPrint(buf, "ssh.exe -tt {s}{s}{s}-p {s} {s}@{s}", .{ auth_flags, legacy_flags, proxy_flags, options.port, options.user, options.host }) catch null
    else
        std.fmt.bufPrint(buf, "ssh.exe -tt {s}{s}{s}{s}@{s}", .{ auth_flags, legacy_flags, proxy_flags, options.user, options.host }) catch null) orelse return null;
    var pos = base.len;
    if (options.remote_command.len > 0) {
        if (!appendAscii(buf, &pos, " ")) return null;
        if (!appendCommandLineQuotedArg(buf, &pos, options.remote_command)) return null;
    }
    return buf[0..pos];
}

pub fn launchKindForCommand(command: CommandLine) LaunchKind {
    var buf: [512]u8 = undefined;
    const lower = commandLineLowerAscii(command, &buf);

    if (std.mem.indexOf(u8, lower, "ssh.exe") != null or
        std.mem.startsWith(u8, lower, "ssh "))
    {
        return .ssh;
    }
    if (std.mem.indexOf(u8, lower, "wsl.exe") != null or
        std.mem.startsWith(u8, lower, "wsl "))
    {
        return .wsl;
    }
    return .local;
}

fn wslenvContainsEntry(wslenv: []const u8, entry: []const u8) bool {
    var it = std.mem.splitScalar(u8, wslenv, ':');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, entry)) return true;
    }
    return false;
}

fn countWslenvEntry(wslenv: []const u8, entry: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, wslenv, ':');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, entry)) count += 1;
    }
    return count;
}

fn appendWslenvEntry(allocator: std.mem.Allocator, env: *std.process.EnvMap, entry: []const u8) !void {
    const key = "WSLENV";
    if (env.get(key)) |current| {
        if (wslenvContainsEntry(current, entry)) return;
        const merged = if (current.len == 0)
            try allocator.dupe(u8, entry)
        else
            try std.fmt.allocPrint(allocator, "{s}:{s}", .{ current, entry });
        defer allocator.free(merged);
        try env.put(key, merged);
        return;
    }

    try env.put(key, entry);
}

fn applyWslTerminalEnvironment(allocator: std.mem.Allocator, env: *std.process.EnvMap) !void {
    try env.put("TERM", "xterm-256color");
    try env.put("COLORTERM", "truecolor");
    try env.put("TERM_PROGRAM", "wispterm");

    try appendWslenvEntry(allocator, env, "TERM/u");
    try appendWslenvEntry(allocator, env, "COLORTERM/u");
    try appendWslenvEntry(allocator, env, "TERM_PROGRAM/u");
}

fn allocWslEnvironmentBlock(
    allocator: std.mem.Allocator,
    command: CommandLine,
    env_map_out: *?std.process.EnvMap,
) !?[]u16 {
    if (launchKindForCommand(command) != .wsl) return null;

    var env = try std.process.getEnvMap(allocator);
    errdefer env.deinit();
    try applyWslTerminalEnvironment(allocator, &env);

    const env_block = try std.process.createWindowsEnvBlock(allocator, &env);
    env_map_out.* = env;
    return env_block;
}

pub const Command = struct {
    pub const Exit = union(enum) {
        exited: u32,
        unknown,
    };

    process: HANDLE = INVALID_HANDLE_VALUE,
    thread: HANDLE = INVALID_HANDLE_VALUE,
    attr_list: ?*anyopaque = null,
    attr_list_size: usize = 0,

    fn start(self: *Command, pseudo_console: PseudoConsoleHandle, command: CommandLine, cwd: Cwd) !void {
        // Query required attribute list size.
        var attr_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);

        const attr_list_mem = std.heap.page_allocator.alloc(u8, attr_size) catch return error.OutOfMemory;
        errdefer std.heap.page_allocator.free(attr_list_mem);

        const attr_list: ?*anyopaque = attr_list_mem.ptr;

        if (InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) == 0) {
            return error.InitializeAttributeListFailed;
        }
        errdefer DeleteProcThreadAttributeList(attr_list);

        if (UpdateProcThreadAttribute(
            attr_list,
            0,
            proc_thread_attribute_pseudoconsole,
            pseudo_console,
            @sizeOf(PseudoConsoleHandle),
            null,
            null,
        ) == 0) {
            return error.UpdateAttributeFailed;
        }

        var startup_info = STARTUPINFOEXW{
            .StartupInfo = std.mem.zeroes(windows.STARTUPINFOW),
            .lpAttributeList = attr_list,
        };
        startup_info.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);

        // CreateProcessW may modify the command buffer, so pass a mutable copy.
        var cmd_len: usize = 0;
        while (command[cmd_len] != 0) : (cmd_len += 1) {}
        cmd_len += 1;

        const cmd_buf = std.heap.page_allocator.alloc(u16, cmd_len) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(cmd_buf);
        @memcpy(cmd_buf, command[0..cmd_len]);

        var env_map: ?std.process.EnvMap = null;
        defer if (env_map) |*map| map.deinit();

        const env_block = try allocWslEnvironmentBlock(std.heap.page_allocator, command, &env_map);
        defer if (env_block) |block| std.heap.page_allocator.free(block);

        const creation_flags: DWORD = extended_startupinfo_present |
            (if (env_block != null) create_unicode_environment else 0);

        var proc_info: windows.PROCESS_INFORMATION = undefined;
        if (CreateProcessW(
            null,
            @ptrCast(cmd_buf.ptr),
            null,
            null,
            0,
            creation_flags,
            if (env_block) |block| @ptrCast(block.ptr) else null,
            cwd,
            &startup_info,
            &proc_info,
        ) == 0) {
            return error.CreateProcessFailed;
        }

        self.process = proc_info.hProcess;
        self.thread = proc_info.hThread;
        self.attr_list = attr_list;
        self.attr_list_size = attr_size;
    }

    pub fn wait(self: *const Command, block: bool) !?Exit {
        if (self.process == INVALID_HANDLE_VALUE) return null;

        const timeout: DWORD = if (block) infinite else 0;
        const result = WaitForSingleObject(self.process, timeout);

        if (result == wait_timeout) return null;
        if (result != wait_object_0) return error.WaitFailed;

        var exit_code: DWORD = 0;
        if (GetExitCodeProcess(self.process, &exit_code) == 0) return error.GetExitCodeFailed;

        return Exit{ .exited = exit_code };
    }

    pub fn deinit(self: *Command) void {
        if (self.process != INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.process);
            self.process = INVALID_HANDLE_VALUE;
        }
        if (self.thread != INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.thread);
            self.thread = INVALID_HANDLE_VALUE;
        }
        if (self.attr_list) |attr| {
            DeleteProcThreadAttributeList(attr);
            const slice: [*]u8 = @ptrCast(attr);
            std.heap.page_allocator.free(slice[0..self.attr_list_size]);
            self.attr_list = null;
        }
    }

    /// No POSIX-style pid cwd query on Windows (local preview uses OSC 7).
    pub fn cwdQueryId(self: *const Command) ?i32 {
        _ = self;
        return null;
    }
};

pub fn startInPseudoConsole(command: *Command, pseudo_console: PseudoConsoleHandle, command_line: CommandLine, cwd: Cwd) !void {
    return command.start(pseudo_console, command_line, cwd);
}

pub fn cwdToUtf8(out: []u8, cwd: Cwd) ?[]u8 {
    const ptr = cwd orelse return null;
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    const utf8_len = std.unicode.utf16LeToUtf8(out, ptr[0..len]) catch return null;
    return out[0..utf8_len];
}

pub fn friendlyShellTitle(title: []const u8) []const u8 {
    var lower_buf: [512]u8 = undefined;
    const len = @min(title.len, lower_buf.len);
    for (0..len) |i| {
        lower_buf[i] = if (title[i] >= 'A' and title[i] <= 'Z') title[i] + 32 else title[i];
    }
    const lower = lower_buf[0..len];

    if (std.mem.indexOf(u8, lower, "powershell.exe") != null) return "Windows PowerShell";
    if (std.mem.indexOf(u8, lower, "pwsh.exe") != null) return "PowerShell";
    if (std.mem.indexOf(u8, lower, "powershell") != null and
        std.mem.indexOf(u8, lower, ".exe") == null) return "Windows PowerShell";
    if (std.mem.indexOf(u8, lower, "pwsh") != null and
        std.mem.indexOf(u8, lower, ".exe") == null) return "PowerShell";
    if (std.mem.indexOf(u8, lower, "cmd.exe") != null) return "Command Prompt";
    if (std.mem.eql(u8, lower, "cmd")) return "Command Prompt";
    if (std.mem.indexOf(u8, lower, "wsl.exe") != null) return "WSL";
    if (std.mem.eql(u8, lower, "wsl")) return "WSL";

    return title;
}

test "windows pty command maps native shell titles to friendly display labels" {
    try std.testing.expectEqualStrings("Windows PowerShell", friendlyShellTitle("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"));
    try std.testing.expectEqualStrings("PowerShell", friendlyShellTitle("pwsh"));
    try std.testing.expectEqualStrings("Command Prompt", friendlyShellTitle("cmd.exe"));
    try std.testing.expectEqualStrings("WSL", friendlyShellTitle("wsl.exe"));
    try std.testing.expectEqualStrings("nvim", friendlyShellTitle("nvim"));
}

test "windows pty command classifies launch context from native command lines" {
    const allocator = std.testing.allocator;

    const ssh = try allocCommandLineFromUtf8(allocator, "cmd.exe /k ssh.exe -tt user@example.test");
    defer freeCommandLine(allocator, ssh);
    try std.testing.expectEqual(LaunchKind.ssh, launchKindForCommand(commandLineFromOwned(ssh)));

    const wsl = try allocCommandLineFromUtf8(allocator, "wsl.exe ~");
    defer freeCommandLine(allocator, wsl);
    try std.testing.expectEqual(LaunchKind.wsl, launchKindForCommand(commandLineFromOwned(wsl)));

    const local = try allocCommandLineFromUtf8(allocator, "powershell.exe -NoLogo");
    defer freeCommandLine(allocator, local);
    try std.testing.expectEqual(LaunchKind.local, launchKindForCommand(commandLineFromOwned(local)));
}

test "windows pty command maps tab kinds to command lines" {
    const current_shell_owned = try allocCommandLineFromUtf8(std.testing.allocator, "pwsh.exe");
    defer freeCommandLine(std.testing.allocator, current_shell_owned);
    const current_shell = commandLineFromOwned(current_shell_owned);

    try std.testing.expectEqualStrings("pwsh.exe", try tabCommandForKind("powershell", current_shell));
    try std.testing.expectEqualStrings("pwsh.exe -NoLogo -NoProfile", try tabCommandForKind("pwsh", current_shell));
    try std.testing.expectEqualStrings("cmd.exe", try tabCommandForKind("cmd", current_shell));
    try std.testing.expectEqualStrings("wsl.exe ~", try tabCommandForKind("wsl", current_shell));
}

test "windows pty command builds WSL interactive command lines" {
    var buf: [1024]u8 = undefined;

    try std.testing.expectEqualStrings("wsl.exe ~", wslInteractiveCommand(&buf, null).?);
    try std.testing.expectEqualStrings("wsl.exe --cd \"~/work dir\"", wslInteractiveCommand(&buf, "~/work dir").?);
    try std.testing.expectEqualStrings("wsl.exe --cd \"~/a\\\"b\"", wslInteractiveCommand(&buf, "~/a\"b").?);
}

test "windows pty command builds SSH interactive command lines" {
    var buf: [1024]u8 = undefined;

    try std.testing.expectEqualStrings(
        "cmd.exe /k ssh.exe -tt -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -p 2222 user@example.test",
        sshInteractiveCommand(&buf, .{
            .user = "user",
            .host = "example.test",
            .port = "2222",
            .password_auth = false,
            .legacy_algorithms = false,
        }).?,
    );

    try std.testing.expectEqualStrings(
        "cmd.exe /k ssh.exe -tt -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o HostkeyAlgorithms=+ssh-rsa,ssh-dss -o PubkeyAcceptedAlgorithms=+ssh-rsa,ssh-dss -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1 -o Ciphers=+aes128-cbc,3des-cbc user@example.test",
        sshInteractiveCommand(&buf, .{
            .user = "user",
            .host = "example.test",
            .port = "",
            .password_auth = true,
            .legacy_algorithms = true,
        }).?,
    );

    // ProxyJump is inserted after the auth/legacy flags, before any port flag.
    try std.testing.expectEqualStrings(
        "cmd.exe /k ssh.exe -tt -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o ProxyJump=admin@jump.test:2200 -p 2222 user@example.test",
        sshInteractiveCommand(&buf, .{
            .user = "user",
            .host = "example.test",
            .port = "2222",
            .proxy_jump = "admin@jump.test:2200",
        }).?,
    );
}

test "windows pty command builds direct SSH control command lines" {
    var buf: [1024]u8 = undefined;

    try std.testing.expectEqualStrings(
        "ssh.exe -tt -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o BatchMode=yes -p 2222 user@example.test \"tmux -CC new -A -s wispterm-test\"",
        sshControlCommand(&buf, .{
            .user = "user",
            .host = "example.test",
            .port = "2222",
            .remote_command = "tmux -CC new -A -s wispterm-test",
        }).?,
    );

    try std.testing.expectEqualStrings(
        "ssh.exe -tt -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 user@example.test \"tmux -CC new -A -s wispterm-test\"",
        sshControlCommand(&buf, .{
            .user = "user",
            .host = "example.test",
            .password_auth = true,
            .remote_command = "tmux -CC new -A -s wispterm-test",
        }).?,
    );
}

test "windows pty command builds WSL exec argv for helper processes" {
    const argv = wslExecArgv("printf %s \"$HOME\"");
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("wsl.exe", argv[0]);
    try std.testing.expectEqualStrings("--exec", argv[1]);
    try std.testing.expectEqualStrings("sh", argv[2]);
    try std.testing.expectEqualStrings("-lc", argv[3]);
    try std.testing.expectEqualStrings("printf %s \"$HOME\"", argv[4]);
}

test "windows pty command applies WSL terminal environment bridge" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();

    try env.put("WSLENV", "EXISTING/u:TERM_PROGRAM/u");
    try applyWslTerminalEnvironment(std.testing.allocator, &env);

    try std.testing.expectEqualStrings("xterm-256color", env.get("TERM").?);
    try std.testing.expectEqualStrings("truecolor", env.get("COLORTERM").?);
    try std.testing.expectEqualStrings("wispterm", env.get("TERM_PROGRAM").?);

    const wslenv = env.get("WSLENV").?;
    try std.testing.expect(wslenvContainsEntry(wslenv, "EXISTING/u"));
    try std.testing.expect(wslenvContainsEntry(wslenv, "TERM/u"));
    try std.testing.expect(wslenvContainsEntry(wslenv, "COLORTERM/u"));
    try std.testing.expect(wslenvContainsEntry(wslenv, "TERM_PROGRAM/u"));
    try std.testing.expectEqual(@as(usize, 1), countWslenvEntry(wslenv, "TERM_PROGRAM/u"));
}

test "windows pty command exposes session launcher command details" {
    try std.testing.expectEqualStrings("ssh.exe", sshLauncherDetail());
    try std.testing.expectEqualStrings("wsl.exe ~", wslLauncherDetail());
    try std.testing.expectEqualStrings("ssh.exe", sshExecutableName());
    try std.testing.expectEqualStrings("scp.exe", scpExecutableName());
}
