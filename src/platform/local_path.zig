const std = @import("std");
const builtin = @import("builtin");
const platform_text = @import("text.zig");

pub fn separator() u8 {
    return separatorForOs(builtin.os.tag);
}

pub fn separatorForOs(os_tag: std.Target.Os.Tag) u8 {
    return switch (os_tag) {
        .windows => '\\',
        else => '/',
    };
}

pub fn isSeparator(ch: u8) bool {
    return isSeparatorForOs(builtin.os.tag, ch);
}

pub fn isSeparatorForOs(os_tag: std.Target.Os.Tag, ch: u8) bool {
    return switch (os_tag) {
        .windows => ch == '\\' or ch == '/',
        else => ch == '/',
    };
}

pub fn endsWithSeparator(path: []const u8) bool {
    return endsWithSeparatorForOs(builtin.os.tag, path);
}

pub fn endsWithSeparatorForOs(os_tag: std.Target.Os.Tag, path: []const u8) bool {
    if (path.len == 0) return false;
    return isSeparatorForOs(os_tag, path[path.len - 1]);
}

pub fn endsWithSeparatorForSeparator(path: []const u8, sep: u8) bool {
    if (path.len == 0) return false;
    const last = path[path.len - 1];
    if (sep == '\\') return last == '\\' or last == '/';
    return last == sep;
}

pub fn joinInto(buf: []u8, parent_path: []const u8, name: []const u8) ?[]const u8 {
    return joinIntoForOs(builtin.os.tag, buf, parent_path, name);
}

pub fn joinIntoForOs(os_tag: std.Target.Os.Tag, buf: []u8, parent_path: []const u8, name: []const u8) ?[]const u8 {
    if (parent_path.len > buf.len) return null;
    var pos: usize = 0;
    @memcpy(buf[0..parent_path.len], parent_path);
    pos = parent_path.len;

    const add_sep = parent_path.len > 0 and !endsWithSeparatorForOs(os_tag, parent_path);
    if (add_sep) {
        if (pos >= buf.len) return null;
        buf[pos] = separatorForOs(os_tag);
        pos += 1;
    }

    if (pos + name.len > buf.len) return null;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    return buf[0..pos];
}

pub fn parentPrefixLen(path: []const u8) usize {
    return parentPrefixLenForOs(builtin.os.tag, path);
}

pub fn parentPrefixLenForOs(os_tag: std.Target.Os.Tag, path: []const u8) usize {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (isSeparatorForOs(os_tag, path[i])) return i + 1;
    }
    return 0;
}

pub fn parent(path: []const u8) ?[]const u8 {
    return parentForOs(builtin.os.tag, path);
}

pub fn parentForOs(os_tag: std.Target.Os.Tag, path: []const u8) ?[]const u8 {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (isSeparatorForOs(os_tag, path[i])) {
            if (i == 0) return path[0..1];
            return path[0..i];
        }
    }
    return null;
}

pub fn basename(path: []const u8) []const u8 {
    return basenameForOs(builtin.os.tag, path);
}

pub fn basenameForOs(os_tag: std.Target.Os.Tag, path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (isSeparatorForOs(os_tag, ch)) start = i + 1;
    }
    return path[start..];
}

pub fn isAbsoluteInstallPath(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return true;
    return hasDriveOrUncRoot(path);
}

fn driveOrUncRootLen(path: []const u8) usize {
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) return 3;

    if (path.len >= 4 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/') and path[2] == '?' and (path[3] == '\\' or path[3] == '/')) {
        if (path.len >= 8 and std.ascii.eqlIgnoreCase(path[4..7], "UNC") and (path[7] == '\\' or path[7] == '/')) {
            return uncRootLenFrom(path, 8);
        }
        if (path.len >= 7 and std.ascii.isAlphabetic(path[4]) and path[5] == ':' and (path[6] == '\\' or path[6] == '/')) return 7;
        return 4;
    }

    if (path.len >= 2 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/')) {
        return uncRootLenFrom(path, 2);
    }

    return 0;
}

fn canonicalDrivePath(path: []const u8) []const u8 {
    if (path.len >= 7 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/') and path[2] == '?' and (path[3] == '\\' or path[3] == '/') and std.ascii.isAlphabetic(path[4]) and path[5] == ':' and (path[6] == '\\' or path[6] == '/')) {
        return path[4..];
    }
    return path;
}

fn uncRootLenFrom(path: []const u8, start: usize) usize {
    const server_end = findSeparator(path, start) orelse return path.len;
    const share_start = server_end + 1;
    const share_end = findSeparator(path, share_start) orelse return path.len;
    return share_end;
}

fn findSeparator(path: []const u8, start: usize) ?usize {
    var i = start;
    while (i < path.len) : (i += 1) {
        if (path[i] == '\\' or path[i] == '/') return i;
    }
    return null;
}

fn trimTrailingSeparators(path: []const u8, root_len: usize) []const u8 {
    var end = path.len;
    while (end > root_len and (path[end - 1] == '\\' or path[end - 1] == '/')) : (end -= 1) {}
    return path[0..end];
}

