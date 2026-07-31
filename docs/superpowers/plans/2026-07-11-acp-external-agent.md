# ACP 外部 agent 会话实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** WispTerm 作为 ACP client,让外部 CLI agent(claude-code-acp / codex-acp)驱动 copilot 会话,含中途权限审批与真实终端 pane 执行;随后删除 cli_agent 工具。

**Architecture:** 三个 PR。PR1:`src/acp/`(schema.zig + client.zig,std-only 双向 JSON-RPC over stdio)。PR2:`ApiProtocol` 加 `.acp` 变体 + profile 加 `command` 字段 + `src/assistant/conversation/acp_turn.zig` 会话驱动(在 session.zig:2833 的 spawn 处分叉)。PR3:`terminal/*` client 能力(复用 ToolHost/终端租约,新增 exit-status 与 kill 两个 host 原语)+ 删除 cli_agent。

**Tech Stack:** Zig 0.15.2;`std.json.parseFromSlice` / `std.json.Stringify.valueAlloc`(0.15.2 的 alloc API);`std.process.Child`;现有 ToolHost / terminal_lease / session 回写函数。

## Global Constraints

- Zig 0.15.2(build.zig.zon minimum_zig_version);JSON 序列化一律 `std.json.Stringify.valueAlloc(allocator, value, .{})`。
- 推送前必跑 `zig fmt build.zig src`(CI "Zig fast tests / Linux" 先查 fmt,本地 test 不含)。
- 快速测试:`zig build test`;新 std-only 文件必须在 `src/test_fast.zig` 注册 `_ = @import(...)`。macOS 全量:`zig build test-full -Dtarget=aarch64-macos`(裸 test-full 只编译不跑)。
- session.zig 现 9623 行,file_size_guard 上限 10000:**ACP 逻辑放新文件 acp_turn.zig,session.zig 只加分叉与字段(≤40 行)**。
- session.zig 禁新增顶层 `g_*` 全局(global_state_guard 上限 20 已满)、禁直写 `g_force_rebuild`/`g_cells_valid`(side_effect_guard 上限 0)。
- `src/assistant/conversation/` 下文件禁 `@import` AppWindow.zig(assistant_agent_boundary_guard)——对 AppWindow 的调用一律走 ToolHost 函数指针。
- 跨线程写 UI 状态只能通过 session.mutex 保护的 `ai_chat.*` 回写函数(与 request.zig 同一契约);reader 线程不直接碰渲染全局。
- git 提交信息结尾:`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`。

## 与设计稿的两处刻意简化(已在 spec 基础上收敛)

1. **provider 类型不新增 AiField**:`ApiProtocol` 加 `.acp` 变体(profile 已有 protocol 字段、表单已有 ←/→ 切换、编解码/透传全部现成)。profile 只新增一个 `command` 字段(ordinal 12)。
2. **"预置模板"实现为预填**:表单协议切到 acp 且 command 为空时,预填 `npx @zed-industries/claude-code-acp`;codex 命令写入 docs。不做自动种子(避免删了又回来的幽灵 profile)。
3. terminal 卡片"点击聚焦"不做:`spawnTab` 新建的 tab 本身就是可见的活动页,卡片文本给出 tab 标题即可。

---

# PR 1:ACP 协议核心(分支 feat/acp-external-agent)

## Task 1: `src/acp/schema.zig` — 协议类型与解析

**Files:**
- Create: `src/acp/schema.zig`
- Modify: `src/test_fast.zig`(在 ~309 行 agent_tools 块附近加 `_ = @import("acp/schema.zig");`)

**Interfaces (Produces):**
```zig
pub const PROTOCOL_VERSION: i64 = 1;
pub const StopReason = enum { end_turn, max_tokens, refusal, cancelled, other };
pub const ToolCallInfo = struct { id: []u8, title: []u8, kind: []u8, status: []u8, content_text: []u8, terminal_id: []u8,
    pub fn deinit(self: *ToolCallInfo, allocator: std.mem.Allocator) void };
pub const SessionUpdate = union(enum) { agent_message_chunk: []u8, agent_thought_chunk: []u8,
    tool_call: ToolCallInfo, tool_call_update: ToolCallInfo, plan: []u8, ignored,
    pub fn deinit(self: *SessionUpdate, allocator: std.mem.Allocator) void };
pub fn parseSessionUpdate(allocator: std.mem.Allocator, params: std.json.Value) ?SessionUpdate;
pub const PermissionOption = struct { id: []u8, name: []u8, kind: []u8 };
pub const PermissionRequest = struct { title: []u8, options: []PermissionOption, pub fn deinit(...) };
pub fn parsePermissionRequest(allocator: std.mem.Allocator, params: std.json.Value) !PermissionRequest;
pub fn encodePermissionSelected(allocator: std.mem.Allocator, option_id: []const u8) ![]u8;
pub fn encodePermissionCancelled(allocator: std.mem.Allocator) ![]u8;
pub fn encodeInitializeParams(allocator: std.mem.Allocator, terminal_capability: bool) ![]u8;
pub fn parseInitializeProtocolVersion(result: std.json.Value) ?i64;
pub fn encodeNewSessionParams(allocator: std.mem.Allocator, cwd: []const u8) ![]u8;
pub fn parseNewSessionId(allocator: std.mem.Allocator, result: std.json.Value) ?[]u8;
pub fn encodePromptParams(allocator: std.mem.Allocator, session_id: []const u8, text: []const u8) ![]u8;
pub fn parseStopReason(result: std.json.Value) StopReason;
pub fn encodeCancelParams(allocator: std.mem.Allocator, session_id: []const u8) ![]u8;
```

