//! `password_input` tool: type a secret from the user's encrypted password
//! store (Password Store page) into a terminal password prompt for sudo, su,
//! ssh, or a database login. The model only ever names the entry. The secret is
//! decrypted after the user approves, written straight to the PTY, and wiped;
//! it never appears in the tool arguments, the tool result, the chat
//! transcript, or saved history, and the conversation's secret filter masks it
//! out of any later tool output. Entries the user marked "agent off" are
//! refused without asking.
//!
//! The secret is typed only while the terminal's last line is a password
//! prompt, checked before the approval and again right before typing, so a
//! prompt that timed out while the user decided cannot turn the secret into a
//! shell command line. Ghostty detects the same state from the PTY's termios
//! (`termio/Exec.zig`: canonical mode with echo off, drawn as a lock cursor);
//! the screen is read here instead because an SSH session's prompt lives on the
//! remote host, where the local termios cannot see it.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const tool_args = @import("args.zig");
const terminal_tools = @import("terminal.zig");
const agent_exec = @import("exec.zig");
const store = @import("../credential/store.zig");
const redact = @import("../credential/redact.zig");

const ToolContext = types.ToolContext;
const ToolHost = types.ToolHost;
const ToolSurface = types.ToolSurface;

pub const TOOL_NAME = "password_input";
/// Earlier name of this tool, which handed the plaintext to the model. A Skill
/// Center opt-out saved under it still disables `password_input`.
pub const LEGACY_TOOL_NAME = "password_get";

pub fn run(ctx: *ToolContext, root: std.json.Value) ![]u8 {
    var vault = try store.load(ctx.allocator);
    defer vault.deinit();
    const entry = switch (try pick(ctx.allocator, vault.entries.items, tool_args.string(root, "name"))) {
        .entry => |entry| entry,
        .message => |message| return message,
    };

    const surface_id = tool_args.string(root, "surface_id") orelse terminal_tools.defaultExecSurfaceId(ctx) orelse return ctx.allocator.dupe(u8, "Missing surface_id");
    const timeout_ms = tool_args.int(root, "timeout_ms") orelse ctx.settings.command_timeout_ms;
    const snapshot = terminal_tools.collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot.deinit(ctx.allocator);
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal tool host is available.");
    const surface = terminal_tools.resolveSurfaceId(snapshot, surface_id, terminal_tools.selectedWriteContext(ctx)) orelse return terminal_tools.allocNoSurfaceError(ctx.allocator, snapshot, surface_id);
    if (try terminal_tools.ensureWriteContext(ctx, surface)) |message| return message;
    return typeAtPrompt(ctx, host, surface, entry, timeout_ms);
}

const Pick = union(enum) {
    entry: *const store.Entry,
    /// Owned explanation for the model; never contains a secret.
    message: []u8,
};

fn pick(allocator: std.mem.Allocator, entries: []const store.Entry, name_opt: ?[]const u8) !Pick {
    const name = name_opt orelse return .{ .message = try listNames(allocator, entries, "Missing name.") };
    const entry = store.lookup(entries, name) orelse {
        var prefix_buf: [160]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "No password named \"{s}\" in the store.", .{name}) catch "No such password in the store.";
        return .{ .message = try listNames(allocator, entries, prefix) };
    };
    if (!entry.agent) {
        return .{ .message = try std.fmt.allocPrint(allocator, "The user does not let the agent use \"{s}\". Ask the user to enter it themselves.", .{entry.name}) };
    }
    if (entry.secret.len == 0) {
        return .{ .message = try std.fmt.allocPrint(allocator, "\"{s}\" has no password set. Ask the user to add it in the Password Store page.", .{entry.name}) };
    }
    return .{ .entry = entry };
}

