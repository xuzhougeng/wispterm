# 飞书一键创建应用(扫码)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在飞书配置表单里加一个「扫码创建应用」入口,扫码走 OAuth 设备授权流(RFC 8628)自动拿到 `app_id`/`app_secret` 并回填进表单,体验对标现有微信扫码登录。

**Architecture:** 镜像现有微信二维码栈的三层拆分(网络/线程 + UI 快照 + GPU 渲染)。新增 `src/feishu/registration.zig`(设备流网络 + mutex 守护的全局状态 + 后台轮询线程 + 可单测的纯状态机)、`src/feishu/registration_panel.zig`(UI 线程快照,镜像 `weixin/qr_panel.zig` 去掉 unbind)、`src/renderer/feishu_qr_renderer.zig`(镜像 `weixin_qr_renderer.zig`)。直接复用 `src/weixin/qr_code.zig` 把 URL 编成二维码矩阵。成功后由渲染层回调 overlays 把凭据回填进现有飞书配置表单。

**Tech Stack:** Zig 0.15.2;`std.http.Client.fetch`(HTTP)、`std.json`(解析)、`std.Thread` + `std.Thread.Mutex` + `std.atomic.Value`(并发)、`std.heap.ArenaAllocator`(快照内存)。

## Global Constraints

- **设备流端点是 `accounts` 域,不是现有 REST 的 `open` 域**:`https://accounts.feishu.cn`(国内)/ `https://accounts.larksuite.com`(Lark),路径 `/oauth/v1/app/registration`,`Content-Type: application/x-www-form-urlencoded`。
- **轮询的 form-POST 绝不能因 HTTP 非 200 而报错返回**:设备流用 4xx + body 传 `authorization_pending`/`slow_down`。必须照常读 body 再解析(与 `rest.zig` 的 `httpsPost` 行为相反)。
- **安全不变量(沿用 `rest.zig`)**:`app_secret`、`device_code`、完整 url 查询绝不打印 / 记日志 / 落盘。`verification_uri` 因要渲染成二维码而对用户可见,但同样不写日志。
- **线程模型镜像 `weixin/controller.zig`**:共享网络状态用普通全局 + `std.Thread.Mutex`(非 threadlocal);UI 快照状态用 `threadlocal var`(仅 UI 线程访问)。`std.atomic.Value(bool)` 作活动标志,内存序 `.acquire`/`.release`/`.acq_rel`。
- **`qr_code.zig` 容量**:支持到 version 10(byte 模式约 271 字节),`verification_uri_complete`(~100–200 字符)在容量内,无需改编码器。
- **v1 砍掉(YAGNI)**:`addons`/`name`/`desc`/`avatar`/`createOnly`/更新已有应用(`clientID`)、命令面板入口、终端 ASCII 二维码、成功后自动 Save/启动 bot、凭据连通性测试。
- **测试目标**:纯逻辑(`registration.zig`、`feishu_config.zig`)进 `src/test_fast.zig`,跑 `zig build test`(macOS 上快速运行)。UI 快照(`registration_panel.zig`)进 `src/test_main.zig`,跑 `zig build test-full -Dtarget=aarch64-macos`(裸 `test-full` 只编译不运行原生测试)。已知无关 flaky:`skill center tool import`(FileNotFound),忽略。

---

## File Structure

**新增**
- `src/feishu/registration.zig` —— 设备流网络逻辑 + 全局状态(mutex)+ 后台线程 + 纯状态机 `decide()`。职责:把"begin→poll→换凭据"封进 `start/cancel/snapshot` 三个 UI 可调接口。
- `src/feishu/registration_panel.zig` —— UI 线程快照面板(镜像 `weixin/qr_panel.zig`):`refresh()` 拍快照、URL 变了用 `qr_code.encodeText` 重算矩阵、`layout()`/`executeAt()` 布局与命中。无 unbind。
- `src/renderer/feishu_qr_renderer.zig` —— GPU 渲染(镜像 `weixin_qr_renderer.zig`):标题"创建飞书应用"、状态/二维码/按钮(Retry/Close),成功时回调 overlays 回填表单。

**改动**
- `src/renderer/overlays/feishu_config.zig` —— 插入 `SCAN_ROW`,行数 5→6,行号常量重排。
- `src/renderer/overlays.zig` —— 新增 `startFeishuRegistration`、`feishuRegPanelHandleAction`、`applyFeishuRegistrationSuccess`;`SCAN_ROW` 的 enter/click/dispatch 接线;表单多渲染一行。
- `src/input.zig` —— 飞书面板的字符吞噬 / esc·enter 键 / 鼠标点击路由(镜像微信三处)。
- `src/AppWindow.zig` —— import 面板与渲染器、render pass 调用、deinit(镜像微信四处)。
- `src/test_fast.zig` —— 注册 `registration.zig`。
- `src/test_main.zig` —— 注册 `registration_panel.zig`。

---

## Task 1: feishu_config.zig 插入 SCAN_ROW

**Files:**
- Modify: `src/renderer/overlays/feishu_config.zig:6-12`(行号常量)
- Test: 同文件内既有 test 块

**Interfaces:**
- Produces: `pub const SCAN_ROW: usize = 2`;重排后 `APP_ID_ROW=3`、`APP_SECRET_ROW=4`、`SAVE_ROW=5`、`FEISHU_ROW_COUNT=6`。`State.focusedField()` / `toggleFocusedBool()` 行为不变(SCAN_ROW 既非字段也非 toggle,落到 `else`)。

- [ ] **Step 1: 改行号常量**

把 `src/renderer/overlays/feishu_config.zig:6-12` 整段替换为:

```zig
// Form rows: 0 = enabled, 1 = international (Lark), 2 = scan-create app,
// 3 = app_id, 4 = app_secret, 5 = Save.
pub const FEISHU_ROW_COUNT: usize = 6;
pub const ENABLED_ROW: usize = 0;
pub const INTERNATIONAL_ROW: usize = 1;
pub const SCAN_ROW: usize = 2;
pub const APP_ID_ROW: usize = 3;
pub const APP_SECRET_ROW: usize = 4;
pub const SAVE_ROW: usize = FEISHU_ROW_COUNT - 1;
```

- [ ] **Step 2: 更新 focusedField 注释 + 行映射**

`focusedField()`(:65-71)逻辑用的是命名常量,无需改逻辑。确认其 `switch` 仍是:

```zig
    pub fn focusedField(self: *const State) ?FeishuField {
        return switch (self.focus) {
            APP_ID_ROW => .app_id,
            APP_SECRET_ROW => .app_secret,
            else => null, // ENABLED / INTERNATIONAL / SCAN / SAVE 行都没有文本字段
        };
    }
```

