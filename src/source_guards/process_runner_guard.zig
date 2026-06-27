//! Process capture guard. Modules that have adopted `process_runner.runCapture`
//! for bounded stdout/stderr capture should not grow a second direct
//! `std.process.Child.init` lifecycle again. Long-lived tunnels/servers stay
//! out of this guard until they have a matching runner abstraction.

const std = @import("std");

const GuardedSource = struct {
    name: []const u8,
    source: []const u8,
};

const guarded = [_]GuardedSource{
    .{ .name = "tools/import.zig", .source = @embedFile("../tools/import.zig") },
    .{ .name = "platform/remote_file.zig", .source = @embedFile("../platform/remote_file.zig") },
};

test "process capture owners use process_runner instead of direct Child.init" {
    var failed = false;
    for (guarded) |g| {
        if (std.mem.indexOf(u8, g.source, "std.process.Child.init") != null) {
            std.debug.print(
                "process_runner_guard: {s} directly initializes std.process.Child. " ++
                    "Use process_runner.runCapture for bounded capture paths.\n",
                .{g.name},
            );
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}
