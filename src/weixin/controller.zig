//! Owns the WeChat direct lifecycle: persisted binding, the ilink client, and
//! the background poller. Built by App with a live Control. This module is
//! platform-neutral (no GUI deps) so it compiles and is checkable off-Windows;
//! the GUI parts live in App/AppWindow and the QR panel.
const std = @import("std");
const types = @import("types.zig");
const state_store = @import("state_store.zig");
const ilink = @import("ilink_client.zig");
const poller = @import("poller.zig");
const control_mod = @import("control.zig");

const log = std.log.scoped(.weixin);

const SHUTDOWN_JOIN_TIMEOUT_MS: u32 = 1500;
const NOTIFY_TEXT_MAX: usize = 2000;
pub const ThreadControl = poller.ThreadControl;

pub const Controller = struct {
    allocator: std.mem.Allocator,
    state_path: []u8,
    control: control_mod.Control,
    settings: types.Settings,

    // Heap-owned copies of the active binding. Empty slices mean "unset".
    token: []u8 = &.{},
    base_url: []u8 = &.{},
    owner: []u8 = &.{},
    bot_id: []u8 = &.{},

    // Live while running. `client` must outlive `poll` (poll holds a ClientApi
    // pointing at it); both are fields of this heap object so addresses are stable.
    client: ilink.Client = undefined,
    poll: poller.Poller = undefined,
    running: bool = false,

    // QR login, driven by a background thread (network calls must not block the
    // UI thread). A panel reads loginSnapshot() to render.
    login_thread: ?std.Thread = null,
    login_mutex: std.Thread.Mutex = .{},
    login_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    login_status: types.QrStatusKind = .unknown,
    login_qr_arena: ?std.heap.ArenaAllocator = null,
    login_qr_string: []const u8 = "",
    login_qr_content: []const u8 = "",

    pub fn create(
        allocator: std.mem.Allocator,
        state_path: []const u8,
        control: control_mod.Control,
        settings: types.Settings,
    ) !*Controller {
        const self = try allocator.create(Controller);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .state_path = try allocator.dupe(u8, state_path),
            .control = control,
            .settings = settings,
        };
        return self;
    }

    pub fn destroy(self: *Controller) void {
        self.cancelLogin();
        if (self.login_thread) |th| {
            th.join();
            self.login_thread = null;
        }
        if (self.login_qr_arena) |*a| a.deinit();
        self.stop();
        self.clearBinding();
        self.allocator.free(self.state_path);
        self.allocator.destroy(self);
    }

    /// Process-exit variant: do not block forever on iLink long-poll/login HTTP
    /// calls. If a worker cannot be joined promptly, it is detached and this
    /// Controller intentionally remains allocated until the process exits.
    pub fn destroyForProcessExit(self: *Controller, thread_control: ThreadControl) bool {
        self.cancelLogin();
        if (!self.joinLoginThreadForProcessExit(thread_control)) return false;
        if (!self.stopForProcessExit(thread_control)) return false;

        if (self.login_qr_arena) |*a| a.deinit();
        self.clearBinding();
        self.allocator.free(self.state_path);
        self.allocator.destroy(self);
        return true;
    }

    /// Starts QR login on a background thread (idempotent). A panel polls
    /// loginSnapshot() for the QR + status; on confirmation the binding is
    /// persisted and polling starts automatically.
    pub fn startLoginAsync(self: *Controller) !void {
        if (self.login_active.swap(true, .acq_rel)) return; // already running
        if (self.login_thread) |th| {
            th.join();
            self.login_thread = null;
        }
        self.resetLoginSnapshot(.wait);
        self.login_thread = std.Thread.spawn(.{}, loginThreadMain, .{self}) catch |err| {
            self.login_active.store(false, .release);
            return err;
        };
        log.info("QR login started", .{});
    }

    pub fn cancelLogin(self: *Controller) void {
        self.login_active.store(false, .release);
        self.resetLoginSnapshot(.unknown);
    }

    pub const LoginSnapshot = struct {
        status: types.QrStatusKind,
        qr_string: []const u8,
        qr_content: []const u8,
    };

    pub const Status = struct {
        running: bool,
        has_token: bool,
        has_owner: bool,
        has_bot_id: bool,
        login_active: bool,
        login_status: types.QrStatusKind,
    };

    pub fn statusSnapshot(self: *Controller) Status {
        const login_active = self.login_active.load(.acquire);
        self.login_mutex.lock();
        const login_status = self.login_status;
        self.login_mutex.unlock();
        const poller_active = self.running and !self.poll.stop_requested.load(.acquire);

        return .{
            .running = poller_active,
            .has_token = self.token.len != 0,
            .has_owner = self.owner.len != 0,
            .has_bot_id = self.bot_id.len != 0,
            .login_active = login_active,
            .login_status = login_status,
        };
    }

    /// Thread-safe snapshot for a UI panel. Returned strings are copied into `arena`.
    pub fn loginSnapshot(self: *Controller, arena: std.mem.Allocator) !LoginSnapshot {
        self.login_mutex.lock();
        defer self.login_mutex.unlock();
        return .{
            .status = self.login_status,
            .qr_string = try arena.dupe(u8, self.login_qr_string),
            .qr_content = try arena.dupe(u8, self.login_qr_content),
        };
    }

    fn loginThreadMain(self: *Controller) void {
        log.info("login: thread start", .{});
        var qr_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer qr_arena.deinit();
        const qr = self.beginLogin(qr_arena.allocator()) catch |err| {
            log.warn("login: beginLogin failed: {}", .{err});
            self.setLoginStatus(.expired);
            self.login_active.store(false, .release);
            return;
        };
        if (!self.login_active.load(.acquire)) return;
        self.setLoginQr(qr.qrcode, qr.qrcode_img_content);

        while (self.login_active.load(.acquire)) {
            var poll_arena = std.heap.ArenaAllocator.init(self.allocator);
            const status = self.pollLogin(poll_arena.allocator(), qr.qrcode) catch |err| {
                log.warn("login: pollLogin failed: {}", .{err});
                poll_arena.deinit();
                std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            };
            if (!self.login_active.load(.acquire)) {
                poll_arena.deinit();
                break;
            }
            self.setLoginStatus(status.status);
            if (status.status == .confirmed) {
                self.confirmLogin(status) catch |err| log.err("login: confirmLogin failed: {}", .{err}); // uses `status` before poll_arena frees
                poll_arena.deinit();
                break;
            }
            if (status.status == .expired) {
                poll_arena.deinit();
                break;
            }
            poll_arena.deinit();
            std.Thread.sleep(2 * std.time.ns_per_s);
        }
        self.login_active.store(false, .release);
    }

    fn setLoginQr(self: *Controller, qr_string: []const u8, qr_content: []const u8) void {
        self.login_mutex.lock();
        defer self.login_mutex.unlock();
        if (self.login_qr_arena) |*a| a.deinit();
        self.login_qr_arena = std.heap.ArenaAllocator.init(self.allocator);
        const a = self.login_qr_arena.?.allocator();
        self.login_qr_string = a.dupe(u8, qr_string) catch "";
        self.login_qr_content = a.dupe(u8, qr_content) catch "";
    }

    fn resetLoginSnapshot(self: *Controller, status: types.QrStatusKind) void {
        self.login_mutex.lock();
        defer self.login_mutex.unlock();
        if (self.login_qr_arena) |*a| a.deinit();
        self.login_qr_arena = null;
        self.login_qr_string = "";
        self.login_qr_content = "";
        self.login_status = status;
    }

    fn setLoginStatus(self: *Controller, status: types.QrStatusKind) void {
        self.login_mutex.lock();
        defer self.login_mutex.unlock();
        self.login_status = status;
    }

    /// Loads the persisted binding; if a token exists, starts polling.
    pub fn start(self: *Controller) !void {
        var loaded = try state_store.load(self.allocator, self.state_path);
        defer loaded.deinit(self.allocator);
        if (loaded.binding.bot_token.len == 0) return; // not logged in yet
        try self.startWithBinding(loaded.binding, .{
            .bootstrap_skip_pending = loaded.binding.sync_buf.len == 0,
        });
    }

    /// Stops the poller, persisting the latest sync cursor so the next start
    /// resumes where it left off.
    pub fn stop(self: *Controller) void {
        self.stopInternal(true);
    }

    fn stopInternal(self: *Controller, persist_sync: bool) void {
        if (!self.running) return;
        self.poll.stop();
        // Persist the advanced sync cursor (best-effort).
        if (persist_sync) self.persist(self.poll.sync_buf) catch {};
        self.allocator.free(self.poll.sync_buf);
        // ilink.Client holds no persistent resources (it opens a fresh
        // std.http.Client per request), so there is nothing to deinit here.
        self.running = false;
    }

    fn stopForProcessExit(self: *Controller, thread_control: ThreadControl) bool {
        if (!self.running) return true;
        if (!self.poll.stopForProcessExit(thread_control)) return false;

        // Persist the advanced sync cursor (best-effort).
        self.persist(self.poll.sync_buf) catch {};
        self.allocator.free(self.poll.sync_buf);
        self.running = false;
        return true;
    }

    /// Clears the persisted owner + token and stops. Used by "Unbind".
    pub fn unbind(self: *Controller) !void {
        self.cancelLogin();
        self.stop();
        self.clearBinding();
        try self.persistBinding(.{});
    }

    /// Forward one notification to the bound owner's WeChat. No-op unless a
    /// binding is live with a bound owner. The network send runs on a detached
    /// one-shot thread so this never blocks the caller (the UI thread).
    /// Best-effort: allocation/spawn/send failures only log.
    /// Reads the live binding fields (owner/token/base_url) without locking;
    /// safe because callers are on the UI thread and the only background mutator
    /// is the one-time QR login.
    pub fn enqueueNotify(self: *Controller, title: []const u8, body: []const u8) void {
        if (!self.running or self.owner.len == 0 or self.token.len == 0) return;

        var text_buf: [NOTIFY_TEXT_MAX]u8 = undefined;
        const text = buildNotifyText(title, body, &text_buf);

        const job = PushJob.create(self.allocator, self.base_url, self.token, self.owner, text) catch return;
        const th = std.Thread.spawn(.{}, PushJob.run, .{job}) catch {
            job.destroy();
            return;
        };
        th.detach();
    }

    // --- login (driven by the QR panel) ---

    /// Step 1 of login: fetch a QR code. The returned value borrows from `arena`.
    pub fn beginLogin(self: *Controller, arena: std.mem.Allocator) !types.QrCode {
        var client = ilink.Client.init(self.allocator, self.configuredBaseUrl(), "");
        return client.getBotQrcode(arena);
    }

    /// Step 2 of login: poll a QR code's status. Borrows from `arena`.
    pub fn pollLogin(self: *Controller, arena: std.mem.Allocator, qrcode: []const u8) !types.QrStatus {
        var client = ilink.Client.init(self.allocator, self.configuredBaseUrl(), "");
        return client.getQrcodeStatus(arena, qrcode);
    }

    /// Step 3: a confirmed QR status carries the bot_token; persist and start.
    pub fn confirmLogin(self: *Controller, status: types.QrStatus) !void {
        if (!self.login_active.load(.acquire)) return error.LoginCancelled;
        if (status.status != .confirmed or status.bot_token.len == 0) return error.NotConfirmed;
        const binding = types.Binding{
            .bot_token = status.bot_token,
            .base_url = if (status.base_url.len != 0) status.base_url else self.configuredBaseUrl(),
            // owner comes from settings.allowed_user (weixin-allowed-user). The
            // first-sender auto-bind described by ownerForBind is not yet wired,
            // so owner stays empty unless allowed_user is configured.
            .owner_user_id = self.settings.allowed_user,
            .bot_id = status.bot_id,
            .sync_buf = "",
        };
        try self.persistBinding(binding);
        try self.startWithBinding(binding, .{ .bootstrap_skip_pending = false });
        log.info("QR login confirmed; polling started", .{});
    }

    // --- internals ---

    fn configuredBaseUrl(self: *Controller) []const u8 {
        return if (self.base_url.len != 0) self.base_url else ilink_default_base_url;
    }

    const StartOptions = struct {
        bootstrap_skip_pending: bool = false,
    };

    fn startWithBinding(self: *Controller, binding: types.Binding, options: StartOptions) !void {
        if (self.running) {
            std.debug.print("weixin direct binding refresh requested; stopping existing poller\n", .{});
            self.stopInternal(false);
        }
        try self.setBinding(binding);

        self.client = ilink.Client.init(self.allocator, self.base_url, self.token);
        self.poll = .{
            .allocator = self.allocator,
            .client = self.client.api(),
            .control = self.control,
            .settings = self.settings,
            .owner = self.owner,
            .account_id = self.bot_id,
            .sync_buf = try self.allocator.dupe(u8, binding.sync_buf),
            .sync_callback = .{ .ctx = self, .callback = persistSyncAdapter },
            .bootstrap_skip_pending = options.bootstrap_skip_pending,
        };
        try self.poll.start();
        self.running = true;
        log.info("direct binding loaded; poller active", .{});
    }

    fn setBinding(self: *Controller, b: types.Binding) !void {
        const token = try self.allocator.dupe(u8, b.bot_token);
        errdefer self.allocator.free(token);
        const base_url = try self.allocator.dupe(u8, b.base_url);
        errdefer self.allocator.free(base_url);
        const owner = try self.allocator.dupe(u8, b.owner_user_id);
        errdefer self.allocator.free(owner);
        const bot_id = try self.allocator.dupe(u8, b.bot_id);
        errdefer self.allocator.free(bot_id);

        self.clearBinding();
        self.token = token;
        self.base_url = base_url;
        self.owner = owner;
        self.bot_id = bot_id;
    }

    fn clearBinding(self: *Controller) void {
        freeOwned(self.allocator, &self.token);
        freeOwned(self.allocator, &self.base_url);
        freeOwned(self.allocator, &self.owner);
        freeOwned(self.allocator, &self.bot_id);
    }

    fn persist(self: *Controller, sync_buf: []const u8) !void {
        try self.persistBinding(.{
            .bot_token = self.token,
            .base_url = self.base_url,
            .owner_user_id = self.owner,
            .bot_id = self.bot_id,
            .sync_buf = sync_buf,
        });
    }

    fn persistBinding(self: *Controller, binding: types.Binding) !void {
        try state_store.save(self.allocator, self.state_path, binding);
    }

    fn persistSyncAdapter(ctx: *anyopaque, sync_buf: []const u8) anyerror!void {
        const self: *Controller = @ptrCast(@alignCast(ctx));
        try self.persist(sync_buf);
    }

    fn joinLoginThreadForProcessExit(self: *Controller, thread_control: ThreadControl) bool {
        if (self.login_thread) |th| {
            _ = thread_control.request_synchronous_io_cancel(th);
            if (thread_control.wait_for_exit(th, SHUTDOWN_JOIN_TIMEOUT_MS)) {
                th.join();
                self.login_thread = null;
                return true;
            }
            th.detach();
            self.login_thread = null;
            std.debug.print("weixin QR login shutdown timed out; detaching for process exit\n", .{});
            return false;
        }
        return true;
    }
};

