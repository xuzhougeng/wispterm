# Memory Digest M2a（脱敏 + LLM 归纳管道）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 spec §7/§8 的 M2a：脱敏 → LLM map（会话摘要，增量）→ LLM reduce（日报 projects/highlights + 项目时间线），CLI 手动触发真实 LLM，产出 spec §9 完整契约的 JSON。

**Architecture:** 在 M1 的 `src/memory_digest/` 上新增 redact.zig / llm.zig / digest.zig，扩展 store.zig 与 run.zig。LLM 调用复用 `assistant/conversation/protocol.zig` 的 pub 层（RequestParams/buildRequestJson/apiEndpoint/parseApiResponse，全部无 Session 依赖），HTTP 头行为镜像 `request.zig` 的 runChatRequestForMessages。digest 通过 `Completer` vtable 注入 LLM——测试全部打桩，永不联网。调度与配置项归 M2b。

**Tech Stack:** Zig（仓库既有版本）；测试进 fast 套件；无新依赖。

## Global Constraints

- 分支：继续在 `feat/memory-digest-m1` 上提交（同一 PR #518 演进）。
- 每次 commit 前跑 `zig fmt build.zig src`；测试统一 `zig build test`；**不要跑裸 `zig build`**。
- 新测试命名前缀 `memory_digest_<file>:`；每个新文件在 `src/test_fast.zig` 的 memory_digest 段追加注册。
- **git 提交显式列出文件，严禁 `git add -A` / `git add .`；提交前 `git status --short` 核对。**
- 测试中绝不发起真实网络请求；digest/run 的 LLM 一律经 Completer 打桩。
- commit 信息 conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。
- 关键真实签名（已核实，直接引用）：
  - `protocol.zig`（`src/assistant/conversation/protocol.zig`）：`Role{user,assistant,tool}`；`RequestMessage{role: Role, content: []u8, reasoning/tool_call_id/tool_calls/images: null 默认}`；`ApiResult{content: []u8, reasoning: ?[]u8, tool_calls: ?[]ToolCall, usage: ?ApiUsage, api_error: bool, deinit(alloc)}`；`RequestParams{model, system_prompt, protocol, thinking_enabled, reasoning_effort, stream, max_tokens: u32 = 8192, ...其余有默认}`；`pub fn buildRequestJson(alloc, params, messages, include_tools) ![]u8`；`pub fn apiEndpoint(alloc, base_url, protocol) ![]u8`；`pub fn parseApiResponse(alloc, body, protocol) !ApiResult`；`ApiProtocol.parse(value) ApiProtocol`。
  - HTTP 模式（`request.zig:566-617` 镜像）：`std.http.Client{.allocator, .write_buffer_size = 16384}`；`std.Io.Writer.Allocating.init(alloc)` 收响应；anthropic 用 `x-api-key` + `anthropic-version: 2023-06-01` 且 authorization `.omit`，其余 `Bearer <key>`；非 `.ok` 状态按错误处理。
  - profile：`src/assistant/profile/store.zig` 的 `pub fn loadProfiles(allocator, out: []profile_codec.AiProfile) usize`；codec 在 `src/renderer/overlays/profile_codec.zig`：`AiProfile{fields, lens}`、`pub fn aiProfileField(profile: *const AiProfile, field: AiField) []const u8`、`AiField{.name,.base_url,.api_key,.model,.protocol,.max_tokens,...}`。AiProfile 约 98KB/个——**必须堆分配**，不得放栈。

---

### Task 1: `src/memory_digest/redact.zig` — 文本脱敏

**Files:**
- Create: `src/memory_digest/redact.zig`
- Modify: `src/test_fast.zig`

**Interfaces:**
- Produces: `pub const MASK = "[REDACTED]"`；`pub fn redact(alloc: std.mem.Allocator, text: []const u8) ![]u8`（返回掩码副本，调用方 free/挂 arena）。