- [ ] **Step 3: 加一条 SCAN_ROW 的导航测试**

在文件末尾既有 test 块后追加:

```zig
test "SCAN_ROW sits between international and app_id, has no field and no toggle" {
    try std.testing.expectEqual(@as(usize, 2), SCAN_ROW);
    try std.testing.expectEqual(@as(usize, 3), APP_ID_ROW);
    try std.testing.expectEqual(@as(usize, 6), FEISHU_ROW_COUNT);

    var s = State{};
    s.focus = SCAN_ROW;
    try std.testing.expect(s.focusedField() == null); // 不是文本字段
    s.toggleFocusedBool(); // 不是 toggle 行 → 不动 enabled/international
    try std.testing.expect(!s.enabled and !s.international);
}
```

并更新既有 `"focus navigation clamps over enabled, international, fields, and Save row"` 测试:它逐行 `focusNextRow()` 到 SAVE_ROW,现在多了一行,需多一次 `focusNextRow()`。把该测试里 `// app_id` 之前加一行:

```zig
    s.focusNextRow(); // international
    s.focusNextRow(); // scan
    s.focusNextRow(); // app_id
    s.focusNextRow(); // app_secret
    s.focusNextRow(); // Save row
```

- [ ] **Step 4: 跑 fast 测试**

Run: `zig build test`
Expected: PASS(含上面新增 / 改动的 feishu_config 测试)。

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays/feishu_config.zig
git commit -m "feat(feishu): add SCAN_ROW to config form row layout"
```

---

## Task 2: registration.zig —— 设备流网络核心 + 状态机

**Files:**
- Create: `src/feishu/registration.zig`
- Modify: `src/test_fast.zig:331`(注册模块)
- Test: `src/feishu/registration.zig` 内 test 块

**Interfaces:**
- Consumes: 无(自包含;`international: bool` 由调用方传入)。
- Produces:
  - `pub const StatusKind = enum { requesting, waiting, success, expired, denied, err }`
  - `pub const Snapshot = struct { status: StatusKind, verify_url: []const u8, app_id: []const u8, app_secret: []const u8 }`
  - `pub fn start(allocator: std.mem.Allocator, international: bool) !void` —— 起后台线程(若已在跑先取消)。
  - `pub fn cancel() void` —— 停线程标志。
  - `pub fn snapshot(arena: std.mem.Allocator) Snapshot` —— 线程安全快照,字符串 dup 进 arena。
  - `pub fn decide(resp: PollResp, already_switched: bool) Decision` —— 纯状态机(供面板/测试)。

- [ ] **Step 1: 写纯状态机的失败测试 + 编译用桩**

新建 `src/feishu/registration.zig`,先只放纯状态机的类型 + 桩 + 测试(桩故意返回错值,产生真红):

```zig
//! 飞书一键创建应用 — OAuth 设备授权流 (RFC 8628)。
//!
//! ponytail: 复制改造微信二维码面板(weixin/qr_panel + weixin_qr_renderer),
//!           而非抽公共件——两条流语义不同(微信"登录绑定"有 unbind,飞书"造新应用"无)
//!           且微信路径已上线。第三个渠道再要二维码面板时再抽 shared qr-login。
//!
//! 安全不变量(沿用 rest.zig):app_secret / device_code / 完整 url 查询
//! 绝不打印、记日志或落盘。verification_uri 因渲染成二维码而对用户可见,亦不写日志。

const std = @import("std");

const log = std.log.scoped(.feishu_reg);

const ENDPOINT_PATH = "/oauth/v1/app/registration";

fn accountsBase(international: bool) []const u8 {
    return if (international) "https://accounts.larksuite.com"
                            else "https://accounts.feishu.cn";
}

