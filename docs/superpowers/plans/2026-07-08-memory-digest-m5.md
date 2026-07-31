# Memory Digest M5（硬化：LLM 超时 + token 用量 + refs 保真）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 终审遗留三项硬化：① llm.Client 真实请求超时（替换"关停 detach"作为唯一兜底）；② runs.json 记录 token 用量；③ reduce 的 session_refs 保真（prompt 强化 + 代码过滤）。附带修 final-review Minor#7（同 slug 混合本地/远程时 paths/aliases 双累积）。**不做**：BSD find（远程机全 Linux，显式报错保留）、网页可视化（用户自建，契约 spec §9）。

**Tech Stack:** Zig 0.15.2。已侦察：std.http.Client 无原生超时；`pub fn request()`（Client.zig:1660）返回 `Request{connection: ?*Connection, ...}`（:765-774），Connection 的 `stream_reader` 字段链可达 `net.Stream`/fd（Zig 结构体字段全公开；file-private 的 `getStream()` 不可调但可直接走字段）；`SO.RCVTIMEO/SNDTIMEO` 在 std.c 有常量，`std.posix.setsockopt` + `timeval` 即可。

## Global Constraints

- 分支 `feat/memory-digest-m1`（PR #521 尚未合并，继续演进）；commit 前 `zig fmt build.zig src`；测试 `zig build test`（禁裸 zig build；Benchmark/tool_import flake 复跑确认）。
- **实现/审查代理亲自动手，禁止 Agent 工具/嵌套委派；显式 stage，严禁 git add -A。**
- 测试绝不真连网络。
- conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。

---

### Task 1: LLM 请求超时 + token 用量入 runs.json

**Files:** Modify `src/memory_digest/llm.zig`、`src/memory_digest/run.zig`、`src/memory_digest/store.zig`、`src/memory_digest/scheduler.zig`、`src/memory_digest/scan_main.zig`

**A. 超时（llm.zig）**：
1. `Config` += `timeout_seconds: u32 = 120`。
2. `Client.complete` 从 `client.fetch(...)` 改为 request 级 API：`client.request(.POST, uri, ...)` → 拿 `req.connection.?` 沿字段链取 socket fd → `std.posix.setsockopt(fd, SOL.SOCKET, SO.RCVTIMEO, timeval)` + SNDTIMEO（macOS/Linux 常量都在 std.c；Windows 用 DWORD 毫秒——本模块只跑桌面端，按 builtin.os 分支或仅 posix 平台设置、Windows 留 TODO 注释均可，写明选择）→ 发 body（`sendBodyComplete`）→ `receiveHead` → 读响应体（沿用 16KB 缓冲/Allocating writer 的等价物，redirect_buffer 按 API 要求给）。头部行为不变（anthropic x-api-key 分支照旧——request API 下 headers 通过 `Request.headers`/`extra_headers` 设置，读 std 源确认字段再写）。
3. 超时错误（read 返回 WouldBlock/超时类 error）→ `return error.LlmTimeout`；日志一行含 model/耗时上限。
4. **兜底**：若实现中发现字段链在 0.15.2 实际不可达（编译不过），停下来把证据写进报告并改用方案 B：保留 fetch + 在 scheduler 线程侧文档化 detach 兜底为唯一机制——不许静默放弃。
5. 无单测（网络粘合，惯例）；`zig build memory-digest -Dtarget=aarch64-macos` 编译过 + 真机 `--profile DeepSeek` 冒烟一次（跑通即够，见 Task 2 步骤合并做）。

**B. token 用量**：
1. `llm.Client` += `total_usage: protocol.ApiUsage = .{}`；complete() 里 parse 出 `ApiResult.usage` 非空则 `self.total_usage.add(u)`（在 free 前取）。
2. `store.RunRecord` += `prompt_tokens: u64 = 0, completion_tokens: u64 = 0, total_tokens: u64 = 0`（additive，schema 兼容）。
3. `run.Options` += `llm_usage: ?*const protocol.ApiUsage = null`；recordRun 时读入 RunRecord。
4. scheduler.runThreadMain 与 scan_main：构造 client 后传 `&client.total_usage`；CLI 摘要行打印 tokens。
5. 测试：store 的 RunRecord 新字段往返；run 的 stub 路径 usage 缺省 0（既有测试不破即可）。

- [ ] 实现；`zig build test` 绿；fmt；commit `feat(memory-digest): llm request timeouts and token usage in runs.json`（显式 stage 五文件）。

---

### Task 2: session_refs 保真 + paths/aliases 双累积 + 真机验证

**Files:** Modify `src/memory_digest/digest.zig`、`src/memory_digest/run.zig`

1. **prompt 强化**（digest.zig reduce prompt const）：明确 "session_refs 与 timeline 的 session_refs 只能填输入数组里 session_id 字段的原值，禁止用标题"。
2. **代码过滤**：reduceDay 后处理（或 dupeReduceResult 内）：`projects[].session_refs` 与 `timelines[].entry.session_refs` 逐项 ∩ 当日输入 sessions 的 session_id 集合，非法项丢弃并 `log.debug` 计数；events[].refs **不过滤**（合法含 pr/commit/file 引用）。测试：stub 回包 refs 混入标题与合法 id → 结果仅剩合法 id；全非法 → 空数组不报错。
3. **Minor#7 双累积**（run.zig phase2 ~456-479 附近）：对每个 reduce slug，遍历该 slug 的全部 summarized 会话——local 的调 `upsertProject`（path），remote 的调 `upsertProjectAlias`（前缀 alias），不再"取第一个命中"。同 slug 同日混合两侧时两者都落。测试：一 local 一 remote 同项目名 stub → project.json 里 paths 与 aliases 各有其一。
4. **真机验证（M5 出口）**：`zig build memory-digest -Dtarget=aarch64-macos`；`./zig-out/bin/wispterm-memory-digest --profile DeepSeek`（可加 --remote）跑通：runs.json 最新记录带非零 token 计数；无超时环境下行为不变；（若方便）临时把 timeout_seconds 调成 1 验证 LlmTimeout 触发路径后改回——或用不可达 base_url 的临时 profile 验证，如实报告。
5. `zig build test-full -Dtarget=aarch64-macos` 全绿。

- [ ] 实现+验证；fmt；commit `feat(memory-digest): session ref fidelity and mixed-source project records`（显式 stage）。