fn typeAtPrompt(ctx: *ToolContext, host: ToolHost, surface: ToolSurface, entry: *const store.Entry, timeout_ms: u32) ![]u8 {
    const prompt = switch (try readPrompt(ctx, host, surface)) {
        .prompt => |line| line,
        .message => |message| return message,
    };
    defer ctx.allocator.free(prompt);

    var reason_buf: [256]u8 = undefined;
    const reason = std.fmt.bufPrint(&reason_buf, "Type the stored password \"{s}\" into the password prompt of \"{s}\" (the password stays hidden)", .{ entry.name, surface.title }) catch "Type a stored password into a terminal password prompt";
    if (!ctx.requestApproval(TOOL_NAME, entry.name, reason)) {
        return std.fmt.allocPrint(ctx.allocator, "User declined to type the password \"{s}\". Do not retry without asking the user.", .{entry.name});
    }
    // The prompt can time out (sudo, ssh) while the approval is pending; never
    // type the secret into whatever replaced it.
    switch (try readPrompt(ctx, host, surface)) {
        .prompt => |line| ctx.allocator.free(line),
        .message => |message| return message,
    }

    const secret = store.reveal(ctx.allocator, entry) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Could not decrypt \"{s}\" ({s}). Ask the user to check the Password Store page.", .{ entry.name, @errorName(err) });
    };
    defer store.wipe(ctx.allocator, secret);
    if (ctx.secret_filter) |filter| filter.remember(secret);
    const input = try std.mem.concat(ctx.allocator, u8, &.{ secret, "\r" });
    const written = host.writeSurface(host.ctx, surface.id, surface.ptr, input);
    store.wipe(ctx.allocator, input);
    if (!written) return ctx.allocator.dupe(u8, "Failed to write to terminal surface.");

    const screen = try agent_exec.waitForReplPromptReturn(ctx, host, surface, .plain, prompt, timeout_ms);
    const masked = try redact.maskOwned(ctx.allocator, screen, secret);
    defer ctx.allocator.free(masked);
    var user_buf: [192]u8 = undefined;
    const user_line = if (entry.username.len > 0)
        std.fmt.bufPrint(&user_buf, "username[{s}]={s}\n", .{ entry.name, entry.username }) catch ""
    else
        "";
    return std.fmt.allocPrint(
        ctx.allocator,
        "Typed the stored password \"{s}\" into the prompt and pressed Enter. The password is never shown to you; to retry, call password_input again.\n{s}Latest snapshot:\n{s}",
        .{ entry.name, user_line, masked },
    );
}

const PromptRead = union(enum) {
    /// Owned copy of the password prompt line.
    prompt: []u8,
    /// Owned refusal for the model.
    message: []u8,
};

fn readPrompt(ctx: *const ToolContext, host: ToolHost, surface: ToolSurface) !PromptRead {
    const screen = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch
        return .{ .message = try ctx.allocator.dupe(u8, "Failed to read terminal snapshot.") };
    defer ctx.allocator.free(screen);
    const line = agent_exec.extractPromptLine(screen);
    if (looksLikePasswordPrompt(line)) return .{ .prompt = try ctx.allocator.dupe(u8, line) };
    return .{ .message = try std.fmt.allocPrint(
        ctx.allocator,
        "Nothing typed: \"{s}\" is not showing a password prompt (last line: \"{s}\"). Run the command that asks for the password first, e.g. terminal_repl_exec repl=plain code=\"sudo -v\", then call password_input while the prompt is on screen.",
        .{ surface.title, line[0..@min(line.len, 120)] },
    ) };
}

/// A trimmed last screen line that asks for a password: it ends with a colon
/// (ASCII or full-width) and names a password. Shell prompts end in `$`, `#`,
/// `%`, or `>`, so typing the secret where it would be echoed and run as a
/// command is refused.
pub fn looksLikePasswordPrompt(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 200) return false;
    if (!std.mem.endsWith(u8, trimmed, ":") and !std.mem.endsWith(u8, trimmed, "：")) return false;
    const words = [_][]const u8{
        "password",
        "passphrase",
        "pass phrase",
        "passcode",
        "passwort",
        "mot de passe",
        "contraseña",
        "senha",
        "пароль",
        "密码",
        "密碼",
        "口令",
        "パスワード",
        "비밀번호",
    };
    for (words) |word| {
        if (std.ascii.indexOfIgnoreCase(trimmed, word) != null) return true;
    }
    return false;
}

/// Names, usernames and notes are not secrets: list the entries the agent may
/// use so it can pick the right one.
fn listNames(allocator: std.mem.Allocator, entries: []const store.Entry, prefix: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, prefix);
    var count: usize = 0;
    for (entries) |entry| {
        if (!entry.agent) continue;
        try out.appendSlice(allocator, if (count == 0) " Available names: " else ", ");
        try out.appendSlice(allocator, entry.name);
        if (entry.username.len > 0 or entry.note.len > 0) {
            try out.appendSlice(allocator, " (");
            if (entry.username.len > 0) try out.print(allocator, "user {s}", .{entry.username});
            if (entry.username.len > 0 and entry.note.len > 0) try out.appendSlice(allocator, "; ");
            try out.appendSlice(allocator, entry.note);
            try out.append(allocator, ')');
        }
        count += 1;
    }
    if (count == 0) try out.appendSlice(allocator, " No entry is available to the agent; ask the user to add one in Command Center > Password Store.");
    return out.toOwnedSlice(allocator);
}

const TestApproval = struct {
    var allow: bool = true;
    var asked: bool = false;
    var asked_command: [64]u8 = undefined;
    var asked_len: usize = 0;
    var asked_reason: [256]u8 = undefined;
    var asked_reason_len: usize = 0;
    fn approve(_: *anyopaque, _: []const u8, command: []const u8, reason: []const u8) bool {
        asked = true;
        asked_len = @min(command.len, asked_command.len);
        @memcpy(asked_command[0..asked_len], command[0..asked_len]);
        asked_reason_len = @min(reason.len, asked_reason.len);
        @memcpy(asked_reason[0..asked_reason_len], reason[0..asked_reason_len]);
        return allow;
    }
    fn cancelled(_: *anyopaque) bool {
        return false;
    }
};