规则（spec §7）：
1. 密钥前缀：`sk-` `ghp_` `gho_` `github_pat_` `xoxb-` `xoxp-` `AKIA`，且前缀左边界非字母数字（或行首），后接 ≥8 个 `[A-Za-z0-9_-]` → 整串掩码。
2. `Bearer ` 后的 ≥8 非空白串 → 掩码该 token。
3. 键值：`password` `passwd` `token` `api_key` `apikey` `secret`（大小写不敏感，左边界同上）后跟 `=` 或 `:`（可带一个空格）再跟 ≥4 非空白串 → 掩码值部分，键保留。
4. ≥64 位连续十六进制 → 掩码；≥40 位且同时含大写+小写+数字的 `[A-Za-z0-9+/=_-]` 串 → 掩码。**40 位纯 hex 的 git SHA 刻意放行**（spec §7 修订）。

- [ ] **Step 1: 写完整文件（实现+表驱动测试）**

```zig
//! Text-level secret masking before chat content reaches the LLM (spec §7).
//! Structural exclusion (wispterm api_key field) already happens in
//! provider_wispterm; this pass catches secrets pasted into message text.
const std = @import("std");

pub const MASK = "[REDACTED]";

const KEY_PREFIXES = [_][]const u8{ "sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AKIA" };
const KV_KEYS = [_][]const u8{ "password", "passwd", "api_key", "apikey", "token", "secret" };

pub fn redact(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const boundary_ok = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]);
        if (boundary_ok) {
            if (matchAt(text, i)) |m| {
                try out.appendSlice(alloc, text[i .. i + m.keep]);
                try out.appendSlice(alloc, MASK);
                i += m.len;
                continue;
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

const Match = struct {
    /// Total input bytes consumed.
    len: usize,
    /// Leading bytes to keep verbatim (e.g. "password=" before the mask).
    keep: usize = 0,
};

fn matchAt(text: []const u8, i: usize) ?Match {
    const rest = text[i..];
    for (KEY_PREFIXES) |prefix| {
        if (std.ascii.startsWithIgnoreCase(rest, prefix)) {
            const tail = tokenLen(rest[prefix.len..], 0);
            if (tail >= 8) return .{ .len = prefix.len + tail };
        }
    }
    if (std.ascii.startsWithIgnoreCase(rest, "bearer ")) {
        const tail = nonSpaceLen(rest["bearer ".len..]);
        if (tail >= 8) return .{ .len = "bearer ".len + tail, .keep = "bearer ".len };
    }
    for (KV_KEYS) |key| {
        if (std.ascii.startsWithIgnoreCase(rest, key)) {
            var j = key.len;
            if (j >= rest.len or (rest[j] != '=' and rest[j] != ':')) continue;
            j += 1;
            if (j < rest.len and rest[j] == ' ') j += 1;
            const tail = nonSpaceLen(rest[j..]);
            if (tail >= 4) return .{ .len = j + tail, .keep = j };
        }
    }
    // Long hex run (>=64) — sha256-style tokens; 40-hex git SHAs pass through.
    const hex = hexLen(rest);
    if (hex >= 64) return .{ .len = hex };
    // Long mixed-case base64-ish run (>=40) with upper+lower+digit.
    const b64 = base64Len(rest);
    if (b64 >= 40 and hasMixedClasses(rest[0..b64])) return .{ .len = b64 };
    return null;
}

fn tokenLen(s: []const u8, start: usize) usize {
    var n = start;
    while (n < s.len and (std.ascii.isAlphanumeric(s[n]) or s[n] == '_' or s[n] == '-')) n += 1;
    return n;
}

fn nonSpaceLen(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and !std.ascii.isWhitespace(s[n]) and s[n] != '"' and s[n] != '\'') n += 1;
    return n;
}

fn hexLen(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and std.ascii.isHex(s[n])) n += 1;
    return n;
}

fn base64Len(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and (std.ascii.isAlphanumeric(s[n]) or
        s[n] == '+' or s[n] == '/' or s[n] == '=' or s[n] == '_' or s[n] == '-')) n += 1;
    return n;
}

fn hasMixedClasses(s: []const u8) bool {
    var upper = false;
    var lower = false;
    var digit = false;
    for (s) |c| {
        if (std.ascii.isUpper(c)) upper = true;
        if (std.ascii.isLower(c)) lower = true;
        if (std.ascii.isDigit(c)) digit = true;
    }
    return upper and lower and digit;
}

const Case = struct { in: []const u8, expect_masked: bool };

test "memory_digest_redact: table-driven positive and negative cases" {
    const cases = [_]Case{
        .{ .in = "key is sk-abc12345678 ok", .expect_masked = true },
        .{ .in = "ghp_0123456789abcdef pushed", .expect_masked = true },
        .{ .in = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload", .expect_masked = true },
        .{ .in = "password=hunter22 login", .expect_masked = true },
        .{ .in = "token: ZXhhbXBsZQ== done", .expect_masked = true },
        .{ .in = "hash 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef end", .expect_masked = true },
        .{ .in = "jwt AbC1dEf2GhI3jKl4MnO5pQr6StU7vWx8Yz90AbC1 sig", .expect_masked = true },
        // Negatives:
        .{ .in = "the task-brief file", .expect_masked = false }, // sk- not at boundary
        .{ .in = "sk-short", .expect_masked = false }, // tail < 8
        .{ .in = "commit 74707cdfd1b3f4b21c9a8e5d6f7a8b9c0d1e2f3a fixed it", .expect_masked = false }, // 40-hex git SHA
        .{ .in = "the token was expired", .expect_masked = false }, // no = or :
        .{ .in = "password= ", .expect_masked = false }, // empty value
        .{ .in = "plain text with nothing", .expect_masked = false },
    };
    for (cases) |case| {
        const out = try redact(std.testing.allocator, case.in);
        defer std.testing.allocator.free(out);
        const masked = std.mem.indexOf(u8, out, MASK) != null;
        if (masked != case.expect_masked) {
            std.debug.print("case failed: '{s}' -> '{s}'\n", .{ case.in, out });
            return error.TestUnexpectedResult;
        }
    }
}

test "memory_digest_redact: keeps key prefix and masks value" {
    const out = try redact(std.testing.allocator, "password=hunter22 rest");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("password=" ++ MASK ++ " rest", out);
}

test "memory_digest_redact: masks whole prefixed key" {
    const out = try redact(std.testing.allocator, "use sk-abc12345678 now");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("use " ++ MASK ++ " now", out);
}
```

