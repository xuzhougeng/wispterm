const std = @import("std");

const windows = std.os.windows;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const HANDLE = windows.HANDLE;

const PROCESS_MEMORY_COUNTERS_EX = extern struct {
    cb: DWORD,
    PageFaultCount: DWORD,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
    PrivateUsage: usize,
};

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "psapi" fn GetProcessMemoryInfo(
    Process: HANDLE,
    ppsmemCounters: *PROCESS_MEMORY_COUNTERS_EX,
    cb: DWORD,
) callconv(.winapi) BOOL;

pub fn queryProcess(comptime ProcessSnapshot: type) ?ProcessSnapshot {
    var counters: PROCESS_MEMORY_COUNTERS_EX = std.mem.zeroes(PROCESS_MEMORY_COUNTERS_EX);
    counters.cb = @intCast(@sizeOf(PROCESS_MEMORY_COUNTERS_EX));

    if (GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) == 0) {
        return null;
    }

    return .{
        .working_set = counters.WorkingSetSize,
        .peak_working_set = counters.PeakWorkingSetSize,
        .pagefile_usage = counters.PagefileUsage,
        .peak_pagefile_usage = counters.PeakPagefileUsage,
        .private_usage = counters.PrivateUsage,
        .page_fault_count = counters.PageFaultCount,
    };
}
