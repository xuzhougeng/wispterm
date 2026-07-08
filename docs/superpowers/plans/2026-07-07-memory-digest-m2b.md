# Memory Digest M2b（配置项 + app 内每日调度）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** spec §11/§12 的 M2b：`memory-digest-*` 配置键 + WispTerm 主循环内的每日一次调度（update_check 模式），到点在后台线程跑 M2a 的完整 LLM 管道，完成后 postWakeup。出口标准：设好配置后 app 每日自动产出日报/时间线。

**Architecture:** 新增 `src/memory_digest/scheduler.zig`（纯决策逻辑 + last_run 状态文件 + 线程编排，模块级状态自持），config.zig 加 5 个键，AppWindow 主循环加一行 tick。调度决策纯函数可测；线程路径靠真机验证。

**Tech Stack:** Zig；无新依赖。

## Global Constraints

- 分支：继续 `feat/memory-digest-m1`。每次 commit 前 `zig fmt build.zig src`；测试 `zig build test`（禁裸 `zig build`；Benchmark 计时 flake 已知，复跑确认）。
- 测试前缀 `memory_digest_scheduler:`；新文件在 `src/test_fast.zig` 的 memory_digest 段注册。
- **git 显式 stage，严禁 `git add -A`；提交前 `git status --short` 核对。**
- 测试绝不联网、绝不 spawn 真线程跑 LLM（决策函数与状态文件才是单测对象）。
- commit 信息 conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
- 已核实锚点：主循环 tick 位置 `AppWindow.zig:6880`（`checkConfigReload` 调用旁）；config 键三段式链路样板 = `restore-tabs-on-startup`（声明 config.zig:456 附近 / 解析 config.zig:1061-1067 / 消费 App.zig:574）；后台线程样板 = `App.zig:600-687`（updateCheckThreadMain + storeUpdateResult 互斥模式）；`postWakeup` 经 `window_backend`（AppWindow 已 import；后台线程完成必须调，`markUiDirty` 是 threadlocal 不可用）；时区 = `terminal_agents/sessions/time.zig` 的 `localOffsetSeconds()`（用法见 appwindow/tab.zig:653）。

---

### Task 1: config.zig 五个键

**Files:**
- Modify: `src/config.zig`

**Interfaces（Task 2/3 消费）:** Config 结构新增字段（声明+解析+默认值，逐字照 spec §12 修订版）：

| 字段 | 类型 | 默认 |
|------|------|------|
| `@"memory-digest-enabled"` | bool | false |
| `@"memory-digest-profile"` | []const u8 | "" |
| `@"memory-digest-run-after"` | []const u8 | "04:00"（解析为字符串存储，格式校验在 scheduler） |
| `@"memory-digest-backfill-days"` | u32 | 7 |
| `@"memory-digest-max-chars"` | u32 | 2000 |

- [ ] **Step 1:** 通读 config.zig 中 `restore-tabs-on-startup`（bool）、`font-size`（u32）、任一字符串键的声明与解析块，逐一仿写五个键。字符串键注意所有权（跟随现有字符串键的 dupe/free 模式）。无效值 `log.warn` 后保默认（现有惯例）。
- [ ] **Step 2:** 若 config.zig 或 test 文件中存在现有键的解析测试模式，为新键补一组（bool 真/假/无效、u32 数字/无效、字符串原样）；若无此模式则不造新测试设施（跟随仓库现状，在报告说明）。
- [ ] **Step 3:** `zig build test` 全绿；fmt；commit `feat(memory-digest): config keys for scheduler`（显式 add config.zig 及测试文件）。

---

### Task 2: `src/memory_digest/scheduler.zig` — 决策 + 状态 + 线程编排

**Files:**
- Create: `src/memory_digest/scheduler.zig`
- Modify: `src/test_fast.zig`

**Interfaces（Task 3 消费）:**

```zig
pub const Settings = struct {
    enabled: bool = false,
    profile_name: []const u8 = "",   // borrowed; updateSettings 内部 dupe
    run_after: []const u8 = "04:00",
    backfill_days: u32 = 7,
    max_chars: u32 = 2000,
};
pub fn updateSettings(s: Settings) void      // 配置加载/热重载时调（主线程）
pub fn tick(gpa: std.mem.Allocator) void     // 主循环每帧调；内部自节流（每 60s 真正检查一次）
pub fn deinit() void                         // app 退出时 join 线程

// 纯决策（单测对象）：
pub fn parseRunAfterMinutes(s: []const u8) ?u16          // "04:00"→240；非法→null
pub fn shouldRun(now_ms: i64, tz_offset_seconds: i32, run_after_minutes: u16, last_run_date_key: u32, app_started_ms: i64) bool
// 条件：本地日 dateKey(now) != last_run_date_key 且 本地时刻 >= run_after 且 now-app_started >= 5min
pub const LastRun = struct { schema_version: u32 = 1, date_key: u32 = 0 };
pub fn loadLastRun(gpa: std.mem.Allocator, path: []const u8) LastRun   // 缺失/损坏→{}
pub fn saveLastRun(gpa: std.mem.Allocator, path: []const u8, v: LastRun) !void  // 原子写
```

