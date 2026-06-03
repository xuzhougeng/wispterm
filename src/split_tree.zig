/// SplitTree represents a tree of terminal surfaces that can be divided.
///
/// In its basic state, there are no splits and it is a single full-sized
/// terminal. However, it can be split arbitrarily many times among two
/// axes (horizontal and vertical) to create a tree of terminal surfaces.
///
/// This is an immutable tree structure, meaning all operations on it
/// will return a new tree with the operation applied. This allows us to
/// store versions of the tree in a history for easy undo/redo.
///
/// This is a monomorphized port of Ghostty's `src/datastruct/split_tree.zig`,
/// specialized for `*Surface` instead of a generic View type.
///
/// Ghostty reference: https://github.com/ghostty-org/ghostty/blob/main/src/datastruct/split_tree.zig
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Surface = @import("Surface.zig");

const SplitTree = @This();

/// The arena allocator used for all allocations in the tree.
/// Since the tree is an immutable structure, this lets us
/// cleanly free all memory when the tree is deinitialized.
arena: ArenaAllocator,

/// All the nodes in the tree. Node at index 0 is always the root.
nodes: []const Node,

/// The handle of the zoomed node. A "zoomed" node is one that is
/// expected to be made the full size of the split tree. Various
/// operations may unzoom (e.g. resize).
zoomed: ?Node.Handle,

/// An empty tree.
pub const empty: SplitTree = .{
    // Arena can be undefined because we have zero allocated nodes.
    // If our nodes are empty our deinit function doesn't touch the arena.
    .arena = undefined,
    .nodes = &.{},
    .zoomed = null,
};

pub const Node = union(enum) {
    leaf: *Surface,
    split: Split,

    /// A handle into the nodes array. This lets us keep track of
    /// nodes with 16-bit handles rather than full pointer-width values.
    pub const Handle = enum(Backing) {
        root = 0,
        _,

        pub const Backing = u16;

        pub inline fn idx(self: Handle) usize {
            return @intFromEnum(self);
        }

        /// Offset the handle by a given amount.
        pub fn offset(self: Handle, v: usize) Handle {
            const self_usize: usize = @intCast(@intFromEnum(self));
            const final = self_usize + v;
            assert(final < std.math.maxInt(Backing));
            return @enumFromInt(final);
        }
    };
};

pub const Split = struct {
    layout: Layout,
    ratio: f16,
    left: Node.Handle,
    right: Node.Handle,

    pub const Layout = enum { horizontal, vertical };
    pub const Direction = enum { left, right, down, up };
};

/// Initialize a new tree with a single surface.
pub fn init(gpa: Allocator, surface: *Surface) Allocator.Error!SplitTree {
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const nodes = try alloc.alloc(Node, 1);
    nodes[0] = .{ .leaf = surface.ref() };

    return .{
        .arena = arena,
        .nodes = nodes,
        .zoomed = null,
    };
}

pub fn deinit(self: *SplitTree) void {
    // Important: only free memory if we have memory to free,
    // because we use an undefined arena for empty trees.
    if (self.nodes.len > 0) {
        // Unref all our surfaces
        const gpa: Allocator = self.arena.child_allocator;
        for (self.nodes) |node| switch (node) {
            .leaf => |surface| surface.unref(gpa),
            .split => {},
        };
        self.arena.deinit();
    }

    self.* = undefined;
}

/// Clone this tree, returning a new tree with the same nodes.
pub fn clone(self: *const SplitTree, gpa: Allocator) Allocator.Error!SplitTree {
    // If we're empty then return an empty tree.
    if (self.isEmpty()) return .empty;

    // Create a new arena allocator for the clone.
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // Allocate a new nodes array and copy the existing nodes into it.
    const nodes = try alloc.dupe(Node, self.nodes);

    // Increase the reference count of all the surfaces in the nodes.
    try refNodes(nodes);

    return .{
        .arena = arena,
        .nodes = nodes,
        .zoomed = self.zoomed,
    };
}

/// Returns true if this is an empty tree.
pub fn isEmpty(self: *const SplitTree) bool {
    return self.nodes.len == 0;
}

/// Returns true if this tree has more than one split (i.e., the root
/// is a split node). This is useful for determining if actions like
/// resize_split or toggle_split_zoom are performable.
pub fn isSplit(self: *const SplitTree) bool {
    if (self.isEmpty()) return false;
    return switch (self.nodes[0]) {
        .split => true,
        .leaf => false,
    };
}

/// An iterator over all the surfaces in the tree.
pub fn iterator(self: *const SplitTree) Iterator {
    return .{ .nodes = self.nodes };
}

pub const SurfaceEntry = struct {
    handle: Node.Handle,
    surface: *Surface,
};

pub const Iterator = struct {
    i: Node.Handle = .root,
    nodes: []const Node,

    pub fn next(self: *Iterator) ?SurfaceEntry {
        // If we have no nodes, return null.
        if (@intFromEnum(self.i) >= self.nodes.len) return null;

        // Get the current node and increment the index.
        const handle = self.i;
        self.i = @enumFromInt(handle.idx() + 1);
        const node = self.nodes[handle.idx()];

        return switch (node) {
            .leaf => |s| .{ .handle = handle, .surface = s },
            .split => self.next(),
        };
    }
};

/// Change the zoomed state to the given node. Assumes the handle is valid.
/// This is the one mutable operation on the tree.
pub fn zoom(self: *SplitTree, handle: ?Node.Handle) void {
    if (handle) |v| {
        assert(@intFromEnum(v) >= 0);
        assert(@intFromEnum(v) < self.nodes.len);
    }
    self.zoomed = handle;
}

pub const Goto = union(enum) {
    /// Previous surface, null if we're the first surface.
    previous,

    /// Next surface, null if we're the last surface.
    next,

    /// Previous surface, but wrapped around to the last surface. May
    /// return the same surface if this is the first surface.
    previous_wrapped,

    /// Next surface, but wrapped around to the first surface. May return
    /// the same surface if this is the last surface.
    next_wrapped,

    /// A spatial direction. "Spatial" means that the direction is
    /// based on the nearest surface in the given direction visually
    /// as the surfaces are laid out on a 2D grid.
    spatial: Spatial.Direction,
};

