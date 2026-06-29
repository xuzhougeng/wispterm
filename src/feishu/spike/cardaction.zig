//! Throwaway spike: de-risk Feishu card.action.trigger callbacks + whether a
//! button on a STREAMING card is clickable.
//! Run: source ~/.zshrc && FEISHU_TEST_CHAT_ID=oc_... zig run src/feishu/spike/cardaction.zig
//! Sends two cards to the chat:
//!   1. a STATIC interactive card with a button (value {"act":"test_static"})
//!   2. a STREAMING card (streaming_mode) with a button (value {"act":"test_stream"})
//! Then YOU click both buttons in Feishu; the running app's SPIKE log
//! (longconn.zig temp log) captures the inbound card.action.trigger frames so
//! we can read the payload shape + see if the streaming-card button fired.
//! NOT production. Token print redacted.

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
    const chat = std.posix.getenv("FEISHU_TEST_CHAT_ID") orelse return err("FEISHU_TEST_CHAT_ID missing");

    // token
    const tok_body = try std.json.Stringify.valueAlloc(a, .{ .app_id = app_id, .app_secret = app_secret }, .{});
    const tok_resp = try httpReq(a, .POST, BASE ++ "/open-apis/auth/v3/tenant_access_token/internal", null, tok_body, "TOKEN");
    const token = (try extractString(a, tok_resp, "tenant_access_token")) orelse return err("no token");
    std.debug.print("\n[TOKEN] ok (len={d})\n", .{token.len});

    // --- 1. STATIC interactive card with a button --------------------------
    // Card JSON 2.0; a button element with a callback behavior carrying a value.
    const static_card =
        \\{"schema":"2.0","body":{"elements":[
        \\{"tag":"markdown","content":"**静态卡片** — 请点下面按钮(测 card.action.trigger)"},
        \\{"tag":"button","text":{"tag":"plain_text","content":"点我 (static)"},"type":"primary","behaviors":[{"type":"callback","value":{"act":"test_static","foo":"bar"}}]}
        \\]}}
    ;
    const static_msg = try std.json.Stringify.valueAlloc(a, .{
        .receive_id = chat,
        .msg_type = "interactive",
        .content = static_card,
    }, .{});
    _ = try httpReq(a, .POST, BASE ++ "/open-apis/im/v1/messages?receive_id_type=chat_id", token, static_msg, "SEND_STATIC");

    // --- 2. STREAMING card with a button (Spike B) -------------------------
    const stream_card =
        \\{"schema":"2.0","config":{"streaming_mode":true},"body":{"elements":[
        \\{"tag":"markdown","element_id":"md","content":"**流式卡片** — 处理中… 请点停止按钮(测流式卡片按钮可点性)"},
        \\{"tag":"button","text":{"tag":"plain_text","content":"⏹ 停止 (stream)"},"type":"danger","behaviors":[{"type":"callback","value":{"act":"test_stream"}}]}
        \\]}}
    ;
    const create_body = try std.json.Stringify.valueAlloc(a, .{ .type = "card_json", .data = stream_card }, .{});
    const create_resp = try httpReq(a, .POST, BASE ++ "/open-apis/cardkit/v1/cards", token, create_body, "CREATE_STREAM_CARD");
    if (try extractString(a, create_resp, "card_id")) |card_id| {
        std.debug.print("\n[CREATE_STREAM_CARD] card_id={s}\n", .{card_id});
        const content = try std.json.Stringify.valueAlloc(a, .{ .type = "card", .data = .{ .card_id = card_id } }, .{});
        const send_body = try std.json.Stringify.valueAlloc(a, .{ .receive_id = chat, .msg_type = "interactive", .content = content }, .{});
        const send_resp = try httpReq(a, .POST, BASE ++ "/open-apis/im/v1/messages?receive_id_type=chat_id", token, send_body, "SEND_STREAM_CARD");

        // --- FINALIZE-PATCH test: replace the streaming card with a button-less resolved card ---
        if (try extractString(a, send_resp, "message_id")) |mid| {
            std.debug.print("\n[FINALIZE] message_id={s}\n", .{mid});
            // 1. close streaming first (settings streaming_mode:false).
            const settings_url = try std.fmt.allocPrint(a, BASE ++ "/open-apis/cardkit/v1/cards/{s}/settings", .{card_id});
            const close_body = try std.json.Stringify.valueAlloc(a, .{ .settings = "{\"config\":{\"streaming_mode\":false}}", .sequence = 99 }, .{});
            _ = try httpReq(a, .PATCH, settings_url, token, close_body, "CLOSE_STREAM");
            // 2. patch the MESSAGE to a button-less resolved card (inline card json string).
            const resolved_card = "{\"schema\":\"2.0\",\"body\":{\"elements\":[{\"tag\":\"markdown\",\"content\":\"✅ 已完成(无按钮)\"}]}}";
            const patch_url = try std.fmt.allocPrint(a, BASE ++ "/open-apis/im/v1/messages/{s}", .{mid});
            const patch_body = try std.json.Stringify.valueAlloc(a, .{ .content = resolved_card }, .{});
            _ = try httpReq(a, .PATCH, patch_url, token, patch_body, "PATCH_MESSAGE");
            std.debug.print("\n[FINALIZE] If the 2nd card became '✅ 已完成(无按钮)' with NO stop button → patch-on-streaming-card works.\n", .{});
        }
    } else {
        std.debug.print("\n[CREATE_STREAM_CARD] no card_id — inspect body above.\n", .{});
    }

    std.debug.print("\n[DONE] Click the STATIC card button; check the streaming card's FINALIZE result.\n", .{});
}

fn err(msg: []const u8) error{Spike} {
    std.debug.print("ERROR: {s}\n", .{msg});
    return error.Spike;
}

fn httpReq(a: std.mem.Allocator, method: std.http.Method, url: []const u8, token: ?[]const u8, body: ?[]const u8, label: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = a };
    defer client.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    var headers: std.http.Client.Request.Headers = .{ .content_type = .{ .override = "application/json; charset=utf-8" } };
    if (token) |t| headers.authorization = .{ .override = try std.fmt.allocPrint(a, "Bearer {s}", .{t}) };
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .keep_alive = false,
        .payload = body,
        .headers = headers,
        .response_writer = &out.writer,
    });
    const resp_body = out.toArrayList().items;
    const shown: []const u8 = if (std.mem.eql(u8, label, "TOKEN")) "<redacted>" else resp_body;
    std.debug.print("\n[{s}] {s} status={d}\n  body={s}\n", .{ label, @tagName(method), @intFromEnum(response.status), shown });
    return resp_body;
}

fn extractString(a: std.mem.Allocator, json: []const u8, key: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return null;
    return findString(parsed.value, key);
}

fn findString(v: std.json.Value, key: []const u8) ?[]const u8 {
    switch (v) {
        .object => |o| {
            if (o.get(key)) |found| if (found == .string) return found.string;
            var it = o.iterator();
            while (it.next()) |e| if (findString(e.value_ptr.*, key)) |s| return s;
        },
        .array => |arr| for (arr.items) |item| {
            if (findString(item, key)) |s| return s;
        },
        else => {},
    }
    return null;
}
