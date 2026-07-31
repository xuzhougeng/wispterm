//! Wire protocol and local implementation for the standalone wispterm-filetool.
const std = @import("std");
const file_edit = @import("file_edit.zig");

pub const tool_name = "wispterm-filetool";
pub const edit_check_command = "edit-check";
pub const edit_count_command = "edit-count";
pub const edit_apply_command = "edit-apply";
pub const helper_unavailable_exit_code: u8 = 127;
pub const max_request_bytes: usize = 2 * file_edit.MAX_FILE_BYTES + 4096;

const EditRequest = struct {
    old_string: []u8,
    new_string: []u8,
    replace_all: bool,

    fn deinit(self: *EditRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.old_string);
        allocator.free(self.new_string);
        self.* = undefined;
    }
};

pub fn encodeEditRequestAlloc(
    allocator: std.mem.Allocator,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const old_b64 = try allocator.alloc(u8, encoder.calcSize(old_string.len));
    defer allocator.free(old_b64);
    _ = encoder.encode(old_b64, old_string);

    const new_b64 = try allocator.alloc(u8, encoder.calcSize(new_string.len));
    defer allocator.free(new_b64);
    _ = encoder.encode(new_b64, new_string);

    return std.fmt.allocPrint(
        allocator,
        "replace_all={d}\nold_b64={s}\nnew_b64={s}\n",
        .{ @intFromBool(replace_all), old_b64, new_b64 },
    );
}

pub fn handleEditCheckAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    request_bytes: []const u8,
    include_diff: bool,
) ![]u8 {
    var request = parseEditRequestAlloc(allocator, request_bytes) catch return errorResponseAlloc(allocator, "BadRequest");
    defer request.deinit(allocator);

    const old_content = readWholeFileAlloc(allocator, path) catch |err| return fileIoErrorAlloc(allocator, err, "ReadFailed");
    defer allocator.free(old_content);

    const outcome = file_edit.applyEdit(allocator, old_content, request.old_string, request.new_string, request.replace_all) catch |err| {
        return editErrorResponseAlloc(allocator, err);
    };
    defer allocator.free(outcome.new_content);

    if (!include_diff) return okHeaderAlloc(allocator, outcome.occurrences);

    const diff = file_edit.unifiedDiffAlloc(allocator, path, old_content, outcome.new_content) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(diff);

    return std.fmt.allocPrint(allocator, "ok occurrences={d}\n{s}", .{ outcome.occurrences, diff });
}

pub fn handleEditApplyAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    request_bytes: []const u8,
) ![]u8 {
    var request = parseEditRequestAlloc(allocator, request_bytes) catch return errorResponseAlloc(allocator, "BadRequest");
    defer request.deinit(allocator);

    const old_content = readWholeFileAlloc(allocator, path) catch |err| return fileIoErrorAlloc(allocator, err, "ReadFailed");
    defer allocator.free(old_content);

    const outcome = file_edit.applyEdit(allocator, old_content, request.old_string, request.new_string, request.replace_all) catch |err| {
        return editErrorResponseAlloc(allocator, err);
    };
    defer allocator.free(outcome.new_content);

    writeFileAtomic(allocator, path, outcome.new_content) catch |err| return fileIoErrorAlloc(allocator, err, "WriteFailed");
    return okHeaderAlloc(allocator, outcome.occurrences);
}

fn parseEditRequestAlloc(allocator: std.mem.Allocator, request_bytes: []const u8) !EditRequest {
    var replace_all: ?bool = null;
    var old_b64: ?[]const u8 = null;
    var new_b64: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, request_bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "replace_all=0")) {
            replace_all = false;
        } else if (std.mem.eql(u8, line, "replace_all=1")) {
            replace_all = true;
        } else if (std.mem.startsWith(u8, line, "old_b64=")) {
            old_b64 = line["old_b64=".len..];
        } else if (std.mem.startsWith(u8, line, "new_b64=")) {
            new_b64 = line["new_b64=".len..];
        } else {
            return error.BadRequest;
        }
    }

    const old_encoded = old_b64 orelse return error.BadRequest;
    const new_encoded = new_b64 orelse return error.BadRequest;
    var request = EditRequest{
        .old_string = try decodeBase64Alloc(allocator, old_encoded),
        .new_string = &[_]u8{},
        .replace_all = replace_all orelse return error.BadRequest,
    };
    errdefer allocator.free(request.old_string);
    request.new_string = try decodeBase64Alloc(allocator, new_encoded);
    return request;
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    try decoder.decode(decoded, encoded);
    return decoded;
}

