const std = @import("std");
const types = @import("types.zig");

pub const ResumeError = error{ MissingProjectDir, UnsupportedProvider, CommandTooLong };

const ResumeCommandParts = struct {
    prefix: []const u8,
    suffix: []const u8,
};

pub fn resumeCommand(meta: types.SessionMeta, out: []u8) ResumeError![]const u8 {
    if (meta.project_dir.len == 0) return error.MissingProjectDir;
    const parts: ResumeCommandParts = switch (meta.resume_kind) {
        .codex_resume => .{ .prefix = "codex resume ", .suffix = "" },
        .claude_resume => .{ .prefix = "claude --resume ", .suffix = "" },
        .kimi_resume => .{ .prefix = "kimi --session ", .suffix = "" },
        .opencode_resume => .{ .prefix = "opencode -s ", .suffix = "" },
        .pi_resume => .{ .prefix = "pi --session ", .suffix = "" },
        .unavailable => return error.UnsupportedProvider,
    };

    var pos: usize = 0;
    try append(out, &pos, parts.prefix);
    const resume_value = piResumeValue(meta);
    if (isShellSafeBareWord(resume_value)) {
        try append(out, &pos, resume_value);
    } else {
        try appendShellSingleQuote(out, &pos, resume_value);
    }
    try append(out, &pos, parts.suffix);
    return out[0..pos];
}

pub fn posixCdThen(command: []const u8, project_dir: []const u8, out: []u8) ResumeError![]const u8 {
    if (project_dir.len == 0) return error.MissingProjectDir;
    var prefix_len: usize = 0;
    try addLen(&prefix_len, "cd ".len);
    try addLen(&prefix_len, try shellSingleQuoteLen(project_dir));
    try addLen(&prefix_len, " && ".len);
    if (prefix_len > out.len or command.len > out.len - prefix_len) return error.CommandTooLong;

    copyPossiblyOverlapping(out[prefix_len..][0..command.len], command);

    var pos: usize = 0;
    try append(out, &pos, "cd ");
    try appendShellSingleQuote(out, &pos, project_dir);
    try append(out, &pos, " && ");
    return out[0 .. pos + command.len];
}

pub fn posixDirectoryTest(project_dir: []const u8, out: []u8) ResumeError![]const u8 {
    if (project_dir.len == 0) return error.MissingProjectDir;
    var pos: usize = 0;
    try append(out, &pos, "test -d ");
    try appendShellSingleQuote(out, &pos, project_dir);
    return out[0..pos];
}

pub fn checkedPosixResume(command: []const u8, project_dir: []const u8, out: []u8) ResumeError![]const u8 {
    if (project_dir.len == 0) return error.MissingProjectDir;
    var pos: usize = 0;
    try append(out, &pos, "test -d ");
    try appendShellSingleQuote(out, &pos, project_dir);
    try append(out, &pos, " && cd ");
    try appendShellSingleQuote(out, &pos, project_dir);
    try append(out, &pos, " && ");
    try append(out, &pos, command);
    return out[0..pos];
}

pub fn posixUserShellCommand(command: []const u8, out: []u8) ResumeError![]const u8 {
    var pos: usize = 0;
    try append(out, &pos, "wispterm_ai_history_cmd=");
    try appendShellSingleQuote(out, &pos, command);
    try append(out, &pos, "; if [ -n \"$SHELL\" ] && [ -x \"$SHELL\" ]; then case \"${SHELL##*/}\" in sh|dash) exec \"$SHELL\" -lc \"$wispterm_ai_history_cmd\" ;; *) exec \"$SHELL\" -lic \"$wispterm_ai_history_cmd\" ;; esac; else exec sh -lc \"$wispterm_ai_history_cmd\"; fi");
    return out[0..pos];
}

