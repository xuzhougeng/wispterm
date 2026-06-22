const std = @import("std");
const builtin = @import("builtin");

const app_dir_name = "wispterm";
const portable_config_basename = "wispterm.conf";

pub const Env = struct {
    appdata: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    temp: ?[]const u8 = null,
    tmp: ?[]const u8 = null,
    tmpdir: ?[]const u8 = null,
    localappdata: ?[]const u8 = null,
    userprofile: ?[]const u8 = null,
};

threadlocal var test_config_dir_override: ?[]const u8 = null;

pub fn setTestConfigDirForCurrentThread(path: []const u8) void {
    if (!builtin.is_test) return;
    test_config_dir_override = path;
}

pub fn clearTestConfigDirForCurrentThread() void {
    if (!builtin.is_test) return;
    test_config_dir_override = null;
}

pub fn configDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    switch (os_tag) {
        .windows => {
            if (nonEmpty(env.appdata)) |appdata| {
                return std.fs.path.join(allocator, &.{ appdata, app_dir_name });
            }
            return configDirFromXdgOrHome(allocator, env);
        },
        .macos => {
            if (nonEmpty(env.home)) |home| {
                return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", app_dir_name });
            }
            return error.NoConfigPath;
        },
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => return configDirFromXdgOrHome(allocator, env),
        else => return configDirFromXdgOrHome(allocator, env),
    }
}

pub fn configDir(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.is_test) {
        if (test_config_dir_override) |path| {
            return allocator.dupe(u8, path);
        }
    }

    const appdata = envVarOwned(allocator, "APPDATA");
    defer if (appdata) |value| allocator.free(value);
    const xdg = envVarOwned(allocator, "XDG_CONFIG_HOME");
    defer if (xdg) |value| allocator.free(value);
    const home = envVarOwned(allocator, "HOME");
    defer if (home) |value| allocator.free(value);

    return configDirFromEnvForOs(allocator, builtin.os.tag, .{
        .appdata = appdata,
        .xdg_config_home = xdg,
        .home = home,
    });
}

pub fn pathInConfigDir(allocator: std.mem.Allocator, basename: []const u8) ![]const u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, basename });
}

pub fn pathInConfigDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
    basename: []const u8,
) ![]const u8 {
    const dir = try configDirFromEnvForOs(allocator, os_tag, env);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, basename });
}

pub fn configFilePath(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "config");
}

pub fn portableConfigFilePath(allocator: std.mem.Allocator) !?[]const u8 {
    const exe_path = std.fs.selfExePathAlloc(allocator) catch return null;
    defer allocator.free(exe_path);
    return try portableConfigFilePathFromExePath(allocator, exe_path);
}

pub fn portableConfigFilePathFromExePath(allocator: std.mem.Allocator, exe_path: []const u8) ![]const u8 {
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.MissingExeDir;
    return std.fs.path.join(allocator, &.{ exe_dir, portable_config_basename });
}

pub fn sessionFilePath(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "session.json");
}

pub fn stateFilePath(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "state");
}

pub fn exportsDir(allocator: std.mem.Allocator) ![]const u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "exports" });
}

pub fn exportsDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    const dir = try configDirFromEnvForOs(allocator, os_tag, env);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "exports" });
}

pub fn aiProfilesPath(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "ai_profiles");
}

pub fn aiProfilesPathFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    return pathInConfigDirFromEnvForOs(allocator, os_tag, env, "ai_profiles");
}

pub fn sshHostsPath(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "ssh_hosts");
}

pub fn sshHostsPathFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    return pathInConfigDirFromEnvForOs(allocator, os_tag, env, "ssh_hosts");
}

pub fn openSshConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const userprofile = envVarOwned(allocator, "USERPROFILE");
    defer if (userprofile) |value| allocator.free(value);
    const home = envVarOwned(allocator, "HOME");
    defer if (home) |value| allocator.free(value);
    return openSshConfigPathFromEnvForOs(allocator, builtin.os.tag, .{
        .userprofile = userprofile,
        .home = home,
    });
}