/// Goto a surface from a certain point in the split tree. Returns null
/// if the direction results in no visitable surface.
///
/// Allocator is only used for temporary state for spatial navigation.
pub fn goto(
    self: *const SplitTree,
    alloc: Allocator,
    from: Node.Handle,
    to: Goto,
) Allocator.Error!?Node.Handle {
    return switch (to) {
        .previous => self.previous(from),
        .next => self.nextHandle(from),
        .previous_wrapped => self.previous(from) orelse self.deepest(.right, .root),
        .next_wrapped => self.nextHandle(from) orelse self.deepest(.left, .root),
        .spatial => |d| spatial: {
            // Get our spatial representation.
            var sp = try self.spatial(alloc);
            defer sp.deinit(alloc);
            break :spatial self.nearest(sp, from, d);
        },
    };
}

pub const Side = enum { left, right };

/// Returns the deepest surface in the tree in the given direction.
/// This can be used to find the leftmost/rightmost surface within
/// a given split structure.
pub fn deepest(
    self: *const SplitTree,
    side: Side,
    from: Node.Handle,
) Node.Handle {
    var current: Node.Handle = from;
    while (true) {
        switch (self.nodes[current.idx()]) {
            .leaf => return current,
            .split => |s| current = switch (side) {
                .left => s.left,
                .right => s.right,
            },
        }
    }
}

/// Returns the previous surface from the given node handle (which itself
/// doesn't need to be a surface). If there is no previous (this is the
/// most previous surface) then this will return null.
///
/// "Previous" is defined as the previous node in an in-order
/// traversal of the tree.
fn previous(self: *const SplitTree, from: Node.Handle) ?Node.Handle {
    return switch (self.previousBacktrack(from, .root)) {
        .result => |v| v,
        .backtrack, .deadend => null,
    };
}

/// Same as `previous`, but returns the next surface instead.
fn nextHandle(self: *const SplitTree, from: Node.Handle) ?Node.Handle {
    return switch (self.nextBacktrack(from, .root)) {
        .result => |v| v,
        .backtrack, .deadend => null,
    };
}

// Design note: we use a recursive backtracking search because
// split trees are never that deep, so we can abuse the stack as
// a safe allocator (stack overflow unlikely unless the kernel is
// tuned in some really weird way).
const Backtrack = union(enum) {
    deadend,
    backtrack,
    result: Node.Handle,
};

fn previousBacktrack(
    self: *const SplitTree,
    from: Node.Handle,
    current: Node.Handle,
) Backtrack {
    // If we reached the point that we're trying to find the previous
    // value of, then we need to backtrack from here.
    if (from == current) return .backtrack;

    return switch (self.nodes[current.idx()]) {
        // If we hit a leaf that isn't our target, then deadend.
        .leaf => .deadend,

        .split => |s| switch (self.previousBacktrack(from, s.left)) {
            .result => |v| .{ .result = v },

            // Backtrack from the left means we have to continue
            // backtracking because we can't see what's before the left.
            .backtrack => .backtrack,

            // If we hit a deadend on the left then let's move right.
            .deadend => switch (self.previousBacktrack(from, s.right)) {
                .result => |v| .{ .result = v },

                // Deadend means its not in this split at all since
                // we already tracked the left.
                .deadend => .deadend,

                // Backtrack means that its in our left view because
                // we can see the immediate previous and there MUST
                // be leaves (we can't have split-only leaves).
                .backtrack => .{ .result = self.deepest(.right, s.left) },
            },
        },
    };
}

// See previousBacktrack for detailed comments. This is a mirror of that.
fn nextBacktrack(
    self: *const SplitTree,
    from: Node.Handle,
    current: Node.Handle,
) Backtrack {
    if (from == current) return .backtrack;
    return switch (self.nodes[current.idx()]) {
        .leaf => .deadend,
        .split => |s| switch (self.nextBacktrack(from, s.right)) {
            .result => |v| .{ .result = v },
            .backtrack => .backtrack,
            .deadend => switch (self.nextBacktrack(from, s.left)) {
                .result => |v| .{ .result = v },
                .deadend => .deadend,
                .backtrack => .{ .result = self.deepest(.left, s.right) },
            },
        },
    };
}

/// Returns the nearest leaf node (surface) in the given direction.
fn nearest(
    self: *const SplitTree,
    sp: Spatial,
    from: Node.Handle,
    direction: Spatial.Direction,
) ?Node.Handle {
    const target = sp.slots[from.idx()];

    var result: ?struct {
        handle: Node.Handle,
        distance: f16,
    } = null;
    for (sp.slots, 0..) |slot, handle| {
        // Never match ourself
        if (handle == from.idx()) continue;

        // Only match leaves
        switch (self.nodes[handle]) {
            .leaf => {},
            .split => continue,
        }

        // Ensure it is in the proper direction
        if (!switch (direction) {
            .left => slot.maxX() <= target.x,
            .right => slot.x >= target.maxX(),
            .up => slot.maxY() <= target.y,
            .down => slot.y >= target.maxY(),
        }) continue;

        // Track our distance
        const dx = slot.x - target.x;
        const dy = slot.y - target.y;
        const distance = @sqrt(dx * dx + dy * dy);

        // If we have a nearest it must be closer.
        if (result) |n| {
            if (distance >= n.distance) continue;
        }
        result = .{
            .handle = @enumFromInt(handle),
            .distance = distance,
        };
    }

    return if (result) |n| n.handle else null;
}