pub fn checkedPowerShellResume(meta: types.SessionMeta, out: []u8) ResumeError![]const u8 {
    if (meta.project_dir.len == 0) return error.MissingProjectDir;
    var pos: usize = 0;
    try append(out, &pos, "if (Test-Path -LiteralPath ");
    try appendPowerShellSingleQuote(out, &pos, meta.project_dir);
    try append(out, &pos, " -PathType Container) { Set-Location -LiteralPath ");
    try appendPowerShellSingleQuote(out, &pos, meta.project_dir);
    try append(out, &pos, "; ");
    switch (meta.resume_kind) {
        .codex_resume => try append(out, &pos, "codex resume "),
        .claude_resume => try append(out, &pos, "claude --resume "),
        .kimi_resume => try append(out, &pos, "kimi --session "),
        .opencode_resume => try append(out, &pos, "opencode -s "),
        .pi_resume => try append(out, &pos, "pi --session "),
        .unavailable => return error.UnsupportedProvider,
    }
    try appendPowerShellSingleQuote(out, &pos, piResumeValue(meta));
    try append(out, &pos, " } else { Write-Error ");
    try appendPowerShellProjectNotFound(out, &pos, meta.project_dir);
    try append(out, &pos, " }");
    return out[0..pos];
}

pub fn failureMessage(err: ResumeError, meta: types.SessionMeta, out: []u8) []const u8 {
    _ = meta;
    _ = out;
    return switch (err) {
        error.MissingProjectDir => "Cannot resume: history has no project folder",
        error.UnsupportedProvider => "Cannot resume: provider does not support resume",
        error.CommandTooLong => "Cannot resume: command is too long",
    };
}

fn piResumeValue(meta: types.SessionMeta) []const u8 {
    if (meta.resume_kind == .pi_resume and isAbsoluteSessionPath(meta.source_path)) {
        return meta.source_path;
    }
    return meta.session_id;
}

/// Session paths can come from a remote POSIX host while WispTerm itself runs
/// on Windows, so do not use only the build target's native path rules.
fn isAbsoluteSessionPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        (path[2] == '/' or path[2] == '\\');
}

fn append(out: []u8, pos: *usize, value: []const u8) ResumeError!void {
    if (value.len > out.len - pos.*) return error.CommandTooLong;
    @memcpy(out[pos.*..][0..value.len], value);
    pos.* += value.len;
}

fn appendByte(out: []u8, pos: *usize, byte: u8) ResumeError!void {
    if (pos.* >= out.len) return error.CommandTooLong;
    out[pos.*] = byte;
    pos.* += 1;
}

fn appendShellSingleQuote(out: []u8, pos: *usize, value: []const u8) ResumeError!void {
    try appendByte(out, pos, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try append(out, pos, "'\\''");
        } else {
            try appendByte(out, pos, ch);
        }
    }
    try appendByte(out, pos, '\'');
}

fn appendPowerShellSingleQuote(out: []u8, pos: *usize, value: []const u8) ResumeError!void {
    try appendByte(out, pos, '\'');
    try appendPowerShellSingleQuoteBody(out, pos, value);
    try appendByte(out, pos, '\'');
}

fn appendPowerShellProjectNotFound(out: []u8, pos: *usize, project_dir: []const u8) ResumeError!void {
    try appendByte(out, pos, '\'');
    try append(out, pos, "Cannot resume: project folder not found: ");
    try appendPowerShellSingleQuoteBody(out, pos, project_dir);
    try appendByte(out, pos, '\'');
}

fn appendPowerShellSingleQuoteBody(out: []u8, pos: *usize, value: []const u8) ResumeError!void {
    for (value) |ch| {
        if (ch == '\'') {
            try append(out, pos, "''");
        } else {
            try appendByte(out, pos, ch);
        }
    }
}

fn shellSingleQuoteLen(value: []const u8) ResumeError!usize {
    var len: usize = 2;
    for (value) |ch| {
        const extra: usize = if (ch == '\'') 4 else 1;
        try addLen(&len, extra);
    }
    return len;
}

fn addLen(len: *usize, extra: usize) ResumeError!void {
    if (extra > std.math.maxInt(usize) - len.*) return error.CommandTooLong;
    len.* += extra;
}

fn copyPossiblyOverlapping(dest: []u8, source: []const u8) void {
    if (dest.len == 0) return;
    if (@intFromPtr(dest.ptr) <= @intFromPtr(source.ptr)) {
        std.mem.copyForwards(u8, dest, source);
    } else {
        std.mem.copyBackwards(u8, dest, source);
    }
}

fn isShellSafeBareWord(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', ':', '@', '%' => {},
            else => return false,
        }
    }
    return true;
}

