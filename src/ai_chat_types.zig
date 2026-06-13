//! Shared tool-related types for the AI chat module: surfaces, snapshots, the
//! tool host vtable, agent settings, and the ToolContext seam handed to the
//! (leaf) tool layer so it never touches Session. No Session/ChatRequest deps.
const std = @import("std");
const weixin_types = @import("weixin/types.zig");
const agent_detector = @import("agent_detector.zig");
const ai_agent_access = @import("ai_agent_access.zig");
const ssh_connection = @import("ssh_connection.zig");
pub const SshConnection = ssh_connection.SshConnection;

const DEFAULT_AGENT_TIMEOUT_MS: u32 = 60_000;
const DEFAULT_AGENT_OUTPUT_LIMIT: u32 = 16 * 1024;

pub const AgentSettings = struct {
    enabled: bool = false,
    permission: AgentPermission = .confirm,
    command_timeout_ms: u32 = DEFAULT_AGENT_TIMEOUT_MS,
    output_limit: u32 = DEFAULT_AGENT_OUTPUT_LIMIT,
    /// Private file-access rules (owned by the app layer; null = guard inactive).
    access_rules: ?*const ai_agent_access.AccessRules = null,
    /// Effective working directory for the conversation (borrowed; null = unset).
    /// When set, the local command tool defaults its cwd here and commands
    /// confined to it skip the approval prompt (the sandbox).
    working_dir: ?[]const u8 = null,
    /// Master switch for the Copilot long-term memory system (config
    /// `ai-memory-enabled`). Gates index injection and memory tool advertisement.
    memory_enabled: bool = false,
    /// When true, the Copilot may append a "distill this into a skill?" prompt
    /// after tool-heavy turns (config `ai-distill-suggest`). Off by default.
    distill_suggest_enabled: bool = false,
};

// AgentPermission lives in ai_agent_config.zig (extracted on main so config.zig
// stays out of the ai_chat dependency graph). Re-export the single source of truth.
pub const AgentPermission = @import("ai_agent_config.zig").AgentPermission;

pub const ToolSurface = struct {
    id: []u8,
    title: []u8,
    cwd: []u8,
    snapshot: []u8,
    tab_index: usize,
    focused: bool,
    is_ssh: bool,
    is_wsl: bool,
    agent_app: agent_detector.App = .none,
    agent_state: agent_detector.State = .none,
    agent_confidence: u8 = 0,
    ptr: *anyopaque,

    pub fn deinit(self: ToolSurface, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.cwd);
        allocator.free(self.snapshot);
    }

    pub const InitMeta = struct {
        tab_index: usize,
        focused: bool,
        is_ssh: bool,
        is_wsl: bool,
        agent_app: agent_detector.App = .none,
        agent_state: agent_detector.State = .none,
        agent_confidence: u8 = 0,
        ptr: *anyopaque,
    };

    /// Build an owned ToolSurface from borrowed strings plus an already-owned
    /// snapshot. Takes ownership of `snapshot` even on failure, so a caller
    /// can pass a freshly built snapshot without its own cleanup path.
    pub fn initOwned(
        allocator: std.mem.Allocator,
        id: []const u8,
        title: []const u8,
        cwd: []const u8,
        snapshot: []u8,
        meta: InitMeta,
    ) !ToolSurface {
        errdefer allocator.free(snapshot);
        const id_owned = try allocator.dupe(u8, id);
        errdefer allocator.free(id_owned);
        const title_owned = try allocator.dupe(u8, title);
        errdefer allocator.free(title_owned);
        const cwd_owned = try allocator.dupe(u8, cwd);
        return .{
            .id = id_owned,
            .title = title_owned,
            .cwd = cwd_owned,
            .snapshot = snapshot,
            .tab_index = meta.tab_index,
            .focused = meta.focused,
            .is_ssh = meta.is_ssh,
            .is_wsl = meta.is_wsl,
            .agent_app = meta.agent_app,
            .agent_state = meta.agent_state,
            .agent_confidence = meta.agent_confidence,
            .ptr = meta.ptr,
        };
    }

    pub fn clone(self: ToolSurface, allocator: std.mem.Allocator) !ToolSurface {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        const title = try allocator.dupe(u8, self.title);
        errdefer allocator.free(title);
        const cwd = try allocator.dupe(u8, self.cwd);
        errdefer allocator.free(cwd);
        const snapshot = try allocator.dupe(u8, self.snapshot);
        errdefer allocator.free(snapshot);
        return .{
            .id = id,
            .title = title,
            .cwd = cwd,
            .snapshot = snapshot,
            .tab_index = self.tab_index,
            .focused = self.focused,
            .is_ssh = self.is_ssh,
            .is_wsl = self.is_wsl,
            .agent_app = self.agent_app,
            .agent_state = self.agent_state,
            .agent_confidence = self.agent_confidence,
            .ptr = self.ptr,
        };
    }
};

