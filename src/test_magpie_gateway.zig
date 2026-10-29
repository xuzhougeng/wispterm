//! Opt-in probe for magpie-agents' isolated gateway test. No personal config.
const std = @import("std");
const magpie = @import("assistant/profile/magpie.zig");
const codec = @import("renderer/overlays/profile_codec.zig");
const protocol = @import("assistant/conversation/protocol.zig");
const http = @import("platform/http_client.zig");

pub fn main() !void {
    const a = std.heap.page_allocator;
    const path = try std.process.getEnvVarOwned(a, "MAGPIE_TEST_CONFIG");
    defer a.free(path);
    const profile = magpie.loadFromPath(a, path) orelse return error.InactiveFixture;
    const url = try protocol.apiEndpoint(a, codec.aiProfileField(&profile, .base_url), .chat_completions);
    defer a.free(url);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{codec.aiProfileField(&profile, .api_key)});
    defer a.free(auth);
    const expected_vision = std.process.getEnvVarOwned(a, "MAGPIE_TEST_VISION") catch null;
    defer if (expected_vision) |expected| a.free(expected);
    if (expected_vision) |expected| {
        if (!std.mem.eql(u8, expected, codec.aiProfileField(&profile, .vision))) return error.UnexpectedVisionSetting;
    }
    // A real one-pixel PNG, passed through the application's request builder.
    var images = [_]protocol.ImageBlock{.{
        .media_type = @constCast("image/png"),
        .data_b64 = @constCast("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="),
    }};
    var messages = [_]protocol.RequestMessage{.{
        .role = .user,
        .content = @constCast("fixture"),
        .images = if (expected_vision != null and std.mem.eql(u8, codec.aiProfileField(&profile, .vision), "on")) &images else null,
    }};
    const body = try protocol.buildRequestJson(a, .{
        .model = codec.aiProfileField(&profile, .model),
        .system_prompt = "",
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
    }, &messages, false);
    defer a.free(body);
    var response = try http.fetch(a, .{
        .method = .POST,
        .url = url,
        .body = body,
        .headers = &.{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "Authorization", .value = auth } },
    });
    defer response.deinit(a);
    if (response.status != 200) return error.GatewayFailed;
    const payload = try std.json.parseFromSlice(std.json.Value, a, response.body, .{});
    defer payload.deinit();
    const content = payload.value.object.get("choices").?.array.items[0].object.get("message").?.object.get("content").?.string;
    if (!std.mem.eql(u8, content, "fixture-ok")) return error.UnexpectedFixtureResponse;
    std.debug.print("fixture-ok\n", .{});
}