/// poll 响应里我们关心的字段(切片借用解析 arena)。
pub const PollResp = struct {
    client_id: []const u8 = "",
    client_secret: []const u8 = "",
    tenant_brand: []const u8 = "",
    err: []const u8 = "",
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
    return .keep_waiting; // 桩 —— Step 3 实现
}

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
```

在 `src/test_fast.zig:331`(`_ = @import("feishu/progress.zig");` 后)加一行:

```zig
    _ = @import("feishu/registration.zig");
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test`
Expected: FAIL —— `decide: credentials present -> success` 等断言失败(桩恒返回 `.keep_waiting`)。

- [ ] **Step 3: 实现 decide()**

把桩替换为:

```zig
pub fn decide(resp: PollResp, already_switched: bool) Decision {
    if (resp.client_id.len > 0 and resp.client_secret.len > 0) return .success;
    if (std.mem.eql(u8, resp.tenant_brand, "lark") and !already_switched) return .switch_to_lark;
    if (resp.err.len == 0 or std.mem.eql(u8, resp.err, "authorization_pending")) return .keep_waiting;
    if (std.mem.eql(u8, resp.err, "slow_down")) return .slow_down;
    if (std.mem.eql(u8, resp.err, "access_denied")) return .denied;
    if (std.mem.eql(u8, resp.err, "expired_token")) return .expired;
    return .fatal;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test`
Expected: PASS(decide 全部测试)。

- [ ] **Step 5: 加 HTTP form-POST + JSON 解析(带测试)**

在 `decide` 之后、test 块之前插入网络原语。`postForm` 关键:**不判 status,照常返回 body**。

```zig
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
    error_description: []const u8 = "",
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
```

在 test 块追加解析测试:

```zig
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

    const pending = try parsePoll(a, \\{"error":"authorization_pending"}
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
```

Run: `zig build test`
Expected: PASS。

- [ ] **Step 6: 加全局状态 + 后台线程 + start/cancel/snapshot**

在文件内(test 块之前)加共享状态与线程。**普通全局 + mutex(非 threadlocal),因为 worker 线程写、UI 线程读。**

```zig
// ---- 共享状态(worker 写 / UI 读,mutex 守护)----------------------------
var g_mutex: std.Thread.Mutex = .{};
var g_active = std.atomic.Value(bool).init(false);
var g_thread: ?std.Thread = null;
var g_gpa: ?std.mem.Allocator = null;

var g_status: StatusKind = .requesting;
var g_arena: ?std.heap.ArenaAllocator = null; // 持有 g_verify_url/g_app_id/g_app_secret 的内存
var g_verify_url: []const u8 = "";
var g_app_id: []const u8 = "";
var g_app_secret: []const u8 = "";

fn setStatus(s: StatusKind) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    g_status = s;
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
}

fn setCreds(s: StatusKind, app_id: []const u8, app_secret: []const u8) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    const a = (&g_arena.?).allocator();
    g_app_id = a.dupe(u8, app_id) catch "";
    g_app_secret = a.dupe(u8, app_secret) catch "";
    g_status = s;
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
        // device_code 要带出 arena 给轮询用 → dup 到稳定内存。
        break :blk .{
            .device_code = alloc.dupe(u8, parsed.device_code) catch "",
            .verification_uri_complete = "", // 不需带出
            .interval = parsed.interval,
            .expire_in = parsed.expire_in,
        };
    };
    defer alloc.free(begin.device_code);

    // 再取一次 verify_url 设进快照(begin_arena 已释放,重新 begin 不必要;
    // 改为在上面 defer 前先 setVerifyUrl)。见 Step 7 修正。
    var interval_s: u64 = if (begin.interval > 0) @intCast(begin.interval) else 5;
    const expire_s: i64 = if (begin.expire_in > 0) begin.expire_in else 600;
    const deadline = std.time.timestamp() + expire_s;

    var base = accountsBase(international);
    var switched = false;
    setStatus(.waiting);

    var first = true;
    while (g_active.load(.acquire)) {
        if (!first) std.Thread.sleep(interval_s * std.time.ns_per_s);
        first = false;
        if (std.time.timestamp() >= deadline) {
            setStatus(.expired);
            break;
        }

        var poll_arena = std.heap.ArenaAllocator.init(alloc);
        const resp = pollOnce(alloc, poll_arena.allocator(), base, begin.device_code) catch {
            poll_arena.deinit();
            std.Thread.sleep(2 * std.time.ns_per_s);
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
            .slow_down => interval_s += 5,
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
```

- [ ] **Step 7: 修正 verify_url 设置时机**

上面 begin 块在 `defer begin_arena.deinit()` 前要把 verify_url 设进快照(否则 arena 释放后丢失)。在 `break :blk` **之前**插入:

```zig
        setVerifyUrl(parsed.verification_uri_complete);
```

并删掉 `break :blk` 里那行误导性的 `.verification_uri_complete = ""` 注释保留空串即可(快照已单独存了 url)。

- [ ] **Step 8: 编译 + 跑 fast 测试**

Run: `zig build test`
Expected: PASS(纯逻辑测试通过;线程代码随 fast 二进制编译通过 —— fast suite 已 import 本模块)。

- [ ] **Step 9: Commit**

```bash
git add src/feishu/registration.zig src/test_fast.zig
git commit -m "feat(feishu): device-authorization registration core (begin/poll/state machine)"
```

---

## Task 3: registration_panel.zig —— UI 线程快照面板

**Files:**
- Create: `src/feishu/registration_panel.zig`
- Modify: `src/test_fast.zig`(注册模块 —— 本文件纯逻辑,无 GPU/AppWindow 依赖,挂 fast suite 秒级验证)
- Test: 同文件内 test 块

**Interfaces:**
- Consumes: `registration.snapshot(arena)`、`registration.StatusKind`、`weixin/qr_code.zig` 的 `encodeText`/`Matrix`。
- Produces(供渲染器/输入/overlays 调用):
  - `pub fn open() void` / `pub fn close() void` / `pub fn visible() bool`
  - `pub fn status() registration.StatusKind`
  - `pub fn statusLabel(s) []const u8` / `pub fn statusDetail(s) []const u8`
  - `pub fn qrMatrix() ?QrMatrixView` / `pub fn qrGenerationFailed() bool`
  - `pub const RefreshResult = struct { redraw: bool, succeeded: bool }`
  - `pub fn refresh(allocator) RefreshResult`
  - `pub fn takeSuccessCreds() ?Creds`(`Creds{ app_id, app_secret }`,UI 线程持有,取走一次)
  - `pub const Action = enum { none, retry, close }`
  - `pub const Rect`/`Layout`/`QrMatrixView`(镜像 weixin)
  - `pub fn layout(w,h,top) Layout` / `pub fn executeAt(x,y,w,h,top) Action` / `pub fn containsPoint(...) bool` / `pub fn deinit() void`

- [ ] **Step 1: 写面板(镜像 weixin/qr_panel.zig,去 unbind,接 registration)**

新建 `src/feishu/registration_panel.zig`。布局沿用 weixin 数值;状态文案换飞书;按钮去掉 unbind(只 retry/close);refresh 接 `registration.snapshot`,success 时不自动关、由 overlays 取 creds 后关。

```zig
//! UI-thread state for the Feishu one-click registration QR panel.
//! 镜像 weixin/qr_panel.zig:registration.zig 持网络线程,本模块只拍快照、
//! 持有 UI 侧二维码矩阵、暴露布局/命中给渲染与输入层。无 unbind。

const std = @import("std");
const registration = @import("registration.zig");
const qr_code = @import("../weixin/qr_code.zig");

pub const StatusKind = registration.StatusKind;

pub const Action = enum { none, retry, close };

pub const Rect = struct { x: f32, top_px: f32, w: f32, h: f32 };

pub const Layout = struct {
    panel: Rect,
    qr: Rect,
    retry: Rect,
    close: Rect,
};

pub const QrMatrixView = struct {
    size: usize,
    modules: []const u8,
    pub fn isBlack(self: QrMatrixView, x: usize, y: usize) bool {
        return x < self.size and y < self.size and self.modules[y * self.size + x] != 0;
    }
};

pub const Creds = struct { app_id: []const u8, app_secret: []const u8 };

const PANEL_MIN_W: f32 = 380;
const PANEL_MAX_W: f32 = 900;
const PANEL_MIN_H: f32 = 500;
const PANEL_MAX_H: f32 = 620;
const PANEL_MARGIN: f32 = 24;
const BUTTON_H: f32 = 38;
const BUTTON_W: f32 = 118;
const BUTTON_GAP: f32 = 10;

pub threadlocal var g_visible: bool = false;
threadlocal var g_status: StatusKind = .requesting;
threadlocal var g_qr_url: ?[]u8 = null;
threadlocal var g_qr_matrix: ?qr_code.Matrix = null;
threadlocal var g_qr_gen_failed: bool = false;
threadlocal var g_last_url_hash: u64 = 0;
threadlocal var g_success_app_id: ?[]u8 = null;
threadlocal var g_success_app_secret: ?[]u8 = null;
threadlocal var g_success_pending: bool = false;

pub fn open() void {
    g_visible = true;
    g_status = .requesting;
}

pub fn close() void {
    g_visible = false;
}

pub fn visible() bool {
    return g_visible;
}

pub fn status() StatusKind {
    return g_status;
}

pub fn statusLabel(s: StatusKind) []const u8 {
    return switch (s) {
        .requesting => "正在申请",
        .waiting => "等待扫码",
        .success => "创建成功",
        .expired => "已过期",
        .denied => "已取消",
        .err => "出错了",
    };
}

pub fn statusDetail(s: StatusKind) []const u8 {
    return switch (s) {
        .requesting => "正在向飞书申请创建链接…",
        .waiting => "请用飞书扫码并确认创建应用。",
        .success => "凭据已回填到配置表单,请检查后保存。",
        .expired => "二维码已过期,点 Retry 重新申请。",
        .denied => "授权被取消,点 Retry 重试。",
        .err => "网络或服务异常,点 Retry 重试。",
    };
}

pub fn qrMatrix() ?QrMatrixView {
    if (g_qr_matrix) |m| return .{ .size = m.size, .modules = m.modules };
    return null;
}

pub fn qrGenerationFailed() bool {
    return g_qr_gen_failed;
}

pub const RefreshResult = struct { redraw: bool, succeeded: bool };

pub fn refresh(allocator: std.mem.Allocator) RefreshResult {
    if (!g_visible) return .{ .redraw = false, .succeeded = false };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const snap = registration.snapshot(arena.allocator());

    var redraw = false;
    if (snap.status != g_status) {
        g_status = snap.status;
        redraw = true;
    }
    redraw = updateQr(snap.verify_url) or redraw;

    var succeeded = false;
    if (snap.status == .success and !g_success_pending and snap.app_id.len > 0) {
        replaceOwned(&g_success_app_id, snap.app_id);
        replaceOwned(&g_success_app_secret, snap.app_secret);
        g_success_pending = true;
        succeeded = true;
        redraw = true;
    }
    return .{ .redraw = redraw, .succeeded = succeeded };
}

/// 取走成功凭据(供 overlays 回填表单),取后清空 pending。返回的切片在下次
/// takeSuccessCreds/deinit 前有效;调用方应立即 copy 进表单 buffer。
pub fn takeSuccessCreds() ?Creds {
    if (!g_success_pending) return null;
    g_success_pending = false;
    return .{
        .app_id = g_success_app_id orelse "",
        .app_secret = g_success_app_secret orelse "",
    };
}

fn updateQr(url: []const u8) bool {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len == 0) return false;
    const h = std.hash.Wyhash.hash(0, trimmed);
    if (h == g_last_url_hash) return false;
    g_last_url_hash = h;

    replaceOwned(&g_qr_url, trimmed);
    clearMatrix();
    g_qr_matrix = qr_code.encodeText(std.heap.page_allocator, trimmed) catch {
        g_qr_gen_failed = true;
        return true;
    };
    g_qr_gen_failed = false;
    return true;
}

fn replaceOwned(slot: *?[]u8, value: []const u8) void {
    if (slot.*) |old| std.heap.page_allocator.free(old);
    slot.* = std.heap.page_allocator.dupe(u8, value) catch null;
}

fn clearMatrix() void {
    if (g_qr_matrix) |*m| m.deinit();
    g_qr_matrix = null;
}

pub fn layout(window_width: f32, window_height: f32, top_offset: f32) Layout {
    const content_h = @max(1.0, window_height - top_offset);
    const panel_w = @round(@min(PANEL_MAX_W, @max(PANEL_MIN_W, window_width - PANEL_MARGIN * 2)));
    const panel_h = @round(@min(PANEL_MAX_H, @max(PANEL_MIN_H, content_h - PANEL_MARGIN * 2)));
    const panel_x = @round(@max(12.0, (window_width - panel_w) / 2.0));
    const panel_top = @round(top_offset + @max(12.0, (content_h - panel_h) / 2.0));

    const qr_size = @round(@max(180.0, @min(@min(panel_w - 104.0, panel_h - 254.0), 292.0)));
    const qr_x = @round(panel_x + (panel_w - qr_size) / 2.0);
    const qr_top = @round(panel_top + 136.0);

    const close_x = @round(panel_x + panel_w - 24.0 - BUTTON_W);
    const retry_x = @round(panel_x + 24.0);
    const button_top = @round(panel_top + panel_h - 24.0 - BUTTON_H);

    return .{
        .panel = .{ .x = panel_x, .top_px = panel_top, .w = panel_w, .h = panel_h },
        .qr = .{ .x = qr_x, .top_px = qr_top, .w = qr_size, .h = qr_size },
        .retry = .{ .x = retry_x, .top_px = button_top, .w = BUTTON_W, .h = BUTTON_H },
        .close = .{ .x = close_x, .top_px = button_top, .w = BUTTON_W, .h = BUTTON_H },
    };
}

pub fn containsPoint(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) bool {
    if (!g_visible) return false;
    const l = layout(window_width, window_height, top_offset);
    return pointInRect(xpos, ypos, l.panel);
}

pub fn executeAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32, top_offset: f32) Action {
    if (!g_visible) return .none;
    const l = layout(window_width, window_height, top_offset);
    const retryable = g_status == .expired or g_status == .denied or g_status == .err;
    if (retryable and pointInRect(xpos, ypos, l.retry)) return .retry;
    if (pointInRect(xpos, ypos, l.close)) return .close;
    return .none;
}

