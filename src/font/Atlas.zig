/// Font atlas — 2D rectangle bin packer for glyph textures.
///
/// Modeled after Ghostty's `src/font/Atlas.zig`.
/// Uses a best-height-then-best-width bin packing algorithm
/// (from Jukka Jylänki's "A Thousand Ways to Pack the Bin").
///
/// Glyphs are rasterized on demand and packed into a CPU-side pixel buffer.
/// The renderer syncs the buffer to a GPU texture when the `modified` counter
/// changes. The atlas starts at 512×512 and doubles when full.
///
/// A 1px border is reserved around the atlas edges to prevent sampling artifacts.

const std = @import("std");

const Atlas = @This();

pub const Format = enum {
    grayscale, // 1 byte per pixel (text glyphs)
    bgra, // 4 bytes per pixel (color emoji — future)

    pub fn depth(self: Format) u32 {
        return switch (self) {
            .grayscale => 1,
            .bgra => 4,
        };
    }
};

pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// A node tracks a horizontal span of available space at a given y.
/// Think of it as a "shelf" in the skyline packing algorithm.
const Node = struct {
    x: u32,
    y: u32,
    width: u32,
};

/// CPU-side pixel buffer (row-major, tightly packed per format depth).
data: []u8,

/// Width = height (always square).
size: u32,

/// Available horizontal spans (skyline nodes).
nodes: std.ArrayListUnmanaged(Node),

/// Pixel format.
format: Format,

/// Bumped on every pixel write. Renderer compares this to know when
/// to re-upload to the GPU.
modified: std.atomic.Value(usize),

pub fn init(allocator: std.mem.Allocator, size: u32, format: Format) !Atlas {
    const depth = format.depth();
    const data = try allocator.alloc(u8, @as(usize, size) * size * depth);
    errdefer allocator.free(data);
    @memset(data, 0);

    // Start with a single node spanning the usable area (1px border on each side).
    var nodes = std.ArrayListUnmanaged(Node){};
    try nodes.append(allocator, .{ .x = 1, .y = 1, .width = size - 2 });

    return .{
        .data = data,
        .size = size,
        .nodes = nodes,
        .format = format,
        .modified = std.atomic.Value(usize).init(0),
    };
}

pub fn deinit(self: *Atlas, allocator: std.mem.Allocator) void {
    allocator.free(self.data);
    self.nodes.deinit(allocator);
    self.* = undefined;
}

/// Reserve a rectangle of the given size in the atlas.
/// Returns the region (top-left x, y, width, height) where pixels should be written.
/// Returns `error.AtlasFull` if the glyph doesn't fit.
pub fn reserve(self: *Atlas, allocator: std.mem.Allocator, width: u32, height: u32) !Region {
    // Add 1px padding around each glyph to prevent GL_LINEAR from
    // sampling neighboring glyphs in the atlas.
    const padded_width = width + 1;
    const padded_height = height + 1;

    // Find best position using best-height-then-best-width heuristic.
    var best_idx: ?usize = null;
    var best_height: u32 = std.math.maxInt(u32);
    var best_width: u32 = std.math.maxInt(u32);
    var best_y: u32 = 0;

    for (self.nodes.items, 0..) |_, idx| {
        if (self.fit(idx, padded_width, padded_height)) |y| {
            // Height heuristic: minimize the resulting top edge (y + height).
            const result_height = y + padded_height;
            if (result_height < best_height or
                (result_height == best_height and self.nodes.items[idx].width < best_width))
            {
                best_height = result_height;
                best_width = self.nodes.items[idx].width;
                best_y = y;
                best_idx = idx;
            }
        }
    }

    const idx = best_idx orelse return error.AtlasFull;
    const x = self.nodes.items[idx].x;

    // Insert a new node for the padded rectangle (padding is below/right).
    const new_node = Node{ .x = x, .y = best_y + padded_height, .width = padded_width };
    try self.nodes.insert(allocator, idx, new_node);

    // Shrink or remove overlapping nodes to the right.
    // We always check at position (idx + 1) since orderedRemove shifts
    // subsequent elements down into the same slot.
    while (idx + 1 < self.nodes.items.len) {
        const prev = self.nodes.items[idx];
        var node = &self.nodes.items[idx + 1];

        const prev_end = prev.x + prev.width;
        if (node.x < prev_end) {
            const shrink = prev_end - node.x;
            if (node.width <= shrink) {
                // Completely covered — remove it.
                _ = self.nodes.orderedRemove(idx + 1);
                continue;
            } else {
                // Partially covered — shrink it.
                node.x += shrink;
                node.width -= shrink;
                break;
            }
        } else {
            break;
        }
    }

    // Merge adjacent nodes with the same y.
    self.merge();

    return .{ .x = x, .y = best_y, .width = width, .height = height };
}