pub const ToolSnapshot = struct {
    surfaces: []ToolSurface,
    active_tab: usize,

    pub fn deinit(self: ToolSnapshot, allocator: std.mem.Allocator) void {
        for (self.surfaces) |surface| surface.deinit(allocator);
        allocator.free(self.surfaces);
    }

    pub fn clone(self: ToolSnapshot, allocator: std.mem.Allocator) !ToolSnapshot {
        const surfaces = try allocator.alloc(ToolSurface, self.surfaces.len);
        errdefer allocator.free(surfaces);
        var written: usize = 0;
        errdefer {
            for (surfaces[0..written]) |surface| surface.deinit(allocator);
        }
        for (self.surfaces) |surface| {
            surfaces[written] = try surface.clone(allocator);
            written += 1;
        }
        return .{
            .surfaces = surfaces,
            .active_tab = self.active_tab,
        };
    }
};

pub const ToolClosedTab = struct {
    tab_index: usize,
    active_tab: usize,
    title: []u8,

    pub fn deinit(self: ToolClosedTab, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
    }
};

pub const SshProfileSaveArgs = struct {
    name: []const u8 = "",
    host: []const u8,
    user: []const u8,
    password: []const u8 = "",
    port: []const u8 = "",
    proxy_jump: []const u8 = "",
};

pub const SavedSshProfile = struct {
    name: []u8,
    host: []u8,
    user: []u8,
    port: []u8,
    updated_existing: bool,
    password_saved: bool,

    pub fn deinit(self: SavedSshProfile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.host);
        allocator.free(self.user);
        allocator.free(self.port);
    }
};

pub const ToolHost = struct {
    ctx: *anyopaque,
    collectSnapshot: *const fn (*anyopaque, std.mem.Allocator) anyerror!ToolSnapshot,
    surfaceSnapshot: *const fn (*anyopaque, std.mem.Allocator, []const u8, *anyopaque) anyerror![]u8,
    writeSurface: *const fn (*anyopaque, []const u8, *anyopaque, []const u8) bool,
    spawnTab: *const fn (*anyopaque, std.mem.Allocator, []const u8, ?[]const u8) anyerror!ToolSurface,
    closeTab: *const fn (*anyopaque, std.mem.Allocator, ?usize, ?[]const u8, ?[]const u8) anyerror!ToolClosedTab,
    saveSshProfile: *const fn (*anyopaque, std.mem.Allocator, SshProfileSaveArgs) anyerror!SavedSshProfile,
    connectSshProfile: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!ToolSurface,
    /// Resolve `surface_id` to its SSH connection for out-of-band file IO, or
    /// null for local/WSL/unknown surfaces. Only the real AppWindow host sets
    /// this; others leave it null (file tools then treat the target as local).
    sshConnectionForSurface: ?*const fn (*anyopaque, []const u8) ?SshConnection = null,
};

pub const WeixinReplyContext = struct {
    sender: weixin_types.AttachmentSender,
    to_user_id: []u8,
    context_token: []u8,
    model_context: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, ctx: weixin_types.ReplyContext) !WeixinReplyContext {
        var out = WeixinReplyContext{
            .sender = ctx.sender,
            .to_user_id = try allocator.dupe(u8, ctx.to_user_id),
            .context_token = &.{},
        };
        errdefer allocator.free(out.to_user_id);
        out.context_token = try allocator.dupe(u8, ctx.context_token);
        errdefer allocator.free(out.context_token);
        out.model_context = if (ctx.model_context.len != 0) try allocator.dupe(u8, ctx.model_context) else &.{};
        return out;
    }

    pub fn clone(self: WeixinReplyContext, allocator: std.mem.Allocator) !WeixinReplyContext {
        var out = WeixinReplyContext{
            .sender = self.sender,
            .to_user_id = try allocator.dupe(u8, self.to_user_id),
            .context_token = &.{},
        };
        errdefer allocator.free(out.to_user_id);
        out.context_token = try allocator.dupe(u8, self.context_token);
        errdefer allocator.free(out.context_token);
        out.model_context = if (self.model_context.len != 0) try allocator.dupe(u8, self.model_context) else &.{};
        return out;
    }

    pub fn deinit(self: *WeixinReplyContext, allocator: std.mem.Allocator) void {
        allocator.free(self.to_user_id);
        allocator.free(self.context_token);
        if (self.model_context.len != 0) allocator.free(self.model_context);
        self.* = undefined;
    }
};