- [ ] **Step 1.1: 写失败测试(文件尾部,与实现同文件)**

先建文件骨架 + 测试。核心测试(照 cli_agent 测试风格):

```zig
const std = @import("std");

// ...(实现将填在这里)...

fn parseValue(a: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, json, .{});
}

test "parseSessionUpdate extracts agent_message_chunk text" {
    const a = std.testing.allocator;
    var p = try parseValue(a,
        \\{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}
    );
    defer p.deinit();
    var u = parseSessionUpdate(a, p.value) orelse return error.TestExpectedUpdate;
    defer u.deinit(a);
    try std.testing.expectEqualStrings("hello", u.agent_message_chunk);
}

test "parseSessionUpdate extracts tool_call with terminal content" {
    const a = std.testing.allocator;
    var p = try parseValue(a,
        \\{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"run tests","kind":"execute","status":"pending","content":[{"type":"terminal","terminalId":"term-abc"}]}}
    );
    defer p.deinit();
    var u = parseSessionUpdate(a, p.value) orelse return error.TestExpectedUpdate;
    defer u.deinit(a);
    try std.testing.expectEqualStrings("run tests", u.tool_call.title);
    try std.testing.expectEqualStrings("term-abc", u.tool_call.terminal_id);
    try std.testing.expectEqualStrings("execute", u.tool_call.kind);
}

test "parseSessionUpdate tolerates unknown variants and malformed params" {
    const a = std.testing.allocator;
    var p = try parseValue(a,
        \\{"sessionId":"s1","update":{"sessionUpdate":"future_thing","x":1}}
    );
    defer p.deinit();
    var u = parseSessionUpdate(a, p.value) orelse return error.TestExpectedUpdate;
    defer u.deinit(a);
    try std.testing.expect(u == .ignored);
    var bad = try parseValue(a, "{\"nope\":true}");
    defer bad.deinit();
    try std.testing.expect(parseSessionUpdate(a, bad.value) == null);
}

test "parsePermissionRequest and outcome encoding round-trip" {
    const a = std.testing.allocator;
    var p = try parseValue(a,
        \\{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"Edit main.zig"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}
    );
    defer p.deinit();
    var req = try parsePermissionRequest(a, p.value);
    defer req.deinit(a);
    try std.testing.expectEqualStrings("Edit main.zig", req.title);
    try std.testing.expectEqual(@as(usize, 2), req.options.len);
    try std.testing.expectEqualStrings("allow_once", req.options[0].kind);
    const sel = try encodePermissionSelected(a, "allow");
    defer a.free(sel);
    try std.testing.expectEqualStrings("{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow\"}}", sel);
}

test "initialize/new/prompt param encoding and result parsing" {
    const a = std.testing.allocator;
    const init_params = try encodeInitializeParams(a, true);
    defer a.free(init_params);
    try std.testing.expect(std.mem.indexOf(u8, init_params, "\"protocolVersion\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_params, "\"terminal\":true") != null);
    const prompt = try encodePromptParams(a, "s1", "do it");
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"sessionId\":\"s1\"") != null);
    var stop = try parseValue(a, "{\"stopReason\":\"end_turn\"}");
    defer stop.deinit();
    try std.testing.expectEqual(StopReason.end_turn, parseStopReason(stop.value));
    var sid = try parseValue(a, "{\"sessionId\":\"abc\"}");
    defer sid.deinit();
    const id = parseNewSessionId(a, sid.value) orelse return error.TestExpectedId;
    defer a.free(id);
    try std.testing.expectEqualStrings("abc", id);
}
```

- [ ] **Step 1.2: 跑测试确认失败**

Run: `zig test src/acp/schema.zig`
Expected: 编译错误(函数未定义)。

- [ ] **Step 1.3: 实现**

要点(完整骨架;`objectString`/`objectValue` 小助手照 cli_agent.zig:58 的写法):

```zig
fn objectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn objectValue(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

/// content 块或块数组 → 拼接其中所有 text;同时提取 terminal 内容块的 terminalId。
fn flattenContent(allocator: std.mem.Allocator, content: std.json.Value, terminal_id_out: *?[]u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const items: []const std.json.Value = switch (content) {
        .array => |arr| arr.items,
        .object => &[_]std.json.Value{content},
        else => &.{},
    };
    for (items) |item| {
        const ty = objectString(item, "type") orelse continue;
        if (std.mem.eql(u8, ty, "text")) {
            if (objectString(item, "text")) |t| try out.appendSlice(allocator, t);
        } else if (std.mem.eql(u8, ty, "content")) {
            // ToolCallContent 包一层 {type:"content",content:{type:"text",...}}
            if (objectValue(item, "content")) |inner| {
                if (objectString(inner, "text")) |t| try out.appendSlice(allocator, t);
            }
        } else if (std.mem.eql(u8, ty, "terminal")) {
            if (objectString(item, "terminalId")) |tid| {
                if (terminal_id_out.* == null) terminal_id_out.* = try allocator.dupe(u8, tid);
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn parseSessionUpdate(allocator: std.mem.Allocator, params: std.json.Value) ?SessionUpdate {
    const update = objectValue(params, "update") orelse return null;
    const variant = objectString(update, "sessionUpdate") orelse return null;
    if (std.mem.eql(u8, variant, "agent_message_chunk") or std.mem.eql(u8, variant, "agent_thought_chunk")) {
        const content = objectValue(update, "content") orelse return .ignored;
        var tid: ?[]u8 = null;
        const text = flattenContent(allocator, content, &tid) catch return null;
        if (tid) |t| allocator.free(t);
        if (std.mem.eql(u8, variant, "agent_message_chunk")) return .{ .agent_message_chunk = text };
        return .{ .agent_thought_chunk = text };
    }
    if (std.mem.eql(u8, variant, "tool_call") or std.mem.eql(u8, variant, "tool_call_update")) {
        var info = parseToolCall(allocator, update) catch return null;
        if (std.mem.eql(u8, variant, "tool_call")) return .{ .tool_call = info };
        return .{ .tool_call_update = info };
    }
    if (std.mem.eql(u8, variant, "plan")) {
        return .{ .plan = renderPlan(allocator, update) catch return null };
    }
    return .ignored;
}
```