test "ai_history_resume: builds provider resume commands" {
    var out: [128]u8 = undefined;
    const codex: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .project_dir = "/home/me/project",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    try std.testing.expectEqualStrings("codex resume abc", try resumeCommand(codex, &out));

    const claude: types.SessionMeta = .{
        .provider = .claude,
        .session_id = "xyz",
        .title = "B",
        .project_dir = "/home/me/project",
        .source_path = "b.jsonl",
        .resume_kind = .claude_resume,
    };
    try std.testing.expectEqualStrings("claude --resume xyz", try resumeCommand(claude, &out));

    const kimi: types.SessionMeta = .{
        .provider = .kimi,
        .session_id = "code-project",
        .title = "C",
        .project_dir = "/home/me/project",
        .source_path = "c.jsonl",
        .resume_kind = .kimi_resume,
    };
    try std.testing.expectEqualStrings("kimi --session code-project", try resumeCommand(kimi, &out));

    const opencode: types.SessionMeta = .{
        .provider = .opencode,
        .session_id = "ses_03282e836ffeRuTJVdTjunUnUs",
        .title = "D",
        .project_dir = "/home/me/project",
        .source_path = "ses_03282e836ffeRuTJVdTjunUnUs",
        .resume_kind = .opencode_resume,
    };
    try std.testing.expectEqualStrings("opencode -s ses_03282e836ffeRuTJVdTjunUnUs", try resumeCommand(opencode, &out));

    const pi_session: types.SessionMeta = .{
        .provider = .pi,
        .session_id = "01a10509-test",
        .title = "E",
        .project_dir = "/home/me/project",
        .source_path = "/home/me/.pi/agent/sessions/--home-me-project--/session.jsonl",
        .resume_kind = .pi_resume,
    };
    try std.testing.expectEqualStrings(
        "pi --session /home/me/.pi/agent/sessions/--home-me-project--/session.jsonl",
        try resumeCommand(pi_session, &out),
    );

    var remote_posix = pi_session;
    remote_posix.source_path = "/home/remote/.pi/agent/sessions/session.jsonl";
    try std.testing.expectEqualStrings(
        "pi --session /home/remote/.pi/agent/sessions/session.jsonl",
        try resumeCommand(remote_posix, &out),
    );
}

test "ai_history_resume: quotes unsafe session ids" {
    var out: [256]u8 = undefined;
    const with_space: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc def",
        .title = "A",
        .project_dir = "/home/me/project",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    try std.testing.expectEqualStrings("codex resume 'abc def'", try resumeCommand(with_space, &out));

    const with_quote: types.SessionMeta = .{
        .provider = .claude,
        .session_id = "it's-here",
        .title = "B",
        .project_dir = "/home/me/project",
        .source_path = "b.jsonl",
        .resume_kind = .claude_resume,
    };
    try std.testing.expectEqualStrings("claude --resume 'it'\\''s-here'", try resumeCommand(with_quote, &out));

    const kimi_with_quote: types.SessionMeta = .{
        .provider = .kimi,
        .session_id = "it'has space",
        .title = "R",
        .project_dir = "/home/me/project",
        .source_path = "r.jsonl",
        .resume_kind = .kimi_resume,
    };
    try std.testing.expectEqualStrings("kimi --session 'it'\\''has space'", try resumeCommand(kimi_with_quote, &out));

    const with_metacharacters: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc;$(touch /tmp/pwn)",
        .title = "C",
        .project_dir = "/home/me/project",
        .source_path = "c.jsonl",
        .resume_kind = .codex_resume,
    };
    try std.testing.expectEqualStrings("codex resume 'abc;$(touch /tmp/pwn)'", try resumeCommand(with_metacharacters, &out));
}

test "ai_history_resume: refuses missing project dir" {
    var out: [128]u8 = undefined;
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    try std.testing.expectError(error.MissingProjectDir, resumeCommand(meta, &out));
}

test "ai_history_resume: unavailable resume kind is unsupported" {
    var out: [128]u8 = undefined;
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .project_dir = "/home/me/project",
        .source_path = "a.jsonl",
        .resume_kind = .unavailable,
    };
    try std.testing.expectError(error.UnsupportedProvider, resumeCommand(meta, &out));
}

test "ai_history_resume: missing project dir takes precedence over unavailable resume kind" {
    var out: [128]u8 = undefined;
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .source_path = "a.jsonl",
        .resume_kind = .unavailable,
    };
    try std.testing.expectError(error.MissingProjectDir, resumeCommand(meta, &out));
}