fn hasDriveOrUncRoot(path: []const u8) bool {
    return driveOrUncRootLen(path) > 0;
}

fn normalizeDriveOrUncPath(path: []const u8, buf: []u8) ?[]const u8 {
    var out_len: usize = 0;
    if (path.len >= 8 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/') and path[2] == '?' and (path[3] == '\\' or path[3] == '/') and std.ascii.eqlIgnoreCase(path[4..7], "UNC") and (path[7] == '\\' or path[7] == '/')) {
        if (buf.len < 2) return null;
        buf[0] = '\\';
        buf[1] = '\\';
        out_len = 2;
        for (path[8..]) |ch| {
            if (out_len >= buf.len) return null;
            buf[out_len] = if (ch == '/') '\\' else ch;
            out_len += 1;
        }
    } else {
        const source = canonicalDrivePath(path);
        for (source) |ch| {
            if (out_len >= buf.len) return null;
            buf[out_len] = if (ch == '/') '\\' else ch;
            out_len += 1;
        }
    }

    const normalized = buf[0..out_len];
    const root_len = driveOrUncRootLen(normalized);
    if (root_len == 0) return null;
    return trimTrailingSeparators(normalized, root_len);
}

fn simpleDrivePathCaseFold(codepoint: u21) u21 {
    if (codepoint >= 'A' and codepoint <= 'Z') return codepoint + 0x20;
    if (codepoint >= 0x00C0 and codepoint <= 0x00D6) return codepoint + 0x20;
    if (codepoint >= 0x00D8 and codepoint <= 0x00DE) return codepoint + 0x20;
    if (codepoint == 0x0178) return 0x00FF;
    if (codepoint >= 0x0100 and codepoint <= 0x0177 and codepoint % 2 == 0) return codepoint + 1;
    if (codepoint >= 0x0181 and codepoint <= 0x024E) {
        return switch (codepoint) {
            0x0181 => 0x0253,
            0x0182, 0x0184, 0x0187, 0x018B, 0x0191, 0x0198, 0x01A0, 0x01A2, 0x01A4, 0x01A7, 0x01AC, 0x01AF, 0x01B3, 0x01B5, 0x01B8, 0x01BC, 0x01CD, 0x01CF, 0x01D1, 0x01D3, 0x01D5, 0x01D7, 0x01D9, 0x01DB, 0x01DE, 0x01E0, 0x01E2, 0x01E4, 0x01E6, 0x01E8, 0x01EA, 0x01EC, 0x01EE, 0x01F4, 0x01F8, 0x01FA, 0x01FC, 0x01FE, 0x0200, 0x0202, 0x0204, 0x0206, 0x0208, 0x020A, 0x020C, 0x020E, 0x0210, 0x0212, 0x0214, 0x0216, 0x0218, 0x021A, 0x021C, 0x021E, 0x0220, 0x0222, 0x0224, 0x0226, 0x0228, 0x022A, 0x022C, 0x022E, 0x0230, 0x0232, 0x0246, 0x0248, 0x024A, 0x024C, 0x024E => codepoint + 1,
            0x0186 => 0x0254,
            0x0189 => 0x0256,
            0x018A => 0x0257,
            0x018E => 0x01DD,
            0x018F => 0x0259,
            0x0190 => 0x025B,
            0x0193 => 0x0260,
            0x0194 => 0x0263,
            0x0196 => 0x0269,
            0x0197 => 0x0268,
            0x019C => 0x026F,
            0x019D => 0x0272,
            0x019F => 0x0275,
            0x01A6 => 0x0280,
            0x01A9 => 0x0283,
            0x01AE => 0x0288,
            0x01B1 => 0x028A,
            0x01B2 => 0x028B,
            0x01B7 => 0x0292,
            0x01F1, 0x01F2 => 0x01F3,
            0x023A => 0x2C65,
            0x023B => 0x023C,
            0x023D => 0x019A,
            0x023E => 0x2C66,
            0x0241 => 0x0242,
            0x0243 => 0x0180,
            0x0244 => 0x0289,
            0x0245 => 0x028C,
            else => codepoint,
        };
    }
    if (codepoint >= 0x0391 and codepoint <= 0x03A1) return codepoint + 0x20;
    if (codepoint >= 0x03A3 and codepoint <= 0x03AB) return codepoint + 0x20;
    if (codepoint == 0x0386) return 0x03AC;
    if (codepoint >= 0x0388 and codepoint <= 0x038A) return codepoint + 0x25;
    if (codepoint == 0x038C) return 0x03CC;
    if (codepoint >= 0x038E and codepoint <= 0x038F) return codepoint + 0x3F;
    if (codepoint >= 0x0400 and codepoint <= 0x040F) return codepoint + 0x50;
    if (codepoint >= 0x0410 and codepoint <= 0x042F) return codepoint + 0x20;
    return codepoint;
}