`parseToolCall`:逐字段 `objectString(update, "toolCallId"/"title"/"kind"/"status")`,缺省 dupe "";content 走 `flattenContent` 且把 terminal_id 收进 `info.terminal_id`(无则 "")。`renderPlan`:`entries` 数组每项 `content` 字符串,拼成 `"plan:\n- xxx\n- yyy"`。编码函数一律手拼 + 单值转义:字符串字段用 `std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = s }, .{})`(mcp_client.zig:221 模式)。`encodeInitializeParams` 输出:

```
{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":<bool>}}
```

`encodeNewSessionParams` 输出 `{"cwd":<escaped>,"mcpServers":[]}`。`encodePromptParams` 输出 `{"sessionId":<esc>,"prompt":[{"type":"text","text":<esc>}]}`。`parseStopReason`:string 匹配 end_turn/max_tokens/refusal/cancelled,其余 `.other`。

- [ ] **Step 1.4: 跑测试通过**

Run: `zig test src/acp/schema.zig`
Expected: All tests passed。

- [ ] **Step 1.5: 注册进快速套件并提交**

`src/test_fast.zig` 在 agent_tools 导入块附近(~309 行)加:
```zig
    _ = @import("acp/schema.zig");
```
Run: `zig build test` → PASS;`zig fmt build.zig src`。
```bash
git add src/acp/schema.zig src/test_fast.zig
git commit -m "feat(acp): protocol schema types and parsing"
```

## Task 2: `src/acp/client.zig` — 双向 JSON-RPC 连接

**Files:**
- Create: `src/acp/client.zig`
- Modify: `src/test_fast.zig`(加 `_ = @import("acp/client.zig");`)

**Interfaces:**
- Consumes: `schema.zig` 的 `parseSessionUpdate`/`SessionUpdate`。
- Produces:
```zig
pub const Handler = struct {
    ctx: *anyopaque,
    /// reader 线程上调用;update 归 callee 释放(用完 update.deinit)。
    onSessionUpdate: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, update: schema.SessionUpdate) void,
    /// 每个入站请求在独立线程上调用。返回 owned JSON(result)或 error.* → 回 JSON-RPC error。
    onRequest: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror![]u8,
};
pub const Connection = struct {
    pub fn spawn(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, handler: Handler) !*Connection;
    /// 阻塞直到响应或连接死亡;返回 owned result JSON 文本。
    pub fn beginCall(self: *Connection, method: []const u8, params_json: []const u8) !*PendingCall;
    pub fn notify(self: *Connection, method: []const u8, params_json: []const u8) !void;
    pub fn alive(self: *Connection) bool;
    pub fn stderrTail(self: *Connection, allocator: std.mem.Allocator) ![]u8;
    pub fn deinit(self: *Connection) void; // kill child + join 全部线程
};
pub const PendingCall = struct {
    /// 等待至多 timeout_ms;完成返回 true。可反复调用(轮询期夹缓存取消检查)。
    pub fn wait(self: *PendingCall, timeout_ms: u64) bool;
    /// 完成后取走结果;错误响应/连接死亡 → error.AcpCallFailed。
    pub fn take(self: *PendingCall, allocator: std.mem.Allocator) ![]u8;
    pub fn release(self: *PendingCall) void;
};
pub fn splitCommand(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8; // 空白切分,不经 shell
```

**内部结构(实现要点,全部单文件):**

- `spawn`:`std.process.Child.init(argv)`,stdin/stdout/stderr 全 `.Pipe`,`create_no_window = true`;spawn 后必须 `waitForSpawn()`,失败时手动关 stdout/stderr 并 reap(**照抄 cli_agent.zig:221-239 的注释与清理顺序,这是 posix_spawn 假成功的已知坑**)。
- 出站写:`write_mutex` 保护,消息 = `{"jsonrpc":"2.0","id":N,"method":...,"params":...}` + `\n`(id 自增,`next_id` 在 mutex 内),照 mcp_client.zig:212 `encodeRequest` 拼法;`notify` 无 id;`respond(id, result_json)` / `respondError(id, code, msg)`。
- pending 表:`std.AutoHashMapUnmanaged(i64, *PendingCall)` + `state_mutex` + 每个 PendingCall 自带 `cond: std.Thread.Condition`、`done/result_json/is_error` 字段与引用计数(caller + reader 各一票,`release` 减到 0 释放)。
- reader 线程:自带 4096 缓冲逐行分帧(cli_agent LineStream 的 push/flushPartial 逻辑内联进来,不再共享)。每行 `std.json.parseFromSlice(Value)`:
  - 有 `id` 且有 `result`/`error` → response:从 pending 表取走,dupe 结果文本(result 用 `Stringify.valueAlloc` 重序列化子值),`done=true` + signal。
  - 有 `method` 且有 `id` → 入站请求:dupe 整行,`std.Thread.spawn(inboundThreadMain, .{self, owned_line})`,线程句柄 append 进 `inbound_threads`(mutex 保护)。
  - 有 `method` 无 `id` → notification:`method == "session/update"` 时 `schema.parseSessionUpdate` → `handler.onSessionUpdate`(reader 线程内联;回写函数自带 session.mutex,安全)。其余忽略。
  - 解析失败的行忽略(容错)。EOF/读错:置 `dead=true`,遍历 pending 全部置错并 signal。
