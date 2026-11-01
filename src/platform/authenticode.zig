//! Authenticode signature checks for the in-place updater. A downloaded
//! release is installed only when its programs carry a valid signature from
//! the same publisher as the running program (magpie's sameSigner; macOS
//! does the same with `codesign --verify` in update_apply_macos.zig).
const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("authenticode_windows.zig"),
    else => @import("authenticode_unsupported.zig"),
};

pub const subject_buffer_len = 256;

/// Subject (simple display name) of the certificate that signed `path`,
/// written into `buf`, when `path` has a valid, trusted Authenticode
/// signature. Null when it is unsigned, tampered with, or not trusted.
pub fn signerSubject(path: []const u8, buf: *[subject_buffer_len]u8) ?[]const u8 {
    return impl.signerSubject(path, buf);
}

/// Error unless `candidate` is validly signed by the publisher that signed
/// `reference` (the running program). An unsigned reference never matches:
/// development builds do not update themselves.
pub fn requireSameSigner(reference: []const u8, candidate: []const u8) !void {
    var ref_buf: [subject_buffer_len]u8 = undefined;
    var cand_buf: [subject_buffer_len]u8 = undefined;
    const ref = signerSubject(reference, &ref_buf) orelse return error.RunningProgramUnsigned;
    const cand = signerSubject(candidate, &cand_buf) orelse return error.UpdateUnsigned;
    if (!std.mem.eql(u8, ref, cand)) return error.UpdateSignerMismatch;
}
