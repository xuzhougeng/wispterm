//! Dev CLI: run one local memory-digest scan against the real machine.
//! Build: zig build memory-digest -Dtarget=aarch64-macos
//! Run:   ./zig-out/bin/wispterm-memory-digest [--profile <name>] [--raw]
//! ponytail: macOS/HOME-based dev tool; the app's scheduler (M2) is the
//! real cross-platform entry point.
const std = @import("std");
const dirs = @import("../platform/dirs.zig");
const llm = @import("llm.zig");
const protocol = @import("../assistant/conversation/protocol.zig");
const profile_codec = @import("../renderer/overlays/profile_codec.zig");
const profile_store = @import("../assistant/profile/store.zig");
const run_mod = @import("run.zig");
const sources_mod = @import("sources.zig");

const Args = struct {
    profile_name: []const u8 = "",
    raw: bool = false,
    remote: bool = false,
};

fn parseArgs(argv: []const [:0]u8) Args {
    var args: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--raw")) {
            args.raw = true;
        } else if (std.mem.eql(u8, argv[i], "--remote")) {
            args.remote = true;
        } else if (std.mem.eql(u8, argv[i], "--profile") and i + 1 < argv.len) {
            i += 1;
            args.profile_name = argv[i];
        }
    }
    return args;
}

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);
    const args = parseArgs(argv);

    const local_roots = try run_mod.defaultLocalRoots(gpa);
    defer local_roots.deinit(gpa);
    const memory_root = try dirs.memoryDir(gpa);
    defer gpa.free(memory_root);

    // Profiles are large fixed-buffer records (~98KB each); heap-allocate
    // rather than putting them on the stack.
    const profiles = try gpa.alloc(profile_codec.AiProfile, 16);
    defer gpa.free(profiles);
    const profile_count = profile_store.loadProfiles(gpa, profiles);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var client: llm.Client = undefined;
    var completer: ?llm.Completer = null;
    var model_label: []const u8 = "";

    if (!args.raw and profile_count > 0) {
        const idx = llm.pickProfile(profiles, profile_count, args.profile_name).?;
        const picked_name = profile_codec.aiProfileField(&profiles[idx], .name);
        if (args.profile_name.len != 0 and !std.mem.eql(u8, picked_name, args.profile_name)) {
            std.debug.print("memory-digest: profile \"{s}\" not found, falling back to \"{s}\"\n", .{ args.profile_name, picked_name });
        }
        const cfg = try llm.configFromProfile(arena_state.allocator(), &profiles[idx]);
        client = .{ .config = cfg };
        completer = client.completer();
        model_label = cfg.model;
    } else if (!args.raw) {
        std.debug.print("memory-digest: no AI profiles configured, running raw (no LLM summaries)\n", .{});
    }

    var remote_sources: []const run_mod.RemoteSource = &.{};
    if (args.remote) {
        const ssh_sources = try sources_mod.loadSshSources(gpa, arena_state.allocator());
        const wsl_sources = try sources_mod.loadWslSources(arena_state.allocator());
        remote_sources = try std.mem.concat(arena_state.allocator(), run_mod.RemoteSource, &.{ ssh_sources, wsl_sources });
    }

    // `client` is only initialized when a completer was picked above; its
    // total_usage field would otherwise be undefined memory, so the usage
    // pointer must stay null on the raw/no-profile path.
    const llm_usage: ?*const protocol.ApiUsage = if (completer != null) &client.total_usage else null;

    const summary = try run_mod.runOnce(gpa, .{
        .roots = local_roots.roots(),
        .memory_root = memory_root,
        .now_ms = std.time.milliTimestamp(),
        // ponytail: dev CLI hardcodes UTC+8; the app injects the real
        // offset when the M2 scheduler lands.
        .tz_offset_seconds = 8 * 3600,
        .completer = completer,
        .model_label = model_label,
        .remote_sources = remote_sources,
        .llm_usage = llm_usage,
    });
    std.debug.print(
        "memory-digest: {d} sessions with new messages, {d} daily files written, {d} summarized, {d} failed, under {s}\n",
        .{ summary.sessions_collected, summary.days_written, summary.sessions_summarized, summary.sessions_failed, memory_root },
    );
    if (completer != null) {
        std.debug.print(
            "memory-digest: {d} tokens ({d} prompt + {d} completion)\n",
            .{ client.total_usage.total_tokens, client.total_usage.prompt_tokens, client.total_usage.completion_tokens },
        );
    }
}