/// Resize the given node in place. The node MUST be a split (asserted).
///
/// In general, this is an immutable data structure so this is
/// heavily discouraged. However, this is provided for convenience
/// and performance reasons where its very important for GUIs to
/// update the ratio during a live resize than to redraw the entire
/// widget tree.
pub fn resizeInPlace(
    self: *SplitTree,
    at: Node.Handle,
    ratio: f16,
) void {
    // Let's talk about this constCast. Our member are const but
    // we actually always own their memory. We don't want consumers
    // who directly access the nodes to be able to modify them
    // (without nasty stuff like this), but given this is internal
    // usage its perfectly fine to modify the node in-place.
    const s: *Split = @constCast(&self.nodes[at.idx()].split);
    s.ratio = ratio;
}

/// Swap the surfaces held by two leaf nodes in place. Both handles MUST refer
/// to leaf nodes (asserted). Topology, layout, ratios, zoom state, and
/// reference counts are all unchanged — only the two *Surface pointers swap.
/// Swapping a node with itself is a harmless no-op.
///
/// Like `resizeInPlace`, this mutates the otherwise-immutable nodes via the
/// constCast escape hatch: we own the memory and a swap touches no handles.
pub fn swapLeaves(self: *SplitTree, a: Node.Handle, b: Node.Handle) void {
    assert(a.idx() < self.nodes.len);
    assert(b.idx() < self.nodes.len);
    if (a == b) return;

    const nodes: []Node = @constCast(self.nodes);
    const surf_a = switch (nodes[a.idx()]) {
        .leaf => |s| s,
        .split => unreachable,
    };
    const surf_b = switch (nodes[b.idx()]) {
        .leaf => |s| s,
        .split => unreachable,
    };
    nodes[a.idx()] = .{ .leaf = surf_b };
    nodes[b.idx()] = .{ .leaf = surf_a };
}

/// Insert another tree into this tree at the given node in the
/// specified direction. The other tree will be inserted in the
/// new direction. For example, if the direction is "right" then
/// `insert` is inserted right of the existing node.
///
/// The allocator will be used for the newly created tree.
/// The previous trees will not be freed, but reference counts
/// for the surfaces will be increased accordingly for the new tree.
pub fn split(
    self: *const SplitTree,
    gpa: Allocator,
    at: Node.Handle,
    direction: Split.Direction,
    ratio: f16,
    insert: *const SplitTree,
) Allocator.Error!SplitTree {
    // The new arena for our new tree.
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // We know we're going to need the sum total of the nodes
    // between the two trees plus one for the new split node.
    const nodes = try alloc.alloc(Node, self.nodes.len + insert.nodes.len + 1);
    if (nodes.len > std.math.maxInt(Node.Handle.Backing)) return error.OutOfMemory;

    // We can copy our nodes exactly as they are, since they're
    // mostly not changing (only `at` is changing).
    @memcpy(nodes[0..self.nodes.len], self.nodes);

    // We can copy the destination nodes as well directly next to
    // the source nodes. We just have to go through and offset
    // all the handles in the destination tree to account for
    // the shift.
    const nodes_inserted = nodes[self.nodes.len..][0..insert.nodes.len];
    @memcpy(nodes_inserted, insert.nodes);
    for (nodes_inserted) |*node| switch (node.*) {
        .leaf => {},
        .split => |*s| {
            // We need to offset the handles in the split
            s.left = s.left.offset(self.nodes.len);
            s.right = s.right.offset(self.nodes.len);
        },
    };

    // Determine our split layout and if we're on the left
    const layout: Split.Layout, const left: bool = switch (direction) {
        .left => .{ .horizontal, true },
        .right => .{ .horizontal, false },
        .up => .{ .vertical, true },
        .down => .{ .vertical, false },
    };

    // Copy our previous value to the end of the nodes list and
    // create our new split node.
    nodes[nodes.len - 1] = nodes[at.idx()];
    nodes[at.idx()] = .{ .split = .{
        .layout = layout,
        .ratio = ratio,
        .left = @enumFromInt(if (left) self.nodes.len else nodes.len - 1),
        .right = @enumFromInt(if (left) nodes.len - 1 else self.nodes.len),
    } };

    // We need to increase the reference count of all the nodes.
    try refNodes(nodes);

    return .{
        .arena = arena,
        .nodes = nodes,
        // Splitting always resets zoom state.
        .zoomed = null,
    };
}

/// Remove a node from the tree.
pub fn remove(
    self: *SplitTree,
    gpa: Allocator,
    at: Node.Handle,
) Allocator.Error!SplitTree {
    assert(at.idx() < self.nodes.len);

    // If we're removing node zero then we're clearing the tree.
    if (at == .root) return .empty;

    // The new arena for our new tree.
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // Allocate our new nodes list with the number of nodes we'll
    // need after the removal.
    const nodes = try alloc.alloc(Node, self.countAfterRemoval(
        .root,
        at,
        0,
    ));

    var result: SplitTree = .{
        .arena = arena,
        .nodes = nodes,
        .zoomed = null,
    };

    // Traverse the tree and copy all our nodes into place.
    assert(self.removeNode(
        &result,
        0,
        .root,
        at,
    ) != 0);

    // Increase the reference count of all the nodes.
    try refNodes(nodes);

    return result;
}

fn removeNode(
    old: *SplitTree,
    new: *SplitTree,
    new_offset: usize,
    current: Node.Handle,
    target: Node.Handle,
) usize {
    assert(current != target);

    // If we have a zoomed node and this is it then we migrate it.
    if (old.zoomed) |v| {
        if (v == current) {
            assert(new.zoomed == null);
            new.zoomed = @enumFromInt(new_offset);
        }
    }

    // Let's talk about this constCast. Our member are const but
    // we actually always own their memory. We don't want consumers
    // who directly access the nodes to be able to modify them
    // (without nasty stuff like this), but given this is internal
    // usage its perfectly fine to modify the node in-place.
    const new_nodes: []Node = @constCast(new.nodes);

    switch (old.nodes[current.idx()]) {
        // Leaf is simple, just copy it over. We don't ref anything
        // yet because it'd make undo (errdefer) harder. We do that
        // all at once later.
        .leaf => |surface| {
            new_nodes[new_offset] = .{ .leaf = surface };
            return 1;
        },

        .split => |s| {
            // If we're removing one of the split node sides then
            // we remove the split node itself as well and only add
            // the other (non-removed) side.
            if (s.left == target) return old.removeNode(
                new,
                new_offset,
                s.right,
                target,
            );
            if (s.right == target) return old.removeNode(
                new,
                new_offset,
                s.left,
                target,
            );

            // Neither side is being directly removed, so we traverse.
            const left = old.removeNode(
                new,
                new_offset + 1,
                s.left,
                target,
            );
            assert(left != 0);
            const right = old.removeNode(
                new,
                new_offset + left + 1,
                s.right,
                target,
            );
            assert(right != 0);
            new_nodes[new_offset] = .{ .split = .{
                .layout = s.layout,
                .ratio = s.ratio,
                .left = @enumFromInt(new_offset + 1),
                .right = @enumFromInt(new_offset + 1 + left),
            } };

            return left + right + 1;
        },
    }
}