/// Builds the WeChat push text "<title>\n<body>" into `out`, truncating to fit.
/// Pure (no allocation/IO) so it is unit-tested directly.
fn buildNotifyText(title: []const u8, body: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    const tcopy = title[0..@min(title.len, out.len)];
    @memcpy(out[0..tcopy.len], tcopy);
    n = tcopy.len;
    if (body.len != 0 and n < out.len) {
        out[n] = '\n';
        n += 1;
        const bcopy = body[0..@min(body.len, out.len - n)];
        @memcpy(out[n..][0..bcopy.len], bcopy);
        n += bcopy.len;
    }
    return out[0..n];
}

/// A self-contained, owned copy of everything one push needs, so the send can
/// run on a detached thread without touching mutable Controller state.
const PushJob = struct {
    allocator: std.mem.Allocator,
    base_url: []u8,
    token: []u8,
    owner: []u8,
    text: []u8,

    fn create(
        allocator: std.mem.Allocator,
        base_url: []const u8,
        token: []const u8,
        owner: []const u8,
        text: []const u8,
    ) !*PushJob {
        const self = try allocator.create(PushJob);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.base_url = try allocator.dupe(u8, base_url);
        errdefer allocator.free(self.base_url);
        self.token = try allocator.dupe(u8, token);
        errdefer allocator.free(self.token);
        self.owner = try allocator.dupe(u8, owner);
        errdefer allocator.free(self.owner);
        self.text = try allocator.dupe(u8, text);
        return self;
    }

    fn destroy(self: *PushJob) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.token);
        self.allocator.free(self.owner);
        self.allocator.free(self.text);
        self.allocator.destroy(self);
    }

    fn run(self: *PushJob) void {
        var client = ilink.Client.init(self.allocator, self.base_url, self.token);
        client.sendText(self.owner, self.text, "") catch |err| {
            std.debug.print("weixin notify forward failed: {}\n", .{err});
        };
        self.destroy();
    }
};

