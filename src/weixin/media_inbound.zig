//! Pure inbound-media helpers for the Weixin direct bridge: decide what to
//! download from a message, name the saved files, and build the WeChat receipt
//! and the synthetic copilot prompt. No I/O lives here.
const std = @import("std");
const types = @import("types.zig");

pub const DownloadPlan = struct {
    kind: types.AttachmentKind,
    encrypt_query_param: []const u8,
    aes_key: []const u8,
    /// file_item only; "" for images.
    file_name: []const u8 = "",
    /// images with no key are fetched as-is (already-decrypted bytes).
    allow_plain: bool = false,
};

/// Selects image (type 2) and file (type 4) items with a usable CDN reference,
/// deduplicating repeated encrypt_query_param values within one message.
/// `out` borrows the input strings; caller owns the returned slice.
pub fn planDownloads(allocator: std.mem.Allocator, items: []const types.MessageItem) ![]DownloadPlan {
    var out: std.ArrayListUnmanaged(DownloadPlan) = .empty;
    errdefer out.deinit(allocator);
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    defer seen.deinit(allocator);

    for (items) |item| {
        const media = item.media orelse continue;
        const enc = std.mem.trim(u8, media.encrypt_query_param, " \t\r\n");
        if (enc.len == 0) continue;
        var dup = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, enc)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        const key = std.mem.trim(u8, media.aes_key, " \t\r\n");
        switch (item.type) {
            2 => {
                try out.append(allocator, .{
                    .kind = .image,
                    .encrypt_query_param = enc,
                    .aes_key = key,
                    .allow_plain = key.len == 0,
                });
                try seen.append(allocator, enc);
            },
            4 => {
                if (key.len == 0) continue; // files require a key
                try out.append(allocator, .{
                    .kind = .file,
                    .encrypt_query_param = enc,
                    .aes_key = key,
                    .file_name = item.file_name,
                });
                try seen.append(allocator, enc);
            },
            else => {},
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Image extension from magic bytes; defaults to "jpg".
pub fn detectImageMimeExt(bytes: []const u8) []const u8 {
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return "jpg";
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "png";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "webp";
    return "jpg";
}

/// Strips any directory components and rejects empty/dotty names, so a remote
/// file_name can never escape the save directory. Returns a borrowed slice of
/// `name` (the basename) or a fallback literal.
pub fn sanitizeFileName(name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return "attachment.bin";
    // basename after the last '/' or '\'
    var start: usize = 0;
    for (trimmed, 0..) |c, i| {
        if (c == '/' or c == '\\') start = i + 1;
    }
    const base = trimmed[start..];
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return "attachment.bin";
    return base;
}

/// Chooses the on-disk name for a saved item. Allocator-owned result.
/// `index` makes image names unique within a message.
pub fn chooseFileName(allocator: std.mem.Allocator, plan: DownloadPlan, bytes: []const u8, index: usize) ![]u8 {
    return switch (plan.kind) {
        .file, .voice => allocator.dupe(u8, sanitizeFileName(plan.file_name)),
        .image => std.fmt.allocPrint(allocator, "image_{d}.{s}", .{ index, detectImageMimeExt(bytes) }),
    };
}

/// If `name` collides with an entry in `taken`, inserts " (n)" before the
/// extension until unique. Allocator-owned result; `taken` holds borrowed names.
pub fn dedupeFileName(allocator: std.mem.Allocator, name: []const u8, taken: []const []const u8) ![]u8 {
    if (!nameTaken(name, taken)) return allocator.dupe(u8, name);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const stem = if (dot) |d| name[0..d] else name;
    const ext = if (dot) |d| name[d..] else "";
    var n: usize = 2;
    while (n < 10000) : (n += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s} ({d}){s}", .{ stem, n, ext });
        if (!nameTaken(candidate, taken)) return candidate;
        allocator.free(candidate);
    }
    return allocator.dupe(u8, name);
}

fn nameTaken(name: []const u8, taken: []const []const u8) bool {
    for (taken) |t_name| {
        if (std.mem.eql(u8, t_name, name)) return true;
    }
    return false;
}

/// The combined receipt + ack sent to WeChat when at least one file is saved.
pub fn buildReceiptText(allocator: std.mem.Allocator, saved_names: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "已收到文件：");
    for (saved_names, 0..) |name, i| {
        if (i != 0) try out.appendSlice(allocator, "、");
        try out.appendSlice(allocator, name);
    }
    try out.appendSlice(allocator, "，正在交给副驾处理。\n发送 /stop 可停止本次处理。");
    return out.toOwnedSlice(allocator);
}

/// The synthetic prompt routed to the copilot. Lists absolute saved paths and
/// appends the user's caption if present. No trailing carriage return.
pub fn buildCopilotPrompt(allocator: std.mem.Allocator, saved_paths: []const []const u8, caption: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "用户通过微信发送了文件：");
    for (saved_paths) |p| {
        try out.appendSlice(allocator, "\n- ");
        try out.appendSlice(allocator, p);
    }
    const cap = std.mem.trim(u8, caption, " \t\r\n");
    if (cap.len != 0) {
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, cap);
    }
    return out.toOwnedSlice(allocator);
}

