//! Output filter for secrets the agent typed into a terminal (`password_input`).
//! The plaintext is never kept: each secret is remembered as its length plus a
//! SipHash-2-4 tag under a key drawn when the filter sees its first secret.
//! Tool output is scanned window by window, so a secret that shows up later
//! (an echoing prompt, a file it landed in) is masked before the text reaches
//! the model, the chat transcript, or saved history.
const std = @import("std");

/// Fixed width, so the mask does not reveal the secret's length.
pub const MASK = "••••••••";

const SipHash = std.crypto.auth.siphash.SipHash64(2, 4);
const CAPACITY = 16;

pub const Filter = struct {
    mutex: std.Thread.Mutex = .{},
    key: [SipHash.key_length]u8 = undefined,
    keyed: bool = false,
    marks: [CAPACITY]Mark = undefined,
    count: usize = 0,
    next: usize = 0,

    const Mark = struct { len: usize, tag: u64 };

    /// Remember `secret` so later output containing it is masked. Keeps the
    /// most recent CAPACITY secrets.
    pub fn remember(self: *Filter, secret: []const u8) void {
        if (secret.len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.keyed) {
            std.crypto.random.bytes(&self.key);
            self.keyed = true;
        }
        const mark = Mark{ .len = secret.len, .tag = SipHash.toInt(secret, &self.key) };
        for (self.marks[0..self.count]) |existing| {
            if (existing.len == mark.len and existing.tag == mark.tag) return;
        }
        self.marks[self.next] = mark;
        self.next = (self.next + 1) % CAPACITY;
        if (self.count < CAPACITY) self.count += 1;
    }

    pub fn isEmpty(self: *Filter) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count == 0;
    }

    /// Takes ownership of `text`. Returns it unchanged when no remembered
    /// secret occurs in it; otherwise wipes and frees it and returns a copy
    /// with every occurrence replaced by MASK.
    pub fn redactOwned(self: *Filter, allocator: std.mem.Allocator, text: []u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count == 0) return text;
        errdefer wipeFree(allocator, text);

        var hidden = try std.DynamicBitSetUnmanaged.initEmpty(allocator, text.len);
        defer hidden.deinit(allocator);
        var any = false;
        for (self.marks[0..self.count]) |mark| {
            if (mark.len > text.len) continue;
            var i: usize = 0;
            while (i + mark.len <= text.len) {
                if (SipHash.toInt(text[i..][0..mark.len], &self.key) == mark.tag) {
                    hidden.setRangeValue(.{ .start = i, .end = i + mark.len }, true);
                    any = true;
                    i += mark.len;
                } else i += 1;
            }
        }
        if (!any) return text;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < text.len) {
            if (!hidden.isSet(i)) {
                try out.append(allocator, text[i]);
                i += 1;
                continue;
            }
            try out.appendSlice(allocator, MASK);
            while (i < text.len and hidden.isSet(i)) i += 1;
        }
        const masked = try out.toOwnedSlice(allocator);
        wipeFree(allocator, text);
        return masked;
    }

    /// Masked copy of borrowed `text`, for callers that do not own it.
    pub fn redactAlloc(self: *Filter, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return self.redactOwned(allocator, try allocator.dupe(u8, text));
    }
};

/// Mask every occurrence of a plaintext `secret` the caller still holds.
/// Takes ownership of `text` like `Filter.redactOwned`.
pub fn maskOwned(allocator: std.mem.Allocator, text: []u8, secret: []const u8) ![]u8 {
    if (secret.len == 0 or std.mem.indexOf(u8, text, secret) == null) return text;
    errdefer wipeFree(allocator, text);
    const masked = try std.mem.replaceOwned(u8, allocator, text, secret, MASK);
    wipeFree(allocator, text);
    return masked;
}

fn wipeFree(allocator: std.mem.Allocator, text: []u8) void {
    std.crypto.secureZero(u8, text);
    allocator.free(text);
}

test "filter masks a remembered secret wherever it appears" {
    const a = std.testing.allocator;
    var filter: Filter = .{};
    try std.testing.expect(filter.isEmpty());
    filter.remember("hunter22");
    try std.testing.expect(!filter.isEmpty());

    const out = try filter.redactAlloc(a, "$ echo hunter22\nhunter22\n$ ");
    defer a.free(out);
    try std.testing.expectEqualStrings("$ echo " ++ MASK ++ "\n" ++ MASK ++ "\n$ ", out);
}

test "filter keeps no plaintext and leaves unrelated text untouched" {
    const a = std.testing.allocator;
    var filter: Filter = .{};
    filter.remember("ZiWS975rGqlZ");
    const bytes = std.mem.asBytes(&filter);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "ZiWS975rGqlZ") == null);

    const text = try a.dupe(u8, "[sudo] password for xzg:\nRC=0\n$ ");
    const out = try filter.redactOwned(a, text);
    defer a.free(out);
    try std.testing.expect(out.ptr == text.ptr);
}

test "filter merges overlapping secrets into one mask and dedupes repeats" {
    const a = std.testing.allocator;
    var filter: Filter = .{};
    filter.remember("abcd1234");
    filter.remember("1234wxyz");
    filter.remember("abcd1234");
    try std.testing.expectEqual(@as(usize, 2), filter.count);
    const out = try filter.redactAlloc(a, "x abcd1234wxyz y");
    defer a.free(out);
    try std.testing.expectEqualStrings("x " ++ MASK ++ " y", out);
}

test "filter keeps only the most recent secrets" {
    var filter: Filter = .{};
    var buf: [8]u8 = undefined;
    for (0..CAPACITY + 3) |n| filter.remember(std.fmt.bufPrint(&buf, "secret{d:0>2}", .{n}) catch unreachable);
    try std.testing.expectEqual(@as(usize, CAPACITY), filter.count);
}

test "maskOwned replaces a held plaintext secret" {
    const a = std.testing.allocator;
    const out = try maskOwned(a, try a.dupe(u8, "Password: s3cret\nok"), "s3cret");
    defer a.free(out);
    try std.testing.expectEqualStrings("Password: " ++ MASK ++ "\nok", out);
    const same = try maskOwned(a, try a.dupe(u8, "nothing here"), "s3cret");
    defer a.free(same);
    try std.testing.expectEqualStrings("nothing here", same);
}