/// Fake terminal: serves `screens` in order (the last one repeats) and records
/// every byte written to it.
const TestHost = struct {
    screens: []const []const u8,
    reads: usize = 0,
    writes: [128]u8 = undefined,
    writes_len: usize = 0,

    fn surfaceSnapshot(ptr: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: *anyopaque) anyerror![]u8 {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        const screen = self.screens[@min(self.reads, self.screens.len - 1)];
        self.reads += 1;
        return allocator.dupe(u8, screen);
    }
    fn writeSurface(ptr: *anyopaque, _: []const u8, _: *anyopaque, data: []const u8) bool {
        const self: *TestHost = @ptrCast(@alignCast(ptr));
        @memcpy(self.writes[self.writes_len..][0..data.len], data);
        self.writes_len += data.len;
        return true;
    }
    fn collectSnapshot(_: *anyopaque, _: std.mem.Allocator) anyerror!types.ToolSnapshot {
        return error.Unsupported;
    }
    fn spawnTab(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8) anyerror!ToolSurface {
        return error.Unsupported;
    }
    fn closeTab(_: *anyopaque, _: std.mem.Allocator, _: ?usize, _: ?[]const u8, _: ?[]const u8) anyerror!types.ToolClosedTab {
        return error.Unsupported;
    }
    fn saveSshProfile(_: *anyopaque, _: std.mem.Allocator, _: types.SshProfileSaveArgs) anyerror!types.SavedSshProfile {
        return error.Unsupported;
    }
    fn connectSshProfile(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!ToolSurface {
        return error.Unsupported;
    }
    fn host(self: *TestHost) ToolHost {
        return .{
            .ctx = @ptrCast(self),
            .collectSnapshot = collectSnapshot,
            .surfaceSnapshot = surfaceSnapshot,
            .writeSurface = writeSurface,
            .spawnTab = spawnTab,
            .closeTab = closeTab,
            .saveSshProfile = saveSshProfile,
            .connectSshProfile = connectSshProfile,
        };
    }
    fn written(self: *const TestHost) []const u8 {
        return self.writes[0..self.writes_len];
    }
};

fn testSurface(test_host: *TestHost) ToolSurface {
    return .{
        .id = @constCast("surface-1"),
        .title = @constCast("lab"),
        .cwd = @constCast("/root"),
        .snapshot = @constCast(""),
        .tab_index = 0,
        .focused = true,
        .is_ssh = true,
        .is_wsl = false,
        .ptr = @ptrCast(test_host),
    };
}

fn testCtx(permission: types.AgentPermission, filter: ?*redact.Filter) ToolContext {
    var dummy: u8 = 0;
    TestApproval.asked = false;
    TestApproval.allow = true;
    return .{
        .allocator = std.testing.allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = permission },
        .secret_filter = filter,
        .approve = TestApproval.approve,
        .cancelled = TestApproval.cancelled,
    };
}

fn testVault() !store.Vault {
    var vault = store.Vault.init(std.testing.allocator);
    errdefer vault.deinit();
    try vault.append(.{ .name = "root", .username = "admin", .secret = try vault.seal("s3cret-pw"), .note = "lab sudo" });
    try vault.append(.{ .name = "mysql", .secret = try vault.seal("m") });
    try vault.append(.{ .name = "bank", .secret = try vault.seal("never"), .agent = false });
    try vault.append(.{ .name = "empty" });
    return vault;
}

fn testEntry(vault: *const store.Vault, name: []const u8) *const store.Entry {
    return store.lookup(vault.entries.items, name).?;
}