- `inboundThreadMain`:重新 parse envelope → `handler.onRequest(ctx, allocator, method, params)`;成功 → `respond`,错误 → `respondError(id, -32603, @errorName(err))`;`conn.closing` 为真时直接返回不写。
  - // ponytail: 每请求一线程,权限/wait_for_exit 等阻塞请求互不卡 reader;规模=单 agent 会话,无需线程池。
- stderr 线程:读进有界尾部缓冲(2 KiB,照 cli_agent `appendTail` 的折半压缩),`stderrTail` 复制出来供错误消息用。
- `deinit`:`closing=true` → kill child(`child.kill()`)→ join reader/stderr/全部 inbound 线程 → 清 pending → 释放。

- [ ] **Step 2.1: 写失败测试**

fake agent 用 `/bin/sh` 逐行应答(bidirectional!),核心三条:

```zig
test "call round-trip against a scripted agent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // 脚本:读一行,凡含 "initialize" 回 initialize response;含 "session/new" 回 sessionId。
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"initialize"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}';;
        \\    *'"session/new"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}';;
        \\  esac
        \\done
    ;
    var recorder = TestHandler{};
    const conn = try Connection.spawn(a, &.{ "/bin/sh", "-c", script }, null, recorder.handler());
    defer conn.deinit();
    const p1 = try conn.beginCall("initialize", "{\"protocolVersion\":1}");
    defer p1.release();
    try std.testing.expect(p1.wait(5000));
    const r1 = try p1.take(a);
    defer a.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "protocolVersion") != null);
}

test "inbound request is dispatched and response written back" {
    // 脚本:读到 prompt 请求(id 1)后 → 发入站请求(id 100)→ 读回我们的响应 →
    // 发 session/update 通知 → 发 prompt 的最终 response。
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"session/prompt"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":100,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"Edit"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}'
        \\      IFS= read -r reply
        \\      case "$reply" in *'"id":100'*'"selected"'*) : ;; *) exit 9 ;; esac
        \\      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ok"}}}}'
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"stopReason":"end_turn"}}'
        \\      ;;
        \\  esac
        \\done
    ;
    // TestHandler.onRequest 记录 method 并返回 encodePermissionSelected("allow");
    // 断言:onSessionUpdate 收到 agent_message_chunk "ok"(条件变量等它到达,避免竞态);
    //       prompt 的 take() 文本含 "end_turn";handler 记录到 "session/request_permission"。
}

test "agent death fails pending calls with stderr tail available" {
    // 脚本:printf 一行垃圾到 stderr 后 exit 3。断言 beginCall 的 take() 报 error.AcpCallFailed,
    // stderrTail 含该行。
}
```

(第 2、3 条测试按第 1 条的完整风格写全——TestHandler 是记录 method/update 的小结构体,handler() 返回填好函数指针的 Handler。)

- [ ] **Step 2.2: 跑测试确认失败**

Run: `zig test src/acp/client.zig` → 编译失败(类型未定义)。

- [ ] **Step 2.3: 实现(按上面内部结构要点)**

- [ ] **Step 2.4: 跑测试通过**

Run: `zig test src/acp/client.zig` → PASS;再 `zig build test`(含 schema + guards)→ PASS。

- [ ] **Step 2.5: 提交并发 PR 1**

```bash
zig fmt build.zig src
git add src/acp/client.zig src/test_fast.zig
git commit -m "feat(acp): bidirectional JSON-RPC stdio client"
git push -u origin feat/acp-external-agent
gh pr create --title "feat: ACP protocol core (schema + stdio client)" --body "..."
```

---

# PR 2:会话接线(分支 feat/acp-session-wiring,基于 PR1)

## Task 3: `ApiProtocol.acp` 变体 + profile `command` 字段

**Files:**
- Modify: `src/assistant/conversation/protocol.zig:23-60`(enum)
- Modify: `src/renderer/overlays/profile_codec.zig:13,27-40`(AI_FIELD_COUNT 12→13,`command = 12`)
- Modify: `src/assistant/profile/store.zig:6`(header 注释加 command)
- Modify: `src/assistant/conversation/request.zig` 及其它 `switch` 穷举点(编译器指路)
- Test: 同文件测试块

**Interfaces (Produces):** `ApiProtocol.acp`;`AiField.command`;`ApiProtocol.parse("acp") == .acp`,`.acp.name() == "acp"`。

- [ ] **Step 3.1: 失败测试**

`protocol.zig` 测试区加:
```zig
test "ApiProtocol parses and cycles acp" {
    try std.testing.expectEqual(ApiProtocol.acp, ApiProtocol.parse("acp"));
    try std.testing.expectEqualStrings("acp", ApiProtocol.acp.name());
    try std.testing.expectEqual(ApiProtocol.acp, ApiProtocol.anthropic.cycle(true));
    try std.testing.expectEqual(ApiProtocol.chat_completions, ApiProtocol.acp.cycle(true));
}
```
`profile_codec.zig` 测试区加(仿既有 11→12 字段兼容测试 295-308 行):
```zig
test "legacy 12-field ai profile line decodes with empty command" {
    // 用 testEncodeProfileLine 生成 12 字段行,截掉最后一个 \t 字段后 decode,
    // 断言 aiProfileField(&p, .command).len == 0 且其余字段完好。
}
```