pub fn deinit() void {
    g_visible = false;
    clearMatrix();
    if (g_qr_url) |u| std.heap.page_allocator.free(u);
    g_qr_url = null;
    if (g_success_app_id) |s| std.heap.page_allocator.free(s);
    g_success_app_id = null;
    if (g_success_app_secret) |s| std.heap.page_allocator.free(s);
    g_success_app_secret = null;
    g_last_url_hash = 0;
    g_success_pending = false;
    g_status = .requesting;
}

fn pointInRect(xpos: f64, ypos: f64, rect: Rect) bool {
    const x: f32 = @floatCast(xpos);
    const y: f32 = @floatCast(ypos);
    return x >= rect.x and x <= rect.x + rect.w and y >= rect.top_px and y <= rect.top_px + rect.h;
}

test "layout keeps retry/close inside panel" {
    const l = layout(800, 600, 32);
    try std.testing.expect(l.retry.x >= l.panel.x);
    try std.testing.expect(l.close.x + l.close.w <= l.panel.x + l.panel.w);
    try std.testing.expect(l.close.top_px + l.close.h <= l.panel.top_px + l.panel.h);
}

test "executeAt: retry hot only on retryable states, close always" {
    g_visible = true;
    defer deinit();
    const l = layout(800, 600, 0);

    g_status = .waiting;
    try std.testing.expectEqual(Action.none, executeAt(l.retry.x + 4, l.retry.top_px + 4, 800, 600, 0));
    try std.testing.expectEqual(Action.close, executeAt(l.close.x + 4, l.close.top_px + 4, 800, 600, 0));

    g_status = .expired;
    try std.testing.expectEqual(Action.retry, executeAt(l.retry.x + 4, l.retry.top_px + 4, 800, 600, 0));
}