const ilink_default_base_url = @import("ilink_codec.zig").DEFAULT_BASE_URL;

fn freeOwned(allocator: std.mem.Allocator, slot: *[]u8) void {
    if (slot.len != 0) allocator.free(slot.*);
    slot.* = &.{};
}

const t = std.testing;

// A no-op Control used to exercise controller lifetime without a GUI.
const NoopControl = struct {
    fn is_connected(_: *anyopaque) bool {
        return false;
    }
    fn find_ai_surface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn find_terminal_surface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn open_ai_agent(_: *anyopaque, _: u32) control_mod.OpenResult {
        return .offline;
    }
    fn open_ai_agent_profile(_: *anyopaque, _: []const u8, _: u32) control_mod.OpenResult {
        return .offline;
    }
    fn model_profiles(_: *anyopaque, _: []u8) []const u8 {
        return "";
    }
    fn switch_ai_profile(_: *anyopaque, _: []const u8) control_mod.SwitchModelResult {
        return .offline;
    }
    fn send_input(_: *anyopaque, _: [16]u8, _: []const u8, _: ?types.ReplyContext) control_mod.SendResult {
        return .offline;
    }
    fn latest_transcript(_: *anyopaque) []const u8 {
        return "";
    }
    fn ai_approval_pending(_: *anyopaque) bool {
        return false;
    }
    fn resolve_ai_approval(_: *anyopaque, _: bool) bool {
        return false;
    }
    fn inbound_file_dir(_: *anyopaque, _: []u8) []const u8 {
        return "";
    }
    var dummy: u8 = 0;
    fn iface() control_mod.Control {
        return .{ .ctx = &dummy, .vtable = &.{
            .is_connected = is_connected,
            .find_ai_surface = find_ai_surface,
            .find_terminal_surface = find_terminal_surface,
            .open_ai_agent = open_ai_agent,
            .open_ai_agent_profile = open_ai_agent_profile,
            .model_profiles = model_profiles,
            .switch_ai_profile = switch_ai_profile,
            .send_input = send_input,
            .latest_transcript = latest_transcript,
            .ai_approval_pending = ai_approval_pending,
            .resolve_ai_approval = resolve_ai_approval,
            .inbound_file_dir = inbound_file_dir,
        } };
    }
};