pub fn openSshConfigPathFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    const base = switch (os_tag) {
        .windows => nonEmpty(env.userprofile) orelse nonEmpty(env.home) orelse return error.NoOpenSshConfigPath,
        else => nonEmpty(env.home) orelse return error.NoOpenSshConfigPath,
    };
    return std.fs.path.join(allocator, &.{ base, ".ssh", "config" });
}

/// The user's home directory (`$HOME`, or `%USERPROFILE%` on Windows). Used to
/// resolve a target software's skills root (e.g. `~/.claude/skills`) natively
/// when no POSIX shell is available to expand `$HOME`.
pub fn homeDir(allocator: std.mem.Allocator) ![]const u8 {
    const userprofile = envVarOwned(allocator, "USERPROFILE");
    defer if (userprofile) |value| allocator.free(value);
    const home = envVarOwned(allocator, "HOME");
    defer if (home) |value| allocator.free(value);
    return homeDirFromEnvForOs(allocator, builtin.os.tag, .{
        .userprofile = userprofile,
        .home = home,
    });
}

pub fn homeDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    const base = switch (os_tag) {
        .windows => nonEmpty(env.userprofile) orelse nonEmpty(env.home) orelse return error.NoHomeDir,
        else => nonEmpty(env.home) orelse return error.NoHomeDir,
    };
    return allocator.dupe(u8, base);
}

pub fn agentHistoryPath(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "agent-history.json");
}

pub fn agentHistoryPathFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    return pathInConfigDirFromEnvForOs(allocator, os_tag, env, "agent-history.json");
}

pub fn aiHistoryCachePath(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "ai_history_cache.json");
}

pub fn aiHistoryCachePathFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    return pathInConfigDirFromEnvForOs(allocator, os_tag, env, "ai_history_cache.json");
}

pub fn skillsDir(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "skills");
}

pub fn skillsDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    return pathInConfigDirFromEnvForOs(allocator, os_tag, env, "skills");
}

pub fn commandsDir(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "commands");
}

pub fn commandsDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    return pathInConfigDirFromEnvForOs(allocator, os_tag, env, "commands");
}

pub fn toolsDir(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "tools");
}

pub fn toolsDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    return pathInConfigDirFromEnvForOs(allocator, os_tag, env, "tools");
}

pub fn pluginSkillsDir(allocator: std.mem.Allocator) ![]const u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "plugins", "skills" });
}

pub fn pluginSkillsDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    const dir = try configDirFromEnvForOs(allocator, os_tag, env);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "plugins", "skills" });
}

/// Path to the Claude Code hook settings file (`~/.claude/settings.json`).
/// Returns `error.NoHomePath` when neither HOME nor USERPROFILE is set.
pub fn agentHookSettingsPath(allocator: std.mem.Allocator) ![]const u8 {
    const userprofile = envVarOwned(allocator, "USERPROFILE");
    defer if (userprofile) |value| allocator.free(value);
    const home = envVarOwned(allocator, "HOME");
    defer if (home) |value| allocator.free(value);

    return agentHookSettingsPathFromEnv(allocator, .{
        .userprofile = userprofile,
        .home = home,
    });
}

pub fn agentHookSettingsPathFromEnv(allocator: std.mem.Allocator, env: Env) ![]const u8 {
    const dot_claude = ".claude";
    if (nonEmpty(env.home)) |home| {
        return std.fs.path.join(allocator, &.{ home, dot_claude, "settings.json" });
    }
    if (nonEmpty(env.userprofile)) |userprofile| {
        return std.fs.path.join(allocator, &.{ userprofile, dot_claude, "settings.json" });
    }
    return error.NoHomePath;
}

pub fn downloadsDir(allocator: std.mem.Allocator) ![]const u8 {
    const userprofile = envVarOwned(allocator, "USERPROFILE");
    defer if (userprofile) |value| allocator.free(value);
    const home = envVarOwned(allocator, "HOME");
    defer if (home) |value| allocator.free(value);

    return downloadsDirFromEnvForOs(allocator, builtin.os.tag, .{
        .userprofile = userprofile,
        .home = home,
    });
}

