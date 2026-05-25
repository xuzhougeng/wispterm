pub const DirectoryWatcher = struct {
    pub fn initPath(dir_path: []const u8) ?DirectoryWatcher {
        _ = dir_path;
        return null;
    }

    pub fn hasChanged(self: *DirectoryWatcher) bool {
        _ = self;
        return false;
    }

    pub fn deinit(self: *DirectoryWatcher) void {
        _ = self;
    }
};