test "create/start without a persisted token stays idle, destroy is clean" {
    const path = "zig-cache-tmp-weixin-ctrl.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctrl = try Controller.create(t.allocator, path, NoopControl.iface(), .{});
    defer ctrl.destroy();

    try ctrl.start(); // no token file → no poller spawned
    try t.expect(!ctrl.running);
}

test "loginSnapshot on a fresh controller reports unknown/empty" {
    const path = "zig-cache-tmp-weixin-ctrl2.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctrl = try Controller.create(t.allocator, path, NoopControl.iface(), .{});
    defer ctrl.destroy();

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const snap = try ctrl.loginSnapshot(arena.allocator());
    try t.expectEqual(types.QrStatusKind.unknown, snap.status);
    try t.expectEqual(@as(usize, 0), snap.qr_string.len);
}

test "status on a fresh controller reports disconnected idle" {
    const path = "zig-cache-tmp-weixin-ctrl-status.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctrl = try Controller.create(t.allocator, path, NoopControl.iface(), .{});
    defer ctrl.destroy();

    const s = ctrl.statusSnapshot();
    try t.expect(!s.running);
    try t.expect(!s.has_token);
    try t.expect(!s.has_owner);
    try t.expect(!s.has_bot_id);
    try t.expect(!s.login_active);
    try t.expectEqual(types.QrStatusKind.unknown, s.login_status);
}