/// Returns the number of nodes that would be needed to store
/// the tree if the target node is removed.
fn countAfterRemoval(
    self: *SplitTree,
    current: Node.Handle,
    target: Node.Handle,
    acc: usize,
) usize {
    assert(current != target);

    return switch (self.nodes[current.idx()]) {
        // Leaf is simple, always takes one node.
        .leaf => acc + 1,

        // Split is slightly more complicated. If either side is the
        // target to remove, then we remove the split node as well
        // so our count is just the count of the other side.
        //
        // If neither side is the target, then we count both sides
        // and add one to account for the split node itself.
        .split => |s| if (s.left == target) self.countAfterRemoval(
            s.right,
            target,
            acc,
        ) else if (s.right == target) self.countAfterRemoval(
            s.left,
            target,
            acc,
        ) else self.countAfterRemoval(
            s.left,
            target,
            acc,
        ) + self.countAfterRemoval(
            s.right,
            target,
            acc,
        ) + 1,
    };
}

/// Reference all the nodes in the given slice, handling unref if
/// any fail. This should be called LAST so you don't have to undo
/// the refs at any further point after this.
fn refNodes(nodes: []Node) Allocator.Error!void {
    // We need to increase the reference count of all the nodes.
    // Careful accounting here so that we properly unref on error
    // only the nodes we referenced.
    // Note: Surface.ref() cannot fail, so no error handling needed,
    // but we keep the pattern from Ghostty for consistency.
    for (0..nodes.len) |i| {
        switch (nodes[i]) {
            .split => {},
            .leaf => |surface| nodes[i] = .{ .leaf = surface.ref() },
        }
    }
}

/// Equalize this node and all its children, returning a new node with splits
/// adjusted so that each split's ratio is based on the relative weight
/// (number of leaves) of its children.
pub fn equalize(
    self: *const SplitTree,
    gpa: Allocator,
) Allocator.Error!SplitTree {
    if (self.isEmpty()) return .empty;

    // Create a new arena allocator for the clone.
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // Allocate a new nodes array and copy the existing nodes into it.
    const nodes = try alloc.dupe(Node, self.nodes);

    // Go through and equalize our ratios based on weights.
    for (nodes) |*node| switch (node.*) {
        .leaf => {},
        .split => |*s| {
            const weight_left = self.weight(s.left, s.layout, 0);
            const weight_right = self.weight(s.right, s.layout, 0);
            assert(weight_left > 0);
            assert(weight_right > 0);
            const total_f16: f16 = @floatFromInt(weight_left + weight_right);
            const weight_left_f16: f16 = @floatFromInt(weight_left);
            s.ratio = weight_left_f16 / total_f16;
        },
    };

    // Increase the reference count of all the surfaces in the nodes.
    try refNodes(nodes);

    return .{
        .arena = arena,
        .nodes = nodes,
        .zoomed = self.zoomed,
    };
}

fn weight(
    self: *const SplitTree,
    from: Node.Handle,
    layout: Split.Layout,
    acc: usize,
) usize {
    return switch (self.nodes[from.idx()]) {
        .leaf => acc + 1,
        .split => |s| if (s.layout == layout)
            self.weight(s.left, layout, acc) +
                self.weight(s.right, layout, acc)
        else
            1,
    };
}

/// Resize the nearest split matching the layout by the given ratio.
/// Positive is right and down.
///
/// The ratio is a signed delta representing the percentage to move
/// the divider. The percentage is of the entire grid size, not just
/// the specific split size.
/// We use the entire grid size because that's what Ghostty's
/// `resize_split` keybind does, because it maps to a general human
/// understanding of moving a split relative to the entire window
/// (generally).
///
/// For example, a ratio of 0.1 and a layout of `vertical` will find
/// the nearest vertical split and move the divider down by 10% of
/// the total grid height.
///
/// If no matching split is found, this does nothing, but will always
/// still return a cloned tree.
pub fn resize(
    self: *const SplitTree,
    gpa: Allocator,
    from: Node.Handle,
    layout: Split.Layout,
    ratio: f16,
) Allocator.Error!SplitTree {
    assert(ratio >= -1 and ratio <= 1);
    assert(!std.math.isNan(ratio));
    assert(!std.math.isInf(ratio));

    // Fast path empty trees.
    if (self.isEmpty()) return .empty;

    // From this point forward worst case we return a clone.
    var result = try self.clone(gpa);
    errdefer result.deinit();

    // Find our nearest parent split node matching the layout.
    const parent_handle = switch (self.findParentSplit(
        layout,
        from,
        .root,
    )) {
        .deadend, .backtrack => return result,
        .result => |v| v,
    };

    // Get our spatial layout, because we need the dimensions of this
    // split with regards to the entire grid.
    var sp = try result.spatial(gpa);
    defer sp.deinit(gpa);

    // Get the ratio of the split relative to the full grid.
    const full_ratio = full_ratio: {
        // Our scale is the amount we need to multiply our individual
        // ratio by to get the full ratio. Its actually a ratio on its
        // own but I'm trying to avoid that word: its the ratio of
        // our spatial width/height to the total.
        const scale = switch (layout) {
            .horizontal => sp.slots[parent_handle.idx()].width / sp.slots[0].width,
            .vertical => sp.slots[parent_handle.idx()].height / sp.slots[0].height,
        };

        const current = result.nodes[parent_handle.idx()].split.ratio;
        break :full_ratio current * scale;
    };

    // Set the final new ratio, clamping it to [0, 1]
    result.resizeInPlace(
        parent_handle,
        @min(@max(full_ratio + ratio, 0), 1),
    );
    return result;
}

