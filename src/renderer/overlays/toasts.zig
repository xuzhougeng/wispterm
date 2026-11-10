const std = @import("std");
const file_explorer = @import("../../file_explorer.zig");
const update_prompt_model = @import("update_prompt_model.zig");
const transfer_toast_model = @import("transfer_toast_model.zig");

pub const COPY_TOAST_DURATION_MS: i64 = 1500;
pub const TRANSFER_TOAST_DURATION_MS: i64 = 2500;
pub const UPDATE_PROMPT_DURATION_MS: i64 = 10000;
pub const UPDATE_STATUS_DURATION_MS: i64 = 2500;

pub const TextToast = struct {
    until_ms: i64 = 0,
    // Sized for the longest localized status messages; 64 bytes cut real
    // English strings and held only ~20 CJK characters.
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn show(self: *TextToast, message: []const u8, now_ms: i64, duration_ms: i64) void {
        self.len = copyTruncated(&self.buf, message);
        self.until_ms = now_ms + duration_ms;
    }

    pub fn active(self: TextToast, now_ms: i64) bool {
        return self.len > 0 and now_ms < self.until_ms;
    }

    pub fn text(self: *const TextToast) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }
};

pub const TransferToast = struct {
    until_ms: i64 = 0,
    sticky: bool = false,
    status: file_explorer.TransferStatus = .idle,
    clickable: bool = false,
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn show(
        self: *TransferToast,
        kind: file_explorer.TransferKind,
        status: file_explorer.TransferStatus,
        message: []const u8,
        now_ms: i64,
        duration_ms: i64,
    ) void {
        self.len = formatTransferToastTruncated(&self.buf, kind, status, message);
        self.status = status;
        self.sticky = status == .in_progress;
        self.clickable = kind == .download and status == .in_progress;
        self.until_ms = now_ms + duration_ms;
    }

    pub fn active(self: TransferToast, now_ms: i64) bool {
        return self.len > 0 and (self.sticky or now_ms < self.until_ms);
    }

    pub fn text(self: *const TransferToast) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }
};

pub const UpdatePrompt = struct {
    until_ms: i64 = 0,
    buf: [128]u8 = undefined,
    len: usize = 0,
    url_buf: [256]u8 = undefined,
    url_len: usize = 0,
    clickable: bool = false,
    action: update_prompt_model.UpdatePromptAction = .none,

    pub fn show(
        self: *UpdatePrompt,
        message: []const u8,
        target_url: []const u8,
        clickable: bool,
        action: update_prompt_model.UpdatePromptAction,
        now_ms: i64,
        duration_ms: i64,
    ) void {
        self.len = copyTruncated(&self.buf, message);
        self.url_len = copyTruncated(&self.url_buf, target_url);
        self.clickable = clickable;
        self.action = action;
        self.until_ms = now_ms + duration_ms;
    }

    pub fn active(self: UpdatePrompt, now_ms: i64) bool {
        return self.len > 0 and now_ms < self.until_ms;
    }

    pub fn text(self: *const UpdatePrompt) ?[]const u8 {
        if (self.len == 0) return null;
        return self.buf[0..self.len];
    }

    pub fn url(self: *const UpdatePrompt) ?[]const u8 {
        if (self.url_len == 0) return null;
        return self.url_buf[0..self.url_len];
    }
};

pub const State = struct {
    copy: TextToast = .{},
    transfer: TransferToast = .{},
    update: UpdatePrompt = .{},
    close_shortcut_confirm_until_ms: i64 = 0,
};

/// Longest prefix of `src` that fits in `limit` bytes without cutting a UTF-8
/// sequence. A split character fails validation downstream and the whole
/// toast is then drawn as mojibake or '?'.
fn utf8PrefixLen(src: []const u8, limit: usize) usize {
    var len = @min(limit, src.len);
    while (len < src.len and len > 0 and (src[len] & 0xc0) == 0x80) len -= 1;
    return len;
}

fn copyTruncated(dst: []u8, src: []const u8) usize {
    const len = utf8PrefixLen(src, dst.len);
    if (len > 0) @memcpy(dst[0..len], src[0..len]);
    return len;
}

fn formatTransferToastTruncated(
    dst: []u8,
    kind: file_explorer.TransferKind,
    status: file_explorer.TransferStatus,
    message: []const u8,
) usize {
    var len: usize = 0;
    appendTruncated(dst, &len, transfer_toast_model.transferToastVerb(kind, status));
    appendTruncated(dst, &len, ": ");
    appendTruncated(dst, &len, message);
    return len;
}