- [ ] **Step 3.2: 确认失败** — `zig build test`,期望上述测试编译/断言失败。

- [ ] **Step 3.3: 实现**

`ApiProtocol`:enum 加 `acp`;`parse` 加 `if (std.ascii.eqlIgnoreCase(trimmed, "acp")) return .acp;`;`name` 加 `.acp => "acp"`;`cycle` 环变为 chat_completions→responses→anthropic→acp→chat_completions(反向对称)。`AiField` 尾部加 `command = 12`,`AI_FIELD_COUNT = 13`(decode 不需默认值,空即可;首 5 字段下限逻辑不变)。store.zig header 字符串补 `, command`。

然后 `zig build test`:编译器会指出所有对 `ApiProtocol` 的穷举 `switch`(集中在 request.zig 的 endpoint/请求体构造)。**每个 HTTP 路径的 switch 补 `.acp` 臂,行为与 `.chat_completions` 相同**(acp 轮次在 submit 就分叉,永远不会走到 HTTP;选无害缺省而非 unreachable,防御配置错乱)。

- [ ] **Step 3.4: 通过** — `zig build test` PASS。

- [ ] **Step 3.5: 提交** — `git commit -m "feat(acp): ApiProtocol.acp variant and profile command field"`

## Task 4: 表单 UI(command 行 + acp 预填)

**Files:**
- Modify: `src/i18n.zig`(结构体 ~168-184、en ~430-446、zh ~686-702 三处加 `sl_ai_command`,如 en "Command", zh "命令")
- Modify: `src/renderer/overlays.zig`:
  - 渲染行:5911-5923 的字段行序列里加 `renderAiSessionField(layout, window_height, @intFromEnum(AiField.command), i18n.s().sl_ai_command, null, false)`(自由文本,不掩码)
  - 宽度循环 5223-5233 加一行
  - `clearAiForm`(4472-4485)与 `openAiConfigForSession`(4227-4243)补 command 默认(空 / 会话现值)
  - `cycleAiFormProtocol`(4543):切换后若协议为 acp 且 command 字段为空 → 预填 `npx @zed-industries/claude-code-acp`
- 注意:`AI_FORM_ROW_COUNT = AI_FIELD_COUNT + 3` 与保存循环 `for (0..AI_FIELD_COUNT)` 自适应,无需改。

**Interfaces:** Consumes Task 3 的 `AiField.command`。

- [ ] **Step 4.1: 实现上述五处**(纯 UI 接线,测试靠既有 overlays 套件 + 手工;`zig build test` 保证编译与 codec 测试)
- [ ] **Step 4.2: `zig build test` PASS + `zig build test-macos-ui`(overlay 键盘行为回归)**
- [ ] **Step 4.3: 提交** — `git commit -m "feat(acp): profile form command field with acp prefill"`

## Task 5: Session 携带 command + spawn 路径透传

**Files:**
- Modify: `src/assistant/conversation/session.zig`(Session struct 附近 ~1053):加字段与 setter
- Modify: `src/renderer/overlays.zig` 三个读取点:`spawnAiProfileWithAgentOverride`(4742)、`applyProfileToSession`(4766)、`makeCopilotSessionForDefaultProfile`(4824)
- Modify: `src/AppWindow.zig:4273` `spawnAiChatTab` 与 `src/appwindow/tab.zig:558`(+1 参数 `command: []const u8`)

**Interfaces (Produces):**
```zig
// session.zig
acp_command: []u8 = &.{},              // Session 字段,owned
pub fn setAcpCommand(self: *Session, command: []const u8) void; // dupe 替换,deinit 释放
// ChatRequest 字段(session.zig:201 区):
acp_command: []u8 = &.{},              // buildRequestLocked 里 dupe,ChatRequest.deinit 释放
```

- [ ] **Step 5.1: 失败测试**(session 测试区,test-full 套件;仿 session.zig:6331 附近 applyProviderProfile 测试的 session 构造法):
```zig
test "setAcpCommand stores an owned copy and survives source mutation" {
    // 构造测试 session(照同文件既有测试);
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..4], "abcd");
    session.setAcpCommand(buf[0..4]);
    buf[0] = 'X'; // 源被改不影响已存值 → 证明 dupe
    try std.testing.expectEqualStrings("abcd", session.acp_command);
    session.setAcpCommand("second"); // 二次 set 释放旧值(testing.allocator 抓泄漏)
    try std.testing.expectEqualStrings("second", session.acp_command);
}
```
- [ ] **Step 5.2: 实现**:Session 字段 + setter + deinit 释放;`buildRequestLocked`(4289)内 `request.acp_command = try self.allocator.dupe(u8, self.acp_command)`;三个 overlays 读取点各加 `aiProfileField(&profile, .command)` 并调 `session.setAcpCommand(...)`(spawn 路径经 `spawnAiChatTab` 新参数落到 tab.zig 里 Session 创建后 set)。
- [ ] **Step 5.3: `zig build test` + `zig build test-full -Dtarget=aarch64-macos` PASS**
- [ ] **Step 5.4: 提交** — `git commit -m "feat(acp): thread acp command from profile into Session and ChatRequest"`

## Task 6: `acp_turn.zig` 会话驱动 + submit 分叉

