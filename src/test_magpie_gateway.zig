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
    const api = protocol.ApiProtocol.parse(codec.aiProfileField(&profile, .protocol));
    const url = try protocol.apiEndpoint(a, codec.aiProfileField(&profile, .base_url), api);
    defer a.free(url);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{codec.aiProfileField(&profile, .api_key)});
    defer a.free(auth);
    const expected_vision = std.process.getEnvVarOwned(a, "MAGPIE_TEST_VISION") catch null;
    defer if (expected_vision) |expected| a.free(expected);
    if (expected_vision) |expected| {
        if (!std.mem.eql(u8, expected, codec.aiProfileField(&profile, .vision))) return error.UnexpectedVisionSetting;
    }
    // Stands in for `/effort` or the header chip: a level the model lists
    // replaces the default for this request; any other level is refused.
    const requested_effort = std.process.getEnvVarOwned(a, "MAGPIE_TEST_REASONING_EFFORT") catch null;
    defer if (requested_effort) |requested| a.free(requested);
    var effort = codec.aiProfileField(&profile, .reasoning_effort);
    if (requested_effort) |requested| {
        if (profile.efforts.contains(requested)) effort = requested;
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
        .system_prompt = codec.aiProfileField(&profile, .system_prompt),
        .protocol = api,
        .thinking_enabled = !std.mem.eql(u8, codec.aiProfileField(&profile, .thinking), "disabled"),
        .reasoning_effort = effort,
        .max_tokens = try std.fmt.parseInt(u32, codec.aiProfileField(&profile, .max_tokens), 10),
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
    if (response.status != 200) {
        std.debug.print("fixture gateway status {d}: {s}\n", .{ response.status, response.body[0..@min(response.body.len, 1024)] });
        return error.GatewayFailed;
    }
    const result = try protocol.parseApiResponse(a, response.body, api);
    defer result.deinit(a);
    if (!std.mem.eql(u8, result.content, "fixture-ok")) return error.UnexpectedFixtureResponse;
    std.debug.print("fixture-ok\n", .{});
}
