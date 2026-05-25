pub const DetachedSpawnOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    create_no_window: bool = false,
};

pub const WaitForPidDiagnostic = struct {
    operation: []const u8,
    code: u32,
    wait_result: ?u32 = null,
};

pub const PipeWriteError = error{ BrokenPipe, WriteFailed };