**Files:**
- Create: `src/assistant/conversation/acp_turn.zig`
- Modify: `src/assistant/conversation/session.zig`:
  - :2833 spawn 分叉(见下)
  - Session 字段 `acp_state: ?*acp_turn.AcpState = null`;deinit(~1388,`releaseOwner` 旁)加 `if (self.acp_state) |st| { st.deinit(); self.acp_state = null; }`
  - `appendAssistantStreamDelta`(5523)改 `pub`
- Modify: `src/test_fast.zig`(acp_turn 若含 std-only 纯函数测试则注册;session 耦合测试走 test-full)

**Interfaces:**
- Consumes: `acp/client.zig` Connection/Handler/PendingCall;`acp/schema.zig`;session 回写函数 `beginAssistantStream`(5441)/`appendAssistantStreamDelta`(5523)/`finishAssistantStream`(5549)/`appendProgressMessage`(5373)/`failAssistantStream`(5590)/`finishStoppedRequest`(4898)/`requestCancelled`(4890)/`maybeAutoTitle`(5185)/`askUser`(2380);`ChatRequest.acp_command`。
- Produces:
```zig
pub const AcpState = struct { conn: *acp_client.Connection, acp_session_id: []u8,
    stream_idx: ?usize, state_mutex: std.Thread.Mutex, ...,
    pub fn deinit(self: *AcpState) void };
pub fn acpTurnThreadMain(request: *ai_chat.ChatRequest) void;
```

**submit 分叉(session.zig:2833 处)**:
```zig
const thread = if (request.protocol == .acp)
    std.Thread.spawn(.{}, acp_turn.acpTurnThreadMain, .{request})
else
    std.Thread.spawn(.{}, ai_chat_request.requestThreadMain, .{request});
const spawned = thread catch { ...既有错误路径不变... };
```

**acpTurnThreadMain 完整逻辑:**

```zig
pub fn acpTurnThreadMain(request: *ai_chat.ChatRequest) void {
    defer request.deinit();
    const session = request.session;
    defer ai_chat.maybeAutoTitle(session);

    const state = ensureState(session, request) catch |err| {
        failTurn(session, "ACP agent 启动失败", err, null);
        return;
    };
    // 取最后一条 user 消息为 prompt(request.messages 尾部向前找 role==.user)。
    const prompt_text = lastUserText(request) orelse {
        ai_chat.failAssistantStream(session, null, "No user message to send.");
        return;
    };
    const params = schema.encodePromptParams(request.allocator, state.acp_session_id, prompt_text) catch return;
    defer request.allocator.free(params);
    const pending = state.conn.beginCall("session/prompt", params) catch |err| {
        failTurn(session, "ACP prompt 发送失败", err, state);
        return;
    };
    defer pending.release();

    var cancel_sent = false;
    while (!pending.wait(100)) {
        if (ai_chat.requestCancelled(request) and !cancel_sent) {
            cancel_sent = true;
            const cp = schema.encodeCancelParams(request.allocator, state.acp_session_id) catch continue;
            defer request.allocator.free(cp);
            state.conn.notify("session/cancel", cp) catch {};
        }
    }
    const result_json = pending.take(request.allocator) catch |err| {
        // 连接死亡:附 stderr 尾部,置空 state 让下一条消息重启进程
        failTurn(session, "ACP agent 异常退出(下一条消息将重启并重置上下文)", err, state);
        teardownState(session);
        return;
    };
    defer request.allocator.free(result_json);
    if (cancel_sent) { ai_chat.finishStoppedRequest(session); return; }
    // 正文已流式进 transcript;收尾必须走标准路径以清 request_inflight/状态行:
    // 若本轮开过流 → finishAssistantStream(session, idx, started_ms, first_token_ms, null);
    // 一条消息都没流出(纯工具轮)→ appendAssistantResult(session, 空 content 的 ApiResult, started_ms)。
    finalizeTurn(session, state, request.started_ms);
}
```

(`failTurn` = `failAssistantStream(session, state?.stream_idx, 格式化文本+stderrTail)`;`ensureState` 首次:`splitCommand(request.acp_command)` → `Connection.spawn`(handler ctx = session)→ `initialize`(校验 protocolVersion==1)→ `session/new`(cwd = `std.fs.cwd().realpathAlloc` 解析 `request` 携带的 working_dir,copilot 语义与现有一致)→ 存 `session.acp_state`;全过程持 state 构建锁防双击并发。)

**Handler 回调(reader/inbound 线程 → session.mutex 回写):**

```zig
fn onSessionUpdate(ctx: *anyopaque, allocator: std.mem.Allocator, update: schema.SessionUpdate) void {
    const session: *ai_chat.Session = @ptrCast(@alignCast(ctx));
    var u = update; defer u.deinit(allocator);
    switch (u) {
        .agent_message_chunk => |text| appendDelta(session, text, null),
        .agent_thought_chunk => |text| appendDelta(session, null, text),
        .tool_call => |info| { closeStream(session); progressCard(session, info); },
        .tool_call_update => |info| if (isFailed(info.status)) progressFail(session, info),
        .plan => |text| ai_chat.appendProgressMessage(session, text) catch {},
        .ignored => {},
    }
}
```
`appendDelta`:state_mutex 下若 `stream_idx == null` 先 `beginAssistantStream`;然后 `appendAssistantStreamDelta(session, idx, content, reasoning)`。`progressCard`:`"[{kind}] {title}"`,有 `terminal_id` 时改为 `"[terminal] {title} → 已在终端标签运行"`。

