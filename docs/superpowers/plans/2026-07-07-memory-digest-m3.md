# Memory Digest M3（远程源 + runs.json）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** spec §6/§13/§15 M3：扫描 WSL/SSH 上的 claude/codex 日志（复用 ScannerHost 的 RemoteExecHost 模式）、runs.json 运行记录（成本/失败可见）、summaryKey 纳入 source_id、远程项目路径进 project.json aliases。出口标准：含至少一个真实 SSH 源的增量运行稳定，runs.json 记录逐源状态。

**Architecture:** 新增 `src/memory_digest/remote.zig`（find 输出解析 + 逐文件游标判定 + cat + provider 解析，全部经 `RemoteExecHost{ctx, exec}` vtable——测试用假 exec 打桩，绝不真连）。run.zig 增加多源编排（逐源隔离失败）。SSH 源枚举读 ssh_hosts（不碰 overlays 的 threadlocal UI 态）。

**Tech Stack:** Zig；无新依赖。已核实 API：`session.zig:81` `RemoteExecHost{ctx: *anyopaque, exec: *const fn (*anyopaque, Allocator, []const u8) anyerror![]u8}`；`session.zig:1058` `providerFindCommand(provider, root, out)`（GNU find 输出 `%T@\t%s\t%p`，head -500）；`session.zig:1116` `remoteCatCommand(path, out)`；`connection.zig:98` `SshConnection.fromParts(Parts{user,host,port,proxy_jump,password,auth_method,identity_file})`；`remote_file.zig:199` `sshExecCapture(allocator, conn, command) ![]u8`（ConnectTimeout=8s 硬编码）；ssh_hosts 加密内容读取 `AppWindow.zig:2407` `sshHostsEncodedContent`（hex 解码 codec 与 SSH 设置页同套——实现者 grep `ssh_hosts` 找解析器）。

## Global Constraints

- 分支 `feat/memory-digest-m1`；commit 前 `zig fmt build.zig src`；测试 `zig build test`（禁裸 zig build；Benchmark 计时 flake 复跑确认）。
- **实现/审查代理必须亲自动手，禁止 Agent 工具/嵌套委派。**
- **显式 stage，严禁 git add -A；提交前 git status --short 核对。**
- 测试绝不真连 SSH/网络：远程路径全走假 RemoteExecHost（返回预置 find/cat 输出的 stub）。
- 测试前缀 `memory_digest_<file>:`；新文件注册 test_fast.zig。
- conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。

---

### Task 1: runs.json（store + run 集成）

**Files:** Modify `src/memory_digest/store.zig`、`src/memory_digest/run.zig`

**Interfaces:**

```zig
// store.zig
pub const SourceStatus = struct {
    source_id: []const u8,
    status: []const u8, // "ok" | "skipped" | "failed"
    detail: []const u8 = "", // 失败原因/跳过原因
    sessions_collected: u32 = 0,
};
pub const RunRecord = struct {
    started_at: i64,
    finished_at: i64 = 0,
    status: []const u8 = "ok", // "ok" | "partial" | "failed"
    sources: []const SourceStatus = &.{},
    sessions_summarized: u32 = 0,
    sessions_failed: u32 = 0,
    llm_calls: u32 = 0,
};
pub fn appendRunRecord(gpa: std.mem.Allocator, memory_root: []const u8, rec: RunRecord) !void
// 读 state/runs.json {schema_version, runs:[]}（缺失/损坏→空），append，只留最近 60 条，原子写。
```

- run.zig：`Summary` += `llm_calls: usize = 0`（digest 的 completer 调用计数——给 Completer 加计数最省事：run 层包一个 counting wrapper `CountingCompleter{inner, count}`，~15 行）；runOnce 结束（成功路径）与错误路径（`errdefer` 或显式 catch-rethrow）都 `appendRunRecord`（写失败只 log.warn 不影响主流程）。M3 Task 3 会填 sources[]；本任务先记 local 单源。
- 测试：appendRunRecord 新建/追加/60 条截断/损坏→重建；runOnce 成功与 reduce 失败两路都留下 RunRecord（复用现有 stub 测试模式）。

