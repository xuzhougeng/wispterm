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
    const body = try std.json.Stringify.valueAlloc(a, .{
        .model = codec.aiProfileField(&profile, .model),
        .messages = .{.{ .role = "user", .content = "fixture" }},
        .stream = false,
    }, .{});
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
