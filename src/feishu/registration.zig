//! 飞书一键创建应用 — OAuth 设备授权流 (RFC 8628)。
//!
//! ponytail: 复制改造微信二维码面板(weixin/qr_panel + weixin_qr_renderer),
//!           而非抽公共件——两条流语义不同(微信"登录绑定"有 unbind,飞书"造新应用"无)
//!           且微信路径已上线。第三个渠道再要二维码面板时再抽 shared qr-login。
//!
//! 安全不变量(沿用 rest.zig):app_secret / device_code / 完整 url 查询
//! 绝不打印、记日志或落盘。verification_uri 因渲染成二维码而对用户可见,亦不写日志。

const std = @import("std");

const ENDPOINT_PATH = "/oauth/v1/app/registration";

fn accountsBase(international: bool) []const u8 {
    return if (international) "https://accounts.larksuite.com" else "https://accounts.feishu.cn";
}

/// poll 响应里我们关心的字段(切片借用解析 arena)。
pub const PollResp = struct {
    client_id: []const u8 = "",
    client_secret: []const u8 = "",
    tenant_brand: []const u8 = "",
    err: []const u8 = "",
};

pub const StatusKind = enum { requesting, waiting, success, expired, denied, err };

pub const Snapshot = struct {
    status: StatusKind,
    verify_url: []const u8,
    app_id: []const u8,
    app_secret: []const u8,
};

pub const Decision = enum {
    keep_waiting, // authorization_pending 或空 error
    slow_down, // 放慢轮询
    switch_to_lark, // tenant_brand==lark 且未切过
    success, // 拿到 client_id+secret
    denied, // access_denied
    expired, // expired_token
    fatal, // 其他未知 error
};

/// 纯状态机:把一次 poll 响应映射成动作。无副作用,供线程循环与单测共用。
pub fn decide(resp: PollResp, already_switched: bool) Decision {
    if (resp.client_id.len > 0 and resp.client_secret.len > 0) return .success;
    if (std.mem.eql(u8, resp.tenant_brand, "lark") and !already_switched) return .switch_to_lark;
    if (resp.err.len == 0 or std.mem.eql(u8, resp.err, "authorization_pending")) return .keep_waiting;
    if (std.mem.eql(u8, resp.err, "slow_down")) return .slow_down;
    if (std.mem.eql(u8, resp.err, "access_denied")) return .denied;
    if (std.mem.eql(u8, resp.err, "expired_token")) return .expired;
    return .fatal;
}

// ---------------------------------------------------------------------------
// HTTP form-POST + JSON parsing
// ---------------------------------------------------------------------------

/// POST application/x-www-form-urlencoded 到设备流端点。
/// 关键:不检查 HTTP status —— 设备流用 4xx + body 传 pending/slow_down,
/// 必须照常读 body(与 rest.zig 的 httpsPost 行为相反)。
fn postForm(client_alloc: std.mem.Allocator, resp_arena: std.mem.Allocator, base: []const u8, form_body: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(resp_arena, "{s}{s}", .{ base, ENDPOINT_PATH });
    var client: std.http.Client = .{ .allocator = client_alloc };
    defer client.deinit();
    var out: std.Io.Writer.Allocating = .init(resp_arena);
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .keep_alive = false,
        .payload = form_body,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .response_writer = &out.writer,
    });
    return out.toArrayList().items; // ← 不判 status
}

/// 百分号编码一个 form 值(只放过 unreserved 字符)。device_code 服务端生成,
/// 通常已是 URL-safe,但仍统一编码以防意外。
fn appendFormValue(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, value: []const u8) !void {
    for (value) |ch| {
        const unreserved = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (unreserved) {
            try buf.append(alloc, ch);
        } else {
            try buf.writer(alloc).print("%{X:0>2}", .{ch});
        }
    }
}

const BeginResp = struct {
    device_code: []const u8 = "",
    verification_uri_complete: []const u8 = "",
    interval: i64 = 0,
    expire_in: i64 = 0,
};

