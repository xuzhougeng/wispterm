//! Pure helpers for launching the user's configured shell as a *login* shell on
//! macOS (the Terminal.app/iTerm/Ghostty convention, so `/etc/zprofile`'s
//! `path_helper` and `~/.bash_profile` run and PATH includes /opt/homebrew/bin
//! etc.).
//!
//! Kept libc-free and OS-agnostic so the logic is unit-tested by the fast suite
//! even though the exec path that uses it (`pty_posix.zig`) only compiles for a
//! POSIX target.
const std = @import("std");

/// Shells we start as login shells. argv[0] is prefixed with the historical BSD
/// login dash ("-zsh", "-bash", …) when its basename matches one of these.
const known_login_shells = [_][]const u8{ "zsh", "bash", "sh", "fish", "dash", "tcsh", "ksh" };

/// Returns the basename of `arg0` when it names a known interactive shell,
/// otherwise null. Used to decide whether to start the child as a login shell.
pub fn loginShellBasename(arg0: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, arg0, '/');
    const base = if (slash) |idx| arg0[idx + 1 ..] else arg0;
    for (known_login_shells) |name| {
        if (std.mem.eql(u8, base, name)) return base;
    }
    return null;
}

/// Writes the BSD login form of argv[0] ("-zsh", "-bash", …) into `buf` when
/// `arg0`'s basename names a known shell, returning the NUL-terminated slice.
/// Returns null to leave argv[0] unchanged (explicit-command tabs, SSH, WSL).
pub fn loginArgv0(buf: []u8, arg0: []const u8) ?[:0]const u8 {
    const base = loginShellBasename(arg0) orelse return null;
    if (1 + base.len + 1 > buf.len) return null;
    buf[0] = '-';
    @memcpy(buf[1 .. 1 + base.len], base);
    buf[1 + base.len] = 0;
    return buf[0 .. 1 + base.len :0];
}

/// A *login* bash sources `~/.bash_profile`/`~/.profile` but **not** `~/.bashrc`,
/// where conda/pyenv/nvm init usually lives — so a bare `shell = bash` would
/// launch without it (unlike zsh, whose login shell reads `~/.zshrc`). After the
/// login profile sets up PATH (`path_helper`, `~/.bash_profile`), re-exec an
/// interactive non-login bash so `~/.bashrc` is sourced too, matching what the
/// user gets by typing `bash` at a login prompt.
///
/// Returns the `-c` payload (`exec '<arg0>'`) for the re-exec, or null when no
/// wrapping is needed:
///   - non-bash shells (zsh/fish read their rc in login mode already),
///   - explicit command lines (`argc > 1`, e.g. a `bash -lc …` resume), or
///   - a pathological path containing a single quote (left to the plain login
///     shell rather than risk a malformed command).
pub fn bashReexecCommand(buf: []u8, arg0: []const u8, argc: usize) ?[:0]const u8 {
    if (argc != 1) return null;
    const base = loginShellBasename(arg0) orelse return null;
    if (!std.mem.eql(u8, base, "bash")) return null;
    if (std.mem.indexOfScalar(u8, arg0, '\'') != null) return null;
    return std.fmt.bufPrintZ(buf, "exec '{s}'", .{arg0}) catch null;
}

test "loginShellBasename recognises known interactive shells" {
    try std.testing.expectEqualStrings("zsh", loginShellBasename("zsh").?);
    try std.testing.expectEqualStrings("zsh", loginShellBasename("/bin/zsh").?);
    try std.testing.expectEqualStrings("bash", loginShellBasename("/usr/local/bin/bash").?);
    try std.testing.expectEqualStrings("fish", loginShellBasename("/opt/homebrew/bin/fish").?);
    try std.testing.expect(loginShellBasename("ssh") == null);
    try std.testing.expect(loginShellBasename("/usr/bin/ssh") == null);
    try std.testing.expect(loginShellBasename("/bin/echo") == null);
}

test "loginArgv0 builds the BSD login argv0 and leaves non-shells alone" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("-zsh", loginArgv0(&buf, "zsh").?);
    try std.testing.expectEqualStrings("-bash", loginArgv0(&buf, "/opt/homebrew/bin/bash").?);
    try std.testing.expect(loginArgv0(&buf, "ssh") == null);
}

test "bashReexecCommand re-execs interactive bash only for the bare login launch" {
    var buf: [256]u8 = undefined;
    // Bare bash (name or absolute path): re-exec the same binary interactively
    // so ~/.bashrc (conda/pyenv/nvm) loads after the login profile.
    try std.testing.expectEqualStrings("exec 'bash'", bashReexecCommand(&buf, "bash", 1).?);
    try std.testing.expectEqualStrings(
        "exec '/usr/local/bin/bash'",
        bashReexecCommand(&buf, "/usr/local/bin/bash", 1).?,
    );
    // zsh already reads ~/.zshrc in login mode — no wrapper.
    try std.testing.expect(bashReexecCommand(&buf, "zsh", 1) == null);
    // Explicit command lines (resume, `bash -c …`) stay intact.
    try std.testing.expect(bashReexecCommand(&buf, "bash", 3) == null);
    // A single quote in the path is left to the plain login shell.
    try std.testing.expect(bashReexecCommand(&buf, "/weird'/bash", 1) == null);
}