fn drivePathCaseInsensitiveUtf8Equal(a: []const u8, b: []const u8) bool {
    if (platform_text.nativeOrdinalIgnoreCaseUtf8Equal(a, b)) |equal| return equal;

    const a_view = std.unicode.Utf8View.init(a) catch return std.mem.eql(u8, a, b);
    const b_view = std.unicode.Utf8View.init(b) catch return std.mem.eql(u8, a, b);
    var a_it = a_view.iterator();
    var b_it = b_view.iterator();
    while (true) {
        const a_cp = a_it.nextCodepoint();
        const b_cp = b_it.nextCodepoint();
        if (a_cp == null or b_cp == null) return a_cp == null and b_cp == null;
        if (simpleDrivePathCaseFold(a_cp.?) != simpleDrivePathCaseFold(b_cp.?)) return false;
    }
}

fn driveOrUncAbsolutePathEqual(a: []const u8, b: []const u8) bool {
    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    const a_normalized = normalizeDriveOrUncPath(a, &a_buf) orelse return false;
    const b_normalized = normalizeDriveOrUncPath(b, &b_buf) orelse return false;
    return drivePathCaseInsensitiveUtf8Equal(a_normalized, b_normalized);
}

fn nativeAbsolutePathEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, trimTrailingSeparators(a, 1), trimTrailingSeparators(b, 1));
}

pub fn absolutePathEqual(a: []const u8, b: []const u8) bool {
    if (driveOrUncAbsolutePathEqual(a, b)) return true;
    return nativeAbsolutePathEqual(a, b);
}

test "platform local path joins with target separators" {
    var buf: [128]u8 = undefined;

    const win = joinIntoForOs(.windows, &buf, "C:\\Users", "xzg").?;
    try std.testing.expectEqualStrings("C:\\Users\\xzg", win);

    const win_slash = joinIntoForOs(.windows, &buf, "C:/Users/", "xzg").?;
    try std.testing.expectEqualStrings("C:/Users/xzg", win_slash);

    const linux = joinIntoForOs(.linux, &buf, "/home/xzg", "Downloads").?;
    try std.testing.expectEqualStrings("/home/xzg/Downloads", linux);
}

test "platform local path basename and parents follow target separator rules" {
    try std.testing.expectEqualStrings("file.txt", basenameForOs(.windows, "C:\\tmp\\file.txt"));
    try std.testing.expectEqualStrings("C:\\tmp\\file.txt", basenameForOs(.linux, "C:\\tmp\\file.txt"));
    try std.testing.expectEqualStrings("file.txt", basenameForOs(.linux, "/tmp/file.txt"));

    try std.testing.expectEqual(@as(usize, "C:\\tmp\\".len), parentPrefixLenForOs(.windows, "C:\\tmp\\file.txt"));
    try std.testing.expectEqualStrings("C:\\tmp", parentForOs(.windows, "C:\\tmp\\file.txt").?);
    try std.testing.expectEqualStrings("/tmp", parentForOs(.linux, "/tmp/file.txt").?);
}

test "platform local path recognizes absolute install paths" {
    try std.testing.expect(isAbsoluteInstallPath("C:\\Apps\\Phantty"));
    try std.testing.expect(isAbsoluteInstallPath("\\\\server\\share\\App"));
    try std.testing.expect(isAbsoluteInstallPath("\\\\?\\C:\\Apps\\Phantty"));
    try std.testing.expect(isAbsoluteInstallPath("/usr/local/bin"));
    try std.testing.expect(!isAbsoluteInstallPath("relative/path"));
}

test "platform local path compares absolute paths with platform-compatible rules" {
    try std.testing.expect(absolutePathEqual("C:\\Apps\\Phantty", "c:\\apps\\phantty\\"));
    try std.testing.expect(absolutePathEqual("D:/Tools/Phantty/", "d:/tools/phantty"));
    try std.testing.expect(absolutePathEqual("C:\\Apps\\Ångström", "c:\\apps\\ångström\\"));
    try std.testing.expect(absolutePathEqual("\\\\Server\\Share\\Apps\\Phantty", "\\\\server\\share\\apps\\phantty\\"));
    try std.testing.expect(absolutePathEqual("//Server/Share/Apps/Phantty", "\\\\server\\share\\apps\\phantty"));
    try std.testing.expect(absolutePathEqual("\\\\server\\share", "\\\\SERVER\\SHARE\\"));
    try std.testing.expect(absolutePathEqual("\\\\?\\C:\\Apps\\Phantty", "C:\\Apps\\Phantty"));
    try std.testing.expect(absolutePathEqual("\\\\?\\C:\\Apps\\Phantty", "\\\\?\\c:\\apps\\phantty\\"));
    try std.testing.expect(absolutePathEqual("\\\\?\\UNC\\Server\\Share\\App", "\\\\server\\share\\App"));
    try std.testing.expect(absolutePathEqual("\\\\?\\UNC\\server\\share", "\\\\server\\share\\"));
    try std.testing.expect(absolutePathEqual("/opt/phantty/", "/opt/phantty"));
    try std.testing.expect(!absolutePathEqual("/opt/phantty", "/opt/other"));
}
