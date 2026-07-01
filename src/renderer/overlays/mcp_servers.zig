//! In-app "MCP Servers" config panel: overlay state that loads configured
//! servers from disk into a fixed-size, heap-free struct. Mirrors
//! ssh_profiles.zig conventions (fixed arrays, fixed char buffers with a
//! `_len`, no heap allocation stored on the struct — this lives inside the
//! multi-MB OverlayState).
const std = @import("std");
const mcp_registry = @import("../../tools/mcp_registry.zig");
const mcp_probe = @import("../../assistant/mcp_probe.zig");

pub const MCP_SERVER_MAX = 32;
pub const FIELD_MAX = 512;

/// One server row as displayed in the panel. `args` is the arg list joined
/// by single spaces (display-only — mcp_registry.ServerConfig owns the real
/// `[][]u8`).
pub const Server = struct {
    name: [FIELD_MAX]u8 = undefined,
    name_len: usize = 0,
    command: [FIELD_MAX]u8 = undefined,
    command_len: usize = 0,
    args: [FIELD_MAX]u8 = undefined,
    args_len: usize = 0,
    enabled: bool = true,
};

pub const View = enum { list, form, json_preview };

/// Form field identifiers, indexed into `State.form_bufs`/`form_lens`.
pub const Field = enum { name, command, args };
const FORM_FIELD_COUNT = @typeInfo(Field).@"enum".fields.len;

pub const FormError = error{ EmptyName, DuplicateName, EmptyCommand, Full };

/// Sentinel for `editing_index`: no server is being edited (an add, not
/// an edit).
pub const EDIT_INDEX_NONE: usize = std.math.maxInt(usize);

pub const ProbeStatus = enum { idle, running, ok, failed };

/// Holds the outcome of the "Test" probe against `servers[target_index]`.
/// Mirrors `mcp_probe.Result`'s fixed buffers (message/tools are plain
/// values, not owned pointers) so `applyProbeResult` can copy one in without
/// touching the heap. The probe thread itself (Task 10) lives in the input
/// handler; this struct only holds + applies the result it hands back.
pub const ProbeState = struct {
    status: ProbeStatus = .idle,
    target_index: usize = 0,
    message: [256]u8 = undefined,
    message_len: usize = 0,
    tools: [24][64]u8 = undefined,
    tool_count: usize = 0,
};

