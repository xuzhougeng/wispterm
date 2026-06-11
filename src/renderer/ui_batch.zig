//! 纯逻辑 UI 字形批处理器：把 ui_pipeline 的逐字形/逐矩形立即绘制聚成
//! instanced 批次（每批一次实例缓冲上传 + 一次 instanced draw），消除弱 CPU 上
//! 每字符一次 use+bind+upload+draw 的驱动开销。
//!
//! 本模块只做累积与冲刷决策（按纹理分批、容量上限、外部管线介入判定）；
//! 真正的 GPU 提交由调用方传入的 sink（duck-typed `draw(texture, instances)`）
//! 完成。绘制顺序的正确性依赖调用方在任何外部状态变化（视口/裁剪/混合/换管线/
//! 绑 FBO）之前先 flush——见 ui_pipeline 的钩子注册。
//! 刻意零项目依赖（只用 std），便于 `zig test src/renderer/ui_batch.zig` 独立单测。
const std = @import("std");

/// 一个批内实例：屏幕矩形（GL 左下原点像素坐标）+ 图集 UV + RGB。
/// extern 布局直接作为 GPU 实例缓冲上传（11 × f32 = 44 字节）。
pub const Instance = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// 单批实例容量。满了自动冲刷再续（一帧可多批）。
pub const capacity = 4096;

pub const Batcher = struct {
    instances: [capacity]Instance = undefined,
    count: usize = 0,
    texture: u32 = 0,

    /// 追加一个实例。纹理切换或容量满时先冲刷已累积的批次。
    pub fn push(self: *Batcher, texture: u32, inst: Instance, sink: anytype) void {
        if (self.count > 0 and texture != self.texture) self.flush(sink);
        if (self.count == capacity) self.flush(sink);
        self.texture = texture;
        self.instances[self.count] = inst;
        self.count += 1;
    }

    /// 把累积的实例交给 sink 绘制并清空。空批不调 sink。
    pub fn flush(self: *Batcher, sink: anytype) void {
        if (self.count == 0) return;
        sink.draw(self.texture, self.instances[0..self.count]);
        self.count = 0;
    }

    pub fn pending(self: *const Batcher) bool {
        return self.count > 0;
    }
};

/// 外部管线 use() 钩子的纯判定：有挂起批次且换到别的程序时才需要冲刷
/// （批管线自身在冲刷中 use() 不得递归触发）。
pub fn shouldFlushOnPipelineUse(pending: bool, program: u32, batch_program: u32) bool {
    return pending and program != batch_program;
}

// ============================================================================
// Tests
// ============================================================================

const RecordedDraw = struct {
    texture: u32,
    count: usize,
    first: Instance,
    last: Instance,
};

const RecordSink = struct {
    draws: [8]RecordedDraw = undefined,
    n: usize = 0,

    pub fn draw(self: *RecordSink, texture: u32, instances: []const Instance) void {
        self.draws[self.n] = .{
            .texture = texture,
            .count = instances.len,
            .first = instances[0],
            .last = instances[instances.len - 1],
        };
        self.n += 1;
    }
};

fn makeInst(x: f32) Instance {
    return .{ .x = x, .y = 0, .w = 1, .h = 1, .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1, .r = 1, .g = 1, .b = 1 };
}

test "push 同纹理累积，flush 一次性绘制且保序" {
    var b: Batcher = .{};
    var sink: RecordSink = .{};
    b.push(7, makeInst(1), &sink);
    b.push(7, makeInst(2), &sink);
    try std.testing.expectEqual(@as(usize, 0), sink.n);
    try std.testing.expect(b.pending());

    b.flush(&sink);
    try std.testing.expectEqual(@as(usize, 1), sink.n);
    try std.testing.expectEqual(@as(u32, 7), sink.draws[0].texture);
    try std.testing.expectEqual(@as(usize, 2), sink.draws[0].count);
    try std.testing.expectEqual(@as(f32, 1), sink.draws[0].first.x);
    try std.testing.expectEqual(@as(f32, 2), sink.draws[0].last.x);
    try std.testing.expect(!b.pending());
}

test "纹理切换时先冲刷旧批" {
    var b: Batcher = .{};
    var sink: RecordSink = .{};
    b.push(7, makeInst(1), &sink);
    b.push(9, makeInst(2), &sink);
    try std.testing.expectEqual(@as(usize, 1), sink.n);
    try std.testing.expectEqual(@as(u32, 7), sink.draws[0].texture);
    try std.testing.expectEqual(@as(usize, 1), sink.draws[0].count);
    try std.testing.expect(b.pending());

    b.flush(&sink);
    try std.testing.expectEqual(@as(u32, 9), sink.draws[1].texture);
}

test "容量满时自动冲刷再续" {
    var b: Batcher = .{};
    var sink: RecordSink = .{};
    for (0..capacity + 1) |i| {
        b.push(7, makeInst(@floatFromInt(i)), &sink);
    }
    try std.testing.expectEqual(@as(usize, 1), sink.n);
    try std.testing.expectEqual(@as(usize, capacity), sink.draws[0].count);
    try std.testing.expectEqual(@as(usize, 1), b.count);

    b.flush(&sink);
    try std.testing.expectEqual(@as(f32, capacity), sink.draws[1].first.x);
}

test "空批 flush 不调 sink" {
    var b: Batcher = .{};
    var sink: RecordSink = .{};
    b.flush(&sink);
    try std.testing.expectEqual(@as(usize, 0), sink.n);
}

test "shouldFlushOnPipelineUse: 仅外部程序且有挂起时冲刷" {
    try std.testing.expect(shouldFlushOnPipelineUse(true, 5, 3));
    try std.testing.expect(!shouldFlushOnPipelineUse(true, 3, 3)); // 批管线自身（冲刷中）
    try std.testing.expect(!shouldFlushOnPipelineUse(false, 5, 3)); // 无挂起
}

test "Instance 是紧凑 44 字节布局（GPU 实例缓冲）" {
    try std.testing.expectEqual(@as(usize, 44), @sizeOf(Instance));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Instance, "u0"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Instance, "r"));
}