test "updateQr builds a matrix and dedups by url hash" {
    defer deinit();
    try std.testing.expect(updateQr("https://accounts.feishu.cn/oauth/v1/app/registration?code=abc"));
    try std.testing.expect(qrMatrix() != null);
    try std.testing.expect(!qrGenerationFailed());
    // 同 url 再来一次 → 不重算(返回 false)
    try std.testing.expect(!updateQr("https://accounts.feishu.cn/oauth/v1/app/registration?code=abc"));
}
```

- [ ] **Step 2: 注册到 test_fast**

`registration_panel.zig` 只 import `registration.zig` 与 `weixin/qr_code.zig`(均纯逻辑,无 AppWindow/GPU),可挂 fast suite。在 `src/test_fast.zig` 的 `_ = @import("feishu/registration.zig");` 后加:

```zig
    _ = @import("feishu/registration_panel.zig");
```

- [ ] **Step 3: 跑 fast 测试**

Run: `zig build test`
Expected: PASS(含本文件 3 个测试)。
若该文件因某依赖无法在 fast suite 编译(理论上不会),回退:改注册到 `src/test_main.zig:818` 并用 `zig build test-full -Dtarget=aarch64-macos`,并在报告里说明。

- [ ] **Step 4: Commit**

```bash
git add src/feishu/registration_panel.zig src/test_fast.zig
git commit -m "feat(feishu): UI-thread snapshot panel for registration QR"
```

---

## Task 4: feishu_qr_renderer.zig —— GPU 渲染

**Files:**
- Create: `src/renderer/feishu_qr_renderer.zig`
- Modify: `src/renderer/gpu/gl_backend_guard.zig`(登记新渲染器源,镜像 weixin 的 :44/:66/:87)

**Interfaces:**
- Consumes: `feishu/registration_panel.zig` 全套;`AppWindow`(titlebar/font/gpu/overlays/g_theme)。
- Produces: `pub fn render(window_width, window_height, top_offset) void`、`pub fn deinit() void`。
- 成功回填靠 `AppWindow.overlays.applyFeishuRegistrationSuccess()`(Task 5 提供)。

- [ ] **Step 1: 写渲染器(镜像 weixin_qr_renderer.zig)**

新建 `src/renderer/feishu_qr_renderer.zig`。与 weixin 版差异:import 飞书面板;标题"创建飞书应用";去掉 unbind 按钮;refresh 返回 succeeded 时回调 overlays;retry 颜色用于 expired/denied/err。

```zig
//! Renderer for the Feishu one-click registration QR panel.
//! 镜像 weixin_qr_renderer.zig;成功时回调 overlays 把凭据回填配置表单后关面板。

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const panel = @import("../feishu/registration_panel.zig");
const titlebar = AppWindow.titlebar;
const font = AppWindow.font;
const gl_init = AppWindow.gpu.gl_init;

fn mix(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const amount = @max(0.0, @min(1.0, t));
    const inv = 1.0 - amount;
    return .{ a[0] * inv + b[0] * amount, a[1] * inv + b[1] * amount, a[2] * inv + b[2] * amount };
}

