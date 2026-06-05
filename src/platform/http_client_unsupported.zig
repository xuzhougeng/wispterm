const std = @import("std");
const http_client = @import("http_client.zig");

pub fn fetch(allocator: std.mem.Allocator, request: http_client.Request) !http_client.Response {
    return http_client.fetchWithStdHttp(allocator, request);
}
