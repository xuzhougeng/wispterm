//! Loopback socket I/O for the agent-control transport — shared by the in-process
//! server (ctl/server.zig) and the standalone wisptermctl client.
//!
//! Why this exists instead of std.net.Stream.read/.writeAll: those are deprecated
//! and BROKEN on Windows for this use. Zig creates every socket with
//! WSA_FLAG_OVERLAPPED (std.posix.socket), and Stream.read maps to
//! `ReadFile(socket, buf, NULL)`. Per Microsoft's docs, calling ReadFile on an
//! overlapped handle with a NULL OVERLAPPED "can incorrectly report that the read
//! operation is complete" — in practice it returns 0 bytes immediately. So every
//! wisptermctl command read the server's reply as 0 bytes and failed with
//! "malformed response from WispTerm" (the v1.30.0 Windows bug). POSIX uses
//! `posix.read`, which is why the macOS/Linux round-trip tests never caught it.
//!
//! Instead we use plain blocking Winsock recv/send on Windows (synchronous on
//! overlapped sockets, honors SO_RCVTIMEO) and posix.recv/posix.send on POSIX.
//! The Windows branch calls ws2_32 directly rather than posix.recv so the lean,
//! no-libc wisptermctl exe links (posix.recvfrom resolves to a libc symbol on
//! windows-gnu). Pure std — no GUI deps.
const std = @import("std");
const builtin = @import("builtin");
const ws2_32 = std.os.windows.ws2_32;

const Handle = std.net.Stream.Handle;

pub const Error = error{ RecvFailed, SendFailed };

/// One receive into `buf`. Returns 0 on an orderly peer shutdown. Any failure —
/// including the SO_RCVTIMEO timeout — maps to error.RecvFailed so a read loop
/// can `catch break` (matching the previous Stream.read semantics).
pub fn recv(handle: Handle, buf: []u8) Error!usize {
    if (builtin.os.tag == .windows) {
        const len: i32 = @intCast(@min(buf.len, @as(usize, std.math.maxInt(i32))));
        const rc = ws2_32.recv(handle, buf.ptr, len, 0);
        if (rc == ws2_32.SOCKET_ERROR) return error.RecvFailed;
        return @intCast(rc); // rc >= 0; 0 == orderly shutdown
    } else {
        return std.posix.recv(handle, buf, 0) catch return error.RecvFailed;
    }
}

/// Write every byte of `bytes`, looping over partial sends.
pub fn sendAll(handle: Handle, bytes: []const u8) Error!void {
    var i: usize = 0;
    while (i < bytes.len) {
        if (builtin.os.tag == .windows) {
            const len: i32 = @intCast(@min(bytes.len - i, @as(usize, std.math.maxInt(i32))));
            const rc = ws2_32.send(handle, bytes[i..].ptr, len, 0);
            if (rc == ws2_32.SOCKET_ERROR) return error.SendFailed;
            i += @intCast(rc);
        } else {
            // MSG.NOSIGNAL: a peer that closed its read end must not raise SIGPIPE
            // (matches the stdlib POSIX socket writer). Winsock has no SIGPIPE.
            i += std.posix.send(handle, bytes[i..], std.posix.MSG.NOSIGNAL) catch return error.SendFailed;
        }
    }
}