test "cancelled login cannot later confirm and persist a binding" {
    const path = "zig-cache-tmp-weixin-ctrl-cancel.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctrl = try Controller.create(t.allocator, path, NoopControl.iface(), .{});
    defer ctrl.destroy();

    ctrl.login_active.store(true, .release);
    ctrl.cancelLogin();

    try t.expectError(error.LoginCancelled, ctrl.confirmLogin(.{
        .status = .confirmed,
        .bot_token = "token",
        .base_url = "https://example.test",
        .bot_id = "bot",
    }));
    try t.expect(!ctrl.statusSnapshot().has_token);
}

test "buildNotifyText joins title and body with a newline" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("Claude Code\n完成", buildNotifyText("Claude Code", "完成", &buf));
}

test "buildNotifyText omits the newline when body is empty" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("Codex", buildNotifyText("Codex", "", &buf));
}

test "buildNotifyText truncates to fit the output buffer" {
    var buf: [5]u8 = undefined;
    try t.expectEqualStrings("Title", buildNotifyText("Title", "body", &buf));
}

test "enqueueNotify is a no-op when no binding is active (owner unbound)" {
    const path = "zig-cache-tmp-weixin-ctrl-enqueue.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctrl = try Controller.create(t.allocator, path, NoopControl.iface(), .{});
    defer ctrl.destroy();

    // Never started → running=false, owner empty: must not spawn a thread or crash.
    ctrl.enqueueNotify("Claude Code", "完成");
    try t.expect(!ctrl.running);
}