```zig
fn onRequest(ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror![]u8 {
    const session: *ai_chat.Session = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, method, "session/request_permission")) {
        var req = try schema.parsePermissionRequest(allocator, params);
        defer req.deinit(allocator);
        var options: [8]ai_chat.QuestionOption = undefined; // ACP 选项实测 ≤4
        const n = @min(req.options.len, options.len);
        for (req.options[0..n], 0..) |opt, i| options[i] = .{ .label = opt.name, .description = opt.kind };
        const answer = session.askUser(req.title, options[0..n]);
        return switch (answer) {
            .option_index => |i| schema.encodePermissionSelected(allocator, req.options[@min(i, n - 1)].id),
            .custom, .cancelled => schema.encodePermissionCancelled(allocator),
        };
    }
    return error.MethodNotFound; // terminal/* 在 PR3 接入
}
```

- [ ] **Step 6.1: 失败测试**:acp_turn 纯函数(`lastUserText`、update→卡片文本映射)fast 单测;端到端 fake-agent 会话测试进 test-full(构造真 Session + `/bin/sh` 脚本 agent,断言 transcript 出现流式文本与进度卡、审批往返走 resolveQuestionOption)。
- [ ] **Step 6.2: 确认失败 → 实现 → `zig build test` + `zig build test-full -Dtarget=aarch64-macos` PASS**
- [ ] **Step 6.3: 手工冒烟**:`npm i -g @zed-industries/claude-code-acp`(或 npx),建 acp profile,copilot 发一条消息,看到流式回复与审批弹窗。
- [ ] **Step 6.4: 提交并发 PR 2**

```bash
zig fmt build.zig src
git add -A && git commit -m "feat(acp): external agent session mode (messages, tool cards, permissions, cancel)"
gh pr create --title "feat: ACP external agent session mode" --body "..."
```

---

# PR 3:terminal 能力 + 删除 cli_agent(分支 feat/acp-terminal,基于 PR2)

## Task 7: 两个新 host 原语(exit status + kill child)

**Files:**
- Modify: `src/assistant/conversation/types.zig:275-291`(ToolHost 加两个 optional 字段 + SurfaceExitInfo 类型)
- Modify: `src/Command.zig`(加 `kill`)、`src/platform/pty_command_unsupported.zig:83`、`src/platform/pty_command_windows.zig:544`(各自 impl)
- Modify: `src/appwindow/surface_snapshots.zig`(两个实现,镜像 156 行 `agentSurfaceSnapshot` 的 `surface_registry.acquire` 守卫)
- Modify: `src/AppWindow.zig:6182-6198` `installAgentToolHost`(接线)

**Interfaces (Produces):**
```zig
// types.zig
pub const SurfaceExitInfo = struct { exited: bool, exit_code: ?u32 };
// ToolHost 新字段(optional,缺省 null,测试 host 不必实现):
surfaceExitStatus: ?*const fn (*anyopaque, []const u8, *anyopaque) anyerror!SurfaceExitInfo = null,
killSurfaceChild: ?*const fn (*anyopaque, []const u8, *anyopaque) anyerror!void = null,
// Command.zig
pub fn kill(self: *Command) void; // posix: std.posix.kill(pid, SIG.HUP) catch {}; windows: TerminateProcess(process, 1)
```

- [ ] **Step 7.1: 失败测试**:`pty_command_unsupported.zig` 加 kill 单测(spawn `sleep 30` 的 Command → kill → wait(true) 非 null);surface_snapshots 的实现走 test-full 既有 harness。
- [ ] **Step 7.2: 实现**:
```zig
// surface_snapshots.zig,镜像 agentSurfaceSnapshot:
pub fn agentSurfaceExitStatus(ctx: *anyopaque, surface_id: []const u8, surface_ptr: *anyopaque) anyerror!ai_chat.SurfaceExitInfo {
    _ = ctx;
    if (!surface_registry.acquire(surface_ptr, surface_id)) return error.SurfaceClosed;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(surface_ptr));
    return switch (surface.currentIoState()) {
        .exited => |info| .{ .exited = true, .exit_code = if (info.status) |st| switch (st) { .exited => |c| c, .unknown => null } else null },
        .failed => .{ .exited = true, .exit_code = null },
        else => .{ .exited = false, .exit_code = null },
    };
}
pub fn agentKillSurfaceChild(...) anyerror!void { // 同守卫;surface.command.kill();
}
```
- [ ] **Step 7.3: `zig build test` + test-full PASS,提交** — `git commit -m "feat(host): surface exit status and kill-child primitives for agent terminals"`

## Task 8: acp_turn 接 `terminal/*` + initialize 声明 terminal 能力

**Files:**
- Modify: `src/assistant/conversation/acp_turn.zig`(onRequest 加 5 个方法;AcpState 加 terminals 表)
- Modify: `src/acp/schema.zig`(加 `parseTerminalCreate` / `encodeTerminalCreated` / `encodeTerminalOutput` / `encodeWaitForExit` 及测试)
- Modify: initialize 调用处 `terminal_capability` 传 true

**Interfaces:**
- Consumes: Task 7 的 `surfaceExitStatus`/`killSurfaceChild`;`ToolHost.spawnTab`(types.zig:280,签名 `(ctx, allocator, kind, command)`,**无 cwd/env 参数**)、`surfaceSnapshot`(:278);`terminal_lease.active().claim/access`(src/agent/terminal_lease.zig:101/131);`session.agentInstanceId()`。
- Produces(schema 侧):
```zig
pub const TerminalCreateParams = struct { command: []u8, joined_args: []u8, cwd: ?[]u8, output_byte_limit: u64, pub fn deinit(...) };
pub fn parseTerminalCreate(allocator, params: std.json.Value) !TerminalCreateParams;
pub fn encodeTerminalCreated(allocator, terminal_id: []const u8) ![]u8;      // {"terminalId":"..."}
pub fn encodeTerminalOutput(allocator, output: []const u8, truncated: bool, exited: bool, exit_code: ?u32) ![]u8; // schema 保持 std-only,不引 types.zig
pub fn encodeWaitForExit(allocator, exit_code: ?u32) ![]u8;                  // {"exitStatus":{"exitCode":N,"signal":null}}
```