/// Copy pixel data into the atlas at the given region.
/// `src` must contain exactly `region.width * region.height * format.depth()` bytes.
/// Bumps the `modified` counter atomically.
pub fn set(self: *Atlas, region: Region, src: []const u8) void {
    const depth = self.format.depth();
    const expected_len = region.width * region.height * depth;
    std.debug.assert(src.len == expected_len);

    const atlas_stride = self.size * depth;
    for (0..region.height) |row| {
        const dst_offset = (region.y + @as(u32, @intCast(row))) * atlas_stride + region.x * depth;
        const src_offset = @as(u32, @intCast(row)) * region.width * depth;
        const row_bytes = region.width * depth;
        @memcpy(
            self.data[dst_offset..][0..row_bytes],
            src[src_offset..][0..row_bytes],
        );
    }

    _ = self.modified.fetchAdd(1, .release);
}

/// Grow the atlas to a larger size. Existing pixel data is preserved
/// (copied to top-left of the new buffer). Nodes are extended to cover
/// the new space.
pub fn grow(self: *Atlas, allocator: std.mem.Allocator, new_size: u32) !void {
    std.debug.assert(new_size > self.size);

    const depth = self.format.depth();
    const new_data = try allocator.alloc(u8, @as(usize, new_size) * new_size * depth);
    @memset(new_data, 0);

    // Copy existing rows into the new buffer.
    const old_stride = self.size * depth;
    const new_stride = new_size * depth;
    for (0..self.size) |row| {
        const old_offset = row * old_stride;
        const new_offset = row * new_stride;
        @memcpy(new_data[new_offset..][0..old_stride], self.data[old_offset..][0..old_stride]);
    }

    allocator.free(self.data);
    self.data = new_data;

    // Extend the last node (or add a new one) to cover the extra width.
    // Also update the initial node constraint for the new border.
    const old_size = self.size;
    self.size = new_size;

    // Add a node for the new space to the right of the old area.
    // The old area's right edge was at old_size - 1 (1px border).
    // New usable right edge is new_size - 1.
    try self.nodes.append(allocator, .{
        .x = old_size - 1,
        .y = 1,
        .width = new_size - old_size,
    });

    self.merge();

    _ = self.modified.fetchAdd(1, .release);
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Check if a rectangle of (width, height) fits starting at node `idx`.
/// Returns the maximum y coordinate across all spanned nodes, or null if
/// the rectangle extends beyond the atlas boundary.
fn fit(self: *const Atlas, idx: usize, width: u32, height: u32) ?u32 {
    const nodes = self.nodes.items;
    const x = nodes[idx].x;

    // Check right boundary (1px border).
    if (x + width > self.size - 1) return null;

    var remaining_width = width;
    var max_y: u32 = 0;
    var i = idx;

    while (remaining_width > 0) {
        if (i >= nodes.len) return null;

        const node = nodes[i];
        max_y = @max(max_y, node.y);

        // Check bottom boundary (1px border).
        if (max_y + height > self.size - 1) return null;

        if (node.width >= remaining_width) {
            remaining_width = 0;
        } else {
            remaining_width -= node.width;
        }
        i += 1;
    }

    return max_y;
}

/// Merge adjacent nodes with the same y coordinate.
fn merge(self: *Atlas) void {
    var i: usize = 0;
    while (i + 1 < self.nodes.items.len) {
        const a = &self.nodes.items[i];
        const b = self.nodes.items[i + 1];
        if (a.y == b.y) {
            a.width += b.width;
            _ = self.nodes.orderedRemove(i + 1);
        } else {
            i += 1;
        }
    }
}
