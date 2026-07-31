const std = @import("std");

const png_signature = "\x89PNG\r\n\x1a\n";
const max_deflate_block: usize = 65_535;

const png_dimensions = struct {
    const Dimensions = struct { width: u32, height: u32 };

    fn parse(data: []const u8) ?Dimensions {
        if (data.len < 24) return null;
        if (!std.mem.eql(u8, data[0..8], png_signature)) return null;
        if (std.mem.readInt(u32, data[8..12], .big) != 13) return null;
        if (!std.mem.eql(u8, data[12..16], "IHDR")) return null;
        return .{
            .width = std.mem.readInt(u32, data[16..20], .big),
            .height = std.mem.readInt(u32, data[20..24], .big),
        };
    }
};

pub const Error = error{
    InvalidImageDimensions,
    InvalidImageBuffer,
    InvalidPngChunkLength,
} || std.mem.Allocator.Error;

pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []const u8,
};

fn checkedRgbaLen(width: u32, height: u32) Error!usize {
    if (width == 0 or height == 0) return error.InvalidImageDimensions;
    const row_bytes = try checkedRowBytes(width);
    return std.math.mul(usize, row_bytes, @as(usize, height)) catch return error.InvalidImageDimensions;
}

fn checkedRowBytes(width: u32) Error!usize {
    return std.math.mul(usize, @as(usize, width), 4) catch return error.InvalidImageDimensions;
}

fn checkedFilteredLen(width: u32, height: u32) Error!usize {
    const row_bytes = try checkedRowBytes(width);
    const row_len = std.math.add(usize, row_bytes, 1) catch return error.InvalidImageDimensions;
    return std.math.mul(usize, @as(usize, height), row_len) catch return error.InvalidImageDimensions;
}

fn checkedZlibStoredLen(payload_len: usize) Error!usize {
    const block_numerator = std.math.add(usize, payload_len, max_deflate_block - 1) catch return error.InvalidPngChunkLength;
    const blocks = block_numerator / max_deflate_block;
    const block_headers = std.math.mul(usize, blocks, 5) catch return error.InvalidPngChunkLength;
    const with_headers = std.math.add(usize, payload_len, block_headers) catch return error.InvalidPngChunkLength;
    return std.math.add(usize, with_headers, 6) catch return error.InvalidPngChunkLength;
}

fn appendU32(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendChunk(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    if (data.len > std.math.maxInt(u32)) return error.InvalidPngChunkLength;
    try appendU32(out, allocator, @intCast(data.len));
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, data);

    var hasher = std.hash.crc.Crc32.init();
    hasher.update(kind);
    hasher.update(data);
    try appendU32(out, allocator, hasher.final());
}

fn appendZlibStored(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, payload: []const u8) !void {
    try out.appendSlice(allocator, &.{ 0x78, 0x01 });
    var remaining = payload;
    while (remaining.len > 0) {
        const n = @min(remaining.len, max_deflate_block);
        const final: u8 = if (n == remaining.len) 1 else 0;
        try out.append(allocator, final);

        var len_buf: [2]u8 = undefined;
        const len16: u16 = @intCast(n);
        std.mem.writeInt(u16, &len_buf, len16, .little);
        try out.appendSlice(allocator, &len_buf);
        std.mem.writeInt(u16, &len_buf, ~len16, .little);
        try out.appendSlice(allocator, &len_buf);

        try out.appendSlice(allocator, remaining[0..n]);
        remaining = remaining[n..];
    }
    try appendU32(out, allocator, std.hash.Adler32.hash(payload));
}

pub fn encodeRgba(allocator: std.mem.Allocator, image: Image) Error![]u8 {
    const expected = try checkedRgbaLen(image.width, image.height);
    if (image.rgba.len != expected) return error.InvalidImageBuffer;

    const row_bytes = try checkedRowBytes(image.width);
    const filtered_len = try checkedFilteredLen(image.width, image.height);
    if (try checkedZlibStoredLen(filtered_len) > std.math.maxInt(u32)) return error.InvalidPngChunkLength;
    var filtered = try std.ArrayListUnmanaged(u8).initCapacity(allocator, filtered_len);
    defer filtered.deinit(allocator);
    for (0..image.height) |row| {
        try filtered.append(allocator, 0);
        const start = row * row_bytes;
        try filtered.appendSlice(allocator, image.rgba[start .. start + row_bytes]);
    }

    var idat = std.ArrayListUnmanaged(u8).empty;
    defer idat.deinit(allocator);
    try appendZlibStored(&idat, allocator, filtered.items);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, png_signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], image.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], image.height, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(&out, allocator, "IHDR", &ihdr);
    try appendChunk(&out, allocator, "IDAT", idat.items);
    try appendChunk(&out, allocator, "IEND", &.{});
    return out.toOwnedSlice(allocator);
}