pub fn downloadsDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    switch (os_tag) {
        .windows => {
            if (nonEmpty(env.userprofile)) |userprofile| {
                return std.fs.path.join(allocator, &.{ userprofile, "Downloads" });
            }
            return error.NoDownloadsPath;
        },
        else => {
            if (nonEmpty(env.home)) |home| {
                return std.fs.path.join(allocator, &.{ home, "Downloads" });
            }
            return error.NoDownloadsPath;
        },
    }
}

pub fn tempDir(allocator: std.mem.Allocator) ![]const u8 {
    const temp = envVarOwned(allocator, "TEMP");
    defer if (temp) |value| allocator.free(value);
    const tmp = envVarOwned(allocator, "TMP");
    defer if (tmp) |value| allocator.free(value);
    const tmpdir = envVarOwned(allocator, "TMPDIR");
    defer if (tmpdir) |value| allocator.free(value);
    const localappdata = envVarOwned(allocator, "LOCALAPPDATA");
    defer if (localappdata) |value| allocator.free(value);

    return tempDirFromEnvForOs(allocator, builtin.os.tag, .{
        .temp = temp,
        .tmp = tmp,
        .tmpdir = tmpdir,
        .localappdata = localappdata,
    });
}

pub fn tempDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    if (os_tag == .windows) {
        if (nonEmpty(env.temp)) |temp| return allocator.dupe(u8, temp);
        if (nonEmpty(env.tmp)) |tmp| return allocator.dupe(u8, tmp);
        if (nonEmpty(env.localappdata)) |localappdata| {
            return std.fs.path.join(allocator, &.{ localappdata, "Temp" });
        }
        return error.NoTempPath;
    }

    if (nonEmpty(env.tmpdir)) |tmpdir| return allocator.dupe(u8, tmpdir);
    if (nonEmpty(env.temp)) |temp| return allocator.dupe(u8, temp);
    if (nonEmpty(env.tmp)) |tmp| return allocator.dupe(u8, tmp);
    return allocator.dupe(u8, "/tmp");
}

pub fn stateFilePathFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    return pathInConfigDirFromEnvForOs(allocator, os_tag, env, "state");
}

pub fn themeFilePath(allocator: std.mem.Allocator, theme_name: []const u8) ![]const u8 {
    const dir = try configDir(allocator);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "themes", theme_name });
}

fn configDirFromXdgOrHome(allocator: std.mem.Allocator, env: Env) ![]const u8 {
    if (nonEmpty(env.xdg_config_home)) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, app_dir_name });
    }
    if (nonEmpty(env.home)) |home| {
        return std.fs.path.join(allocator, &.{ home, ".config", app_dir_name });
    }
    return error.NoConfigPath;
}

fn envVarOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const actual = value orelse return null;
    if (actual.len == 0) return null;
    return actual;
}

test "configDir uses test override in Zig test processes" {
    const allocator = std.testing.allocator;
    const override = "/tmp/wispterm-test-config";

    setTestConfigDirForCurrentThread(override);
    defer clearTestConfigDirForCurrentThread();

    const path = try configDir(allocator);
    defer allocator.free(path);

    try std.testing.expectEqualStrings(override, path);
}

test "platform dirs resolve app config root per OS" {
    const allocator = std.testing.allocator;

    {
        const dir = try configDirFromEnvForOs(allocator, .windows, .{
            .appdata = "C:/Users/alice/AppData/Roaming",
        });
        defer allocator.free(dir);
        const expected = try std.fs.path.join(allocator, &.{ "C:/Users/alice/AppData/Roaming", app_dir_name });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, dir);
    }

    {
        const dir = try configDirFromEnvForOs(allocator, .linux, .{
            .xdg_config_home = "/home/alice/.config",
            .home = "/home/alice",
        });
        defer allocator.free(dir);
        const expected = try std.fs.path.join(allocator, &.{ "/home/alice/.config", app_dir_name });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, dir);
    }

    {
        const dir = try configDirFromEnvForOs(allocator, .linux, .{
            .home = "/home/alice",
        });
        defer allocator.free(dir);
        const expected = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, dir);
    }

    {
        const dir = try configDirFromEnvForOs(allocator, .macos, .{
            .home = "/Users/alice",
        });
        defer allocator.free(dir);
        const expected = try std.fs.path.join(allocator, &.{ "/Users/alice", "Library", "Application Support", app_dir_name });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, dir);
    }
}

