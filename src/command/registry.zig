//! Pure scan/parse of the user `commands/` directory into slash commands.
//! Peer to skill_registry.zig: text + dir -> command data; no Session state,
//! no networking. Each *.md file is one command.
const std = @import("std");

pub const MAX_COMMAND_MD_BYTES: usize = 256 * 1024;

pub const CustomCommand = struct {
    name: []u8,
    description: []u8,
    action: ?[]u8, // raw frontmatter value; validated by the caller
    body: []u8, // prompt template when action == null

    pub fn deinit(self: *CustomCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.action) |a| allocator.free(a);
        allocator.free(self.body);
        self.* = undefined;
    }
};

/// Parse one command file's bytes. Returns null when there is no `name:`.
pub fn parseCommandFile(allocator: std.mem.Allocator, bytes: []const u8) !?CustomCommand {
    var name: ?[]const u8 = null;
    var description: []const u8 = "";
    var action: ?[]const u8 = null;
    var body_start: usize = 0;

    const trimmed_bytes = std.mem.trimLeft(u8, bytes, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed_bytes, "---")) {
        // find frontmatter block between the first and second '---' lines
        const after_open = std.mem.indexOfScalar(u8, bytes, '\n') orelse return null;
        const fm_region = bytes[after_open + 1 ..];
        const close_rel = std.mem.indexOf(u8, fm_region, "\n---") orelse return null;
        const fm = fm_region[0..close_rel];
        body_start = after_open + 1 + close_rel + 1; // past "\n"
        // skip the closing "---" line
        if (std.mem.indexOfScalar(u8, bytes[body_start..], '\n')) |nl| body_start += nl + 1;

        var it = std.mem.splitScalar(u8, fm, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.mem.eql(u8, key, "name")) {
                name = value;
            } else if (std.mem.eql(u8, key, "description")) {
                description = value;
            } else if (std.mem.eql(u8, key, "action")) {
                if (value.len > 0) action = value;
            }
        }
    }

    const cmd_name = name orelse return null;
    if (cmd_name.len == 0) return null;
    const body = if (body_start < bytes.len) bytes[body_start..] else "";

    const owned_name = try allocator.dupe(u8, cmd_name);
    errdefer allocator.free(owned_name);
    const owned_desc = try allocator.dupe(u8, description);
    errdefer allocator.free(owned_desc);
    const owned_action = if (action) |av| try allocator.dupe(u8, av) else null;
    errdefer if (owned_action) |av| allocator.free(av);
    const owned_body = try allocator.dupe(u8, body);

    return .{ .name = owned_name, .description = owned_desc, .action = owned_action, .body = owned_body };
}

pub fn freeCommandList(allocator: std.mem.Allocator, commands: []CustomCommand) void {
    for (commands) |*c| c.deinit(allocator);
    allocator.free(commands);
}

/// Scan `commands_rel` under `root_dir` for `*.md` files. Missing dir -> empty.
pub fn listCommands(allocator: std.mem.Allocator, root_dir: std.fs.Dir, commands_rel: []const u8) ![]CustomCommand {
    var list: std.ArrayListUnmanaged(CustomCommand) = .empty;
    errdefer freeCommandListBuilder(allocator, &list);

    var dir = root_dir.openDir(
        if (commands_rel.len == 0) "." else commands_rel,
        .{ .iterate = true },
    ) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(CustomCommand, 0),
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const bytes = dir.readFileAlloc(allocator, entry.name, MAX_COMMAND_MD_BYTES) catch continue;
        defer allocator.free(bytes);
        if (try parseCommandFile(allocator, bytes)) |cmd| {
            list.append(allocator, cmd) catch |err| {
                var c = cmd;
                c.deinit(allocator);
                return err;
            };
        }
    }
    return list.toOwnedSlice(allocator);
}

fn freeCommandListBuilder(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(CustomCommand)) void {
    for (list.items) |*c| c.deinit(allocator);
    list.deinit(allocator);
}

test "parseCommandFile reads name, description, action, and body" {
    const a = std.testing.allocator;
    const src =
        "---\nname: review\ndescription: review the diff\naction: \n---\nPlease review the current git diff.\n";
    var cmd = (try parseCommandFile(a, src)).?;
    defer cmd.deinit(a);
    try std.testing.expectEqualStrings("review", cmd.name);
    try std.testing.expectEqualStrings("review the diff", cmd.description);
    try std.testing.expectEqual(@as(?[]const u8, null), cmd.action);
    try std.testing.expectEqualStrings("Please review the current git diff.", std.mem.trim(u8, cmd.body, " \t\r\n"));
}

test "parseCommandFile reads action mapping" {
    const a = std.testing.allocator;
    const src = "---\nname: clear\naction: clear_context\n---\n";
    var cmd = (try parseCommandFile(a, src)).?;
    defer cmd.deinit(a);
    try std.testing.expectEqualStrings("clear_context", cmd.action.?);
}

test "parseCommandFile rejects missing name" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(?CustomCommand, null), try parseCommandFile(a, "---\ndescription: x\n---\nbody"));
}