fn findParentSplit(
    self: *const SplitTree,
    layout: Split.Layout,
    from: Node.Handle,
    current: Node.Handle,
) Backtrack {
    if (from == current) return .backtrack;
    return switch (self.nodes[current.idx()]) {
        .leaf => .deadend,
        .split => |s| switch (self.findParentSplit(
            layout,
            from,
            s.left,
        )) {
            .result => |v| .{ .result = v },
            .backtrack => if (s.layout == layout)
                .{ .result = current }
            else
                .backtrack,
            .deadend => switch (self.findParentSplit(
                layout,
                from,
                s.right,
            )) {
                .deadend => .deadend,
                .result => |v| .{ .result = v },
                .backtrack => if (s.layout == layout)
                    .{ .result = current }
                else
                    .backtrack,
            },
        },
    };
}

/// Spatial representation of the split tree. See spatial.
pub const Spatial = struct {
    /// The slots of the spatial representation in the same order
    /// as the tree it was created from.
    slots: []const Slot,

    pub const empty: Spatial = .{ .slots = &.{} };

    pub const Direction = enum { left, right, down, up };

    pub const Slot = struct {
        x: f16,
        y: f16,
        width: f16,
        height: f16,

        pub fn maxX(self: *const Slot) f16 {
            return self.x + self.width;
        }

        pub fn maxY(self: *const Slot) f16 {
            return self.y + self.height;
        }
    };

    pub fn deinit(self: *Spatial, alloc: Allocator) void {
        alloc.free(self.slots);
        self.* = undefined;
    }
};

/// A leaf panel's handle plus its normalized top-left position (from `spatial`),
/// used to order panels by on-screen reading order.
pub const PanelPos = struct {
    handle: Node.Handle,
    x: f16,
    y: f16,
};

/// Number of vertical buckets across the 1.0-tall grid. Panels whose `y` round
/// to the same bucket are treated as the same visual row (then ordered by `x`).
/// 64 ≈ 1.5% tolerance — fine because rows are separated by a meaningful
/// fraction of the height. A quantized integer key keeps the comparison
/// transitive (avoids the floating-epsilon-comparator hazard).
const ROW_QUANTA: f32 = 64.0;

fn rowKey(y: f16) i32 {
    return @intFromFloat(@round(@as(f32, @floatCast(y)) * ROW_QUANTA));
}

fn readingOrderLessThan(_: void, a: PanelPos, b: PanelPos) bool {
    const ay = rowKey(a.y);
    const by = rowKey(b.y);
    if (ay != by) return ay < by;
    return a.x < b.x;
}

/// Sort panels into screen reading order: top-left → bottom-right (row-major).
/// Stable (so exact ties keep tree order); N is the tiny panel count.
pub fn sortReadingOrder(items: []PanelPos) void {
    std.sort.insertion(PanelPos, items, {}, readingOrderLessThan);
}

/// Leaf-panel handles in screen reading order (top-left → bottom-right).
/// Caller owns the returned slice. Empty tree → zero-length slice.
pub fn readingOrder(self: *const SplitTree, alloc: Allocator) Allocator.Error![]Node.Handle {
    if (self.nodes.len == 0) return alloc.alloc(Node.Handle, 0);

    var sp = try self.spatial(alloc);
    defer sp.deinit(alloc);

    var positions: std.ArrayListUnmanaged(PanelPos) = .empty;
    defer positions.deinit(alloc);
    var it = self.iterator();
    while (it.next()) |entry| {
        const slot = sp.slots[entry.handle.idx()];
        try positions.append(alloc, .{ .handle = entry.handle, .x = slot.x, .y = slot.y });
    }
    sortReadingOrder(positions.items);

    const handles = try alloc.alloc(Node.Handle, positions.items.len);
    for (positions.items, 0..) |p, i| handles[i] = p.handle;
    return handles;
}

/// Handle of the n-th panel (1-based) in reading order, or null if out of range.
pub fn panelHandleAt(self: *const SplitTree, alloc: Allocator, n_one_based: usize) Allocator.Error!?Node.Handle {
    const order = try self.readingOrder(alloc);
    defer alloc.free(order);
    if (n_one_based >= 1 and n_one_based <= order.len) return order[n_one_based - 1];
    return null;
}

/// Spatial representation of the split tree. This can be used to
/// better understand the layout of the tree in a 2D space.
///
/// The bounds of the representation are always based on the total
/// 2D space being 1x1. The x/y coordinates and width/height dimensions
/// of each individual split and leaf are relative to this.
/// This means that the spatial representation is a normalized
/// representation of the actual space.
///
/// The top-left corner of the tree is always (0, 0).
///
/// We use a normalized form because we can calculate it without
/// accessing to the actual rendered view sizes. These actual sizes
/// may not be available at various times because GUI toolkits often
/// only make them available once they're part of a widget tree and
/// a SplitTree can represent views that aren't currently visible.
pub fn spatial(
    self: *const SplitTree,
    alloc: Allocator,
) Allocator.Error!Spatial {
    // No nodes, empty spatial representation.
    if (self.nodes.len == 0) return .empty;

    // Get our total dimensions.
    const dim = self.dimensions(.root);

    // Create our slots which will match our nodes exactly.
    const slots = try alloc.alloc(Spatial.Slot, self.nodes.len);
    errdefer alloc.free(slots);
    slots[0] = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(dim.width),
        .height = @floatFromInt(dim.height),
    };
    self.fillSpatialSlots(slots, .root);

    // Normalize the dimensions to 1x1 grid.
    for (slots) |*slot| {
        slot.x /= @floatFromInt(dim.width);
        slot.y /= @floatFromInt(dim.height);
        slot.width /= @floatFromInt(dim.width);
        slot.height /= @floatFromInt(dim.height);
    }

    return .{ .slots = slots };
}