pub const State = struct {
    visible: bool = false,
    view: View = .list,
    servers: [MCP_SERVER_MAX]Server = undefined,
    count: usize = 0,
    list_selected: usize = 0,
    form_bufs: [FORM_FIELD_COUNT][FIELD_MAX]u8 = undefined,
    form_lens: [FORM_FIELD_COUNT]usize = .{0} ** FORM_FIELD_COUNT,
    editing_index: usize = EDIT_INDEX_NONE,
    /// Set by `save` on success; the caller (input handler) reads and clears
    /// this to show a one-shot "Saved" confirmation.
    saved: bool = false,
    /// Result of the last "Test" probe, applied via `applyProbeResult`.
    probe: ProbeState = .{},

    /// Reset to defaults and load `<config-dir>/mcp.json` into `servers`.
    /// A missing/unreadable config file yields zero servers (not an error).
    pub fn open(self: *State, allocator: std.mem.Allocator) void {
        self.* = .{ .visible = true };
        const loaded = mcp_registry.loadConfigFile(allocator) catch return;
        defer mcp_registry.freeServersConfig(allocator, loaded);
        for (loaded) |cfg| {
            if (self.count >= MCP_SERVER_MAX) break;
            var s = Server{ .enabled = cfg.enabled };
            setBuf(&s.name, &s.name_len, cfg.name);
            setBuf(&s.command, &s.command_len, cfg.command);
            var joined: [FIELD_MAX]u8 = undefined;
            var n: usize = 0;
            for (cfg.args, 0..) |arg, i| {
                if (i != 0 and n < FIELD_MAX) {
                    joined[n] = ' ';
                    n += 1;
                }
                const take = @min(arg.len, FIELD_MAX - n);
                @memcpy(joined[n..][0..take], arg[0..take]);
                n += take;
            }
            setBuf(&s.args, &s.args_len, joined[0..n]);
            self.servers[self.count] = s;
            self.count += 1;
        }
    }

    /// Move the list selection by `delta`, clamped to `[0, count-1]`.
    pub fn moveSelection(self: *State, delta: i32) void {
        if (self.count == 0) return;
        const cur: i32 = @intCast(self.list_selected);
        const max: i32 = @intCast(self.count - 1);
        self.list_selected = @intCast(std.math.clamp(cur + delta, 0, max));
    }

    pub fn serverName(self: *const State, i: usize) []const u8 {
        return self.servers[i].name[0..self.servers[i].name_len];
    }

    pub fn serverArgs(self: *const State, i: usize) []const u8 {
        return self.servers[i].args[0..self.servers[i].args_len];
    }

    pub fn formField(self: *const State, field: Field) []const u8 {
        const idx = @intFromEnum(field);
        return self.form_bufs[idx][0..self.form_lens[idx]];
    }

    pub fn setFormField(self: *State, field: Field, value: []const u8) void {
        const idx = @intFromEnum(field);
        setBuf(&self.form_bufs[idx], &self.form_lens[idx], value);
    }

    /// Clear the form and switch to it, ready to add a new server.
    pub fn beginAdd(self: *State) void {
        self.form_lens = .{0} ** FORM_FIELD_COUNT;
        self.editing_index = EDIT_INDEX_NONE;
        self.view = .form;
    }

    /// Populate the form from `servers[index]` and switch to it.
    pub fn beginEdit(self: *State, index: usize) void {
        self.setFormField(.name, self.serverName(index));
        self.setFormField(.command, self.servers[index].command[0..self.servers[index].command_len]);
        self.setFormField(.args, self.serverArgs(index));
        self.editing_index = index;
        self.view = .form;
    }

    /// Validate the form (non-empty unique name, non-empty command) and
    /// write it into `servers`: appends when adding, overwrites in place
    /// when `editing_index` was set by `beginEdit`. The duplicate-name
    /// check skips `editing_index` so editing a server keeps its own name.
    /// `enabled` is not a form field: editing a server preserves its
    /// existing `enabled` value, and adding one defaults it to `true`.
    /// Adding past `MCP_SERVER_MAX` returns `error.Full` instead of
    /// overflowing `servers`.
    pub fn commitForm(self: *State) FormError!void {
        const name = self.formField(.name);
        if (name.len == 0) return error.EmptyName;
        const command = self.formField(.command);
        if (command.len == 0) return error.EmptyCommand;
        for (0..self.count) |i| {
            if (i == self.editing_index) continue;
            if (std.mem.eql(u8, self.serverName(i), name)) return error.DuplicateName;
        }

        const target: *Server = if (self.editing_index != EDIT_INDEX_NONE)
            &self.servers[self.editing_index]
        else blk: {
            if (self.count >= MCP_SERVER_MAX) return error.Full;
            self.count += 1;
            self.servers[self.count - 1] = .{};
            break :blk &self.servers[self.count - 1];
        };
        setBuf(&target.name, &target.name_len, name);
        setBuf(&target.command, &target.command_len, command);
        setBuf(&target.args, &target.args_len, self.formField(.args));
    }

    /// Remove `servers[list_selected]`, shifting later entries down.
    pub fn removeSelected(self: *State) void {
        if (self.list_selected >= self.count) return;
        for (self.list_selected..self.count - 1) |i| {
            self.servers[i] = self.servers[i + 1];
        }
        self.count -= 1;
        if (self.list_selected >= self.count and self.count > 0) {
            self.list_selected = self.count - 1;
        }
    }

    /// Flip `enabled` on `servers[list_selected]`.
    pub fn toggleSelected(self: *State) void {
        if (self.list_selected >= self.count) return;
        self.servers[self.list_selected].enabled = !self.servers[self.list_selected].enabled;
    }

    /// Copy a completed `mcp_probe.probeBlocking`/`start` result into
    /// `self.probe`, tagging it with the `servers[index]` it belongs to.
    /// `r` is a plain value (no owned heap memory), so this is a straight
    /// field copy — heap-free like the rest of `State`.
    pub fn applyProbeResult(self: *State, index: usize, r: mcp_probe.Result) void {
        self.probe.target_index = index;
        self.probe.message = r.message;
        self.probe.message_len = r.message_len;
        self.probe.tools = r.tools;
        self.probe.tool_count = r.tool_count;
        self.probe.status = if (r.ok) .ok else .failed;
    }

    /// Build an owned `[]mcp_registry.ServerConfig` from `servers[0..count]`.
    /// Each server's `args` display string is split on whitespace runs.
    /// Caller frees with `mcp_registry.freeServersConfig`.
    pub fn toServerConfigs(self: *const State, allocator: std.mem.Allocator) ![]mcp_registry.ServerConfig {
        var list: std.ArrayListUnmanaged(mcp_registry.ServerConfig) = .empty;
        errdefer {
            for (list.items) |cfg| {
                allocator.free(cfg.name);
                allocator.free(cfg.command);
                for (cfg.args) |arg| allocator.free(arg);
                allocator.free(cfg.args);
            }
            list.deinit(allocator);
        }

        for (0..self.count) |i| {
            const name = try allocator.dupe(u8, self.serverName(i));
            errdefer allocator.free(name);
            const command = try allocator.dupe(u8, self.servers[i].command[0..self.servers[i].command_len]);
            errdefer allocator.free(command);

            var args: std.ArrayListUnmanaged([]u8) = .empty;
            errdefer {
                for (args.items) |arg| allocator.free(arg);
                args.deinit(allocator);
            }
            var it = std.mem.tokenizeAny(u8, self.serverArgs(i), " \t");
            while (it.next()) |tok| {
                try args.append(allocator, try allocator.dupe(u8, tok));
            }
            const args_owned = try args.toOwnedSlice(allocator);
            errdefer allocator.free(args_owned);

            try list.append(allocator, .{
                .name = name,
                .command = command,
                .args = args_owned,
                .enabled = self.servers[i].enabled,
            });
        }
        return list.toOwnedSlice(allocator);
    }

    /// Read-only JSON preview of what `save` would write.
    pub fn jsonPreview(self: *const State, allocator: std.mem.Allocator) ![]u8 {
        const cfgs = try self.toServerConfigs(allocator);
        defer mcp_registry.freeServersConfig(allocator, cfgs);
        return mcp_registry.writeServersConfig(allocator, cfgs);
    }

    /// Write `servers[0..count]` to `<config-dir>/mcp.json` and mark `saved`.
    /// The caller is responsible for triggering an MCP tools reload.
    pub fn save(self: *State, allocator: std.mem.Allocator) !void {
        const cfgs = try self.toServerConfigs(allocator);
        defer mcp_registry.freeServersConfig(allocator, cfgs);
        try mcp_registry.saveConfigFile(allocator, cfgs);
        self.saved = true;
    }
};

