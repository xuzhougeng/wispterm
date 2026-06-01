//! Pure transfer-toast text model: maps a file-transfer kind+status to the
//! toast verb and full message. Extracted from overlays.zig so the wording is
//! unit-tested in the fast suite; overlays keeps the toast timing/hit-test/draw
//! state and re-exports these helpers.
const std = @import("std");
const file_explorer = @import("../../file_explorer.zig");

pub fn transferToastVerb(kind: file_explorer.TransferKind, status: file_explorer.TransferStatus) []const u8 {
    return switch (kind) {
        .download => switch (status) {
            .in_progress => "Downloading",
            .success => "Downloaded",
            .failed => "Download failed",
            .cancelled => "Download interrupted",
            .idle => "Download",
        },
        .upload => switch (status) {
            .in_progress => "Uploading",
            .success => "Uploaded",
            .failed => "Upload failed",
            .cancelled => "Upload interrupted",
            .idle => "Upload",
        },
    };
}

pub fn formatTransferToast(
    buf: []u8,
    kind: file_explorer.TransferKind,
    status: file_explorer.TransferStatus,
    message: []const u8,
) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ transferToastVerb(kind, status), message });
}

test "overlays: transfer toast text describes download states" {
    var buf: [160]u8 = undefined;

    try std.testing.expectEqualStrings(
        "Downloading: file.txt",
        try formatTransferToast(&buf, .download, .in_progress, "file.txt"),
    );
    try std.testing.expectEqualStrings(
        "Downloaded: file.txt",
        try formatTransferToast(&buf, .download, .success, "file.txt"),
    );
    try std.testing.expectEqualStrings(
        "Download failed: file.txt",
        try formatTransferToast(&buf, .download, .failed, "file.txt"),
    );
}