fn readWholeFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, file_edit.MAX_FILE_BYTES);
}

fn createWriteFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, .{ .truncate = true });
    return std.fs.cwd().createFile(path, .{ .truncate = true });
}

fn renameFile(old_path: []const u8, new_path: []const u8) !void {
    if (std.fs.path.isAbsolute(old_path) and std.fs.path.isAbsolute(new_path)) {
        return std.fs.renameAbsolute(old_path, new_path);
    }
    return std.fs.cwd().rename(old_path, new_path);
}

fn deleteFileBestEffort(path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteFileAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteFile(path) catch {};
    }
}

fn writeFileAtomic(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.wispterm.tmp", .{path});
    defer allocator.free(tmp);
    errdefer deleteFileBestEffort(tmp);

    var file = try createWriteFile(tmp);
    errdefer file.close();
    try file.writeAll(content);
    file.close();

    try renameFile(tmp, path);
}

fn okHeaderAlloc(allocator: std.mem.Allocator, occurrences: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "ok occurrences={d}\n", .{occurrences});
}

fn editErrorResponseAlloc(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return switch (err) {
        error.EmptyOld => errorResponseAlloc(allocator, "EmptyOld"),
        error.NotFound => errorResponseAlloc(allocator, "NotFound"),
        error.NotUnique => errorResponseAlloc(allocator, "NotUnique"),
        error.OutOfMemory => error.OutOfMemory,
        else => errorResponseAlloc(allocator, @errorName(err)),
    };
}

fn fileIoErrorAlloc(allocator: std.mem.Allocator, err: anyerror, fallback_code: []const u8) ![]u8 {
    return switch (err) {
        error.FileTooBig => errorResponseAlloc(allocator, "TooLarge"),
        error.OutOfMemory => error.OutOfMemory,
        else => errorResponseAlloc(allocator, fallback_code),
    };
}

fn errorResponseAlloc(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "error {s}\n", .{code});
}

test "remote filetool encodes edit requests without putting content in argv" {
    const a = std.testing.allocator;
    const request = try encodeEditRequestAlloc(a, "old\ntext", "new\ntext", true);
    defer a.free(request);

    try std.testing.expect(std.mem.indexOf(u8, request, "replace_all=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "old=old") == null);
    try std.testing.expect(std.mem.indexOf(u8, request, "new=new") == null);
}

test "remote filetool check returns a diff and apply edits the file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "demo.txt", .data = "alpha\nbeta\ngamma\n" });
    const path = try tmp.dir.realpathAlloc(a, "demo.txt");
    defer a.free(path);
    const request = try encodeEditRequestAlloc(a, "beta", "BETA", false);
    defer a.free(request);

    const check = try handleEditCheckAlloc(a, path, request, true);
    defer a.free(check);
    try std.testing.expect(std.mem.startsWith(u8, check, "ok occurrences=1\n"));
    try std.testing.expect(std.mem.indexOf(u8, check, "-beta\n+BETA\n") != null);

    const apply = try handleEditApplyAlloc(a, path, request);
    defer a.free(apply);
    try std.testing.expectEqualStrings("ok occurrences=1\n", apply);

    const after = try tmp.dir.readFileAlloc(a, "demo.txt", 1024);
    defer a.free(after);
    try std.testing.expectEqualStrings("alpha\nBETA\ngamma\n", after);
}

test "remote filetool redacted check returns only the count" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "secret.txt", .data = "alpha\nbeta\n" });
    const path = try tmp.dir.realpathAlloc(a, "secret.txt");
    defer a.free(path);
    const request = try encodeEditRequestAlloc(a, "beta", "BETA", false);
    defer a.free(request);

    const check = try handleEditCheckAlloc(a, path, request, false);
    defer a.free(check);
    try std.testing.expectEqualStrings("ok occurrences=1\n", check);
}