注意：若 `std.ascii.startsWithIgnoreCase` 不存在，用 `std.ascii.eqlIgnoreCase(rest[0..prefix.len], prefix)` 加长度检查替代（行为一致）。

- [ ] **Step 2: 注册 `_ = @import("memory_digest/redact.zig");`（run.zig 那行之后）+ `zig build test` 全过**
- [ ] **Step 3: fmt + commit** `feat(memory-digest): text-level secret redaction`（显式 add redact.zig + test_fast.zig）

---

### Task 2: `src/memory_digest/llm.zig` — 无 Session 薄客户端 + profile 选择

**Files:**
- Create: `src/memory_digest/llm.zig`
- Modify: `src/test_fast.zig`

**Interfaces:**
- Produces:
  - `pub const Completer = struct { ctx: *anyopaque, completeFn: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, system_prompt: []const u8, user_text: []const u8) anyerror![]u8, pub fn complete(...) anyerror![]u8 }`（digest/run 消费；测试打桩的注入点）
  - `pub const Config = struct { base_url: []const u8, api_key: []const u8, model: []const u8, protocol: protocol.ApiProtocol, max_tokens: u32 = 4096 }`
  - `pub const Client = struct { config: Config, pub fn completer(self: *Client) Completer, pub fn complete(self: *Client, gpa, system_prompt, user_text) ![]u8 }`
  - `pub fn pickProfile(profiles: []const profile_codec.AiProfile, count: usize, name: []const u8) ?usize`（name 空 → 0（若 count>0）；否则按 .name 精确匹配）
  - `pub fn configFromProfile(arena: std.mem.Allocator, profile: *const profile_codec.AiProfile) !Config`（字段 dupe 进 arena；protocol 用 `ApiProtocol.parse`；max_tokens `std.fmt.parseInt(u32,...,10) catch 4096`，空串同 4096）

- [ ] **Step 1: 写完整文件**

实现要点（HTTP 部分镜像 `request.zig:566-617`，那是已在生产验证的模式）：

```zig
//! Session-free LLM client for the memory digest (spec §8). Request JSON,
//! endpoint routing and response parsing reuse the assistant protocol layer;
//! the HTTP call mirrors assistant/conversation/request.zig's
//! runChatRequestForMessages (Bearer vs x-api-key, 16KB buffer, blocking).
const std = @import("std");
const protocol = @import("../assistant/conversation/protocol.zig");
const profile_codec = @import("../renderer/overlays/profile_codec.zig");
```