实现要点：
1. 模块级状态（新文件自持，不进 session.zig 的 g_* 守卫范围）：settings（arena 持有 dupe 的字符串）、`thread: ?std.Thread`、`in_flight: std.atomic.Value(bool)`、`last_tick_check_ms: i64`、`app_started_ms`（首次 tick 记录）。
2. `tick`：未启用→返回；距上次真正检查 <60s→返回；in_flight→返回；`loadLastRun(<memoryDir>/state/last_run.json)` + `shouldRun(...)` → 否→返回；是→ `in_flight=true`，`std.Thread.spawn(.{}, runThreadMain, .{gpa快照参数})`（先 join 掉已结束旧线程句柄）。
3. `runThreadMain`：完全复用 M2a 组件——堆分配 profiles + `profile_store.loadProfiles` + `llm.pickProfile(settings.profile_name)` + `configFromProfile`；构建 `run.Options{roots=真实三源路径（照 scan_main.zig 的组装逻辑抽个共享 helper 或就地复制,tz=time.localOffsetSeconds(), backfill_days, max_chars_per_message, completer, model_label}`；`run.runOnce`；成功→`saveLastRun(今天 date_key)`；无论成败 `log.info/warn` 摘要计数；最后 `in_flight=false` + `window_backend.postWakeup()`。找不到任何 profile → log.warn 跳过（**不**降级 raw——自动任务无 LLM 没意义），仍 saveLastRun（避免每分钟重试敲日志；注释注明）。runOnce 失败（如 ReduceFailed）→ **不** saveLastRun，60s 节流下当日自然重试，注释注明 M3 runs.json 接管补跑语义。
4. `scan_main.zig` 的 roots 组装若被抽成共享 helper，放 `run.zig` 里 `pub fn defaultLocalRoots(gpa) !...`（谁改谁负责保 CLI 行为不变）；ponytail：直接复制 ~15 行也可接受，注明即可。

- [ ] **Step 1:** 写 scheduler.zig（实现 + 单测：parseRunAfterMinutes 合法/非法表；shouldRun 的 已跑过今天/未到时点/未满5分钟/满足全部 四象限；LastRun 状态文件往返+损坏→空）。线程路径不单测。
- [ ] **Step 2:** 注册 test_fast.zig；`zig build test`；fmt；commit `feat(memory-digest): daily scheduler with pure decision core`（显式 add）。

---

### Task 3: AppWindow 接线 + 真机验证

**Files:**
- Modify: `src/AppWindow.zig`（主循环 tick 一行 + 配置应用两处 + 退出 deinit 一处）
- Modify（如 Task 2 选了共享 helper）: `src/memory_digest/run.zig`、`src/memory_digest/scan_main.zig`

- [ ] **Step 1:** 通读 `checkConfigReload`（AppWindow.zig:5987 起）与初始配置加载路径，找到 cfg 值被消费的位置；两处都调 `memory_digest_scheduler.updateSettings(.{ .enabled = cfg.@"memory-digest-enabled", ... })`。
- [ ] **Step 2:** 主循环（AppWindow.zig:6880 `checkConfigReload` 调用之后）加 `memory_digest_scheduler.tick(allocator);`；找到主循环退出/清理段加 `memory_digest_scheduler.deinit();`。
- [ ] **Step 3:** `zig build test` + `zig build test-full -Dtarget=aarch64-macos` 全绿；fmt。
- [ ] **Step 4: 真机验证（M2b 出口标准）**——config 文件写入 `memory-digest-enabled = true`、`memory-digest-profile = DeepSeek`、`memory-digest-run-after = 00:00`；删除 `<memoryDir>/state/last_run.json`；`zig build macos-app` 并启动；等待 ≤90s（60s 节流 + 5 分钟启动延迟——**验证时把 5min 启动延迟临时经 Settings 参数化或调成 0，用注释标明默认 5min**，或改为 shouldRun 的 app_started 参数在测试里注入——实现者选一种并在报告说明）；确认：日志出现 digest 摘要行、`state/last_run.json` 写入今日、daily 有更新、UI 无卡顿（调度线程期间正常操作）。验证输出写报告。
- [ ] **Step 5:** commit `feat(memory-digest): wire daily scheduler into app main loop`（显式 add AppWindow.zig 等）。

注意：启动延迟的参数化以"默认行为=5 分钟"为准，真机验证不许靠改产品默认值过关。