test "ai_history_resume: reports command too long for small output buffers" {
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .project_dir = "/home/me/project",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };

    var resume_out: [8]u8 = undefined;
    try std.testing.expectError(error.CommandTooLong, resumeCommand(meta, &resume_out));

    var dir_out: [8]u8 = undefined;
    try std.testing.expectError(error.CommandTooLong, posixDirectoryTest("/home/me/project", &dir_out));
    try std.testing.expectError(error.CommandTooLong, posixCdThen("codex resume abc", "/home/me/project", &dir_out));
}

test "ai_history_resume: quotes project dir before shell commands" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "test -d '/home/me/it'\\''s here'",
        try posixDirectoryTest("/home/me/it's here", &out),
    );
    try std.testing.expectEqualStrings(
        "cd '/home/me/space dir' && codex resume abc",
        try posixCdThen("codex resume abc", "/home/me/space dir", &out),
    );
}

test "ai_history_resume: local shell command checks directory before resume" {
    var resume_buf: [128]u8 = undefined;
    var out: [512]u8 = undefined;
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .project_dir = "/home/me/project",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    const resume_cmd = try resumeCommand(meta, &resume_buf);
    try std.testing.expectEqualStrings(
        "test -d '/home/me/project' && cd '/home/me/project' && codex resume abc",
        try checkedPosixResume(resume_cmd, meta.project_dir, &out),
    );
}

test "ai_history_resume: checked POSIX resume quotes single quotes and reports missing or long commands" {
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "test -d '/home/me/it'\\''s/project' && cd '/home/me/it'\\''s/project' && codex resume 'abc def'",
        try checkedPosixResume("codex resume 'abc def'", "/home/me/it's/project", &out),
    );

    try std.testing.expectError(error.MissingProjectDir, checkedPosixResume("codex resume abc", "", &out));

    var tiny: [16]u8 = undefined;
    try std.testing.expectError(error.CommandTooLong, checkedPosixResume("codex resume abc", "/home/me/project", &tiny));
}

test "ai_history_resume: wraps POSIX resume in user shell for PATH setup" {
    var out: [768]u8 = undefined;
    try std.testing.expectEqualStrings(
        "wispterm_ai_history_cmd='test -d '\\''/home/me/project'\\'' && cd '\\''/home/me/project'\\'' && codex resume abc'; if [ -n \"$SHELL\" ] && [ -x \"$SHELL\" ]; then case \"${SHELL##*/}\" in sh|dash) exec \"$SHELL\" -lc \"$wispterm_ai_history_cmd\" ;; *) exec \"$SHELL\" -lic \"$wispterm_ai_history_cmd\" ;; esac; else exec sh -lc \"$wispterm_ai_history_cmd\"; fi",
        try posixUserShellCommand("test -d '/home/me/project' && cd '/home/me/project' && codex resume abc", &out),
    );
}

test "ai_history_resume: user shell wrapper reports command too long" {
    var tiny: [16]u8 = undefined;
    try std.testing.expectError(error.CommandTooLong, posixUserShellCommand("codex resume abc", &tiny));
}

test "ai_history_resume: checked PowerShell resume checks directory before resume" {
    var out: [512]u8 = undefined;
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc def",
        .title = "A",
        .project_dir = "C:\\Users\\me\\it's project",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    try std.testing.expectEqualStrings(
        "if (Test-Path -LiteralPath 'C:\\Users\\me\\it''s project' -PathType Container) { Set-Location -LiteralPath 'C:\\Users\\me\\it''s project'; codex resume 'abc def' } else { Write-Error 'Cannot resume: project folder not found: C:\\Users\\me\\it''s project' }",
        try checkedPowerShellResume(meta, &out),
    );

    const pi_session: types.SessionMeta = .{
        .provider = .pi,
        .session_id = "01a10509-test",
        .title = "P",
        .project_dir = "C:\\Project",
        .source_path = "C:\\Users\\me\\.pi\\agent\\sessions\\session.jsonl",
        .resume_kind = .pi_resume,
    };
    try std.testing.expectEqualStrings(
        "if (Test-Path -LiteralPath 'C:\\Project' -PathType Container) { Set-Location -LiteralPath 'C:\\Project'; pi --session 'C:\\Users\\me\\.pi\\agent\\sessions\\session.jsonl' } else { Write-Error 'Cannot resume: project folder not found: C:\\Project' }",
        try checkedPowerShellResume(pi_session, &out),
    );

    const kimi: types.SessionMeta = .{
        .provider = .kimi,
        .session_id = "code-project",
        .title = "R",
        .project_dir = "C:\\Project",
        .source_path = "r.jsonl",
        .resume_kind = .kimi_resume,
    };
    try std.testing.expectEqualStrings(
        "if (Test-Path -LiteralPath 'C:\\Project' -PathType Container) { Set-Location -LiteralPath 'C:\\Project'; kimi --session 'code-project' } else { Write-Error 'Cannot resume: project folder not found: C:\\Project' }",
        try checkedPowerShellResume(kimi, &out),
    );

    const opencode: types.SessionMeta = .{
        .provider = .opencode,
        .session_id = "ses_abc",
        .title = "O",
        .project_dir = "C:\\Project",
        .source_path = "ses_abc",
        .resume_kind = .opencode_resume,
    };
    try std.testing.expectEqualStrings(
        "if (Test-Path -LiteralPath 'C:\\Project' -PathType Container) { Set-Location -LiteralPath 'C:\\Project'; opencode -s 'ses_abc' } else { Write-Error 'Cannot resume: project folder not found: C:\\Project' }",
        try checkedPowerShellResume(opencode, &out),
    );
}