`Client.complete`：
1. `RequestParams{ .model, .system_prompt, .protocol, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .max_tokens }`（其余字段用默认）。
2. `const content = try gpa.dupe(u8, user_text); defer gpa.free(content);` 构造 `var messages = [_]protocol.RequestMessage{.{ .role = .user, .content = content }};`（RequestMessage.content 是 `[]u8` 所以必须 dupe）。
3. `buildRequestJson(gpa, params, &messages, false)`（include_tools=false）→ defer free。
4. `apiEndpoint(gpa, config.base_url, config.protocol)` → defer free。
5. fetch：完全按 request.zig 模式（client struct、Allocating writer、anthropic 头分支）。非 `.ok` → `return error.LlmHttpError`。
6. `parseApiResponse(gpa, body, protocol)` → 若 `.api_error` → `result.deinit(gpa); return error.LlmApiError;`；否则 free 掉 reasoning/tool_calls，`return result.content;`（调用方 free）。

`pickProfile`/`configFromProfile` 纯逻辑。测试只测这两个（Client.complete 是网络粘合，其组件各自有测试，真机验证在 Task 7——文件头加一行注释说明）：

```zig
fn testProfile(name: []const u8, model: []const u8, proto: []const u8, max_tokens: []const u8) profile_codec.AiProfile {
    var p: profile_codec.AiProfile = .{};
    setField(&p, .name, name);
    setField(&p, .base_url, "https://api.example.com/v1");
    setField(&p, .api_key, "k");
    setField(&p, .model, model);
    setField(&p, .protocol, proto);
    setField(&p, .max_tokens, max_tokens);
    return p;
}

fn setField(p: *profile_codec.AiProfile, field: profile_codec.AiField, value: []const u8) void {
    const idx: usize = @intFromEnum(field);
    @memcpy(p.fields[idx][0..value.len], value);
    p.lens[idx] = value.len;
}

test "memory_digest_llm: pickProfile by name with first as fallback" {
    var profiles = [_]profile_codec.AiProfile{ testProfile("a", "m1", "", "8192"), testProfile("b", "m2", "anthropic", "") };
    try std.testing.expectEqual(@as(?usize, 1), pickProfile(&profiles, 2, "b"));
    try std.testing.expectEqual(@as(?usize, 0), pickProfile(&profiles, 2, ""));
    try std.testing.expectEqual(@as(?usize, 0), pickProfile(&profiles, 2, "missing")); // fallback first + log 由调用方
    try std.testing.expectEqual(@as(?usize, null), pickProfile(&profiles, 0, ""));
}

test "memory_digest_llm: configFromProfile parses protocol and max_tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = testProfile("a", "deepseek-v4", "anthropic", "9000");
    const cfg = try configFromProfile(arena.allocator(), &p);
    try std.testing.expectEqualStrings("deepseek-v4", cfg.model);
    try std.testing.expectEqual(protocol.ApiProtocol.anthropic, cfg.protocol);
    try std.testing.expectEqual(@as(u32, 9000), cfg.max_tokens);
    var p2 = testProfile("a", "m", "", "");
    const cfg2 = try configFromProfile(arena.allocator(), &p2);
    try std.testing.expectEqual(protocol.ApiProtocol.chat_completions, cfg2.protocol);
    try std.testing.expectEqual(@as(u32, 4096), cfg2.max_tokens);
}
```

注意 `AiProfile` 若无默认初始化 `.{}`（fields undefined），改 `var p: profile_codec.AiProfile = undefined; p.lens = .{0} ** profile_codec.AI_FIELD_COUNT;`（以 codec 实际定义为准——先读 `src/renderer/overlays/profile_codec.zig:40-85` 再写）。`pickProfile("missing")` 的行为定为"回退第一个"，调用方（Task 7 CLI）负责打日志。

- [ ] **Step 2: 注册 + `zig build test`**
- [ ] **Step 3: fmt + commit** `feat(memory-digest): session-free llm client and profile selection`

---

### Task 3: 采集器游标控制权移交 run.zig

