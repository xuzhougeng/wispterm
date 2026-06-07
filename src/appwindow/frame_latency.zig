//! 纯逻辑帧延迟统计：记录最近 N 个「输入 → 呈现」延迟样本，按需算 p50/p95/max。
//! 用于量化命令中心 / 新建会话 / 设置等 overlay 的方向键导航手感（"不跟手"）。
//! 刻意零项目依赖（只用 std），便于 `zig test src/appwindow/frame_latency.zig` 独立单测。
const std = @import("std");

/// 滑动窗口容量。每帧 record 是 O(1)；分位数只在周期 summary() 时算一次。
pub const CAPACITY = 256;

pub const Summary = struct {
    count: usize,
    p50_us: i64,
    p95_us: i64,
    /// 全程峰值（不随窗口重置清零），用来抓偶发的单次大延迟。
    max_us: i64,
};

/// 环形样本缓冲。单位与调用方一致（主循环传微秒）；本模块只做无量纲统计。
pub const Stats = struct {
    samples: [CAPACITY]i64 = undefined,
    len: usize = 0, // 当前窗口内有效样本数（<= CAPACITY）
    head: usize = 0, // 下一个写入位置（环形）
    max_all: i64 = 0, // 全程峰值，resetWindow 不清

    pub fn record(self: *Stats, latency: i64) void {
        const v: i64 = if (latency < 0) 0 else latency; // 负延迟（时钟抖动）夹到 0
        self.samples[self.head] = v;
        self.head = (self.head + 1) % CAPACITY;
        if (self.len < CAPACITY) self.len += 1;
        if (v > self.max_all) self.max_all = v;
    }

    pub fn isEmpty(self: *const Stats) bool {
        return self.len == 0;
    }

    /// 基于当前窗口的样本算 p50/p95；max 取全程峰值。
    pub fn summary(self: *const Stats) Summary {
        if (self.len == 0) return .{ .count = 0, .p50_us = 0, .p95_us = 0, .max_us = self.max_all };
        var tmp: [CAPACITY]i64 = undefined;
        // len<CAPACITY 时 samples[0..len] 即写入顺序前 len 个；回绕后整段都有效。
        // 都要排序，顺序无所谓。
        @memcpy(tmp[0..self.len], self.samples[0..self.len]);
        std.mem.sort(i64, tmp[0..self.len], {}, std.sort.asc(i64));
        return .{
            .count = self.len,
            .p50_us = percentile(tmp[0..self.len], 50),
            .p95_us = percentile(tmp[0..self.len], 95),
            .max_us = self.max_all,
        };
    }

    /// 清空滑动窗口（保留全程峰值）。周期输出后调用，让分位数反映「最近一秒」。
    pub fn resetWindow(self: *Stats) void {
        self.len = 0;
        self.head = 0;
    }
};

/// 升序切片的 nearest-rank 分位数，p ∈ [1,100]。rank = ceil(p*n/100)，clamp 到 [1,n]。
fn percentile(sorted: []const i64, p: u8) i64 {
    if (sorted.len == 0) return 0;
    const n = sorted.len;
    const num = @as(usize, p) * n;
    var rank = num / 100;
    if (num % 100 != 0) rank += 1; // ceil
    if (rank == 0) rank = 1;
    if (rank > n) rank = n;
    return sorted[rank - 1];
}

test "frame_latency: 空统计无样本" {
    var s = Stats{};
    try std.testing.expect(s.isEmpty());
    const sum = s.summary();
    try std.testing.expectEqual(@as(usize, 0), sum.count);
    try std.testing.expectEqual(@as(i64, 0), sum.max_us);
}

test "frame_latency: 基本分位数与全程峰值" {
    var s = Stats{};
    // 1..=10 微秒
    for (1..11) |i| s.record(@intCast(i));
    try std.testing.expect(!s.isEmpty());
    const sum = s.summary();
    try std.testing.expectEqual(@as(usize, 10), sum.count);
    // nearest-rank: p50 → rank=ceil(0.5*10)=5 → sorted[4]=5
    try std.testing.expectEqual(@as(i64, 5), sum.p50_us);
    // p95 → rank=ceil(0.95*10)=10 → sorted[9]=10
    try std.testing.expectEqual(@as(i64, 10), sum.p95_us);
    try std.testing.expectEqual(@as(i64, 10), sum.max_us);
}

test "frame_latency: 负样本夹到 0" {
    var s = Stats{};
    s.record(-100);
    s.record(50);
    const sum = s.summary();
    try std.testing.expectEqual(@as(i64, 50), sum.max_us);
    // 排序后 [0, 50]，p50 rank=ceil(0.5*2)=1 → sorted[0]=0
    try std.testing.expectEqual(@as(i64, 0), sum.p50_us);
}

test "frame_latency: 环形回绕只保留最近 CAPACITY 个，峰值不随窗口清零" {
    var s = Stats{};
    // 先打一个大值，再灌满 CAPACITY 个小值把它挤出窗口
    s.record(9999);
    for (0..CAPACITY) |_| s.record(7);
    try std.testing.expectEqual(@as(usize, CAPACITY), s.len);
    const sum = s.summary();
    try std.testing.expectEqual(@as(usize, CAPACITY), sum.count);
    try std.testing.expectEqual(@as(i64, 7), sum.p50_us); // 窗口内全是 7
    try std.testing.expectEqual(@as(i64, 9999), sum.max_us); // 全程峰值仍记得 9999
}

test "frame_latency: resetWindow 清窗口但留全程峰值" {
    var s = Stats{};
    s.record(100);
    s.record(200);
    s.resetWindow();
    try std.testing.expect(s.isEmpty());
    const sum = s.summary();
    try std.testing.expectEqual(@as(usize, 0), sum.count);
    try std.testing.expectEqual(@as(i64, 200), sum.max_us);
}

test "frame_latency: percentile nearest-rank 边界" {
    const data = [_]i64{ 10, 20, 30, 40 };
    try std.testing.expectEqual(@as(i64, 10), percentile(&data, 1)); // rank 1
    try std.testing.expectEqual(@as(i64, 20), percentile(&data, 50)); // ceil(2)=2 → sorted[1]
    try std.testing.expectEqual(@as(i64, 40), percentile(&data, 100)); // rank 4
}
