//! Feishu long-connection spike (M0).
//! Proves two things:
//!   1. tenant_access_token can be obtained via the internal auth endpoint.
//!   2. The WS endpoint-discovery API returns a wss:// address.
//!
//! Credentials are read exclusively from env vars FEISHU_APP_ID and
//! FEISHU_APP_SECRET — never from any file or literal.
//!
//! Run (standalone, only std used):
//!   FEISHU_APP_ID=... FEISHU_APP_SECRET=... zig run src/feishu/spike/discover.zig
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // --- read credentials from env ---
    const app_id = std.process.getEnvVarOwned(alloc, "FEISHU_APP_ID") catch |err| {
        std.debug.print("ERROR: FEISHU_APP_ID not set ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer alloc.free(app_id);

    const app_secret = std.process.getEnvVarOwned(alloc, "FEISHU_APP_SECRET") catch |err| {
        std.debug.print("ERROR: FEISHU_APP_SECRET not set ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer alloc.free(app_secret);

    // ---------------------------------------------------------------
    // Step 1: tenant_access_token
    // POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal
    // ---------------------------------------------------------------
    std.debug.print("[1] Requesting tenant_access_token...\n", .{});

    const token_body = try std.fmt.allocPrint(alloc,
        \\{{"app_id":"{s}","app_secret":"{s}"}}
    , .{ app_id, app_secret });
    defer alloc.free(token_body);

    var arena1 = std.heap.ArenaAllocator.init(alloc);
    defer arena1.deinit();
    const a1 = arena1.allocator();

    const token_resp = try httpsPost(
        alloc,
        a1,
        "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
        token_body,
    );

    // Parse: {"code":0,"tenant_access_token":"t-...","expire":7200}
    const TokenResp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        tenant_access_token: []const u8 = "",
        expire: i64 = 0,
    };
    const tp = try std.json.parseFromSliceLeaky(TokenResp, a1, token_resp, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    if (tp.code != 0) {
        std.debug.print("[1] FAILED  code={d} msg={s}\n", .{ tp.code, tp.msg });
        std.process.exit(1);
    }
    // ponytail: token value never printed — only existence confirmed
    std.debug.print("[1] OK  expire={d}s\n", .{tp.expire});

    // ---------------------------------------------------------------
    // Step 2: endpoint discovery
    // POST https://open.feishu.cn/callback/ws/endpoint
    // Note: keys are AppID / AppSecret (SDK convention, initial-caps)
    // ---------------------------------------------------------------
    std.debug.print("[2] Requesting WS endpoint...\n", .{});

    const ep_body = try std.fmt.allocPrint(alloc,
        \\{{"AppID":"{s}","AppSecret":"{s}"}}
    , .{ app_id, app_secret });
    defer alloc.free(ep_body);

    var arena2 = std.heap.ArenaAllocator.init(alloc);
    defer arena2.deinit();
    const a2 = arena2.allocator();

    const ep_resp = try httpsPost(
        alloc,
        a2,
        "https://open.feishu.cn/callback/ws/endpoint",
        ep_body,
    );

    // {"code":0,"data":{"URL":"wss://...","ClientConfig":{...}}}
    // Known error codes: AuthFailed=514, ExceedConnLimit=1000040350
    const ClientConfig = struct {
        ReconnectCount: i64 = 0,
        ReconnectInterval: i64 = 0,
        ReconnectNonce: i64 = 0,
        PingInterval: i64 = 0,
    };
    const EndpointData = struct {
        URL: []const u8 = "",
        ClientConfig: ClientConfig = .{},
    };
    const EndpointResp = struct {
        code: i64 = -1,
        msg: []const u8 = "",
        data: EndpointData = .{},
    };
    const ep = try std.json.parseFromSliceLeaky(EndpointResp, a2, ep_resp, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    if (ep.code != 0) {
        std.debug.print("[2] FAILED  code={d} msg={s}\n", .{ ep.code, ep.msg });
        std.process.exit(1);
    }

    // Print only scheme+host+path; strip query (may contain connection token).
    const wss_url = ep.data.URL;
    const host_path = stripQuery(wss_url);
    std.debug.print("[2] OK  wss_host_path={s}  (query=<redacted>)\n", .{host_path});

    const cfg = ep.data.ClientConfig;
    std.debug.print(
        "    ClientConfig: ReconnectCount={d} ReconnectInterval={d}ms ReconnectNonce={d} PingInterval={d}ms\n",
        .{ cfg.ReconnectCount, cfg.ReconnectInterval, cfg.ReconnectNonce, cfg.PingInterval },
    );

    std.debug.print("\nSpike DONE.\n", .{});
}

/// Returns the portion of `url` up to (but not including) the '?' query.
fn stripQuery(url: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    return url[0..q];
}

/// Perform a single HTTPS POST with JSON body, returns response body bytes
/// allocated in `resp_arena`. Uses `alloc` for the http.Client itself.
fn httpsPost(
    alloc: std.mem.Allocator,
    resp_arena: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var out: std.Io.Writer.Allocating = .init(resp_arena);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .keep_alive = false,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/json; charset=utf-8" } },
        .response_writer = &out.writer,
    });

    if (response.status != .ok) {
        const excerpt = out.toArrayList().items;
        std.debug.print("HTTP error {}: {s}\n", .{ response.status, excerpt[0..@min(excerpt.len, 256)] });
        return error.HttpError;
    }
    return out.toArrayList().items;
}