pub fn flipRgbaRows(allocator: std.mem.Allocator, bottom_up: []const u8, width: u32, height: u32) Error![]u8 {
    const expected = try checkedRgbaLen(width, height);
    if (bottom_up.len != expected) return error.InvalidImageBuffer;
    const row_bytes = try checkedRowBytes(width);
    const out = try allocator.alloc(u8, bottom_up.len);
    errdefer allocator.free(out);
    for (0..height) |row| {
        const src_row = @as(usize, height) - 1 - row;
        @memcpy(out[row * row_bytes .. (row + 1) * row_bytes], bottom_up[src_row * row_bytes .. (src_row + 1) * row_bytes]);
    }
    return out;
}

test "png_writer encodes RGBA8 PNG with expected dimensions" {
    const rgba = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    const png = try encodeRgba(std.testing.allocator, .{
        .width = 2,
        .height = 2,
        .rgba = &rgba,
    });
    defer std.testing.allocator.free(png);

    try std.testing.expect(std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n"));
    const dims = png_dimensions.parse(png) orelse return error.MissingPngDimensions;
    try std.testing.expectEqual(@as(u32, 2), dims.width);
    try std.testing.expectEqual(@as(u32, 2), dims.height);
    try std.testing.expect(std.mem.endsWith(u8, png, "IEND\xaeB`\x82"));
}

test "png_writer flips OpenGL bottom-up RGBA rows into PNG top-down rows" {
    const bottom_up = [_]u8{
        1, 1, 1, 255, 2, 2, 2, 255,
        3, 3, 3, 255, 4, 4, 4, 255,
    };
    const top_down = try flipRgbaRows(std.testing.allocator, &bottom_up, 2, 2);
    defer std.testing.allocator.free(top_down);

    try std.testing.expectEqualSlices(u8, &[_]u8{
        3, 3, 3, 255, 4, 4, 4, 255,
        1, 1, 1, 255, 2, 2, 2, 255,
    }, top_down);
}

test "png_writer rejects RGBA buffers with the wrong size" {
    try std.testing.expectError(error.InvalidImageBuffer, encodeRgba(std.testing.allocator, .{
        .width = 2,
        .height = 2,
        .rgba = &[_]u8{0} ** 15,
    }));
}

test "png_writer emits valid chunk CRCs and stored zlib payload" {
    const rgba = [_]u8{
        10, 20, 30, 255,
        40, 50, 60, 255,
    };
    const png = try encodeRgba(std.testing.allocator, .{
        .width = 1,
        .height = 2,
        .rgba = &rgba,
    });
    defer std.testing.allocator.free(png);

    var offset: usize = png_signature.len;
    inline for (.{ "IHDR", "IDAT", "IEND" }) |kind| {
        const len = std.mem.readInt(u32, png[offset..][0..4], .big);
        const chunk_kind = png[offset + 4 ..][0..4];
        const data = png[offset + 8 ..][0..len];
        const crc = std.mem.readInt(u32, png[offset + 8 + len ..][0..4], .big);

        try std.testing.expectEqualStrings(kind, chunk_kind);
        var hasher = std.hash.crc.Crc32.init();
        hasher.update(chunk_kind);
        hasher.update(data);
        try std.testing.expectEqual(hasher.final(), crc);

        if (std.mem.eql(u8, kind, "IDAT")) {
            try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x01, 0x01, 10, 0, 245, 255 }, data[0..7]);
            try std.testing.expectEqualSlices(u8, &[_]u8{
                0, 10, 20, 30, 255,
                0, 40, 50, 60, 255,
            }, data[7..17]);
            try std.testing.expectEqual(std.hash.Adler32.hash(data[7..17]), std.mem.readInt(u32, data[17..21], .big));
        }

        offset += 12 + len;
    }
    try std.testing.expectEqual(png.len, offset);
}
