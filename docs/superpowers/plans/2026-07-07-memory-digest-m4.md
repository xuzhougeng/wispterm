# Memory Digest M4（写入端补洞 + 手动触发）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** spec §10/§15 M4：WispTerm 自身 copilot 历史补会话级 cwd 与**消息级真实时间戳**（追加时刻打点，不是转换时刻），digest 端消费；命令面板 "Run Memory Digest Now" 手动触发。出口标准：新 copilot 会话项目归属正确、消息按真实时刻归日；面板一键触发可用。

## Global Constraints

- 分支 `feat/memory-digest-m1`；commit 前 `zig fmt build.zig src`；测试 `zig build test`（禁裸 zig build；Benchmark/tool_import flake 复跑确认）。
- **实现/审查代理亲自动手，禁止 Agent 工具/嵌套委派；显式 stage，严禁 git add -A。**
- conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
- 已核实锚点：`src/agent/history.zig:15-46`（MessageRecord/SessionRecord）；`src/assistant/conversation/session.zig:4233` `toHistoryRecordLocked`（构造 record 的唯一点，可访问 `effectiveWorkingDirLocked()` ~1046）、`captureHistoryChangeLocked` ~4311、消息 append 点 1248/2370/2599/2636；命令面板：`src/command/center_state.zig:6-109`（CommandAction+command_entries）、`src/renderer/overlays.zig:697-781`（executeCommand）。

---

### Task 1: 写入端 cwd/ts + digest 消费

**Files:** Modify `src/agent/history.zig`、`src/assistant/conversation/session.zig`、`src/memory_digest/provider_wispterm.zig`、`src/memory_digest/collector.zig`（wispterm 分支 project_path）

1. `history.zig`：`SessionRecord` += `cwd: []const u8 = ""`；`MessageRecord` += `ts: i64 = 0`。**默认值保证旧文件 std.json 解析兼容，无迁移**。所有权照同结构既有字符串字段模式（读 history_store 的 dupe/free 全链路再动手）。
2. `session.zig`：先查内存消息结构（Session.messages 的元素类型）有没有时间戳字段；**没有则加 `ts_ms: i64 = 0`**，在全部 append 用户/assistant/tool 消息的点（探索定位 1248/2370/2599/2636，以 grep `messages.append` 全量核对为准）赋 `std.time.milliTimestamp()`。`toHistoryRecordLocked`：MessageRecord.ts = 内存消息 ts_ms；SessionRecord.cwd = `effectiveWorkingDirLocked() orelse ""`（注意锁内调用安全——函数名带 Locked 说明已在锁内，直接调）。**若 ai_chat/序列化-反序列化路径（历史恢复回内存）存在，恢复时也要带回 ts**（grep record→内存的反向转换点）。
3. `provider_wispterm.zig`：RawSession += `cwd: []const u8 = ""`；RawMessage += `ts: i64 = 0`；输出 `Session` += `cwd: []const u8`；消息 `timestamp_ms = if (raw.ts > 0) raw.ts else parsed.updated_at`。
4. `collector.zig` wispterm 分支：`project_path` 从 `""` 改为 `sess.cwd`（空串行为不变→unassigned）。
5. 测试：history 侧——新字段写入往返（照 history_store 既有 tmpDir 测试模式，构造带 cwd/ts 的 record 存取断言）；旧 JSON（无新字段）解析默认值；provider_wispterm——带 cwd/ts 的 fixture 解析正确 + 旧 fixture 兼容（既有测试即回归）；collector wispterm 分支 project_path 断言更新。
6. session.zig 改动跑 `zig build test` 外，**必须**跑 `zig build test-full -Dtarget=aarch64-macos`（ai_chat/session 测试在 full 套件）。

- [ ] 实现+测试全绿；fmt；commit `feat(memory-digest): record cwd and message timestamps in copilot history`（显式 add 四文件）。

---

### Task 2: 命令面板手动触发 + 真机验证

**Files:** Modify `src/memory_digest/scheduler.zig`、`src/command/center_state.zig`、`src/renderer/overlays.zig`

1. scheduler.zig：`pub fn runNow(gpa: std.mem.Allocator) void`——跳过 enabled/日期/时点/启动延迟检查（手动=用户明确意图），保留 in_flight 守卫（已在跑→log.info 忽略）与线程 join/spawn 逻辑（抽出 tick 的 spawn 段共用）；成功照常 saveLastRun。单测：不可测线程，仅测"in_flight 时 runNow 不 spawn"如可行，否则报告说明。
2. center_state.zig：`CommandAction` += `.run_memory_digest_now`；`command_entries` += `.{ .title = "Run Memory Digest Now", .detail = "Scan AI chat logs and generate today's digest", .shortcut = "", .action = .run_memory_digest_now }`（标签硬编码，跟现状；不加 keybind）。
3. overlays.zig `executeCommand`：`.run_memory_digest_now => memory_digest_scheduler.runNow(<该函数可用的 allocator，照相邻分支>)`。
4. 命令中心若有守卫测试/条目计数测试（grep command_entries 相关 test）同步更新。
5. 真机验证：`zig build test` + `test-full -Dtarget=aarch64-macos` 绿；`zig build macos-app` 启动（无需 enabled——runNow 绕过），命令面板执行 "Run Memory Digest Now"，观察 daily/runs.json 更新与日志；随手发一条 copilot 消息后再触发一次，确认新会话带 cwd（daily 里该会话 project ≠ unassigned）。输出写报告。
- [ ] 实现+验证；fmt；commit `feat(memory-digest): manual run command in palette`（显式 add 三文件）。