/// Truncate-copy `src` into `buf`, recording the copied length in `len_ptr`.
fn setBuf(buf: []u8, len_ptr: *usize, src: []const u8) void {
    const len = @min(src.len, buf.len);
    @memcpy(buf[0..len], src[0..len]);
    len_ptr.* = len;
}

test "add a server through the form" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "gh");
    s.setFormField(.command, "github-mcp");
    s.setFormField(.args, "stdio --verbose");
    try s.commitForm();
    try std.testing.expectEqual(@as(usize, 1), s.count);
    try std.testing.expectEqualStrings("gh", s.serverName(0));
    try std.testing.expectEqualStrings("stdio --verbose", s.serverArgs(0));
    try std.testing.expect(s.servers[0].enabled);
}

test "form rejects empty name, empty command, and duplicate name" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.command, "x");
    try std.testing.expectError(error.EmptyName, s.commitForm());
    s.setFormField(.name, "a");
    s.setFormField(.command, "");
    try std.testing.expectError(error.EmptyCommand, s.commitForm());
    s.setFormField(.command, "x");
    try s.commitForm(); // "a" added
    s.beginAdd();
    s.setFormField(.name, "a");
    s.setFormField(.command, "y");
    try std.testing.expectError(error.DuplicateName, s.commitForm());
}

