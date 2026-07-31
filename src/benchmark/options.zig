//! wispterm-bench CLI options. Pure parse logic so it is unit-tested in the
//! fast suite without spawning the bench binary (which links ghostty-vt).

const std = @import("std");

pub const Options = struct {
    /// Per-case run mode. `duration_ms` drives a fixed-window run; 0 means the
    /// default (a single `once` step), which is useful for smoke-checking.
    duration_ms: u64 = 0,
    /// If non-empty, only cases whose names match are run. Empty = run all.
    only: ?[]const u8 = null,
    list: bool = false,
    help: bool = false,
    /// Allocator the parsed `only` string is duped into, so the caller owns it.
    allocator: std.mem.Allocator,
    _only_owned: ?[]u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._only_owned) |o| self.allocator.free(o);
    }
};

pub const ParseError = error{
    MissingValue,
    InvalidDuration,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) ParseError!Options {
    var opts: Options = .{ .allocator = allocator };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--help") or eql(arg, "-h")) {
            opts.help = true;
        } else if (eql(arg, "--list")) {
            opts.list = true;
        } else if (eql(arg, "--duration")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.duration_ms = parseDuration(args[i]) catch return error.InvalidDuration;
        } else if (eql(arg, "--case")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            if (opts._only_owned) |o| allocator.free(o);
            opts._only_owned = try allocator.dupe(u8, args[i]);
            opts.only = opts._only_owned;
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            opts.duration_ms = parseDuration(arg["--duration=".len..]) catch return error.InvalidDuration;
        } else if (std.mem.startsWith(u8, arg, "--case=")) {
            if (opts._only_owned) |o| allocator.free(o);
            opts._only_owned = try allocator.dupe(u8, arg["--case=".len..]);
            opts.only = opts._only_owned;
        } else {
            // Unknown args are ignored so the CLI stays forgiving; listing the
            // known set is `--help`'s job.
        }
    }
    return opts;
}

fn parseDuration(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidDuration;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub const USAGE =
    \\wispterm-bench — WispTerm CPU-side benchmark CLI (Ghostty-aligned)
    \\
    \\Usage:
    \\  wispterm-bench [options]
    \\
    \\Options:
    \\  --list              List available benchmark cases and exit
    \\  --case <name>       Run only the named case (default: run all)
    \\  --duration <ms>     Per-case run window in milliseconds (default: 1000)
    \\  --help, -h          Show this help
    \\
    \\Build with:
    \\  zig build -Demit-bench -Doptimize=ReleaseFast
    \\
    \\Compare branches with hyperfine; keep inputs/flags identical across runs.
    \\
;

test "parse: defaults" {
    var opts = try parse(std.testing.allocator, &.{});
    defer opts.deinit();
    try std.testing.expectEqual(@as(u64, 0), opts.duration_ms);
    try std.testing.expect(opts.only == null);
    try std.testing.expect(!opts.list);
    try std.testing.expect(!opts.help);
}

test "parse: --list and --help flags" {
    var opts = try parse(std.testing.allocator, &.{ "--list", "--help" });
    defer opts.deinit();
    try std.testing.expect(opts.list);
    try std.testing.expect(opts.help);
}

test "parse: --duration accepts integer milliseconds" {
    var opts = try parse(std.testing.allocator, &.{ "--duration", "250" });
    defer opts.deinit();
    try std.testing.expectEqual(@as(u64, 250), opts.duration_ms);
}

test "parse: --duration=eq form" {
    var opts = try parse(std.testing.allocator, &.{"--duration=500"});
    defer opts.deinit();
    try std.testing.expectEqual(@as(u64, 500), opts.duration_ms);
}

test "parse: --case dups name into owned storage" {
    var opts = try parse(std.testing.allocator, &.{ "--case", "terminal-stream" });
    defer opts.deinit();
    try std.testing.expectEqualStrings("terminal-stream", opts.only.?);
}

test "parse: missing --duration value returns MissingValue" {
    try std.testing.expectError(error.MissingValue, parse(std.testing.allocator, &.{"--duration"}));
}

test "parse: non-numeric duration returns InvalidDuration" {
    try std.testing.expectError(error.InvalidDuration, parse(std.testing.allocator, &.{ "--duration", "abc" }));
}

test "parse: unknown args are ignored, not fatal" {
    var opts = try parse(std.testing.allocator, &.{ "--bogus", "--duration", "10" });
    defer opts.deinit();
    try std.testing.expectEqual(@as(u64, 10), opts.duration_ms);
}