fn fillSpatialSlots(
    self: *const SplitTree,
    slots: []Spatial.Slot,
    current_: Node.Handle,
) void {
    const current = current_.idx();
    assert(slots[current].width >= 0 and slots[current].height >= 0);
    switch (self.nodes[current]) {
        // Leaf node, current slot is already filled by caller.
        .leaf => {},

        .split => |s| {
            switch (s.layout) {
                .horizontal => {
                    slots[s.left.idx()] = .{
                        .x = slots[current].x,
                        .y = slots[current].y,
                        .width = slots[current].width * s.ratio,
                        .height = slots[current].height,
                    };
                    slots[s.right.idx()] = .{
                        .x = slots[current].x + slots[current].width * s.ratio,
                        .y = slots[current].y,
                        .width = slots[current].width * (1 - s.ratio),
                        .height = slots[current].height,
                    };
                },

                .vertical => {
                    slots[s.left.idx()] = .{
                        .x = slots[current].x,
                        .y = slots[current].y,
                        .width = slots[current].width,
                        .height = slots[current].height * s.ratio,
                    };
                    slots[s.right.idx()] = .{
                        .x = slots[current].x,
                        .y = slots[current].y + slots[current].height * s.ratio,
                        .width = slots[current].width,
                        .height = slots[current].height * (1 - s.ratio),
                    };
                },
            }

            self.fillSpatialSlots(slots, s.left);
            self.fillSpatialSlots(slots, s.right);
        },
    }
}

/// Get the dimensions of the tree starting from the given node.
///
/// This creates relative dimensions (see Spatial) by assuming each
/// leaf is exactly 1x1 unit in size.
fn dimensions(self: *const SplitTree, current: Node.Handle) struct {
    width: u16,
    height: u16,
} {
    return switch (self.nodes[current.idx()]) {
        .leaf => .{ .width = 1, .height = 1 },
        .split => |s| split: {
            const left = self.dimensions(s.left);
            const right = self.dimensions(s.right);
            break :split switch (s.layout) {
                .horizontal => .{
                    .width = left.width + right.width,
                    .height = @max(left.height, right.height),
                },

                .vertical => .{
                    .width = @max(left.width, right.width),
                    .height = left.height + right.height,
                },
            };
        },
    };
}

/// Create a SplitTree from a session_persist NodeSnap. The factory callback
/// is responsible for materializing one *Surface per leaf snapshot. Returning
/// null from the factory aborts the rebuild with error.SurfaceCreationFailed.
///
/// On error.SurfaceCreationFailed, any *Surface values returned by previous
/// successful factory calls are NOT freed by this function — they are leaked.
/// The factory must either track created surfaces externally for cleanup,
/// or the caller must accept this leak as a fatal error path.
///
/// Splits are always binary; ratios are clamped to [0.05, 0.95] for safety.
/// Pre-order traversal: root first, then left subtree, then right subtree.
/// Pre-order leaf order matches session_persist.leafByIndex semantics, so
/// `focused_leaf` from a TabSnap can be resolved against the resulting nodes.
pub fn fromSnapshot(
    gpa: Allocator,
    snap: *const @import("session_persist.zig").NodeSnap,
    factory: *const fn (
        snap: *const @import("session_persist.zig").SurfaceSnap,
        gpa: Allocator,
    ) ?*Surface,
) !SplitTree {
    const session_persist = @import("session_persist.zig");
    const total = countSnapNodes(snap);

    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const nodes = try alloc.alloc(Node, total);

    const Ctx = struct {
        nodes: []Node,
        idx: usize = 0,
        gpa: Allocator,
        factory: *const fn (
            snap: *const session_persist.SurfaceSnap,
            gpa: Allocator,
        ) ?*Surface,

        fn writeNode(self: *@This(), n: *const session_persist.NodeSnap) !Node.Handle {
            const my_handle: Node.Handle = @enumFromInt(@as(Node.Handle.Backing, @intCast(self.idx)));
            self.idx += 1;
            switch (n.*) {
                .leaf => |leaf| {
                    const surface = self.factory(&leaf.surface, self.gpa) orelse return error.SurfaceCreationFailed;
                    self.nodes[my_handle.idx()] = .{ .leaf = surface };
                },
                .split => |sp| {
                    // Reserve current index, then write children in pre-order.
                    const left = try self.writeNode(sp.left);
                    const right = try self.writeNode(sp.right);
                    var ratio: f64 = sp.ratio;
                    if (ratio < session_persist.RATIO_MIN) ratio = session_persist.RATIO_MIN;
                    if (ratio > session_persist.RATIO_MAX) ratio = session_persist.RATIO_MAX;
                    if (std.math.isNan(ratio)) ratio = 0.5;
                    self.nodes[my_handle.idx()] = .{ .split = .{
                        .layout = switch (sp.layout) {
                            .horizontal => .horizontal,
                            .vertical => .vertical,
                        },
                        .ratio = @floatCast(ratio),
                        .left = left,
                        .right = right,
                    } };
                },
            }
            return my_handle;
        }
    };

    var ctx = Ctx{ .nodes = nodes, .gpa = gpa, .factory = factory };
    _ = try ctx.writeNode(snap);

    return .{
        .arena = arena,
        .nodes = nodes,
        .zoomed = null, // resolved by the caller (tab.zig) after the tree is built
    };
}

fn countSnapNodes(snap: *const @import("session_persist.zig").NodeSnap) usize {
    return switch (snap.*) {
        .leaf => 1,
        .split => |sp| 1 + countSnapNodes(sp.left) + countSnapNodes(sp.right),
    };
}

// ============================================================================
// Tests
// ============================================================================