fn textWidth(text: []const u8) f32 {
    var width: f32 = 0;
    const view = std.unicode.Utf8View.init(text) catch {
        for (text) |byte| width += titlebar.titlebarGlyphAdvance(if (byte >= 0x20 and byte <= 0x7e) byte else '?');
        return width;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| width += titlebar.titlebarGlyphAdvance(cp);
    return width;
}

fn textYFromTop(window_height: f32, top_px: f32) f32 {
    return @round(window_height - top_px - font.g_titlebar_cell_height);
}

fn rectY(window_height: f32, rect: panel.Rect) f32 {
    return @round(window_height - rect.top_px - rect.h);
}

pub fn render(window_width: f32, window_height: f32, top_offset: f32) void {
    if (!panel.visible()) return;

    const allocator = AppWindow.g_allocator orelse std.heap.page_allocator;
    const r = panel.refresh(allocator);
    if (r.redraw) {
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
    }
    if (r.succeeded) {
        AppWindow.overlays.applyFeishuRegistrationSuccess(); // 回填表单 + 关面板 + toast
        return;
    }
    if (!panel.visible()) return;

    AppWindow.gpu.state.setBlendEnabled(true);
    AppWindow.gpu.state.setBlendMode(.alpha);

    const l = panel.layout(window_width, window_height, top_offset);
    const panel_y = rectY(window_height, l.panel);
    const qr_y = rectY(window_height, l.qr);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel_bg = mix(bg, fg, 0.045);
    const panel_border = mix(bg, fg, 0.22);
    const qr_bg = .{ 0.96, 0.97, 0.98 };
    const qr_border = mix(bg, fg, 0.30);
    const normal = mix(bg, fg, 0.90);
    const muted = mix(bg, fg, 0.62);
    const danger = .{ 0.88, 0.28, 0.24 };

    AppWindow.overlays.renderRoundedQuadAlpha(0, 0, window_width, window_height, 1, .{ 0.0, 0.0, 0.0 }, 0.28);
    AppWindow.overlays.renderRoundedQuadAlpha(l.panel.x - 1, panel_y - 1, l.panel.w + 2, l.panel.h + 2, 10, panel_border, 0.50);
    AppWindow.overlays.renderRoundedQuadAlpha(l.panel.x, panel_y, l.panel.w, l.panel.h, 9, panel_bg, 0.98);

    const pad_x: f32 = 28;
    const title_y = textYFromTop(window_height, l.panel.top_px + 24);
    _ = titlebar.renderTextLimited("创建飞书应用", l.panel.x + pad_x, title_y, normal, l.panel.w - pad_x * 2);

    const s = panel.status();
    const status_color = switch (s) {
        .expired, .denied, .err => danger,
        .success => accent,
        else => normal,
    };
    const status_y = textYFromTop(window_height, l.panel.top_px + 60);
    _ = titlebar.renderTextLimited(panel.statusLabel(s), l.panel.x + pad_x, status_y, status_color, l.panel.w - pad_x * 2);

    const detail_y = textYFromTop(window_height, l.panel.top_px + 94);
    _ = titlebar.renderTextLimited(panel.statusDetail(s), l.panel.x + pad_x, detail_y, muted, l.panel.w - pad_x * 2);

    gl_init.renderQuadAlpha(l.qr.x - 10, qr_y - 10, l.qr.w + 20, l.qr.h + 20, qr_border, 0.42);
    gl_init.renderQuadAlpha(l.qr.x - 8, qr_y - 8, l.qr.w + 16, l.qr.h + 16, qr_bg, 1.0);

    if (panel.qrMatrix()) |matrix| {
        renderQrMatrix(matrix, l.qr, window_height);
    } else {
        renderQrFallback(l, window_height, normal);
    }

    const hint_y = textYFromTop(window_height, l.close.top_px - 34);
    _ = titlebar.renderTextLimited("凭据将在创建成功后回填到配置表单。", l.panel.x + pad_x, hint_y, muted, l.panel.w - pad_x * 2);

    const retryable = s == .expired or s == .denied or s == .err;
    if (retryable) {
        renderButton(l.retry, window_height, "Retry", accent, .{ 1.0, 1.0, 1.0 }, true);
    }
    renderButton(l.close, window_height, "Close", panel_border, normal, false);
}

fn renderQrMatrix(matrix: panel.QrMatrixView, rect: panel.Rect, window_height: f32) void {
    const quiet_modules: usize = 4;
    const total_modules = matrix.size + quiet_modules * 2;
    const module_px = @max(1.0, @floor(rect.w / @as(f32, @floatFromInt(total_modules))));
    const draw_size = module_px * @as(f32, @floatFromInt(total_modules));
    const start_x = @round(rect.x + (rect.w - draw_size) / 2.0 + module_px * @as(f32, @floatFromInt(quiet_modules)));
    const start_top = @round(rect.top_px + (rect.h - draw_size) / 2.0 + module_px * @as(f32, @floatFromInt(quiet_modules)));

    const black = .{ 0.03, 0.04, 0.05 };
    for (0..matrix.size) |y| {
        const y_top = start_top + module_px * @as(f32, @floatFromInt(y));
        const gl_y = @round(window_height - y_top - module_px);
        for (0..matrix.size) |x| {
            if (!matrix.isBlack(x, y)) continue;
            const gl_x = start_x + module_px * @as(f32, @floatFromInt(x));
            gl_init.renderQuadAlpha(gl_x, gl_y, module_px, module_px, black, 1.0);
        }
    }
}

fn renderQrFallback(l: panel.Layout, window_height: f32, normal: [3]f32) void {
    const qr_y = rectY(window_height, l.qr);
    const message = if (panel.qrGenerationFailed()) "二维码生成失败" else "正在获取二维码…";
    const msg_w = textWidth(message);
    const msg_y = qr_y + l.qr.h * 0.52;
    _ = titlebar.renderTextLimited(message, l.qr.x + @max(8.0, (l.qr.w - msg_w) / 2.0), msg_y, normal, l.qr.w - 16);
}

fn renderButton(rect: panel.Rect, window_height: f32, label: []const u8, base: [3]f32, text_color: [3]f32, primary: bool) void {
    const y = rectY(window_height, rect);
    const bg = if (primary) base else mix(AppWindow.g_theme.background, base, 0.30);
    const border = if (primary) mix(base, .{ 1.0, 1.0, 1.0 }, 0.18) else base;
    AppWindow.overlays.renderRoundedQuadAlpha(rect.x - 1, y - 1, rect.w + 2, rect.h + 2, 6, border, if (primary) 0.74 else 0.42);
    AppWindow.overlays.renderRoundedQuadAlpha(rect.x, y, rect.w, rect.h, 5, bg, if (primary) 0.92 else 0.58);
    const label_w = textWidth(label);
    const text_y = @round(y + (rect.h - font.g_titlebar_cell_height) / 2.0);
    _ = titlebar.renderTextLimited(label, rect.x + @max(8.0, (rect.w - label_w) / 2.0), text_y, text_color, rect.w - 16);
}

pub fn deinit() void {}
```

- [ ] **Step 2: 登记到 gl_backend_guard.zig**

`src/renderer/gpu/gl_backend_guard.zig` 用 `@embedFile` + 一个名单校验各渲染器只用许可的 GPU 调用。镜像 weixin 的三处:
- :44 旁加 `const src_feishu_qr = @embedFile("../feishu_qr_renderer.zig");`
- :66 与 :87 的名单各加一项 `.{ .name = "renderer/feishu_qr_renderer.zig", .source = src_feishu_qr },`

(若该 guard 实际不是这种名单结构,以 weixin 条目为准照抄一份对应飞书条目。)

> **执行顺序/合并说明(重要)**:本任务在 **Task 5 之后** 完成,并**与 Task 6 合并为一次实现**。原因:`feishu_qr_renderer.zig` 只有被 `AppWindow` import(Task 6)才进入编译图——`@embedFile`(guard)只嵌字节、不编译;fast suite 不引 AppWindow。因此渲染器无法单独编译验证。把"建渲染器 + 注册 guard"(本任务)与"AppWindow import/render/deinit/shutdown + input 路由"(Task 6)一起做,用 `zig build macos-app` 一次性编译验证。`applyFeishuRegistrationSuccess` 此时已由 Task 5 提供。

- [ ] **Step 3: 不单独验证(渲染器随 Task 6 一起编译)**

渲染器此刻不在编译图中(无人 import),`zig build test` 不会编译它。**不在此处单独 build**;继续做 Task 6 的 AppWindow import,使渲染器进入编译图后统一验证。

- [ ] **Step 4: 合并提交(见 Task 6)**

不单独提交渲染器;与 Task 6 的 AppWindow/input 改动一起验证后提交(见 Task 6 的提交步骤,git add 时包含 `src/renderer/feishu_qr_renderer.zig` 和 `src/renderer/gpu/gl_backend_guard.zig`)。

---

## Task 5: overlays.zig 接线(触发 / 动作 / 回填 / 渲染行)

**Files:**
- Modify: `src/renderer/overlays.zig`(import、SessionAction、enter/click/dispatch、render row、三个新函数)

**Interfaces:**
- Consumes: `feishu/registration.zig`(`start`/`cancel`)、`feishu/registration_panel.zig`(`open`/`close`/`takeSuccessCreds`/`visible`/`status`/`Action`/`executeAt`)。
- Produces(供 input.zig / 渲染器调用):
  - `pub fn startFeishuRegistration() void`
  - `pub fn feishuRegPanelHandleAction(action: feishu_reg_panel.Action) void`
  - `pub fn applyFeishuRegistrationSuccess() void`
  - `pub fn feishuRegPanelVisible() bool` / `pub fn feishuRegPanelStatus()`(给 input 用)

- [ ] **Step 1: 加 import**

在 overlays.zig 顶部 import 区(`const feishu_config = @import("overlays/feishu_config.zig");` 附近,:46)加:

```zig
const feishu_registration = @import("../feishu/registration.zig");
const feishu_reg_panel = @import("../feishu/registration_panel.zig");
```

- [ ] **Step 2: SessionAction 加 feishu_scan + dispatch**

`SessionAction` 枚举(含 `feishu_save` 的那个,:2251 附近)加成员 `feishu_scan,`。在其 dispatch(:2744 `.feishu_save => saveFeishuConfig(),` 旁)加:

```zig
        .feishu_scan => startFeishuRegistration(),
```

- [ ] **Step 3: enter 行处理加 SCAN_ROW**

`sessionLauncherHandleKeyImpl` 里飞书分支的 enter(:2592-2595)改为:

```zig
            .enter => switch (feishuConfig().focus) {
                feishu_config.SAVE_ROW => saveFeishuConfig(),
                feishu_config.SCAN_ROW => startFeishuRegistration(),
                else => feishuConfig().toggleFocusedBool(), // toggle rows flip; field rows no-op
            },
```

- [ ] **Step 4: 点击命中加 SCAN_ROW**

`sessionHitTest` 飞书分支(:4987-4992)改为:

```zig
    if (feishuForm().visible) {
        if (row >= FEISHU_ROW_COUNT) return null;
        feishuConfig().focus = row;
        if (row == feishu_config.SAVE_ROW) return .feishu_save;
        if (row == feishu_config.SCAN_ROW) return .feishu_scan;
        feishuConfig().toggleFocusedBool(); // toggle rows flip on click; field rows no-op
        return null;
    }
```

- [ ] **Step 5: 渲染多画一行**

`renderFeishuConfigForm`(:5182)在 international 行(:5189)与 app_id 行之间插入 scan 行:

```zig
    // Row 2: 扫码创建应用(动作行,右侧给一句提示)
    renderSessionRow(layout, window_height, feishu_config.SCAN_ROW, i18n.s().feishu_form_scan, i18n.s().feishu_form_scan_hint, st.focus == feishu_config.SCAN_ROW);
```

并把后面 app_id/app_secret/Save 行注释里的 "Row 2/3/4" 更新为 "Row 3/4/5"(纯注释,不影响逻辑,因为用的是命名常量)。

- [ ] **Step 6: 加 i18n 文案键**

在 `src/i18n.zig` 的字符串结构里加 `feishu_form_scan` 与 `feishu_form_scan_hint`,并在每个语言表里给值(参考既有 `feishu_form_save` 的填法)。中文:`feishu_form_scan = "扫码创建应用"`、`feishu_form_scan_hint = "用飞书扫码自动获取 app_id/secret"`;英文给对应英文。

> 用 `grep -n "feishu_form_save" src/i18n.zig` 找到所有需要补的语言表位置,逐个照 save 键补两行。

- [ ] **Step 7: 加三个新函数**

在 `saveFeishuConfig`(:3984)附近加:

```zig
fn startFeishuRegistration() void {
    const allocator = AppWindow.g_allocator orelse std.heap.page_allocator;
    feishu_registration.start(allocator, feishuConfig().international) catch {
        showStatusToast(i18n.s().toast_feishu_scan_failed);
        return;
    };
    feishu_reg_panel.open();
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

pub fn feishuRegPanelHandleAction(action: feishu_reg_panel.Action) void {
    switch (action) {
        .none => {},
        .close => {
            feishu_registration.cancel();
            feishu_reg_panel.close();
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        },
        .retry => {
            const allocator = AppWindow.g_allocator orelse std.heap.page_allocator;
            feishu_registration.start(allocator, feishuConfig().international) catch {
                showStatusToast(i18n.s().toast_feishu_scan_failed);
                return;
            };
            feishu_reg_panel.open();
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
        },
    }
}

/// 渲染层在检测到注册成功时调用:把凭据回填进飞书配置表单并关面板。
pub fn applyFeishuRegistrationSuccess() void {
    if (feishu_reg_panel.takeSuccessCreds()) |creds| {
        feishuConfig().setValue(.app_id, creds.app_id);
        if (creds.app_secret.len > 0) feishuConfig().setValue(.app_secret, creds.app_secret);
        showStatusToast(i18n.s().toast_feishu_scan_success);
    }
    feishu_registration.cancel();
    feishu_reg_panel.close();
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

pub fn feishuRegPanelVisible() bool {
    return feishu_reg_panel.visible();
}

pub fn feishuRegPanelExecuteAt(xpos: f64, ypos: f64, w: f32, h: f32, top: f32) feishu_reg_panel.Action {
    return feishu_reg_panel.executeAt(xpos, ypos, w, h, top);
}
```

- [ ] **Step 8: 加两个 toast 文案键**

在 i18n.zig 加 `toast_feishu_scan_failed`(中文"创建应用失败,请重试")、`toast_feishu_scan_success`(中文"应用已创建,凭据已回填,请保存")。逐语言表照 `toast_feishu_restart` 补。

- [ ] **Step 9: 编译(overlays 独立编译,不依赖渲染器)**

> 执行顺序修正:本任务在 Task 4/6 之前完成。overlays.zig 只 import `feishu_registration`(Task 2 ✅)与 `feishu_reg_panel`(Task 3 ✅),**不引用渲染器**,故可独立编译。新增的 `applyFeishuRegistrationSuccess`/`feishuRegPanelVisible/ExecuteAt/HandleAction` 都是 `pub fn`,未被调用也不报 unused。

Run: `zig build test` 和 `zig build macos-app`
Expected: 均 PASS(overlays + i18n 编译进 app;渲染器尚未存在,但 overlays 不依赖它)。

- [ ] **Step 10: Commit**

```bash
git add src/renderer/overlays.zig src/i18n.zig
git commit -m "feat(feishu): wire scan-row trigger, panel actions, credential fill-back"
```

---

## Task 6: input.zig + AppWindow.zig 接线(渲染管线 + 输入路由)

**Files:**
- Modify: `src/AppWindow.zig`(:111-112 import、:4400 与 :7121 render、:7204 deinit)
- Modify: `src/input.zig`(:2681 字符吞噬、:3133 键、:5316 点击)

**Interfaces:**
- Consumes: `AppWindow.feishu_reg_renderer`、`overlays.feishuRegPanelVisible/HandleAction/ExecuteAt`、`feishu_reg_panel.status()`。

- [ ] **Step 1: AppWindow import 面板与渲染器**

`src/AppWindow.zig:111-112`(weixin 两行旁)加:

```zig
const feishu_registration = @import("feishu/registration.zig");
pub const feishu_reg_panel = @import("feishu/registration_panel.zig");
const feishu_reg_renderer = @import("renderer/feishu_qr_renderer.zig");
```

- [ ] **Step 2: 两处 render pass 调用**

`:4400` 与 `:7121` 的 `weixin_qr_renderer.render(...)` 行**后面**各加一行(飞书面板叠在微信之上即可,二者互斥):

```zig
    feishu_reg_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
```

(注意 :7121 那处缩进多一层,照该块现有缩进。)

- [ ] **Step 3: deinit 清理**

`:7204` 的 `weixin_qr_renderer.deinit(); weixin_qr_panel.deinit();` 后加(`shutdown()` 停并 join 注册轮询线程,关闭 Task 2 评审标记的线程泄漏):

```zig
    feishu_reg_renderer.deinit();
    feishu_reg_panel.deinit();
    feishu_registration.shutdown();
```

- [ ] **Step 4: input.zig 字符吞噬**

`:2681` `if (weixinQrPanelConsumesChar()) return .none;` 后加:

```zig
    if (overlays.feishuRegPanelVisible()) return .none;
```

- [ ] **Step 5: input.zig 键处理(esc 关 / enter 在可重试态 retry)**

`:3133` 的 weixin 面板键块后加一个平行块:

```zig
    if (overlays.feishuRegPanelVisible()) {
        switch (ev.key_code) {
            platform_input.key_escape => overlays.feishuRegPanelHandleAction(.close),
            platform_input.key_enter => {
                const s = AppWindow.feishu_reg_panel.status();
                if (s == .expired or s == .denied or s == .err) overlays.feishuRegPanelHandleAction(.retry);
            },
            else => {},
        }
        return .none;
    }
```

- [ ] **Step 6: input.zig 鼠标点击**

`:5316` weixin 的鼠标块(`if (AppWindow.weixin_qr_panel.visible()) { ... executeAt ... }`,即 :5305 起那段)后加一个平行块(复用同样的 fb/坐标计算):

```zig
    if (overlays.feishuRegPanelVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const fb = window_backend.framebufferSize(win);
            const w_f: f32 = @floatFromInt(fb.width);
            const h_f: f32 = @floatFromInt(fb.height);
            const top_offset: f32 = @floatCast(titlebarHeight());
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            overlays.feishuRegPanelHandleAction(overlays.feishuRegPanelExecuteAt(xpos, ypos, w_f, h_f, top_offset));
        }
        return;
    }
```

(以 :5305-5319 weixin 块的实际取值方式为准照抄,只把 panel 换成飞书的;weixin 块若有外层 `if visible` 守卫,保持同构。)

- [ ] **Step 7: 编译 + 全量测试**

Run: `zig build test` 然后 `zig build test-full -Dtarget=aarch64-macos`
Expected: 均 PASS(忽略已知无关 flaky)。

- [ ] **Step 8: Commit**

```bash
git add src/AppWindow.zig src/input.zig
git commit -m "feat(feishu): mount registration panel in render pass and input routing"
```

---

## Task 7: 真机端到端验证

**Files:** 无(手动验证)

- [ ] **Step 1: 构建 app**

Run: `zig build macos-app`
Expected: 构建成功,产出 macOS app bundle。

- [ ] **Step 2: 打开飞书配置表单**

启动 app → 命令面板 → "Configure Feishu"(`.configure_feishu`)→ 出现 6 行表单,第 3 行为「扫码创建应用」。

- [ ] **Step 3: 触发扫码,确认二维码渲染**

焦点移到「扫码创建应用」行按回车(或点击)→ 弹出二维码面板,标题"创建飞书应用",状态由"正在申请"转为"等待扫码",二维码出现。

- [ ] **Step 4: 真机扫码(可选,需真实飞书账号)**

用飞书 App 扫码并确认创建。**不动鼠标键盘**观察:面板应在确认后约一个轮询周期内自动关闭,表单的 app_id/app_secret 已回填,弹出"应用已创建"toast。
- 若必须动一下输入面板才更新 → 说明事件驱动渲染没被 worker 线程唤醒:在 `registration.zig` 的 `setStatus`/`setCreds`/`setVerifyUrl` 末尾加 `@import("../platform/window_backend.zig").postWakeup();`(参见记忆 event-driven-wakeup),重测。

- [ ] **Step 5: 边界:Close / 过期 / 拒绝**

- 申请后点 Close → 面板关闭,后台轮询停止(`cancel`)。
- 等二维码过期(或服务端返回 expired)→ 状态变"已过期",出现 Retry,点 Retry 重新申请。

- [ ] **Step 6: 保存生效**

回填后焦点到 Save 行回车 → `saveFeishuConfig` 写入 `feishu-app-id`/`feishu-app-secret`,提示重启生效。重启后飞书 bot 应能用新凭据连上。

---

## Self-Review

**Spec coverage(对照 spec 各节)**
- 协议 begin/poll/状态机/不判status/切域 → Task 2(`decide` + `threadMain` + `postForm`)。✓
- 端点 accounts 域 + form-urlencoded → Task 2 `accountsBase`/`postForm`。✓
- 复用 qr_code.zig、复制 panel/renderer(方案 A)→ Task 3/4。✓
- 入口=配置表单内按钮、成功回填表单 → Task 1/5。✓
- 线程/mutex/threadlocal 边界、安全不变量 → Task 2(全局+mutex)/Task 3(threadlocal)。✓
- 砍掉 addons/preset/命令面板/ASCII 二维码/自动 Save → 计划未实现,符合非目标。✓
- 测试:registration 纯状态机(fast)、panel(test-full)、feishu_config(fast)→ Task 1/2/3。✓
- 风险:qr 容量(version 10 足够,Global Constraints 已记)、form 编码(`appendFormValue` + 测试)、不判 status(`postForm` 注释 + 约束)。✓

**Placeholder scan**:无 TBD/TODO;每个改动步给了真实代码或明确 grep 指引(i18n 多语言表逐键补,因表结构随语言数变动,用 grep 定位而非硬编码行号)。✓

**Type consistency**:`StatusKind`(registration 定义,panel `pub const StatusKind = registration.StatusKind` 复用)、`Action{none,retry,close}`(panel 定义,overlays/input 引用一致)、`Snapshot`/`Creds`/`RefreshResult` 字段名跨 Task 2→3→5 一致;`SCAN_ROW` 跨 Task 1→5 一致;`applyFeishuRegistrationSuccess`/`feishuRegPanelVisible`/`feishuRegPanelExecuteAt`/`feishuRegPanelHandleAction` 在 Task 5 定义、Task 4/6 引用,命名一致。✓

> 注:i18n 键(`feishu_form_scan`、`feishu_form_scan_hint`、`toast_feishu_scan_failed`、`toast_feishu_scan_success`)需在所有语言表补齐,否则 i18n 结构体编译不过——Task 5 Step 6/8 用 grep 法覆盖全部语言。