- [ ] Step 1 实现+测试；Step 2 `zig build test` 全绿；Step 3 fmt+commit `feat(memory-digest): runs.json observability`（显式 add store.zig run.zig）。

---

### Task 2: `src/memory_digest/remote.zig` — 远程采集核心

**Files:** Create `src/memory_digest/remote.zig`；Modify `src/test_fast.zig`

**Interfaces:**

```zig
pub const ExecHost = struct { // 与 session.zig RemoteExecHost 同构，本模块自定义避免 import UI 耦合层
    ctx: *anyopaque,
    exec: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, command: []const u8) anyerror![]u8,
};
pub const RemoteRootsSpec = struct { claude: bool = true, codex: bool = true }; // wispterm 仅本地
pub fn collectRemote(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,           // CollectedSession 输出挂这
    out: *std.ArrayListUnmanaged(types.CollectedSession),
    source_id: []const u8,              // "ssh:<name>" | "wsl:<distro>"
    host: ExecHost,
    cur: *cursors_mod.Set,
    min_mtime_ns: i128,
) !u32                                   // 返回本源采集的会话数
```

实现要点：
1. `printf %s "$HOME"` 拿远程 home（exec 一次；失败→error.RemoteHomeFailed，调用方按源隔离处理）。
2. 每 provider（claude→`<home>/.claude/projects`、codex→`<home>/.codex/sessions`）：拼 find（**复用 `session.zig` 的 `providerFindCommand`——它是 pub**，root 用远程 home 拼出）→ exec → 解析每行 `%T@\t%s\t%p`（`mtime_epoch_float\tsize\tpath`；mtime 取整秒→ns）。**无 tab 的行（BSD fallback 无时间戳）→ 整源降级：log.warn + 返回 error.RemoteFindUnsupported**（ponytail：M3 只支持 GNU find 的 Linux 远端，BSD 留升级注释）。
3. 每文件：`stat=(size, mtime_ns)` → `cur.pendingFrom(source_id, provider, path, size, mtime_ns)`（cursor key 的 file=远程绝对路径，天然与 local 不冲突——source_id 也不同）→ null 跳过；mtime < min_mtime_ns 跳过（不建游标，同 local 语义）。
4. 变更文件：`remoteCatCommand(path)`（复用 session.zig pub fn）→ exec → bytes 走既有 provider_claude/provider_codex parseMetadata+parseTranscript → subagent 过滤 → 新消息切片 → CollectedSession{source_id=传入值, file_size/file_mtime_ns 填 stamp}——**这段与 collector.zig 的 collectJsonlFile 高度同构：把 collector.zig 里"bytes→CollectedSession"的解析段抽成 `pub fn ingestJsonlBytes(...)` 供两处共用**（谁抽谁保证 collector 既有测试全绿）。
5. cat 失败单文件跳过（不动游标，下次重试）；单文件 >64MB 由 cat 返回后长度判断（超限 stamp 防热重试，同 local 语义）。

测试（假 ExecHost：按 command 前缀分流返回预置输出）：
- find 输出 2 文件 → 首轮 2 会话；游标推进（模拟 run 层）后二轮 find 相同 → 0 会话 0 次 cat（**断言 stub 的 cat 调用计数为 0**——增量的核心价值）；
- 文件 mtime/size 变化 → 只 cat 那一个；
- BSD 格式（无 tab）→ error.RemoteFindUnsupported；
- home 失败 → error.RemoteHomeFailed；
- cat 返回 claude fixture（复用既有已验证 fixture 行）→ 解析出正确 project_path/新消息。

- [ ] Step 1 实现+抽 ingestJsonlBytes+测试；Step 2 注册+`zig build test`；Step 3 fmt+commit `feat(memory-digest): remote source collector over exec host`。

---