/// Mock surface for testing. Uses a simple label for identification.
const TestSurface = struct {
    label: []const u8,
    ref_count: u32 = 1,

    pub fn ref(self: *TestSurface) *TestSurface {
        self.ref_count += 1;
        return self;
    }

    pub fn unref(self: *TestSurface, _: Allocator) void {
        self.ref_count -= 1;
    }
};

// Type alias for testing with mock surfaces.
// Note: For actual tests we need to use the real SplitTree with *Surface,
// but we can test the logic with a simpler mock by checking the structure
// directly.

test "SplitTree: init creates single-leaf tree" {
    // This test would require a real Surface which needs PTY, etc.
    // For unit testing the data structure, we verify the structure
    // is correct by examining the implementation directly.
    // Integration tests with real surfaces will be done in AppWindow.
}

test "SplitTree: empty tree" {
    const tree = SplitTree.empty;
    try std.testing.expect(tree.isEmpty());
    try std.testing.expect(!tree.isSplit());
    try std.testing.expectEqual(@as(usize, 0), tree.nodes.len);
}

test "SplitTree: fromSnapshot rebuilds nested topology with correct handles and ratios" {
    const session_persist = @import("session_persist.zig");

    var leaf_a = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var leaf_b = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var leaf_c = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var inner = session_persist.NodeSnap{ .split = .{ .layout = .vertical, .ratio = 0.4, .left = &leaf_a, .right = &leaf_b } };
    var root = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.6, .left = &inner, .right = &leaf_c } };

    // Stub factory: returns sentinel pointers so we can verify topology
    // without spinning up real Surfaces (which need PTY).
    const Stub = struct {
        var counter: usize = 0;
        var sentinels: [16]usize = undefined;
        fn make(_: *const session_persist.SurfaceSnap, _: Allocator) ?*Surface {
            const ptr = &sentinels[counter];
            counter += 1;
            return @ptrCast(@alignCast(ptr));
        }
    };
    Stub.counter = 0;

    var tree = try fromSnapshot(std.testing.allocator, &root, Stub.make);
    defer {
        // Sentinel leaves can't be unref'd via the real Surface path, so we
        // free the arena directly without invoking the destructor.
        if (tree.nodes.len > 0) tree.arena.deinit();
        tree = undefined;
    }

    // Pre-order layout: [root_split, inner_split, leaf_a, leaf_b, leaf_c]
    try std.testing.expectEqual(@as(usize, 5), tree.nodes.len);
    const root_node = tree.nodes[0];
    try std.testing.expect(root_node == .split);
    try std.testing.expectEqual(SplitTree.Split.Layout.horizontal, root_node.split.layout);
    try std.testing.expectApproxEqAbs(@as(f16, 0.6), root_node.split.ratio, 0.01);
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 1), @intFromEnum(root_node.split.left));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 4), @intFromEnum(root_node.split.right));

    const inner_node = tree.nodes[1];
    try std.testing.expect(inner_node == .split);
    try std.testing.expectEqual(SplitTree.Split.Layout.vertical, inner_node.split.layout);
    try std.testing.expectApproxEqAbs(@as(f16, 0.4), inner_node.split.ratio, 0.01);
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 2), @intFromEnum(inner_node.split.left));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 3), @intFromEnum(inner_node.split.right));

    try std.testing.expect(tree.nodes[2] == .leaf);
    try std.testing.expect(tree.nodes[3] == .leaf);
    try std.testing.expect(tree.nodes[4] == .leaf);
    // Pre-order: leaf_a got sentinel[0], leaf_b got sentinel[1], leaf_c got sentinel[2].
    // This catches any future bug that swaps left/right traversal order.
    const sentinel_a: *Surface = @ptrCast(@alignCast(&Stub.sentinels[0]));
    const sentinel_b: *Surface = @ptrCast(@alignCast(&Stub.sentinels[1]));
    const sentinel_c: *Surface = @ptrCast(@alignCast(&Stub.sentinels[2]));
    try std.testing.expectEqual(sentinel_a, tree.nodes[2].leaf);
    try std.testing.expectEqual(sentinel_b, tree.nodes[3].leaf);
    try std.testing.expectEqual(sentinel_c, tree.nodes[4].leaf);
}

test "SplitTree: fromSnapshot clamps ratios" {
    const session_persist = @import("session_persist.zig");

    var l = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var r = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var root = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 5.0, .left = &l, .right = &r } };

    const Stub = struct {
        var counter: usize = 0;
        var sentinels: [16]usize = undefined;
        fn make(_: *const session_persist.SurfaceSnap, _: Allocator) ?*Surface {
            const ptr = &sentinels[counter];
            counter += 1;
            return @ptrCast(@alignCast(ptr));
        }
    };
    Stub.counter = 0;

    var tree = try fromSnapshot(std.testing.allocator, &root, Stub.make);
    defer {
        if (tree.nodes.len > 0) tree.arena.deinit();
        tree = undefined;
    }

    try std.testing.expect(tree.nodes[0].split.ratio <= 0.95);
}