test "toggle and remove the selected server" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "a");
    s.setFormField(.command, "x");
    try s.commitForm();
    s.list_selected = 0;
    s.toggleSelected();
    try std.testing.expect(!s.servers[0].enabled);
    s.removeSelected();
    try std.testing.expectEqual(@as(usize, 0), s.count);
}

test "open loads servers from the config dir and clamps selection" {
    const mcp_registry_dirs = @import("../../platform/dirs.zig");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    mcp_registry_dirs.setTestConfigDirOverride(dir_path);
    defer mcp_registry_dirs.setTestConfigDirOverride(null);
    const servers = [_]mcp_registry.ServerConfig{
        .{ .name = @constCast("a"), .command = @constCast("x"), .args = &.{}, .enabled = true },
        .{ .name = @constCast("b"), .command = @constCast("y"), .args = &.{}, .enabled = false },
    };
    try mcp_registry.saveConfigFile(a, servers[0..]);

    var state: State = .{};
    state.open(a);
    try std.testing.expect(state.visible);
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expectEqualStrings("a", state.serverName(0));
    try std.testing.expect(!state.servers[1].enabled);

    state.list_selected = 0;
    state.moveSelection(-1); // clamps at 0
    try std.testing.expectEqual(@as(usize, 0), state.list_selected);
    state.moveSelection(5); // clamps at count-1
    try std.testing.expectEqual(@as(usize, 1), state.list_selected);
}

test "edit preserves enabled state of a disabled server" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "a");
    s.setFormField(.command, "x");
    try s.commitForm();
    s.list_selected = 0;
    s.toggleSelected();
    try std.testing.expect(!s.servers[0].enabled);

    s.beginEdit(0);
    s.setFormField(.command, "y");
    try s.commitForm();
    try std.testing.expect(!s.servers[0].enabled);
}

test "jsonPreview equals what save writes, and splits args" {
    const a = std.testing.allocator;
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "c");
    s.setFormField(.command, "npx");
    s.setFormField(.args, "-y  pkg");
    try s.commitForm(); // double space → 2 args

    const cfgs = try s.toServerConfigs(a);
    defer mcp_registry.freeServersConfig(a, cfgs);
    try std.testing.expectEqual(@as(usize, 1), cfgs.len);
    try std.testing.expectEqual(@as(usize, 2), cfgs[0].args.len);
    try std.testing.expectEqualStrings("pkg", cfgs[0].args[1]);

    const preview = try s.jsonPreview(a);
    defer a.free(preview);
    try std.testing.expect(std.mem.indexOf(u8, preview, "\"c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "\"npx\"") != null);
}

test "applyProbeResult stores tool names and status on the state" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "x");
    s.setFormField(.command, "/bin/sh");
    try s.commitForm();
    var r = mcp_probe.Result{ .ok = true, .message = undefined, .message_len = 0, .tools = undefined, .tool_count = 1 };
    @memcpy(r.tools[0][0..4], "echo");
    s.applyProbeResult(0, r);
    try std.testing.expect(s.probe.status == .ok);
    try std.testing.expectEqual(@as(usize, 1), s.probe.tool_count);
}

test "commitForm rejects a 33rd server" {
    var s: State = .{};
    var i: usize = 0;
    while (i < MCP_SERVER_MAX) : (i += 1) {
        s.beginAdd();
        var name_buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "s{d}", .{i}) catch unreachable;
        s.setFormField(.name, name);
        s.setFormField(.command, "x");
        try s.commitForm();
    }
    try std.testing.expectEqual(@as(usize, MCP_SERVER_MAX), s.count);

    s.beginAdd();
    s.setFormField(.name, "overflow");
    s.setFormField(.command, "x");
    try std.testing.expectError(error.Full, s.commitForm());
    try std.testing.expectEqual(@as(usize, MCP_SERVER_MAX), s.count);
}