test "ai_history_resume: build failure messages explain what the user can fix" {
    var out: [128]u8 = undefined;
    const meta: types.SessionMeta = .{
        .provider = .claude,
        .session_id = "abc",
        .title = "A",
        .source_path = "a.jsonl",
        .resume_kind = .claude_resume,
    };

    try std.testing.expectEqualStrings(
        "Cannot resume: history has no project folder",
        failureMessage(error.MissingProjectDir, meta, &out),
    );
    try std.testing.expectEqualStrings(
        "Cannot resume: provider does not support resume",
        failureMessage(error.UnsupportedProvider, meta, &out),
    );
    try std.testing.expectEqualStrings(
        "Cannot resume: command is too long",
        failureMessage(error.CommandTooLong, meta, &out),
    );
}

test "ai_history_resume: checked PowerShell resume reports missing unsupported and long commands" {
    var out: [512]u8 = undefined;
    const missing: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    try std.testing.expectError(error.MissingProjectDir, checkedPowerShellResume(missing, &out));

    const unsupported: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .project_dir = "C:\\Project",
        .source_path = "a.jsonl",
        .resume_kind = .unavailable,
    };
    try std.testing.expectError(error.UnsupportedProvider, checkedPowerShellResume(unsupported, &out));

    var tiny: [16]u8 = undefined;
    try std.testing.expectError(error.CommandTooLong, checkedPowerShellResume(unsupported, &tiny));
}

test "ai_history_resume: cd then preserves command from same output buffer" {
    var out: [256]u8 = undefined;
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc def",
        .title = "A",
        .project_dir = "/home/me/space dir",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };

    const resume_cmd = try resumeCommand(meta, &out);
    const full = try posixCdThen(resume_cmd, meta.project_dir, &out);

    try std.testing.expectEqualStrings(
        "cd '/home/me/space dir' && codex resume 'abc def'",
        full,
    );
}

test "ai_history_resume: long project dir uses caller output capacity" {
    var project_dir_buf: [600]u8 = undefined;
    @memset(&project_dir_buf, 'a');
    project_dir_buf[0] = '/';

    var out: [700]u8 = undefined;
    const test_command = try posixDirectoryTest(&project_dir_buf, &out);

    try std.testing.expectEqual(@as(usize, "test -d ".len + project_dir_buf.len + 2), test_command.len);
    try std.testing.expectEqualStrings("test -d '", test_command[0.."test -d '".len]);
    try std.testing.expectEqualStrings(project_dir_buf[0..], test_command["test -d '".len .. test_command.len - 1]);
    try std.testing.expectEqual(@as(u8, '\''), test_command[test_command.len - 1]);

    const cd_command = try posixCdThen("codex resume abc", &project_dir_buf, &out);

    try std.testing.expectEqual(@as(usize, "cd ".len + project_dir_buf.len + 2 + " && codex resume abc".len), cd_command.len);
    try std.testing.expectEqualStrings("cd '", cd_command[0.."cd '".len]);
    try std.testing.expectEqualStrings(project_dir_buf[0..], cd_command["cd '".len .. cd_command.len - " && codex resume abc".len - 1]);
    try std.testing.expectEqualStrings("' && codex resume abc", cd_command[cd_command.len - "' && codex resume abc".len ..]);
}
