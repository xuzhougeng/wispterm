/// Size and dimension types used throughout the renderer.
/// Modeled after Ghostty's size types in `src/renderer/size.zig`.
/// Grid dimensions in cells.
pub const GridSize = struct {
    cols: u16 = 80,
    rows: u16 = 24,
};

/// Cell dimensions in pixels.
pub const CellSize = struct {
    width: f32 = 10,
    height: f32 = 20,
    baseline: f32 = 4,
    cursor_height: f32 = 16,
    box_thickness: u32 = 1,
};

/// Screen/surface size in pixels.
pub const ScreenSize = struct {
    width: u32 = 0,
    height: u32 = 0,
};

/// Padding around the terminal grid, in pixels.
/// Modeled after Ghostty's `src/renderer/size.zig` Padding struct.
pub const Padding = struct {
    top: u32 = 0,
    bottom: u32 = 0,
    left: u32 = 0,
    right: u32 = 0,

    /// Returns padding that balances the whitespace around the screen
    /// for the given screen, grid, and cell sizes.
    pub fn balanced(
        screen_width: u32,
        screen_height: u32,
        grid_cols: u16,
        grid_rows: u16,
        cell_width: f32,
        cell_height: f32,
    ) Padding {
        // The size of our full grid
        const grid_width = @as(f32, @floatFromInt(grid_cols)) * cell_width;
        const grid_height = @as(f32, @floatFromInt(grid_rows)) * cell_height;

        // The empty space to the right of a line and bottom of the last row
        const space_right = @as(f32, @floatFromInt(screen_width)) - grid_width;
        const space_bot = @as(f32, @floatFromInt(screen_height)) - grid_height;

        // The padding is split equally along both axes.
        const padding_right = @floor(space_right / 2);
        const padding_left = padding_right;

        const padding_bot = @floor(space_bot / 2);
        const padding_top = padding_bot;

        const zero: f32 = 0;
        return .{
            .top = @intFromFloat(@max(zero, padding_top)),
            .bottom = @intFromFloat(@max(zero, padding_bot)),
            .right = @intFromFloat(@max(zero, padding_right)),
            .left = @intFromFloat(@max(zero, padding_left)),
        };
    }

    /// Add another padding to this one.
    pub fn add(self: Padding, other: Padding) Padding {
        return .{
            .top = self.top + other.top,
            .bottom = self.bottom + other.bottom,
            .right = self.right + other.right,
            .left = self.left + other.left,
        };
    }

    /// Check equality.
    pub fn eql(self: Padding, other: Padding) bool {
        return self.top == other.top and
            self.bottom == other.bottom and
            self.left == other.left and
            self.right == other.right;
    }

    /// Total horizontal padding.
    pub fn horizontal(self: Padding) u32 {
        return self.left + self.right;
    }

    /// Total vertical padding.
    pub fn vertical(self: Padding) u32 {
        return self.top + self.bottom;
    }
};

/// Combined size information for a surface.
/// This holds all the sizing info needed for rendering.
pub const Size = struct {
    screen: ScreenSize = .{},
    cell: CellSize = .{},
    grid: GridSize = .{},
    padding: Padding = .{},

    /// Compute grid dimensions from screen size, cell size, and padding.
    pub fn computeGrid(self: *Size) void {
        const avail_width = @as(i32, @intCast(self.screen.width)) - @as(i32, @intCast(self.padding.horizontal()));
        const avail_height = @as(i32, @intCast(self.screen.height)) - @as(i32, @intCast(self.padding.vertical()));

        self.grid.cols = if (avail_width > 0 and self.cell.width > 0)
            @intFromFloat(@max(1, @as(f32, @floatFromInt(avail_width)) / self.cell.width))
        else
            1;
        self.grid.rows = if (avail_height > 0 and self.cell.height > 0)
            @intFromFloat(@max(1, @as(f32, @floatFromInt(avail_height)) / self.cell.height))
        else
            1;
    }

    /// Balance padding so the grid is centered in the screen.
    pub fn balancePadding(self: *Size) void {
        self.padding = Padding.balanced(
            self.screen.width,
            self.screen.height,
            self.grid.cols,
            self.grid.rows,
            self.cell.width,
            self.cell.height,
        );
    }
};