fn appendTruncated(dst: []u8, len: *usize, src: []const u8) void {
    const remaining = dst.len - len.*;
    const n = utf8PrefixLen(src, remaining);
    if (n == 0) return;
    @memcpy(dst[len.*..][0..n], src[0..n]);
    len.* += n;
}

test "toast state stores status text until expiration" {
    var toast: TextToast = .{};

    toast.show("Copied", 1000, COPY_TOAST_DURATION_MS);

    try std.testing.expect(toast.active(1000));
    try std.testing.expectEqualStrings("Copied", toast.text().?);
    try std.testing.expect(!toast.active(2500));
}

test "transfer toast state tracks sticky clickable download progress" {
    var toast: TransferToast = .{};

    toast.show(.download, .in_progress, "remote.txt", 2000, TRANSFER_TOAST_DURATION_MS);

    try std.testing.expect(toast.active(2000 + TRANSFER_TOAST_DURATION_MS));
    try std.testing.expect(toast.sticky);
    try std.testing.expect(toast.clickable);
    try std.testing.expectEqual(file_explorer.TransferStatus.in_progress, toast.status);
    try std.testing.expect(std.mem.endsWith(u8, toast.text().?, "remote.txt"));
}

test "transfer toast long messages replace stale progress state" {
    var toast: TransferToast = .{};
    const old_name = "old-download.txt";
    const long_message = "new-failed-transfer-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    toast.show(.download, .in_progress, old_name, 2000, TRANSFER_TOAST_DURATION_MS);
    toast.show(.download, .failed, long_message, 3000, TRANSFER_TOAST_DURATION_MS);

    try std.testing.expectEqual(file_explorer.TransferStatus.failed, toast.status);
    try std.testing.expect(!toast.sticky);
    try std.testing.expect(!toast.clickable);

    const text = toast.text().?;
    try std.testing.expect(std.mem.startsWith(u8, text, "Download failed: new-failed-transfer-"));
    try std.testing.expect(std.mem.indexOf(u8, text, old_name) == null);
}

test "update prompt state stores URL only when provided" {
    var prompt: UpdatePrompt = .{};

    prompt.show(
        "Update available",
        "https://example.test/release",
        true,
        .open_release,
        3000,
        UPDATE_PROMPT_DURATION_MS,
    );

    try std.testing.expect(prompt.active(3000));
    try std.testing.expect(prompt.clickable);
    try std.testing.expectEqual(update_prompt_model.UpdatePromptAction.open_release, prompt.action);
    try std.testing.expectEqualStrings("Update available", prompt.text().?);
    try std.testing.expectEqualStrings("https://example.test/release", prompt.url().?);
}

test "update prompt state clears URL when new prompt omits one" {
    var prompt: UpdatePrompt = .{};

    prompt.show(
        "Update available",
        "https://example.test/release",
        true,
        .open_release,
        3000,
        UPDATE_PROMPT_DURATION_MS,
    );
    prompt.show(
        "No update ready",
        "",
        false,
        .none,
        4000,
        UPDATE_STATUS_DURATION_MS,
    );

    try std.testing.expectEqualStrings("No update ready", prompt.text().?);
    try std.testing.expect(prompt.url() == null);
    try std.testing.expect(!prompt.clickable);
    try std.testing.expectEqual(update_prompt_model.UpdatePromptAction.none, prompt.action);
}

test "text toast truncates stored text to fixed buffer" {
    var toast: TextToast = .{};
    const long_message = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789--" ** 3;

    toast.show(long_message, 5000, COPY_TOAST_DURATION_MS);

    try std.testing.expectEqual(toast.buf.len, toast.text().?.len);
    try std.testing.expectEqualStrings(long_message[0..toast.buf.len], toast.text().?);
}

test "toasts truncate on a UTF-8 boundary" {
    var toast: TextToast = .{};
    // 54 three-byte characters = 162 bytes; the buffer holds 160.
    toast.show("\u{5df2}" ** 54, 0, 1000);
    const shown = toast.text().?;
    try std.testing.expectEqual(@as(usize, 159), shown.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shown));

    var transfer: TransferToast = .{};
    transfer.show(.download, .in_progress, "\u{6587}" ** 80, 0, 1000);
    try std.testing.expect(std.unicode.utf8ValidateSlice(transfer.text().?));
}