### Task 3: 源枚举 + 多源编排 + summaryKey/alias + 配置

**Files:** Modify `src/memory_digest/run.zig`、`src/memory_digest/scheduler.zig`、`src/memory_digest/scan_main.zig`、`src/config.zig`（+1 键）、`src/memory_digest/store.zig`（upsertProject alias 变体）

1. config.zig 加 `@"memory-digest-scan-remote"`: bool = false（**默认关**——比 spec 的 true 保守，首版远程扫描明确 opt-in；同步改 spec §12 表格默认值）。照 Task 1 样板+测试。
2. `run.Options` += `remote_sources: []const RemoteSource = &.{}`，`RemoteSource = struct { source_id: []const u8, host: remote.ExecHost }`。runOnce collect 阶段：local 照旧 → 逐 remote source `remote.collectRemote`，**单源失败 → SourceStatus{failed, detail=@errorName} 记 runs.json、继续其他源**（不整体失败）。sources[] 状态填全（local 也记）。
3. summaryKey：`fn summaryKey` 改为 `{source_id}|{provider}:{session_id}`（`|` 不出现在 source_id）；查旧摘要时 source_id=="local" 且新 key 未命中 → 回退查旧格式 `provider:session_id`（迁移注释：一个运行周期后可删）。测试：local 旧 key 回退命中；remote 不回退。
4. project aliases：store 加 `pub fn upsertProjectAlias(gpa, memory_root, slug, alias, date) !void`（进 aliases 数组去重，其余同 upsertProject）；run 的 phase2 对 remote 会话（source_id != "local"）用 `alias = "{source_id}:{project_path}"` 调 alias 变体，local 照旧 paths。测试：remote 会话产生 alias 不产生 path。
5. SSH 源枚举（scheduler + CLI 共用，放 run.zig 或新小文件 `sources.zig`）：`pub fn loadSshSources(gpa, arena) ![]RemoteSource` ——读 ssh_hosts（grep `sshHostsEncodedContent` / ssh 设置页找解析 codec；**不要**用 overlays 的 threadlocal）→ 每 profile 构造 `SshConnection.fromParts` → ExecHost 包装 `remote_file.sshExecCapture`（connection 值语义固定缓冲，装箱进 arena 分配的 ctx struct）。WSL：Windows-only，`Target.wsl` 的 exec 用 `remote_file.wslExec`——**macOS 上编译期排除/运行时空列表**，实现照 file_backend/session.zig 的现有平台分支。
6. scheduler runThreadMain 与 scan_main CLI：`memory-digest-scan-remote`（scheduler 从 Settings 加字段；CLI 加 `--remote` flag）为真时 loadSshSources 填 Options.remote_sources。
7. 测试：多源编排用假 ExecHost（一源成功一源 home 失败 → runs.json sources[] 一 ok 一 failed、成功源会话进 daily）；summaryKey 迁移；alias。

- [ ] Step 1-7 实现+测试；`zig build test` 全绿；fmt+commit `feat(memory-digest): multi-source orchestration with ssh sources`（显式 add；spec §12 默认值修订同 commit）。

---

### Task 4: 真机验证 + 收尾

- [ ] Step 1: `zig build test-full -Dtarget=aarch64-macos` + `zig fmt --check` 全绿。
- [ ] Step 2: 真机——`./zig-out/bin/wispterm-memory-digest --remote --profile DeepSeek`（构建带 `-Dtarget=aarch64-macos`）。预期：连接 ssh_hosts 里可达的主机（hk 等），runs.json sources[] 逐源状态；不可达/无日志的源 failed/ok-0 均可接受，**验证的是隔离性与增量**（连跑两次，第二次远程 cat 次数应为 0——从日志或耗时判断）。真机输出与逐源状态写报告。不可达全部源时如实记录（家庭网络环境差异可接受），只要本地源不受影响 + runs.json 记录完整即算过。
- [ ] Step 3: commit（若有微调）+ push + 汇报。