test "platform dirs build config and theme file paths" {
    const allocator = std.testing.allocator;

    const dir = try configDirFromEnvForOs(allocator, .linux, .{
        .home = "/home/alice",
    });
    defer allocator.free(dir);

    const config_path = try std.fs.path.join(allocator, &.{ dir, "config" });
    defer allocator.free(config_path);
    try std.testing.expect(std.mem.endsWith(u8, config_path, std.fs.path.sep_str ++ app_dir_name ++ std.fs.path.sep_str ++ "config"));

    const theme_path = try std.fs.path.join(allocator, &.{ dir, "themes", "Builtin Dark" });
    defer allocator.free(theme_path);
    try std.testing.expect(std.mem.endsWith(u8, theme_path, std.fs.path.sep_str ++ app_dir_name ++ std.fs.path.sep_str ++ "themes" ++ std.fs.path.sep_str ++ "Builtin Dark"));
}

test "platform dirs build portable config path from executable path" {
    const allocator = std.testing.allocator;

    const path = try portableConfigFilePathFromExePath(allocator, "C:/Apps/WispTerm/wispterm.exe");
    defer allocator.free(path);
    const expected = try std.fs.path.join(allocator, &.{ "C:/Apps/WispTerm", "wispterm.conf" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "platform dirs build window state path" {
    const allocator = std.testing.allocator;

    const state_path = try stateFilePathFromEnvForOs(allocator, .macos, .{
        .home = "/Users/alice",
    });
    defer allocator.free(state_path);

    const expected = try std.fs.path.join(allocator, &.{ "/Users/alice", "Library", "Application Support", app_dir_name, "state" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, state_path);
}

test "platform dirs ignore empty env values" {
    const allocator = std.testing.allocator;

    const dir = try configDirFromEnvForOs(allocator, .linux, .{
        .xdg_config_home = "",
        .home = "/home/alice",
    });
    defer allocator.free(dir);

    const expected = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, dir);
}

test "platform dirs resolve temporary directory per OS" {
    const allocator = std.testing.allocator;

    {
        const dir = try tempDirFromEnvForOs(allocator, .windows, .{
            .tmp = "C:/Users/alice/AppData/Local/TempFallback",
            .temp = "C:/Users/alice/AppData/Local/Temp",
        });
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("C:/Users/alice/AppData/Local/Temp", dir);
    }

    {
        const dir = try tempDirFromEnvForOs(allocator, .windows, .{
            .localappdata = "C:/Users/alice/AppData/Local",
        });
        defer allocator.free(dir);
        const expected = try std.fs.path.join(allocator, &.{ "C:/Users/alice/AppData/Local", "Temp" });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, dir);
    }

    {
        const dir = try tempDirFromEnvForOs(allocator, .linux, .{
            .tmpdir = "/var/tmp",
        });
        defer allocator.free(dir);
        try std.testing.expectEqualStrings("/var/tmp", dir);
    }
}

test "platform dirs expose app data paths for shared features" {
    const allocator = std.testing.allocator;
    const env = Env{ .home = "/home/alice" };

    const exports = try exportsDirFromEnvForOs(allocator, .linux, env);
    defer allocator.free(exports);
    const expected_exports = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name, "exports" });
    defer allocator.free(expected_exports);
    try std.testing.expectEqualStrings(expected_exports, exports);

    const ai_profiles = try aiProfilesPathFromEnvForOs(allocator, .linux, env);
    defer allocator.free(ai_profiles);
    const expected_ai = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name, "ai_profiles" });
    defer allocator.free(expected_ai);
    try std.testing.expectEqualStrings(expected_ai, ai_profiles);

    const ssh_hosts = try sshHostsPathFromEnvForOs(allocator, .linux, env);
    defer allocator.free(ssh_hosts);
    const expected_ssh = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name, "ssh_hosts" });
    defer allocator.free(expected_ssh);
    try std.testing.expectEqualStrings(expected_ssh, ssh_hosts);

    const history = try agentHistoryPathFromEnvForOs(allocator, .linux, env);
    defer allocator.free(history);
    const expected_history = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name, "agent-history.json" });
    defer allocator.free(expected_history);
    try std.testing.expectEqualStrings(expected_history, history);

    const ai_history_cache = try aiHistoryCachePathFromEnvForOs(allocator, .linux, env);
    defer allocator.free(ai_history_cache);
    const expected_ai_history_cache = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name, "ai_history_cache.json" });
    defer allocator.free(expected_ai_history_cache);
    try std.testing.expectEqualStrings(expected_ai_history_cache, ai_history_cache);
}