pub const ApprovalView = struct {
    tool: []const u8,
    command: []const u8,
    reason: []const u8,
};

fn noopNote(_: *anyopaque, _: []const u8) void {}

/// Narrow context handed to the tool layer so it never touches `Session`.
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    ctx: *anyopaque, // opaque Session; only the callbacks below dereference it
    tool_host: ?ToolHost,
    tool_snapshot: ?ToolSnapshot,
    settings: AgentSettings,
    copilot: bool = false,
    weixin_reply_context: ?WeixinReplyContext = null,
    write_context_surface_id: [64]u8 = undefined,
    write_context_surface_id_len: usize = 0,

    approve: *const fn (ctx: *anyopaque, tool: []const u8, command: []const u8, reason: []const u8) bool,
    cancelled: *const fn (ctx: *anyopaque) bool,
    /// Post a transcript note (e.g. a diff) before an approval prompt. Defaults
    /// to a no-op so test contexts need not wire it.
    note: *const fn (ctx: *anyopaque, text: []const u8) void = noopNote,

    pub fn requestApproval(self: *const ToolContext, tool: []const u8, command: []const u8, reason: []const u8) bool {
        return self.approve(self.ctx, tool, command, reason);
    }
    pub fn isCancelled(self: *const ToolContext) bool {
        return self.cancelled(self.ctx);
    }
    pub fn writeContextSurfaceId(self: *const ToolContext) ?[]const u8 {
        if (self.write_context_surface_id_len == 0) return null;
        return self.write_context_surface_id[0..self.write_context_surface_id_len];
    }
    pub fn emitNote(self: *const ToolContext, text: []const u8) void {
        self.note(self.ctx, text);
    }
    pub fn sshConnectionForSurface(self: *const ToolContext, surface_id: []const u8) ?SshConnection {
        const host = self.tool_host orelse return null;
        const resolver = host.sshConnectionForSurface orelse return null;
        return resolver(host.ctx, surface_id);
    }
};

test "ToolSurface.initOwned dupes borrowed strings and adopts the owned snapshot" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    const snapshot = try a.dupe(u8, "snap");
    const id_src = "surface-1";
    const ts = try ToolSurface.initOwned(a, id_src, "title-1", "/work", snapshot, .{
        .tab_index = 3,
        .focused = true,
        .is_ssh = false,
        .is_wsl = true,
        .ptr = @ptrCast(&dummy),
    });
    defer ts.deinit(a);

    try std.testing.expectEqualStrings("surface-1", ts.id);
    try std.testing.expect(ts.id.ptr != id_src.ptr); // copied, not aliased
    try std.testing.expectEqualStrings("title-1", ts.title);
    try std.testing.expectEqualStrings("/work", ts.cwd);
    try std.testing.expect(ts.snapshot.ptr == snapshot.ptr); // ownership moved, no copy
    try std.testing.expectEqual(@as(usize, 3), ts.tab_index);
    try std.testing.expect(ts.focused);
    try std.testing.expect(ts.is_wsl);
}

test "ToolSurface.initOwned frees the snapshot and earlier dupes when an allocation fails" {
    // Fail each of the three dupes in turn. The adopted snapshot comes from
    // the leak-checking testing allocator, so any path that drops it (or an
    // earlier dupe) fails the test at the end-of-test leak check.
    var dummy: u8 = 0;
    var fail_index: usize = 0;
    while (fail_index < 3) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const snapshot = try std.testing.allocator.dupe(u8, "snap");
        try std.testing.expectError(error.OutOfMemory, ToolSurface.initOwned(
            failing.allocator(),
            "surface-1",
            "title-1",
            "/work",
            snapshot,
            .{
                .tab_index = 0,
                .focused = false,
                .is_ssh = false,
                .is_wsl = false,
                .ptr = @ptrCast(&dummy),
            },
        ));
    }
}