const t = std.testing;

test "planDownloads selects image and file items and dedups by encrypt param" {
    const items = [_]types.MessageItem{
        .{ .type = 1, .text = "caption" },
        .{ .type = 4, .file_name = "a.pdf", .media = .{ .encrypt_query_param = "E1", .aes_key = "K1" } },
        .{ .type = 2, .media = .{ .encrypt_query_param = "E2", .aes_key = "K2" } },
        .{ .type = 2, .media = .{ .encrypt_query_param = "E2", .aes_key = "K2" } }, // dup → skip
        .{ .type = 4, .file_name = "nokey.bin", .media = .{ .encrypt_query_param = "E3", .aes_key = "" } }, // file w/o key → skip
        .{ .type = 2, .media = .{ .encrypt_query_param = "E4", .aes_key = "" } }, // image plain
    };
    const plans = try planDownloads(t.allocator, &items);
    defer t.allocator.free(plans);
    try t.expectEqual(@as(usize, 3), plans.len);
    try t.expectEqual(types.AttachmentKind.file, plans[0].kind);
    try t.expectEqualStrings("a.pdf", plans[0].file_name);
    try t.expectEqual(types.AttachmentKind.image, plans[1].kind);
    try t.expect(!plans[1].allow_plain);
    try t.expectEqualStrings("E4", plans[2].encrypt_query_param);
    try t.expect(plans[2].allow_plain);
}

test "detectImageMimeExt sniffs common formats" {
    try t.expectEqualStrings("png", detectImageMimeExt("\x89PNG\r\n\x1a\n----"));
    try t.expectEqualStrings("jpg", detectImageMimeExt(&[_]u8{ 0xFF, 0xD8, 0xFF, 0x00 }));
    try t.expectEqualStrings("gif", detectImageMimeExt("GIF89a..."));
    try t.expectEqualStrings("jpg", detectImageMimeExt("unknown"));
}

test "sanitizeFileName strips path components and rejects traversal" {
    try t.expectEqualStrings("report.pdf", sanitizeFileName("report.pdf"));
    try t.expectEqualStrings("report.pdf", sanitizeFileName("/etc/../report.pdf"));
    try t.expectEqualStrings("report.pdf", sanitizeFileName("C:\\Users\\x\\report.pdf"));
    try t.expectEqualStrings("attachment.bin", sanitizeFileName("   "));
    try t.expectEqualStrings("attachment.bin", sanitizeFileName("a/b/.."));
}

test "chooseFileName names files and images" {
    const fplan = DownloadPlan{ .kind = .file, .encrypt_query_param = "E", .aes_key = "K", .file_name = "doc.pdf" };
    const fname = try chooseFileName(t.allocator, fplan, "", 0);
    defer t.allocator.free(fname);
    try t.expectEqualStrings("doc.pdf", fname);

    const iplan = DownloadPlan{ .kind = .image, .encrypt_query_param = "E", .aes_key = "" };
    const iname = try chooseFileName(t.allocator, iplan, "\x89PNG\r\n\x1a\n", 3);
    defer t.allocator.free(iname);
    try t.expectEqualStrings("image_3.png", iname);
}

test "dedupeFileName appends a counter before the extension" {
    const taken = [_][]const u8{ "doc.pdf", "doc (2).pdf" };
    const a = try dedupeFileName(t.allocator, "fresh.pdf", &taken);
    defer t.allocator.free(a);
    try t.expectEqualStrings("fresh.pdf", a);

    const b = try dedupeFileName(t.allocator, "doc.pdf", &taken);
    defer t.allocator.free(b);
    try t.expectEqualStrings("doc (3).pdf", b);
}

test "buildReceiptText joins names with the start-of-processing line" {
    const names = [_][]const u8{ "a.pdf", "image_0.png" };
    const text = try buildReceiptText(t.allocator, &names);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "已收到文件：a.pdf、image_0.png") != null);
    try t.expect(std.mem.indexOf(u8, text, "/stop") != null);
}

test "buildCopilotPrompt lists absolute paths and optional caption" {
    const paths = [_][]const u8{"/work/weixin_inbound/a.pdf"};
    const with_cap = try buildCopilotPrompt(t.allocator, &paths, "请总结这个 PDF");
    defer t.allocator.free(with_cap);
    try t.expect(std.mem.indexOf(u8, with_cap, "- /work/weixin_inbound/a.pdf") != null);
    try t.expect(std.mem.indexOf(u8, with_cap, "请总结这个 PDF") != null);

    const no_cap = try buildCopilotPrompt(t.allocator, &paths, "   ");
    defer t.allocator.free(no_cap);
    try t.expect(std.mem.endsWith(u8, no_cap, "a.pdf"));
}
