//! Throwaway spike: de-risk Feishu CardKit streaming-card API shapes.
//! Run: source ~/.zshrc && zig run src/feishu/spike/cardkit.zig
//! Reads FEISHU_APP_ID / FEISHU_APP_SECRET (required) and FEISHU_TEST_CHAT_ID
//! (optional; if absent the spike lists chats so we can pick one).
//! Prints every request path + response status + body so we can capture the
//! exact endpoints / request bodies / response field paths into the protocol
//! notes. NOT production code; cleaned up after the shapes are confirmed.

const std = @import("std");

const BASE = "https://open.feishu.cn";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const app_id = std.posix.getenv("FEISHU_APP_ID") orelse return err("FEISHU_APP_ID missing");
    const app_secret = std.posix.getenv("FEISHU_APP_SECRET") orelse return err("FEISHU_APP_SECRET missing");
    const test_chat = std.posix.getenv("FEISHU_TEST_CHAT_ID"); // optional

    // --- 1. tenant_access_token -------------------------------------------
    const tok_body = try std.json.Stringify.valueAlloc(a, .{ .app_id = app_id, .app_secret = app_secret }, .{});
    const tok_resp = try httpReq(a, .POST, BASE ++ "/open-apis/auth/v3/tenant_access_token/internal", null, tok_body, "TOKEN");
    const token = try extractString(a, tok_resp, "tenant_access_token") orelse return err("no token in response");
    std.debug.print("\n[TOKEN] got token (len={d})\n", .{token.len});

    // --- 2. create streaming card -----------------------------------------
    // Card JSON 2.0 with streaming_mode + a single markdown element id="md".
    const card_json = try std.json.Stringify.valueAlloc(a, .{
        .schema = "2.0",
        .config = .{ .streaming_mode = true },
        .body = .{
            .elements = .{
                .{ .tag = "markdown", .element_id = "md", .content = "处理中…" },
            },
        },
    }, .{});

    // Guess: POST /open-apis/cardkit/v1/cards  body {type:"card_json", data:<card_json string>}
    const create_body = try std.json.Stringify.valueAlloc(a, .{ .type = "card_json", .data = card_json }, .{});
    const create_resp = try httpReq(a, .POST, BASE ++ "/open-apis/cardkit/v1/cards", token, create_body, "CREATE_CARD");
    const card_id = (try extractString(a, create_resp, "card_id")) orelse {
        std.debug.print("\n[CREATE_CARD] no card_id — inspect body above, adjust endpoint/body, re-run.\n", .{});
        return;
    };
    std.debug.print("\n[CREATE_CARD] card_id={s}\n", .{card_id});

    // --- 3. send the card to the chat (only if we have a chat_id) ---------
    // The stream/close endpoints target card_id and need no chat; only the
    // visual confirmation needs the card delivered to a chat.
    const chat_id: ?[]const u8 = test_chat;
    if (chat_id) |cid| {
        // Guess: msg_type "interactive", content references card_id.
        const content = try std.json.Stringify.valueAlloc(a, .{ .type = "card", .data = .{ .card_id = card_id } }, .{});
        const send_body = try std.json.Stringify.valueAlloc(a, .{
            .receive_id = cid,
            .msg_type = "interactive",
            .content = content,
        }, .{});
        _ = try httpReq(a, .POST, BASE ++ "/open-apis/im/v1/messages?receive_id_type=chat_id", token, send_body, "SEND_CARD");
    } else {
        std.debug.print("\n[SEND_CARD] no FEISHU_TEST_CHAT_ID — skipping send (no visual). Still confirming stream/close shapes below.\n", .{});
    }

    // --- 5. stream two content updates ------------------------------------
    // Guess: POST /open-apis/cardkit/v1/cards/:card_id/elements/:element_id/content
    const stream_url = try std.fmt.allocPrint(a, BASE ++ "/open-apis/cardkit/v1/cards/{s}/elements/md/content", .{card_id});
    const upd1 = try std.json.Stringify.valueAlloc(a, .{ .content = "🔧 正在执行 read_file…", .sequence = 1 }, .{});
    _ = try httpReq(a, .PUT, stream_url, token, upd1, "STREAM_1");
    const upd2 = try std.json.Stringify.valueAlloc(a, .{ .content = "🔧 正在执行 read_file…\n✅ 完成，这是结果。", .sequence = 2 }, .{});
    _ = try httpReq(a, .PUT, stream_url, token, upd2, "STREAM_2");

    // --- 6. close streaming -----------------------------------------------
    // Guess: PATCH /open-apis/cardkit/v1/cards/:card_id/settings
    const settings_url = try std.fmt.allocPrint(a, BASE ++ "/open-apis/cardkit/v1/cards/{s}/settings", .{card_id});
    const close_body = try std.json.Stringify.valueAlloc(a, .{ .settings = "{\"config\":{\"streaming_mode\":false}}", .sequence = 3 }, .{});
    _ = try httpReq(a, .PATCH, settings_url, token, close_body, "CLOSE_STREAM");

    std.debug.print("\n[DONE] check Feishu: card should have streamed then frozen.\n", .{});
}

fn err(msg: []const u8) error{Spike} {
    std.debug.print("ERROR: {s}\n", .{msg});
    return error.Spike;
}

fn httpReq(
    a: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    token: ?[]const u8,
    body: ?[]const u8,
    label: []const u8,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = a };
    defer client.deinit();

    var out: std.Io.Writer.Allocating = .init(a);
    var headers: std.http.Client.Request.Headers = .{ .content_type = .{ .override = "application/json; charset=utf-8" } };
    var auth_buf: []u8 = &.{};
    if (token) |t| {
        auth_buf = try std.fmt.allocPrint(a, "Bearer {s}", .{t});
        headers.authorization = .{ .override = auth_buf };
    }

    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .keep_alive = false,
        .payload = body,
        .headers = headers,
        .response_writer = &out.writer,
    });

    const resp_body = out.toArrayList().items;
    // Redact the token response body — it carries a secret we must never
    // persist into fixtures/logs.
    const shown: []const u8 = if (std.mem.eql(u8, label, "TOKEN")) "<redacted: contains tenant_access_token>" else resp_body;
    std.debug.print("\n[{s}] {s} {s}\n  status={d}\n  body={s}\n", .{ label, @tagName(method), pathOf(url), @intFromEnum(response.status), shown });
    return resp_body;
}

fn pathOf(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return url;
    const after = url[scheme_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return after;
    return after[slash..];
}

/// Minimal recursive scan for a string field `key` anywhere in the JSON.
fn extractString(a: std.mem.Allocator, json: []const u8, key: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return null;
    return findString(parsed.value, key);
}

fn findString(v: std.json.Value, key: []const u8) ?[]const u8 {
    switch (v) {
        .object => |o| {
            if (o.get(key)) |found| {
                if (found == .string) return found.string;
            }
            var it = o.iterator();
            while (it.next()) |entry| {
                if (findString(entry.value_ptr.*, key)) |s| return s;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (findString(item, key)) |s| return s;
            }
        },
        else => {},
    }
    return null;
}