**Files:**
- Modify: `src/memory_digest/types.zig`（CollectedSession + stamp 字段）
- Modify: `src/memory_digest/collector.zig`（emit 不再推游标；测试适配）
- Modify: `src/memory_digest/run.zig`（处理成功后统一推游标——本任务保持 M1 等价行为）

**Interfaces:**
- `types.CollectedSession` 新增 `file_size: u64 = 0, file_mtime_ns: i128 = 0`（游标 stamp，供 run 层在该会话处理成功后调用 `cur.update(...)`）。
- `collector.emit()` 语义变更：**产出会话时不再调 `cur.update`**（skip 路径——subagent/无新消息/超大/损坏——照旧 stamp）；stamp 值填进 CollectedSession。
- `run.zig` 新增私有 helper `fn advanceCursor(cur: *cursors_mod.Set, s: types.CollectedSession) !void`（`cur.update(s.source_id 对应源, provider, s.source_file, s.file_size, s.file_mtime_ns, s.total_messages)`），M1 路径（无 LLM）对每个采到的会话在写完产物前循环调用（行为与 M1 完全等价：产物写失败→runOnce 返回错误→saveToPath 不执行）。

为什么：spec §6/§13 要求"单会话 LLM 归纳失败→该会话游标不推进"。M1 里游标在采集时就推了，Task 7 无法按会话粒度回退。本任务先把控制权交给 run 层，行为不变，Task 7 再按 map 成败选择性推进。

- [ ] **Step 1: types.zig 加两个字段（带注释说明归属 run 层）**
- [ ] **Step 2: collector.zig 修改 emit（删除末尾 cur.update，stamp 进 CollectedSession；`emit` 的 `stat` 参数已有）**
- [ ] **Step 3: collector 测试适配**——"first run collects, second collects none" 与 "appended lines" 两个测试在两次 collectLocal 之间模拟 run 层推进：

```zig
for (first.sessions) |s| {
    try cur.update(SOURCE_LOCAL, s.provider, s.source_file, s.file_size, s.file_mtime_ns, s.total_messages);
}
```

同时新增断言：collectLocal 返回后，被产出会话的游标**未**推进（`cur.pendingFrom(...) != null` 仍返回旧起点）。
- [ ] **Step 4: run.zig 在 daily 写入循环前对全部 sessions 调 advanceCursor（现有 run 集成测试应保持绿——它们断言的是第二次 runOnce 采不到东西，而 run 现在补推游标，语义等价）**
- [ ] **Step 5: `zig build test` 全过；fmt + commit** `refactor(memory-digest): move cursor advancement to run layer`（显式 add 三个文件）

---

### Task 4: store.zig M2 产物扩展 + session_summaries 状态

**Files:**
- Modify: `src/memory_digest/store.zig`

**Interfaces（全部 Task 5-7 消费）:**

```zig
pub const Artifact = struct { type: []const u8, ref: []const u8 };

// DailySession 新增（全带默认值，M1 写法不受影响）：
//   summary: []const u8 = "", topics: []const []const u8 = &.{},
//   outcome: []const u8 = "unknown", artifacts: []const Artifact = &.{},

pub const DailyProject = struct { slug: []const u8, summary: []const u8, session_refs: []const []const u8 = &.{} };
// Daily 新增: model: []const u8 = "", projects: []const DailyProject = &.{}, highlights: []const []const u8 = &.{}

pub const TimelineEvent = struct { type: []const u8, text: []const u8, refs: []const []const u8 = &.{} };
pub const TimelineEntry = struct { date: []const u8, summary: []const u8, events: []const TimelineEvent = &.{}, session_refs: []const []const u8 = &.{} };
pub fn upsertTimelineEntry(gpa: std.mem.Allocator, memory_root: []const u8, slug: []const u8, entry: TimelineEntry) !void
// 读 projects/<slug>/timeline.json（缺失/损坏→空），按 date 去重替换或追加，date 降序排序，原子写回。schema {schema_version, slug, entries}

pub fn upsertProject(gpa: std.mem.Allocator, memory_root: []const u8, slug: []const u8, project_path: []const u8, date: []const u8) !void
// 读 projects/<slug>/project.json（缺失→新建 {schema_version, slug, name=slug, paths=[], aliases=[], first_seen=date, last_active=date}）
// path 非空且不在 paths → 追加；last_active = max(旧, date)；first_seen = min(旧, date)；原子写

pub const SummaryRecord = struct {
    key: []const u8, // "provider:session_id"
    date: []const u8,
    summary: []const u8,
    topics: []const []const u8 = &.{},
    outcome: []const u8 = "unknown",
    artifacts: []const Artifact = &.{},
};
pub const SummaryStore = struct {
    arena: std.heap.ArenaAllocator,
    records: std.ArrayListUnmanaged(SummaryRecord) = .empty,
    pub fn init(gpa) SummaryStore / deinit / find(key) ?*SummaryRecord /
    pub fn put(self, rec: SummaryRecord) !void  // 按 key 覆盖或追加，字段 dupe 进 arena
    pub fn loadFromPath(gpa, path) !SummaryStore  // 缺失/损坏→空（cursors.Set 同款模式）
    pub fn saveToPath(self, gpa, path) !void      // 原子写 {schema_version, records}
};
```