test "password_input asks even under full permission, types the secret, and never returns it" {
    var vault = try testVault();
    defer vault.deinit();
    var filter: redact.Filter = .{};
    var ctx = testCtx(.full, &filter);
    // The prompt echoes the secret here so the test proves the result masks it.
    const prompt = "$ sudo -v\n[sudo] password for admin:";
    var term = TestHost{ .screens = &.{ prompt, prompt, "$ sudo -v\n[sudo] password for admin: s3cret-pw\n$ " } };
    const out = try typeAtPrompt(&ctx, term.host(), testSurface(&term), testEntry(&vault, "root"), 1000);
    defer std.testing.allocator.free(out);

    try std.testing.expect(TestApproval.asked);
    try std.testing.expectEqualStrings("root", TestApproval.asked_command[0..TestApproval.asked_len]);
    const reason = TestApproval.asked_reason[0..TestApproval.asked_reason_len];
    try std.testing.expect(std.mem.indexOf(u8, reason, "\"lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reason, "s3cret") == null);
    try std.testing.expectEqualStrings("s3cret-pw\r", term.written());
    try std.testing.expect(std.mem.indexOf(u8, out, "s3cret") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "username[root]=admin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[sudo] password for admin: " ++ redact.MASK) != null);

    // Later tool output in the conversation is masked too.
    const later = try filter.redactAlloc(std.testing.allocator, "history: echo s3cret-pw");
    defer std.testing.allocator.free(later);
    try std.testing.expectEqualStrings("history: echo " ++ redact.MASK, later);
}

test "password_input refuses to type at a shell prompt" {
    var vault = try testVault();
    defer vault.deinit();
    var ctx = testCtx(.full, null);
    var term = TestHost{ .screens = &.{"admin@lab:~/password-notes$ "} };
    const out = try typeAtPrompt(&ctx, term.host(), testSurface(&term), testEntry(&vault, "root"), 1000);
    defer std.testing.allocator.free(out);
    try std.testing.expect(!TestApproval.asked);
    try std.testing.expectEqual(@as(usize, 0), term.writes_len);
    try std.testing.expect(std.mem.startsWith(u8, out, "Nothing typed"));
}

test "password_input re-checks the prompt after approval" {
    var vault = try testVault();
    defer vault.deinit();
    var ctx = testCtx(.full, null);
    // sudo gave up while the approval was pending; the shell prompt is back.
    var term = TestHost{ .screens = &.{ "Password:", "sudo: timed out reading password\n$ " } };
    const out = try typeAtPrompt(&ctx, term.host(), testSurface(&term), testEntry(&vault, "root"), 1000);
    defer std.testing.allocator.free(out);
    try std.testing.expect(TestApproval.asked);
    try std.testing.expectEqual(@as(usize, 0), term.writes_len);
    try std.testing.expect(std.mem.startsWith(u8, out, "Nothing typed"));
}

test "password_input denial types nothing" {
    var vault = try testVault();
    defer vault.deinit();
    var ctx = testCtx(.confirm, null);
    TestApproval.allow = false;
    var term = TestHost{ .screens = &.{"Enter password:"} };
    const out = try typeAtPrompt(&ctx, term.host(), testSurface(&term), testEntry(&vault, "root"), 1000);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), term.writes_len);
    try std.testing.expect(std.mem.indexOf(u8, out, "declined") != null);
}

test "password_input refuses agent-off and empty entries before any prompt" {
    var vault = try testVault();
    defer vault.deinit();
    const off = try pick(std.testing.allocator, vault.entries.items, "bank");
    defer std.testing.allocator.free(off.message);
    try std.testing.expect(std.mem.indexOf(u8, off.message, "does not let the agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, off.message, "never") == null);
    const empty = try pick(std.testing.allocator, vault.entries.items, "empty");
    defer std.testing.allocator.free(empty.message);
    try std.testing.expect(std.mem.indexOf(u8, empty.message, "no password set") != null);
}

test "password_input unknown or missing name lists agent entries without secrets" {
    var vault = try testVault();
    defer vault.deinit();
    const unknown = try pick(std.testing.allocator, vault.entries.items, "pg");
    defer std.testing.allocator.free(unknown.message);
    try std.testing.expect(std.mem.indexOf(u8, unknown.message, "Available names: root (user admin; lab sudo), mysql") != null);
    try std.testing.expect(std.mem.indexOf(u8, unknown.message, "bank") == null);
    try std.testing.expect(std.mem.indexOf(u8, unknown.message, "s3cret") == null);
    const missing = try pick(std.testing.allocator, &.{}, null);
    defer std.testing.allocator.free(missing.message);
    try std.testing.expect(std.mem.indexOf(u8, missing.message, "No entry is available") != null);
    const found = try pick(std.testing.allocator, vault.entries.items, "ROOT");
    try std.testing.expectEqualStrings("root", found.entry.name);
}

test "looksLikePasswordPrompt accepts password prompts and rejects shell prompts" {
    const prompts = [_][]const u8{
        "[sudo] password for xzg:",
        "Password:",
        "Password: ",
        "admin@10.0.0.2's password:",
        "Enter password:",
        "Password for user postgres:",
        "Enter passphrase for key '/home/x/.ssh/id_ed25519':",
        "Enter PEM pass phrase:",
        "[sudo] xzg 的密码：",
        "Passwort:",
    };
    for (prompts) |line| try std.testing.expect(looksLikePasswordPrompt(line));
    const not_prompts = [_][]const u8{
        "",
        "$ ",
        "admin@lab:~/password$",
        "root@lab:/srv/passwords#",
        "mysql>",
        "Sorry, try again.",
        "Login:",
        ">>> password = input()",
    };
    for (not_prompts) |line| try std.testing.expect(!looksLikePasswordPrompt(line));
}