**命令组装(cwd/env 的 ponytail 落法):**spawnTab 的命令串走 `parseArgv` + `execvp`,**不经 shell、不可指定 cwd/env**。因此:
- argv:每个 arg 单引号包裹(内部 `'` 转义为 `'\''`)后空格拼接——parseArgv 支持引号;
- cwd 存在时:整体包成 `/bin/sh -c 'cd <cwd> && exec <quoted-cmd>'`(Windows:`cmd.exe /c "cd /d <cwd> && <cmd>"`,记住 `/c` 不是 `/k` 的教训);
- env:MVP 忽略,收到时在进度卡注记一行 "env ignored"。
- // ponytail: 若真实 agent 大量依赖 env,再扩 spawnTab 链(AgentTabNewRequest 加字段)。

**onRequest 分发新增:**
- `terminal/create`:parse → 组命令串 → `host.spawnTab(host.ctx, allocator, "command", cmd)` → `terminal_lease.active().claim(session.agentInstanceId(), surface.id)` → AcpState.terminals 记 `{id, ptr, output_byte_limit}` → `encodeTerminalCreated(surface.id)`。
- `terminal/output`:查表(仅本会话创建的 terminalId,未知 → error)→ `host.surfaceSnapshot(...)` → 按 limit 截尾 → 若 `surfaceExitStatus` 显示已退出附 exitStatus。
- `terminal/wait_for_exit`:循环 `surfaceExitStatus` 每 150ms,`conn.closing`/会话取消时提前返回 error;退出后 `encodeWaitForExit`。(运行在每请求独立线程上,不卡 reader——PR1 已保证。)
- `terminal/kill`:`host.killSurfaceChild(...)`,pane 保留。
- `terminal/release`:从表中移除;租约随会话结束 `releaseOwner` 统一释放,pane 留给用户。
  - // ponytail: 不做单 surface 租约释放;agent 会话结束前该 pane 对其它 agent 只读,可接受。

- [ ] **Step 8.1: schema 新函数失败测试 → 实现 → `zig test src/acp/schema.zig` PASS**
- [ ] **Step 8.2: acp_turn terminal 分发实现;test-full 加 fake-host 测试(spawnTab/surfaceSnapshot 用桩,断言 create→output→wait→kill 全链路 JSON)**
- [ ] **Step 8.3: `zig build test` + test-full PASS,提交** — `git commit -m "feat(acp): terminal capability backed by real WispTerm panes"`

## Task 9: 真机 E2E 验收(双后端)

- [ ] **Step 9.1: 重建 app**:`zig build macos-app -Dtarget=aarch64-macos`(注意装的是 zig-out,不是 /Applications——验证跑 zig-out 里那份)。
- [ ] **Step 9.2: claude-code-acp 全链路**:acp profile(预填命令)→ copilot 对话 → 看到流式文本+思考;让它改一个文件 → 权限弹窗 allow/reject 都走一遍;让它跑 `zig build test` → 新 pane 可见输出、卡片注记;中途 stop → 状态 "Stopped"、agent 停止。
- [ ] **Step 9.3: codex-acp 同链路**(命令按适配器实际发布形态填,如 `codex-acp` 或 `npx @zed-industries/codex-acp`;联调后把最终命令写进 docs/ai-agent.md 与表单预填注释)。
- [ ] **Step 9.4: 崩溃恢复**:会话中 `kill -9` agent 进程 → 卡片报错;再发一条消息 → 自动重启、上下文重置提示。
- [ ] **Step 9.5: 修复途中发现的问题,逐项提交。**

## Task 10: 删除 cli_agent

**Files(全部删除点,来源 `grep -rn cli_agent src/`):**
- Delete: `src/agent_tools/cli_agent.zig`
- Modify: `src/agent_tools/mod.zig`:39(import)、325-334(分发)、1414-1445(测试)
- Modify: `src/assistant/conversation/protocol.zig`:727(保留名)、815(schema 注册)、2240-2251(测试改为断言 cli_agent **不在**工具集且名字不再保留)
- Modify: `src/tools/first_party.zig`:59(目录项)
- Modify: `src/test_fast.zig`:309(import)

- [ ] **Step 10.1: 按上表删除;protocol.zig 原测试改写:**
```zig
test "toolset no longer includes cli_agent" {
    // 复用原测试的 out 构造,断言 indexOf "\"name\":\"cli_agent\"" == null
    // 且 builtinToolNameReserved("cli_agent") == false。
}
```
- [ ] **Step 10.2: `zig build test` + `zig build test-full -Dtarget=aarch64-macos` PASS(无残留引用)**
- [ ] **Step 10.3: 提交并发 PR 3**

```bash
zig fmt build.zig src
git add -A && git commit -m "feat(acp): remove cli_agent tool superseded by ACP external agent sessions"
gh pr create --title "feat: ACP terminal capability + remove cli_agent" --body "..."
```

---

## 合并纪律(stacked PR 两次踩坑的教训)

每个 PR 合并后**立即**:`git merge-base --is-ancestor <feature-sha> origin/main` 验证真进了 main;子分支 rebase 到 main 再继续,绝不 merge 进已死的 base 分支。