/// 解析 begin/poll 响应。切片借用 `arena`(调用方持有)。
fn parseBegin(arena: std.mem.Allocator, body: []const u8) !BeginResp {
    return std.json.parseFromSliceLeaky(BeginResp, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

const PollRespJson = struct {
    client_id: []const u8 = "",
    client_secret: []const u8 = "",
    user_info: ?struct { open_id: []const u8 = "", tenant_brand: []const u8 = "" } = null,
    @"error": []const u8 = "",
};

fn parsePoll(arena: std.mem.Allocator, body: []const u8) !PollResp {
    const j = try std.json.parseFromSliceLeaky(PollRespJson, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return .{
        .client_id = j.client_id,
        .client_secret = j.client_secret,
        .tenant_brand = if (j.user_info) |ui| ui.tenant_brand else "",
        .err = j.@"error",
    };
}

// ---------------------------------------------------------------------------
// 共享状态(worker 写 / UI 读,mutex 守护)
// ---------------------------------------------------------------------------

var g_mutex: std.Thread.Mutex = .{};
var g_active = std.atomic.Value(bool).init(false);
var g_thread: ?std.Thread = null;
var g_gpa: ?std.mem.Allocator = null;

var g_status: StatusKind = .requesting;
var g_arena: ?std.heap.ArenaAllocator = null; // 持有 g_verify_url/g_app_id/g_app_secret 的内存
var g_verify_url: []const u8 = "";
var g_app_id: []const u8 = "";
var g_app_secret: []const u8 = "";

/// UI 层注入的唤醒回调(app 传 window_backend.postWakeup),让 worker 线程状态变更后
/// 唤醒事件驱动渲染循环。registration.zig 保持平台无关(fast 测试可编译);
/// 测试中 hook 为 null,wake() 为 no-op。
var g_wakeup_hook: ?*const fn () void = null;

pub fn setWakeupHook(hook: ?*const fn () void) void {
    g_wakeup_hook = hook;
}

fn wake() void {
    if (g_wakeup_hook) |h| h();
}

fn setStatus(s: StatusKind) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    g_status = s;
    wake();
}

fn resetState(alloc: std.mem.Allocator, s: StatusKind) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_arena) |*a| a.deinit();
    g_arena = std.heap.ArenaAllocator.init(alloc);
    g_status = s;
    g_verify_url = "";
    g_app_id = "";
    g_app_secret = "";
}

fn setVerifyUrl(url: []const u8) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    const a = (&g_arena.?).allocator();
    g_verify_url = a.dupe(u8, url) catch "";
    wake();
}

fn setCreds(s: StatusKind, app_id: []const u8, app_secret: []const u8) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    const a = (&g_arena.?).allocator();
    g_app_id = a.dupe(u8, app_id) catch "";
    g_app_secret = a.dupe(u8, app_secret) catch "";
    g_status = s;
    wake();
}

pub fn snapshot(arena: std.mem.Allocator) Snapshot {
    g_mutex.lock();
    defer g_mutex.unlock();
    return .{
        .status = g_status,
        .verify_url = arena.dupe(u8, g_verify_url) catch "",
        .app_id = arena.dupe(u8, g_app_id) catch "",
        .app_secret = arena.dupe(u8, g_app_secret) catch "",
    };
}

pub fn cancel() void {
    g_active.store(false, .release);
}

/// 可中断睡眠:每 ~200ms 检查一次活动标志,cancel() 后及时退出。
fn sleepInterruptible(total_s: u64) void {
    const chunk_ns: u64 = 200 * std.time.ns_per_ms;
    var remaining: u64 = total_s * std.time.ns_per_s;
    while (remaining > 0 and g_active.load(.acquire)) {
        const step = @min(remaining, chunk_ns);
        std.Thread.sleep(step);
        remaining -= step;
    }
}

/// 面板拆除 / 进程退出时调用:停轮询线程、join、释放快照内存。
/// 配合可中断睡眠,join 通常在 ~200ms 内返回。
pub fn shutdown() void {
    cancel();
    if (g_thread) |th| {
        th.join();
        g_thread = null;
    }
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_arena) |*a| a.deinit();
    g_arena = null;
}

pub fn start(allocator: std.mem.Allocator, international: bool) !void {
    if (g_active.swap(true, .acq_rel)) return; // 已在跑
    if (g_thread) |th| {
        th.join();
        g_thread = null;
    }
    g_gpa = allocator;
    resetState(allocator, .requesting);
    g_thread = std.Thread.spawn(.{}, threadMain, .{international}) catch |err| {
        g_active.store(false, .release);
        return err;
    };
}

