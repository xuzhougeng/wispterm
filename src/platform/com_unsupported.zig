pub const Apartment = struct {
    initialized: bool = false,

    pub fn deinit(self: Apartment) void {
        _ = self;
    }
};

pub fn initUiThread() Apartment {
    return .{};
}