- [ ] **Step 1: 实现（upsert 的读回用局部 lenient shape + ignore_unknown_fields，模式照 run.zig 的 mergeDailyWithExisting；SummaryStore 整体照抄 cursors.Set 的 arena 模式）**
- [ ] **Step 2: 测试（同文件底部，前缀 `memory_digest_store:`）**：
  - timeline upsert：新建→追加第二天→重放第一天（替换不重复）→断言降序与条目数
  - project upsert：新建含 first/last_seen；第二次换 path 追加、date 更新 last_active
  - SummaryStore：put 覆盖同 key；save/load 往返；损坏文件→空
- [ ] **Step 3: 注册无需改（store.zig 已注册）；`zig build test`；fmt + commit** `feat(memory-digest): timeline, project card and session summary state`

---

### Task 5: digest.zig — map（会话摘要）

**Files:**
- Create: `src/memory_digest/digest.zig`
- Modify: `src/test_fast.zig`

**Interfaces:**
- Produces:
  - `pub const MapOptions = struct { max_chars_per_message: usize = 2000, input_budget_chars: usize = 24_000 }`
  - `pub const MapResult = struct { summary: []const u8, topics: []const []const u8, outcome: []const u8, artifacts: []const store.Artifact }`（全挂调用方 arena）
  - `pub fn summarizeSession(arena: std.mem.Allocator, gpa: std.mem.Allocator, completer: llm.Completer, sess: types.CollectedSession, old_summary: ?[]const u8, opts: MapOptions) !MapResult`
  - `pub fn parseJsonObjectLenient(arena: std.mem.Allocator, comptime T: type, raw: []const u8) !T`（剥 ``` 围栏、截取首 `{` 到尾 `}`、`ignore_unknown_fields` 解析——reduce 复用）

实现要点：
1. 输入构建：遍历 `sess.new_messages`，跳过 `kind == .meta` 与空内容；每条经 `redact.redact`（gpa，用完 free 或挂临时 arena）；超过 `max_chars_per_message` 的截断为 头 2/3 + `\n…[截断]…\n` + 尾 1/3；拼成 `[角色] 内容\n` 列表。
2. 分块：拼接总量超 `input_budget_chars` → 按消息边界切块；对前面每块调用 completer 生成"滚动纯文本摘要"（prompt B），最后一块带滚动摘要调 prompt A 产出最终 JSON。不超限则单次 prompt A。
3. Prompt A（中文，const 存文件顶部）：身份=开发日志归纳员；输入=旧摘要（若有）+ 本次新增对话；要求：在旧摘要基础上合并新进展、不复述密钥、**只输出 JSON**：`{"summary":"…","topics":["…"],"outcome":"completed|in_progress|abandoned|unknown","artifacts":[{"type":"pr|commit|file|url","ref":"…"}]}`。Prompt B（滚动压缩）：输出纯文本摘要，无 JSON 要求。
4. 解析失败重试一次：第二次调用在 user 文本尾部附上 `（上次输出无法解析为 JSON：<err>。请只输出合法 JSON。）`；再失败 → `error.MapFailed`。
5. completer 返回的 `[]u8` 用 gpa free；结果字段 dupe 进 arena。

- [ ] **Step 1: 写完整文件（实现 + 打桩测试）**。测试用可编程 stub：

```zig
const StubCompleter = struct {
    responses: []const []const u8,
    calls: usize = 0,
    last_user_text: [8192]u8 = undefined,
    last_user_len: usize = 0,

    fn completer(self: *StubCompleter) llm.Completer {
        return .{ .ctx = self, .completeFn = complete };
    }
    fn complete(ctx: *anyopaque, gpa: std.mem.Allocator, system_prompt: []const u8, user_text: []const u8) anyerror![]u8 {
        _ = system_prompt;
        const self: *StubCompleter = @ptrCast(@alignCast(ctx));
        const n = @min(user_text.len, self.last_user_text.len);
        @memcpy(self.last_user_text[0..n], user_text[0..n]);
        self.last_user_len = n;
        const resp = self.responses[@min(self.calls, self.responses.len - 1)];
        self.calls += 1;
        return gpa.dupe(u8, resp);
    }
};
```

测试用例（构造 CollectedSession 直接填字段，消息用 `@constCast("…")` 或 arena dupe）：
  - 正常：stub 回 `{"summary":"s","topics":["t"],"outcome":"completed","artifacts":[{"type":"pr","ref":"#1"}]}` → MapResult 各字段正确，calls==1
  - 围栏：stub 回 ```` ```json\n{...}\n``` ```` → 解析成功
  - 重试：responses={garbage, valid} → calls==2 且成功；responses={garbage, garbage} → error.MapFailed，calls==2
  - 旧摘要注入：old_summary 非空 → `last_user_text` 中包含旧摘要子串
  - 截断：一条 6000 字符消息 + max_chars=2000 → `last_user_text` 含 `…[截断]…` 且长度显著小于 6000
  - 分块：3 条各 100 字符消息 + input_budget=120 → calls>=2（滚动摘要至少一次）
  - 脱敏集成：消息含 `sk-abc12345678` → `last_user_text` 不含该串、含 `[REDACTED]`
- [ ] **Step 2: 注册 + `zig build test`**
- [ ] **Step 3: fmt + commit** `feat(memory-digest): llm map stage for session summaries`

---

### Task 6: digest.zig — reduce（日报 + 时间线）

**Files:**
- Modify: `src/memory_digest/digest.zig`

**Interfaces:**
- Produces:
  - `pub const ProjectTimeline = struct { slug: []const u8, entry: store.TimelineEntry }`
  - `pub const ReduceResult = struct { projects: []const store.DailyProject, highlights: []const []const u8, timelines: []const ProjectTimeline }`
  - `pub fn reduceDay(arena: std.mem.Allocator, gpa: std.mem.Allocator, completer: llm.Completer, date: []const u8, sessions: []const store.DailySession) !ReduceResult`

实现要点：
1. 输入 = 会话摘要的紧凑 JSON 数组（project/title/summary/outcome，用 `std.json.Stringify.valueAlloc` 生成，别手拼）；> 50 条时按 project 分桶各自调用，再用各项目 summary 拼一次小调用合成 highlights。
2. Prompt（中文 const）：输出 JSON `{"projects":[{"slug":"…","summary":"…","session_refs":["…"]}],"highlights":["…"],"timeline":{"<slug>":{"summary":"…","events":[{"type":"progress|decision|problem|todo","text":"…","refs":["…"]}]}}}`。timeline map 解析：`std.json.parseFromSlice(std.json.Value,…)` 取 object 遍历（动态键），或让 LLM 输出 `"timeline":[{"slug":…,…}]` 数组——**选数组形式**，省 Value 遍历（prompt 里写清楚）。
3. 解析复用 `parseJsonObjectLenient` + 同款重试一次策略；失败 → `error.ReduceFailed`。
4. TimelineEntry.date = 传入 date；session_refs 取该 slug 下 sessions 的 session_id。

- [ ] **Step 1: 实现 + 打桩测试**：正常回包 → projects/highlights/timelines 正确；>50 会话（构造 60 条两项目）→ stub calls >= 3（两桶+highlights 合成）；解析失败重试；ReduceFailed 路径
- [ ] **Step 2: `zig build test`；fmt + commit** `feat(memory-digest): llm reduce stage for daily report and timelines`

---

### Task 7: run.zig 编排升级 + CLI 真实 LLM + 真机验证

**Files:**
- Modify: `src/memory_digest/run.zig`
- Modify: `src/memory_digest/scan_main.zig`

**Interfaces:**
- `run.Options` 新增：`completer: ?llm.Completer = null, model_label: []const u8 = "", max_chars_per_message: usize = 2000`
- `run.Summary` 新增：`sessions_summarized: usize = 0, sessions_failed: usize = 0`

流程（completer 非空时；null 保持 M1 原路径不变）：
1. collect 后、写 daily 前：`SummaryStore.loadFromPath(gpa, <state>/session_summaries.json)`。
2. 对每个 CollectedSession：`digest.summarizeSession(...)`（old_summary 取 store 里同 key 的 summary）。成功 → `advanceCursor` + `summaries.put(记录, date=该会话归属日)` + 该会话的 DailySession 条目带上 summary/topics/outcome/artifacts；失败 → `log.warn` + 计数 + **不推游标**、不进 daily。
3. map 全部结束后立刻 `summaries.saveToPath`（spec §13：map 结果先落盘）。
4. 每个活跃日：daily 条目合并写（现有 mergeDailyWithExisting 逻辑不动，`Daily.model = model_label`）→ `digest.reduceDay(该日全部 sessions 条目——含从磁盘读回合并后的)` → 填 `daily.projects/highlights` 重写 daily → 对每个 timeline 调 `store.upsertTimelineEntry` + 按 slug 对应会话的 project_path 调 `store.upsertProject`。reduce 失败 → 整次 runOnce 返回 `error.ReduceFailed`（游标已按会话推进+summaries 已存，重跑时 map 幂等增量——ponytail 注释：M3 用 runs.json 做按日补跑）。
5. 游标 saveToPath 移到 reduce 全部成功之后（保持"最后落盘"不变式）。

CLI（scan_main.zig）：
1. 堆分配 `const profiles = try gpa.alloc(profile_codec.AiProfile, 16); defer gpa.free(profiles);` + `profile_store.loadProfiles(gpa, profiles)`。
2. 命令行参数：`--profile <name>`（可选）、`--raw`（跳过 LLM，走 M1 路径）。`std.process.argsAlloc` 解析。
3. 有 profile 且非 --raw：`llm.pickProfile` → `configFromProfile`（arena）→ `var client = llm.Client{...}` → Options 带 `client.completer()` 与 `model_label = cfg.model`；找不到任何 profile → 打印提示走 raw。
4. 打印 summary 各计数。

- [ ] **Step 1: run.zig 实现 + 打桩集成测试**（前缀 `memory_digest_run:`）：
  - stub completer（map 回固定 JSON、reduce 回固定 JSON）+ claude fixture → daily 含 summary 字段与 projects/highlights；`projects/project/timeline.json` 存在且含 events；`state/session_summaries.json` 存在
  - 第二次 runOnce（无新消息）→ 零 LLM 调用（stub calls 不增）
  - map 失败 stub（对某会话回 garbage×2）：该会话不进 daily、游标未推进（第三次 runOnce 重新采到它）、其他会话正常
  - reduce 失败 stub：runOnce 返回 error.ReduceFailed，但 session_summaries.json 已写、cursors.json 未写
- [ ] **Step 2: scan_main.zig 实现；`zig build memory-digest -Dtarget=aarch64-macos` + `zig build test` 全绿**
- [ ] **Step 3: 真机验证（M2a 出口标准）**——运行 `./zig-out/bin/wispterm-memory-digest`（真实 LLM，默认第一个 profile）：
  - 打印 summarized/failed 计数；今天的 daily JSON 里 sessions[].summary 非空、projects/highlights 非空
  - `projects/phantty/timeline.json` 有今天的 entry 且 events 分类合理
  - 抽查摘要质量（是否命中今天真实做的事）；grep daily 无 `sk-`/`api_key` 泄漏
  - 把 CLI 输出与抽查结论写进报告
- [ ] **Step 4: fmt + commit** `feat(memory-digest): llm orchestration in run and real-llm cli`
- [ ] **Step 5: 收尾**——`zig build test-full -Dtarget=aarch64-macos` + `zig fmt --check build.zig src`，然后停下汇报（PR #518 顺势更新描述由控制器做）