test "platform dirs expose app skill roots" {
    const allocator = std.testing.allocator;
    const env = Env{ .home = "/home/alice" };

    const skills = try skillsDirFromEnvForOs(allocator, .linux, env);
    defer allocator.free(skills);
    const expected_skills = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name, "skills" });
    defer allocator.free(expected_skills);
    try std.testing.expectEqualStrings(expected_skills, skills);

    const plugin_skills = try pluginSkillsDirFromEnvForOs(allocator, .linux, env);
    defer allocator.free(plugin_skills);
    const expected_plugin_skills = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name, "plugins", "skills" });
    defer allocator.free(expected_plugin_skills);
    try std.testing.expectEqualStrings(expected_plugin_skills, plugin_skills);

    const commands = try commandsDirFromEnvForOs(allocator, .linux, env);
    defer allocator.free(commands);
    const expected_commands = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name, "commands" });
    defer allocator.free(expected_commands);
    try std.testing.expectEqualStrings(expected_commands, commands);

    const tools = try toolsDirFromEnvForOs(allocator, .linux, env);
    defer allocator.free(tools);
    const expected_tools = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name, "tools" });
    defer allocator.free(expected_tools);
    try std.testing.expectEqualStrings(expected_tools, tools);
}

test "platform dirs resolve downloads directory per OS" {
    const allocator = std.testing.allocator;

    const downloads = try downloadsDirFromEnvForOs(allocator, .windows, .{
        .userprofile = "C:/Users/alice",
    });
    defer allocator.free(downloads);
    const expected = try std.fs.path.join(allocator, &.{ "C:/Users/alice", "Downloads" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, downloads);
}

test "platform dirs resolve openssh config path per OS" {
    const allocator = std.testing.allocator;

    const windows = try openSshConfigPathFromEnvForOs(allocator, .windows, .{
        .userprofile = "C:/Users/alice",
        .home = "/ignored",
    });
    defer allocator.free(windows);
    const expected_windows = try std.fs.path.join(allocator, &.{ "C:/Users/alice", ".ssh", "config" });
    defer allocator.free(expected_windows);
    try std.testing.expectEqualStrings(expected_windows, windows);

    const linux = try openSshConfigPathFromEnvForOs(allocator, .linux, .{
        .home = "/home/alice",
    });
    defer allocator.free(linux);
    const expected_linux = try std.fs.path.join(allocator, &.{ "/home/alice", ".ssh", "config" });
    defer allocator.free(expected_linux);
    try std.testing.expectEqualStrings(expected_linux, linux);

    try std.testing.expectError(error.NoOpenSshConfigPath, openSshConfigPathFromEnvForOs(allocator, .linux, .{}));
}

test "platform dirs resolve home directory per OS" {
    const allocator = std.testing.allocator;

    const windows = try homeDirFromEnvForOs(allocator, .windows, .{
        .userprofile = "C:/Users/alice",
        .home = "/ignored",
    });
    defer allocator.free(windows);
    try std.testing.expectEqualStrings("C:/Users/alice", windows);

    const linux = try homeDirFromEnvForOs(allocator, .linux, .{ .home = "/home/alice" });
    defer allocator.free(linux);
    try std.testing.expectEqualStrings("/home/alice", linux);

    try std.testing.expectError(error.NoHomeDir, homeDirFromEnvForOs(allocator, .linux, .{}));
}