fn threadMain(international: bool) void {
    const alloc = g_gpa orelse return;

    // --- begin ---
    var begin_arena = std.heap.ArenaAllocator.init(alloc);
    const begin: BeginResp = blk: {
        defer begin_arena.deinit();
        const body = postForm(alloc, begin_arena.allocator(), accountsBase(international),
            "action=begin&archetype=PersonalAgent&auth_method=client_secret&request_user_info=open_id") catch {
            setStatus(.err);
            g_active.store(false, .release);
            return;
        };
        const parsed = parseBegin(begin_arena.allocator(), body) catch {
            setStatus(.err);
            g_active.store(false, .release);
            return;
        };
        if (parsed.device_code.len == 0 or parsed.verification_uri_complete.len == 0) {
            setStatus(.err);
            g_active.store(false, .release);
            return;
        }
        // Step 7: setVerifyUrl 在 break :blk 之前、begin_arena 释放之前调用
        setVerifyUrl(parsed.verification_uri_complete);
        // device_code 要带出 arena 给轮询用 → dup 到稳定内存。
        break :blk .{
            .device_code = alloc.dupe(u8, parsed.device_code) catch "",
            .verification_uri_complete = "", // url 已单独存入快照,此处不需带出
            .interval = parsed.interval,
            .expire_in = parsed.expire_in,
        };
    };
    defer alloc.free(begin.device_code);

    var interval_s: u64 = if (begin.interval > 0) @intCast(begin.interval) else 5;
    const expire_s: i64 = if (begin.expire_in > 0) begin.expire_in else 600;
    const deadline = std.time.timestamp() + expire_s;

    var base = accountsBase(international);
    var switched = false;
    setStatus(.waiting);

    var first = true;
    while (g_active.load(.acquire)) {
        if (!first) sleepInterruptible(interval_s);
        first = false;
        if (std.time.timestamp() >= deadline) {
            setStatus(.expired);
            break;
        }

        var poll_arena = std.heap.ArenaAllocator.init(alloc);
        const resp = pollOnce(alloc, poll_arena.allocator(), base, begin.device_code) catch {
            poll_arena.deinit();
            sleepInterruptible(2);
            continue;
        };
        if (!g_active.load(.acquire)) {
            poll_arena.deinit();
            break;
        }
        switch (decide(resp, switched)) {
            .success => {
                setCreds(.success, resp.client_id, resp.client_secret);
                poll_arena.deinit();
                break;
            },
            .switch_to_lark => {
                base = "https://accounts.larksuite.com";
                switched = true;
                // 立即重 poll(不 sleep):置 first 让循环跳过 sleep。
                first = true;
            },
            .slow_down => interval_s += 5, // ponytail: uncapped backoff, bounded by the expire_s deadline below
            .keep_waiting => {},
            .denied => {
                setStatus(.denied);
                poll_arena.deinit();
                break;
            },
            .expired => {
                setStatus(.expired);
                poll_arena.deinit();
                break;
            },
            .fatal => {
                setStatus(.err);
                poll_arena.deinit();
                break;
            },
        }
        poll_arena.deinit();
    }
    g_active.store(false, .release);
}

fn pollOnce(client_alloc: std.mem.Allocator, arena: std.mem.Allocator, base: []const u8, device_code: []const u8) !PollResp {
    var form: std.ArrayList(u8) = .empty;
    defer form.deinit(arena);
    try form.appendSlice(arena, "action=poll&device_code=");
    try appendFormValue(&form, arena, device_code);
    const body = try postForm(client_alloc, arena, base, form.items);
    return parsePoll(arena, body);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "decide: credentials present -> success" {
    try std.testing.expectEqual(Decision.success, decide(.{
        .client_id = "cli_x",
        .client_secret = "sec_x",
    }, false));
}

test "decide: lark tenant switches once, then keeps polling" {
    try std.testing.expectEqual(Decision.switch_to_lark, decide(.{ .tenant_brand = "lark" }, false));
    // 已切过 → 不再切,按普通 pending 继续
    try std.testing.expectEqual(Decision.keep_waiting, decide(.{ .tenant_brand = "lark" }, true));
}

test "decide: error codes map to terminal/slow states" {
    try std.testing.expectEqual(Decision.keep_waiting, decide(.{ .err = "authorization_pending" }, false));
    try std.testing.expectEqual(Decision.keep_waiting, decide(.{ .err = "" }, false));
    try std.testing.expectEqual(Decision.slow_down, decide(.{ .err = "slow_down" }, false));
    try std.testing.expectEqual(Decision.denied, decide(.{ .err = "access_denied" }, false));
    try std.testing.expectEqual(Decision.expired, decide(.{ .err = "expired_token" }, false));
    try std.testing.expectEqual(Decision.fatal, decide(.{ .err = "weird_error" }, false));
}

test "decide: success beats a stale error field" {
    // 服务端同时给了 creds 和上一轮的 pending,creds 优先。
    try std.testing.expectEqual(Decision.success, decide(.{
        .client_id = "cli_x",
        .client_secret = "sec_x",
        .err = "authorization_pending",
    }, false));
}

test "parsePoll extracts creds and tenant brand, ignores unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = try parsePoll(a,
        \\{"client_id":"cli_9","client_secret":"sec_9","user_info":{"open_id":"ou_1","tenant_brand":"feishu"},"extra":1}
    );
    try std.testing.expectEqualStrings("cli_9", ok.client_id);
    try std.testing.expectEqualStrings("sec_9", ok.client_secret);
    try std.testing.expectEqualStrings("feishu", ok.tenant_brand);
    try std.testing.expectEqual(Decision.success, decide(ok, false));

    const pending = try parsePoll(a,
        \\{"error":"authorization_pending"}
    );
    try std.testing.expectEqual(Decision.keep_waiting, decide(pending, false));
}

test "parseBegin reads device_code and verification url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try parseBegin(arena.allocator(),
        \\{"device_code":"dev_1","verification_uri_complete":"https://x/y?code=1","interval":5,"expire_in":600}
    );
    try std.testing.expectEqualStrings("dev_1", b.device_code);
    try std.testing.expectEqualStrings("https://x/y?code=1", b.verification_uri_complete);
    try std.testing.expectEqual(@as(i64, 5), b.interval);
}

test "appendFormValue percent-encodes reserved chars" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendFormValue(&buf, std.testing.allocator, "a b/c+d");
    try std.testing.expectEqualStrings("a%20b%2Fc%2Bd", buf.items);
}