test "SplitTree: swapLeaves exchanges leaf surfaces and preserves topology" {
    const session_persist = @import("session_persist.zig");

    var leaf_a = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var leaf_b = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var root = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.6, .left = &leaf_a, .right = &leaf_b } };

    const Stub = struct {
        var counter: usize = 0;
        var sentinels: [16]usize = undefined;
        fn make(_: *const session_persist.SurfaceSnap, _: Allocator) ?*Surface {
            const ptr = &sentinels[counter];
            counter += 1;
            return @ptrCast(@alignCast(ptr));
        }
    };
    Stub.counter = 0;

    var tree = try fromSnapshot(std.testing.allocator, &root, Stub.make);
    defer {
        // Sentinel leaves can't be unref'd; free the arena directly.
        if (tree.nodes.len > 0) tree.arena.deinit();
        tree = undefined;
    }

    // Pre-order layout: [root_split@0, leaf_a@1, leaf_b@2]
    const a: Node.Handle = @enumFromInt(1);
    const b: Node.Handle = @enumFromInt(2);
    const surf_a = tree.nodes[1].leaf;
    const surf_b = tree.nodes[2].leaf;
    try std.testing.expect(surf_a != surf_b);

    // Capture topology before the swap.
    const layout_before = tree.nodes[0].split.layout;
    const ratio_before = tree.nodes[0].split.ratio;
    const left_before = tree.nodes[0].split.left;
    const right_before = tree.nodes[0].split.right;

    tree.swapLeaves(a, b);

    // Surfaces exchanged.
    try std.testing.expectEqual(surf_b, tree.nodes[1].leaf);
    try std.testing.expectEqual(surf_a, tree.nodes[2].leaf);

    // Topology untouched: layout, ratio, and child handles unchanged.
    try std.testing.expectEqual(layout_before, tree.nodes[0].split.layout);
    try std.testing.expectEqual(ratio_before, tree.nodes[0].split.ratio);
    try std.testing.expectEqual(left_before, tree.nodes[0].split.left);
    try std.testing.expectEqual(right_before, tree.nodes[0].split.right);

    // Swapping the same pair again restores the original arrangement.
    tree.swapLeaves(a, b);
    try std.testing.expectEqual(surf_a, tree.nodes[1].leaf);
    try std.testing.expectEqual(surf_b, tree.nodes[2].leaf);
}

test "sortReadingOrder orders panels top-left to bottom-right" {
    const at = struct {
        fn h(i: u16) Node.Handle {
            return @enumFromInt(i);
        }
    }.h;
    // Shuffled input: BR, TL, BL, TR (2x2 grid positions).
    var items = [_]PanelPos{
        .{ .handle = at(6), .x = 0.5, .y = 0.5 }, // bottom-right
        .{ .handle = at(2), .x = 0.0, .y = 0.0 }, // top-left
        .{ .handle = at(5), .x = 0.0, .y = 0.5 }, // bottom-left
        .{ .handle = at(3), .x = 0.5, .y = 0.0 }, // top-right
    };
    sortReadingOrder(&items);
    try std.testing.expectEqual(@as(Node.Handle.Backing, 2), @intFromEnum(items[0].handle));
    try std.testing.expectEqual(@as(Node.Handle.Backing, 3), @intFromEnum(items[1].handle));
    try std.testing.expectEqual(@as(Node.Handle.Backing, 5), @intFromEnum(items[2].handle));
    try std.testing.expectEqual(@as(Node.Handle.Backing, 6), @intFromEnum(items[3].handle));
}

test "sortReadingOrder: a tall left panel precedes a stacked right column" {
    const at = struct {
        fn h(i: u16) Node.Handle {
            return @enumFromInt(i);
        }
    }.h;
    // Left spans full height (top-left at y=0); right column split top (y=0) / bottom (y=0.5).
    var items = [_]PanelPos{
        .{ .handle = at(4), .x = 0.5, .y = 0.5 }, // right-bottom
        .{ .handle = at(2), .x = 0.0, .y = 0.0 }, // left (tall)
        .{ .handle = at(3), .x = 0.5, .y = 0.0 }, // right-top
    };
    sortReadingOrder(&items);
    try std.testing.expectEqual(@as(Node.Handle.Backing, 2), @intFromEnum(items[0].handle)); // left (row 0, x 0)
    try std.testing.expectEqual(@as(Node.Handle.Backing, 3), @intFromEnum(items[1].handle)); // right-top (row 0, x 0.5)
    try std.testing.expectEqual(@as(Node.Handle.Backing, 4), @intFromEnum(items[2].handle)); // right-bottom (row 1)
}

test "SplitTree: readingOrder is row-major top-left to bottom-right" {
    const session_persist = @import("session_persist.zig");
    // 2x2 grid: root stacks two rows (vertical); each row is left|right (horizontal).
    var tl = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var tr = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var bl = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var br = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var top = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = &tl, .right = &tr } };
    var bot = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = &bl, .right = &br } };
    var root = session_persist.NodeSnap{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = &top, .right = &bot } };

    const Stub = struct {
        var counter: usize = 0;
        var sentinels: [16]usize = undefined;
        fn make(_: *const session_persist.SurfaceSnap, _: Allocator) ?*Surface {
            const ptr = &sentinels[counter];
            counter += 1;
            return @ptrCast(@alignCast(ptr));
        }
    };
    Stub.counter = 0;

    var tree = try fromSnapshot(std.testing.allocator, &root, Stub.make);
    defer {
        if (tree.nodes.len > 0) tree.arena.deinit();
        tree = undefined;
    }

    const order = try tree.readingOrder(std.testing.allocator);
    defer std.testing.allocator.free(order);

    // Pre-order node handles: root=0, top=1, tl=2, tr=3, bot=4, bl=5, br=6.
    try std.testing.expectEqual(@as(usize, 4), order.len);
    try std.testing.expectEqual(@as(Node.Handle.Backing, 2), @intFromEnum(order[0])); // top-left
    try std.testing.expectEqual(@as(Node.Handle.Backing, 3), @intFromEnum(order[1])); // top-right
    try std.testing.expectEqual(@as(Node.Handle.Backing, 5), @intFromEnum(order[2])); // bottom-left
    try std.testing.expectEqual(@as(Node.Handle.Backing, 6), @intFromEnum(order[3])); // bottom-right

    // panelHandleAt is 1-based and range-checked.
    try std.testing.expectEqual(@as(?Node.Handle, @enumFromInt(2)), try tree.panelHandleAt(std.testing.allocator, 1));
    try std.testing.expectEqual(@as(?Node.Handle, @enumFromInt(6)), try tree.panelHandleAt(std.testing.allocator, 4));
    try std.testing.expectEqual(@as(?Node.Handle, null), try tree.panelHandleAt(std.testing.allocator, 5));
    try std.testing.expectEqual(@as(?Node.Handle, null), try tree.panelHandleAt(std.testing.allocator, 0));
}
