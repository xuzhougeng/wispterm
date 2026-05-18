# Remote Auto AI Agent Creation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plain Weixin text and `/ai <content>` automatically open a default Agent tab when the selected Remote session has no AI Chat surface.

**Architecture:** The relay asks Phantty to open an Agent tab with a request id, waits for an explicit desktop result, then waits for the next layout containing an AI Chat surface before sending the original text. Phantty handles the request on the UI thread using the same default-profile agent path as the command center `New Agent` action. This is Remote-only work, so the Ghostty comparison requirement does not apply.

**Tech Stack:** TypeScript Node relay with `node:test`, Zig desktop client with WinHTTP websockets and Win32 UI-thread messages, Vite Remote docs.

---

## File Structure

- Modify `remote/src/server/session.ts`: add relay message fields, pending AI Agent open result tracking, `requestAiAgentOpen()`, and result handling from Phantty.
- Modify `remote/test/server/session.test.ts`: test the control message, result resolution, timeout, and invalid result handling.
- Modify `remote/src/server/bridge/weixin/agent.ts`: make AI routing auto-open an Agent tab when no AI Chat surface exists.
- Modify `remote/test/server/weixin_agent.test.ts`: test existing-AI behavior, auto-open success, no-profile, timeout, offline, `/ai`, and `/term`.
- Modify `src/remote_client.zig`: recognize `open-ai-agent`, dispatch an opener callback, and send `open-ai-agent-result`.
- Modify `src/AppWindow.zig`: register the Remote opener callback, post a UI-thread request, call the default Agent opener, and reply to the relay.
- Modify `src/renderer/overlays.zig`: expose a Remote-safe default Agent opener that returns `opened`, `no_profile`, or `failed`.
- Modify `remote/README.md`: document the auto-open behavior and the new relay messages.

## Task 1: Relay Session Control Message

**Files:**
- Modify: `remote/src/server/session.ts`
- Test: `remote/test/server/session.test.ts`

- [ ] **Step 1: Write failing session tests**

Add these tests to `remote/test/server/session.test.ts` after the existing peer-status test:

```ts
test("RemoteSession requests AI Agent open and resolves the matching result", async () => {
  const session = new RemoteSession("alpha");
  const phantty = new FakeSocket();
  session.attachPhantty(phantty as never);

  const pending = session.requestAiAgentOpen("req-1", 50);
  assert.deepEqual(JSON.parse(phantty.sent.at(-1) ?? "{}"), {
    type: "open-ai-agent",
    requestId: "req-1",
  });

  phantty.emit("message", Buffer.from(JSON.stringify({
    type: "open-ai-agent-result",
    requestId: "req-1",
    status: "opened",
  })));

  assert.equal(await pending, "opened");
});

test("RemoteSession ignores AI Agent open results with unknown statuses", async () => {
  const session = new RemoteSession("alpha");
  const phantty = new FakeSocket();
  session.attachPhantty(phantty as never);

  const pending = session.requestAiAgentOpen("req-invalid", 10);
  phantty.emit("message", Buffer.from(JSON.stringify({
    type: "open-ai-agent-result",
    requestId: "req-invalid",
    status: "bogus",
  })));

  assert.equal(await pending, "timeout");
});

test("RemoteSession AI Agent open request times out without a matching result", async () => {
  const session = new RemoteSession("alpha");
  const phantty = new FakeSocket();
  session.attachPhantty(phantty as never);

  assert.equal(await session.requestAiAgentOpen("req-timeout", 5), "timeout");
});

test("RemoteSession AI Agent open request reports offline when Phantty is disconnected", async () => {
  const session = new RemoteSession("alpha");

  assert.equal(await session.requestAiAgentOpen("req-offline", 5), "offline");
});
```

- [ ] **Step 2: Run the failing session tests**

Run:

```bash
node --import tsx --test remote/test/server/session.test.ts
```

Expected: the new tests fail because `requestAiAgentOpen()` does not exist.

- [ ] **Step 3: Implement the session control protocol**

In `remote/src/server/session.ts`, extend `RelayMessage`:

```ts
export type RelayMessage = {
  type?: string;
  at?: number;
  data?: string;
  encoding?: string;
  surfaceId?: string;
  message?: string;
  requestId?: string;
  status?: string;
  phanttyConnected?: boolean;
  activeTab?: number;
  tabs?: Array<{
    index: number;
    focusedSurfaceId?: string;
    surfaces: Array<{
      id: string;
      title?: string;
      focused?: boolean;
      kind?: "terminal" | "ai_chat";
      readOnly?: boolean;
      snapshot?: string;
    }>;
  }>;
};
```

Add these exports near `RemoteSurfaceRef`:

```ts
export type AiAgentOpenStatus = "opened" | "no-profile" | "failed";
export type AiAgentOpenResult = AiAgentOpenStatus | "offline" | "timeout";

const AI_AGENT_OPEN_STATUSES = new Set<AiAgentOpenStatus>(["opened", "no-profile", "failed"]);
```

Add a pending-result map to `RemoteSession`:

```ts
private pendingAiAgentOpenRequests = new Map<string, (status: AiAgentOpenStatus) => void>();
```

Add this public method and its helper methods inside `RemoteSession`:

```ts
async requestAiAgentOpen(requestId: string, timeoutMs = 2000): Promise<AiAgentOpenResult> {
  if (!isSocketOpen(this.phantty)) return "offline";

  const wait = this.registerAiAgentOpenWait(requestId, timeoutMs);
  if (!safeSend(this.phantty, { type: "open-ai-agent", requestId })) {
    wait.cancel();
    return "offline";
  }

  return await wait.promise;
}

private registerAiAgentOpenWait(
  requestId: string,
  timeoutMs: number,
): { promise: Promise<AiAgentOpenStatus | "timeout">; cancel: () => void } {
  let settled = false;
  let timer: ReturnType<typeof setTimeout>;
  let resolvePromise: (status: AiAgentOpenStatus | "timeout") => void = () => {};

  const cleanup = () => {
    clearTimeout(timer);
    this.pendingAiAgentOpenRequests.delete(requestId);
  };

  const promise = new Promise<AiAgentOpenStatus | "timeout">((resolve) => {
    resolvePromise = resolve;
    timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve("timeout");
    }, Math.max(0, timeoutMs));

    this.pendingAiAgentOpenRequests.set(requestId, (status) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(status);
    });
  });

  return {
    promise,
    cancel: () => {
      if (settled) return;
      settled = true;
      cleanup();
      resolvePromise("timeout");
    },
  };
}

private handleAiAgentOpenResult(message: RelayMessage): void {
  if (typeof message.requestId !== "string") return;
  if (!isAiAgentOpenStatus(message.status)) return;

  const resolve = this.pendingAiAgentOpenRequests.get(message.requestId);
  if (!resolve) return;
  resolve(message.status);
}
```

Add this helper near `isWritableTerminalSurface()`:

```ts
function isAiAgentOpenStatus(value: unknown): value is AiAgentOpenStatus {
  return typeof value === "string" && AI_AGENT_OPEN_STATUSES.has(value as AiAgentOpenStatus);
}
```

In `attachPhantty()`'s `"message"` handler, handle the result before layout/output routing:

```ts
if (message.type === "open-ai-agent-result") {
  this.handleAiAgentOpenResult(message);
  return;
}
```

- [ ] **Step 4: Verify the session tests pass**

Run:

```bash
node --import tsx --test remote/test/server/session.test.ts
```

Expected: all `session.test.ts` tests pass.

- [ ] **Step 5: Commit the relay session protocol**

Run:

```bash
git add remote/src/server/session.ts remote/test/server/session.test.ts
git commit -m "feat: add remote ai agent open control"
```

## Task 2: Weixin Auto-Open Routing

**Files:**
- Modify: `remote/src/server/bridge/weixin/agent.ts`
- Test: `remote/test/server/weixin_agent.test.ts`

- [ ] **Step 1: Write failing Weixin routing tests**

In `remote/test/server/weixin_agent.test.ts`, replace the simple `sessionWithLayout()` fake websocket with a reusable fake socket:

```ts
class FakeSocket {
  readyState = 1;
  sent: string[] = [];
  listeners = new Map<string, Array<(raw?: unknown) => void>>();

  send(payload: string): void {
    this.sent.push(payload);
    sent.push(JSON.parse(payload));
  }

  close(): void {}
  ping(): void {}

  on(event: string, fn: (raw?: unknown) => void): void {
    const list = this.listeners.get(event) ?? [];
    list.push(fn);
    this.listeners.set(event, list);
  }

  emit(event: string, raw?: unknown): void {
    for (const fn of this.listeners.get(event) ?? []) fn(raw);
  }
}
```

Update `sessionWithLayout()` so it uses `attachPhantty()`:

```ts
function sessionWithLayout(): RemoteSession {
  const session = new RemoteSession("alpha-secret");
  session.applyLayout({
    type: "layout",
    activeTab: 0,
    tabs: [{
      index: 0,
      focusedSurfaceId: "term1",
      surfaces: [
        { id: "term1", title: "PowerShell", kind: "terminal", focused: true, readOnly: false },
        { id: "aichat0000000000", title: "AI", kind: "ai_chat", snapshot: "AI\nready" },
      ],
    }],
  });
  session.attachPhantty(new FakeSocket() as never);
  return session;
}
```

Add these helpers:

```ts
function sessionWithoutAiChat(): RemoteSession {
  const session = new RemoteSession("alpha-secret");
  session.applyLayout({
    type: "layout",
    activeTab: 0,
    tabs: [{
      index: 0,
      focusedSurfaceId: "term1",
      surfaces: [
        { id: "term1", title: "PowerShell", kind: "terminal", focused: true, readOnly: false },
      ],
    }],
  });
  session.attachPhantty(new FakeSocket() as never);
  return session;
}

function phanttySocket(session: RemoteSession): FakeSocket {
  return session.phantty as unknown as FakeSocket;
}

async function waitForSentType(type: string): Promise<Record<string, unknown>> {
  const deadline = Date.now() + 100;
  while (Date.now() < deadline) {
    const message = sent.find((entry) => (entry as { type?: string }).type === type);
    if (message) return message as Record<string, unknown>;
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  throw new Error(`message not sent: ${type}`);
}
```

Add these tests after `"plain text routes to ai chat with carriage return"`:

```ts
test("plain text auto-opens AI Agent when no AI Chat surface exists", async () => {
  sent = [];
  const session = sessionWithoutAiChat();
  const pending = routeWeixinText({
    text: "summarize current work",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session }],
    aiAgentOpenTimeoutMs: 100,
  });

  const open = await waitForSentType("open-ai-agent");
  assert.equal(typeof open.requestId, "string");

  phanttySocket(session).emit("message", Buffer.from(JSON.stringify({
    type: "open-ai-agent-result",
    requestId: open.requestId,
    status: "opened",
  })));
  session.applyLayout({
    type: "layout",
    activeTab: 1,
    tabs: [{
      index: 1,
      focusedSurfaceId: "aichat0000000001",
      surfaces: [
        { id: "aichat0000000001", title: "AI", kind: "ai_chat", snapshot: "AI\nready" },
      ],
    }],
  });

  const reply = await pending;
  assert.equal(reply.text, "信息已收到，开始处理。");
  assert.equal(reply.ai?.baselineTranscript, "AI\nready");
  assert.equal((sent.at(-1) as { surfaceId: string }).surfaceId, "aichat0000000001");
  assert.equal((sent.at(-1) as { data: string }).data, "73756d6d6172697a652063757272656e7420776f726b0d");
});

test("/ai auto-opens AI Agent with the explicit prompt content", async () => {
  sent = [];
  const session = sessionWithoutAiChat();
  const pending = routeWeixinText({
    text: "/ai check status",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session }],
    aiAgentOpenTimeoutMs: 100,
  });

  const open = await waitForSentType("open-ai-agent");
  phanttySocket(session).emit("message", Buffer.from(JSON.stringify({
    type: "open-ai-agent-result",
    requestId: open.requestId,
    status: "opened",
  })));
  session.applyLayout({
    type: "layout",
    activeTab: 1,
    tabs: [{
      index: 1,
      focusedSurfaceId: "aichat0000000001",
      surfaces: [
        { id: "aichat0000000001", title: "AI", kind: "ai_chat", snapshot: "" },
      ],
    }],
  });

  const reply = await pending;
  assert.equal(reply.text, "信息已收到，开始处理。");
  assert.equal((sent.at(-1) as { data: string }).data, "636865636b207374617475730d");
});

test("AI auto-open reports missing profile from Phantty", async () => {
  sent = [];
  const session = sessionWithoutAiChat();
  const pending = routeWeixinText({
    text: "hello",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session }],
    aiAgentOpenTimeoutMs: 100,
  });

  const open = await waitForSentType("open-ai-agent");
  phanttySocket(session).emit("message", Buffer.from(JSON.stringify({
    type: "open-ai-agent-result",
    requestId: open.requestId,
    status: "no-profile",
  })));

  const reply = await pending;
  assert.equal(reply.text, "Phantty 尚未配置 AI Chat profile。请先在桌面端创建 AI Chat profile。");
});

test("AI auto-open reports timeout when no AI Chat layout arrives", async () => {
  sent = [];
  const session = sessionWithoutAiChat();
  const pending = routeWeixinText({
    text: "hello",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session }],
    aiAgentOpenTimeoutMs: 10,
  });

  const open = await waitForSentType("open-ai-agent");
  phanttySocket(session).emit("message", Buffer.from(JSON.stringify({
    type: "open-ai-agent-result",
    requestId: open.requestId,
    status: "opened",
  })));

  const reply = await pending;
  assert.equal(reply.text, "已请求 Phantty 打开 AI Agent，但未等到 AI Chat tab。请检查桌面端配置后重试。");
});

test("/term does not request AI Agent open", async () => {
  sent = [];
  const reply = await routeWeixinText({
    text: "/term pwd",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session: sessionWithoutAiChat() }],
    aiAgentOpenTimeoutMs: 10,
  });

  assert.match(reply.text, /已发送到终端/);
  assert.equal(sent.some((entry) => (entry as { type?: string }).type === "open-ai-agent"), false);
});
```

- [ ] **Step 2: Run the failing Weixin tests**

Run:

```bash
node --import tsx --test remote/test/server/weixin_agent.test.ts
```

Expected: the new tests fail because `aiAgentOpenTimeoutMs` and auto-open routing do not exist.

- [ ] **Step 3: Implement auto-open routing**

In `remote/src/server/bridge/weixin/agent.ts`, extend `WeixinRouteInput`:

```ts
export type WeixinRouteInput = {
  text: string;
  settings: WeixinSettings;
  sessions: RoutedSession[];
  saveTargetSession?: (key: string) => Promise<void>;
  aiAgentOpenTimeoutMs?: number;
};
```

Add constants and request id generation near the types:

```ts
const AI_AGENT_OPEN_TIMEOUT_MS = 2000;
let nextAiAgentOpenSeq = 0;

function nextAiAgentOpenRequestId(): string {
  nextAiAgentOpenSeq = (nextAiAgentOpenSeq + 1) % Number.MAX_SAFE_INTEGER;
  return `weixin-ai-${Date.now().toString(36)}-${nextAiAgentOpenSeq}`;
}
```

Update the call site in `routeWeixinText()`:

```ts
if (cmd === "/ai") return sendAi(target.session, arg, input.aiAgentOpenTimeoutMs);
return sendAi(target.session, text, input.aiAgentOpenTimeoutMs);
```

Replace `sendAi()` with these helpers:

```ts
async function sendAi(
  session: RemoteSession,
  text: string,
  timeoutMs = AI_AGENT_OPEN_TIMEOUT_MS,
): Promise<WeixinRouteReply> {
  const existing = session.findAiChatSurface();
  if (existing) return sendAiToSurface(session, existing, text);

  const status = await session.requestAiAgentOpen(nextAiAgentOpenRequestId(), timeoutMs);
  if (status === "offline") return { text: "Phantty 当前离线，无法打开 AI Agent。" };
  if (status === "no-profile") return { text: "Phantty 尚未配置 AI Chat profile。请先在桌面端创建 AI Chat profile。" };
  if (status === "failed") return { text: "Phantty 无法打开 AI Agent。请检查桌面端配置后重试。" };
  if (status === "timeout") return { text: "已请求 Phantty 打开 AI Agent，但未等到 AI Chat tab。请检查桌面端配置后重试。" };

  const opened = await waitForAiChatSurface(session, timeoutMs);
  if (!opened) return { text: "已请求 Phantty 打开 AI Agent，但未等到 AI Chat tab。请检查桌面端配置后重试。" };
  return sendAiToSurface(session, opened, text);
}

function sendAiToSurface(session: RemoteSession, ai: { id: string; title: string }, text: string): WeixinRouteReply {
  const baselineTranscript = session.latestAiChatTranscript();
  if (!session.sendInput(ai.id, `${text}\r`)) return { text: "Phantty 当前离线，无法发送给 AI Agent。" };
  return {
    text: "信息已收到，开始处理。",
    ai: {
      session,
      baselineTranscript,
    },
  };
}

async function waitForAiChatSurface(session: RemoteSession, timeoutMs: number): Promise<{ id: string; title: string } | null> {
  const existing = session.findAiChatSurface();
  if (existing) return existing;

  return await new Promise((resolve) => {
    let settled = false;
    const cleanup = () => {
      settled = true;
      clearTimeout(timer);
      unsubscribe();
    };
    const timer = setTimeout(() => {
      if (settled) return;
      cleanup();
      resolve(null);
    }, Math.max(0, timeoutMs));
    const unsubscribe = session.onLayout(() => {
      const ai = session.findAiChatSurface();
      if (!ai || settled) return;
      cleanup();
      resolve(ai);
    });
  });
}
```

- [ ] **Step 4: Verify the Weixin tests pass**

Run:

```bash
node --import tsx --test remote/test/server/weixin_agent.test.ts
```

Expected: all `weixin_agent.test.ts` tests pass.

- [ ] **Step 5: Commit Weixin auto-open routing**

Run:

```bash
git add remote/src/server/bridge/weixin/agent.ts remote/test/server/weixin_agent.test.ts
git commit -m "feat: auto-open ai agent for weixin prompts"
```

## Task 3: Desktop Remote Client Protocol

**Files:**
- Modify: `src/remote_client.zig`

- [ ] **Step 1: Write failing Zig protocol tests**

Add these tests near the existing `remote_client.zig` tests:

```zig
const TestAiAgentOpenCtx = struct {
    called: bool = false,
    request_id_buf: [128]u8 = undefined,
    request_id_len: usize = 0,

    fn onOpen(ctx: *anyopaque, request_id: []const u8) void {
        const self: *TestAiAgentOpenCtx = @ptrCast(@alignCast(ctx));
        self.called = true;
        self.request_id_len = @min(request_id.len, self.request_id_buf.len);
        @memcpy(self.request_id_buf[0..self.request_id_len], request_id[0..self.request_id_len]);
    }
};

fn initTestClient(allocator: std.mem.Allocator) !Client {
    return .{
        .allocator = allocator,
        .endpoint = .{
            .secure = false,
            .host = try allocator.dupe(u8, "127.0.0.1"),
            .port = 80,
            .object_name = try allocator.dupe(u8, "/ws/phantty?session=test"),
        },
        .device_name = null,
        .session_key = try allocator.dupe(u8, "test"),
    };
}

test "open ai agent message dispatches request id" {
    const allocator = std.testing.allocator;
    var client = try initTestClient(allocator);
    defer client.deinit();

    var ctx = TestAiAgentOpenCtx{};
    client.registerAiAgentOpener(&ctx, TestAiAgentOpenCtx.onOpen);

    handleIncomingMessage(&client, "{\"type\":\"open-ai-agent\",\"requestId\":\"remote-ai-1\"}");

    try std.testing.expect(ctx.called);
    try std.testing.expectEqualStrings("remote-ai-1", ctx.request_id_buf[0..ctx.request_id_len]);
}

test "open ai agent result message escapes request id" {
    const allocator = std.testing.allocator;
    const message = try buildAiAgentOpenResultMessage(allocator, "remote-\"one", .no_profile);
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "{\"type\":\"open-ai-agent-result\",\"requestId\":\"remote-\\\"one\",\"status\":\"no-profile\"}",
        message,
    );
}
```

- [ ] **Step 2: Run the failing Zig protocol tests**

Run:

```powershell
zig build test
```

Expected: the new tests fail because `registerAiAgentOpener()` and `buildAiAgentOpenResultMessage()` do not exist.

- [ ] **Step 3: Implement Remote client open/result protocol**

In `src/remote_client.zig`, add these public types near `SurfaceWriteFn`:

```zig
pub const AiAgentOpenStatus = enum {
    opened,
    no_profile,
    failed,
};

pub const AiAgentOpenFn = *const fn (ctx: *anyopaque, request_id: []const u8) void;
```

Add these fields to `Client`:

```zig
ai_agent_open_ctx: ?*anyopaque = null,
ai_agent_open_fn: ?AiAgentOpenFn = null,
```

Add these methods to `Client`:

```zig
pub fn registerAiAgentOpener(
    self: *Client,
    ctx: *anyopaque,
    open_fn: AiAgentOpenFn,
) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.ai_agent_open_ctx = ctx;
    self.ai_agent_open_fn = open_fn;
}

pub fn sendAiAgentOpenResult(
    self: *Client,
    request_id: []const u8,
    status: AiAgentOpenStatus,
) void {
    if (request_id.len == 0 or self.stop_requested.load(.acquire)) return;
    const message = buildAiAgentOpenResultMessage(self.allocator, request_id, status) catch return;
    self.enqueueOwnedMessage(message);
}

fn dispatchAiAgentOpen(self: *Client, request_id: []const u8) void {
    var ctx: ?*anyopaque = null;
    var open_fn: ?AiAgentOpenFn = null;

    self.mutex.lock();
    ctx = self.ai_agent_open_ctx;
    open_fn = self.ai_agent_open_fn;
    self.mutex.unlock();

    if (ctx) |target_ctx| {
        if (open_fn) |target_fn| target_fn(target_ctx, request_id);
    }
}
```

Add these helpers near `buildOutputMessage()`:

```zig
fn buildAiAgentOpenResultMessage(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    status: AiAgentOpenStatus,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"type\":\"open-ai-agent-result\",\"requestId\":\"");
    try appendJsonString(&out, allocator, request_id);
    try out.appendSlice(allocator, "\",\"status\":\"");
    try out.appendSlice(allocator, aiAgentOpenStatusJson(status));
    try out.appendSlice(allocator, "\"}");
    return out.toOwnedSlice(allocator);
}

fn aiAgentOpenStatusJson(status: AiAgentOpenStatus) []const u8 {
    return switch (status) {
        .opened => "opened",
        .no_profile => "no-profile",
        .failed => "failed",
    };
}
```

Replace `handleIncomingMessage()` with:

```zig
fn handleIncomingMessage(client: *Client, message: []const u8) void {
    if (isJsonMessageType(message, "input-bytes")) {
        const surface_id = extractJsonString(message, "surfaceId") orelse return;
        const hex_data = extractJsonString(message, "data") orelse return;

        const decoded = decodeHexAlloc(client.allocator, hex_data) catch return;
        defer client.allocator.free(decoded);
        client.dispatchInput(surface_id, decoded);
        return;
    }

    if (isJsonMessageType(message, "open-ai-agent")) {
        const request_id = extractJsonString(message, "requestId") orelse return;
        client.dispatchAiAgentOpen(request_id);
        return;
    }
}
```

- [ ] **Step 4: Verify Zig protocol tests pass**

Run:

```powershell
zig build test
```

Expected: all Zig unit tests pass.

- [ ] **Step 5: Commit desktop protocol support**

Run:

```bash
git add src/remote_client.zig
git commit -m "feat: handle remote ai agent open requests"
```

## Task 4: AppWindow UI Thread Agent Creation

**Files:**
- Modify: `src/AppWindow.zig`
- Modify: `src/renderer/overlays.zig`

- [ ] **Step 1: Add a failing manual assertion through compilation**

Add a temporary call in `src/AppWindow.zig` inside `runMainLoop()` after `installAgentToolHost(self);`:

```zig
installRemoteControlHandlers(self);
```

Run:

```powershell
zig build test
```

Expected: compilation fails because `installRemoteControlHandlers()` does not exist. Keep this call and implement it in the next step.

- [ ] **Step 2: Implement the Remote-safe default Agent opener**

In `src/renderer/overlays.zig`, add this public enum near the AI profile globals:

```zig
pub const RemoteAgentOpenResult = enum {
    opened,
    no_profile,
    failed,
};
```

Replace `openDefaultAgentSessionFromCommandCenter()` and refactor `connectAiProfileWithAgentOverride()` as follows:

```zig
fn openDefaultAgentSessionFromCommandCenter() void {
    loadAiProfiles();
    switch (command_center_state.resolveNewAgentLaunch(g_ai_profile_count != 0)) {
        .open_form => openAiFormNewWithMode(.session_setup),
        .connect_default_profile_as_agent => _ = spawnAiProfileWithAgentOverride(0, "true"),
    }
}

pub fn openDefaultAgentSessionForRemote() RemoteAgentOpenResult {
    loadAiProfiles();
    if (g_ai_profile_count == 0) return .no_profile;
    return if (spawnAiProfileWithAgentOverride(0, "true")) .opened else .failed;
}

fn connectAiProfileWithAgentOverride(idx: usize, agent_override: ?[]const u8) void {
    _ = spawnAiProfileWithAgentOverride(idx, agent_override);
}

fn spawnAiProfileWithAgentOverride(idx: usize, agent_override: ?[]const u8) bool {
    if (idx >= g_ai_profile_count) return false;
    const profile = &g_ai_profiles[idx];
    const name = aiProfileField(profile, .name);
    const base_url = aiProfileField(profile, .base_url);
    const api_key = aiProfileField(profile, .api_key);
    const model = aiProfileField(profile, .model);
    const system_prompt = aiProfileField(profile, .system_prompt);
    const thinking = aiProfileField(profile, .thinking);
    const reasoning_effort = aiProfileField(profile, .reasoning_effort);
    const stream_val = aiProfileField(profile, .stream);
    const agent_val = agent_override orelse aiProfileField(profile, .agent);
    if (base_url.len == 0 or model.len == 0) return false;
    if (!isHttpUrlish(base_url)) return false;

    sessionLauncherClose();
    return AppWindow.spawnAiChatTab(name, base_url, api_key, model, system_prompt, thinking, reasoning_effort, stream_val, agent_val);
}
```

- [ ] **Step 3: Implement AppWindow request structs and message ids**

In `src/AppWindow.zig`, add a new Win32 message constant:

```zig
const WM_PHANTTY_REMOTE_OPEN_AI_AGENT = win32_backend.WM_APP + 0x55;
```

Add this request struct after `RemoteAiInputRequest`:

```zig
const RemoteAiAgentOpenRequest = struct {
    client: *remote.Client,
    request_id: []u8,
};
```

- [ ] **Step 4: Implement the Remote opener callback**

In `src/AppWindow.zig`, add these functions near `remoteAiWrite()`:

```zig
fn remoteAiAgentOpen(ctx: *anyopaque, request_id: []const u8) void {
    const window: *AppWindow = @ptrCast(@alignCast(ctx));
    const client = window.app.remote_client orelse return;

    const request = std.heap.page_allocator.create(RemoteAiAgentOpenRequest) catch {
        client.sendAiAgentOpenResult(request_id, .failed);
        return;
    };
    request.* = .{
        .client = client,
        .request_id = std.heap.page_allocator.dupe(u8, request_id) catch {
            std.heap.page_allocator.destroy(request);
            client.sendAiAgentOpenResult(request_id, .failed);
            return;
        },
    };

    const hwnd = window.getHwnd() orelse {
        std.heap.page_allocator.free(request.request_id);
        std.heap.page_allocator.destroy(request);
        client.sendAiAgentOpenResult(request_id, .failed);
        return;
    };

    const ok = win32_backend.PostMessageW(
        hwnd,
        WM_PHANTTY_REMOTE_OPEN_AI_AGENT,
        0,
        @bitCast(@as(isize, @intCast(@intFromPtr(request)))),
    ) != 0;
    if (!ok) {
        std.heap.page_allocator.free(request.request_id);
        std.heap.page_allocator.destroy(request);
        client.sendAiAgentOpenResult(request_id, .failed);
    }
}

fn handleRemoteAiAgentOpenRequest(request: *RemoteAiAgentOpenRequest) void {
    defer {
        std.heap.page_allocator.free(request.request_id);
        std.heap.page_allocator.destroy(request);
    }

    const status: remote.AiAgentOpenStatus = switch (overlays.openDefaultAgentSessionForRemote()) {
        .opened => .opened,
        .no_profile => .no_profile,
        .failed => .failed,
    };
    request.client.sendAiAgentOpenResult(request.request_id, status);

    if (status == .opened) {
        g_remote_layout_last_ms = 0;
        if (g_allocator) |alloc| syncRemoteLayout(alloc);
    }
}
```

- [ ] **Step 5: Register the callback and handle the UI message**

In `src/AppWindow.zig`, add:

```zig
fn installRemoteControlHandlers(self: *AppWindow) void {
    if (self.app.remote_client) |client| {
        client.registerAiAgentOpener(self, remoteAiAgentOpen);
    }
}
```

Keep the call added in Step 1:

```zig
installAgentToolHost(self);
installRemoteControlHandlers(self);
```

In `onWin32Message()`, add:

```zig
WM_PHANTTY_REMOTE_OPEN_AI_AGENT => {
    const request: *RemoteAiAgentOpenRequest = @ptrFromInt(@as(usize, @bitCast(lParam)));
    handleRemoteAiAgentOpenRequest(request);
    return 1;
},
```

- [ ] **Step 6: Verify desktop compilation**

Run:

```powershell
zig build test
zig build
```

Expected: unit tests pass, then the debug build succeeds.

- [ ] **Step 7: Commit AppWindow integration**

Run:

```bash
git add src/AppWindow.zig src/renderer/overlays.zig
git commit -m "feat: open default agent from remote control"
```

## Task 5: Documentation And Full Verification

**Files:**
- Modify: `remote/README.md`

- [ ] **Step 1: Update Remote README behavior text**

In `remote/README.md`, replace:

```md
working; the server replies `pong` without touching AI Chat. Plain Weixin text
is routed to the selected Remote session's AI Chat surface. The server confirms
receipt immediately, checks the AI Chat snapshot at 10, 30, 60, and 120 seconds
for progress, and also listens for later AI Chat snapshot updates. Tool activity
returns a still-processing reply; a completed AI answer returns the latest
assistant message. Direct terminal input requires
`/term <command>` or `/keys <text>`.
```

with:

```md
working; the server replies `pong` without touching AI Chat. Plain Weixin text
is routed to the selected Remote session's AI Chat surface. If that session has
no AI Chat surface, the relay asks Phantty to open a default Agent tab first;
Phantty uses the desktop `New Agent` default profile path and reports a setup
message if no AI profile exists. The server confirms receipt immediately,
checks the AI Chat snapshot at 10, 30, 60, and 120 seconds for progress, and
also listens for later AI Chat snapshot updates. Tool activity returns a
still-processing reply; a completed AI answer returns the latest assistant
message. Direct terminal input requires `/term <command>` or `/keys <text>`.
```

After the browser input JSON example, add:

````md
The relay can also ask Phantty to create an Agent tab when Weixin input has no
AI Chat target:

```json
{ "type": "open-ai-agent", "requestId": "weixin-ai-1" }
```

Phantty replies with the matching request id and a status of `opened`,
`no-profile`, or `failed`:

```json
{ "type": "open-ai-agent-result", "requestId": "weixin-ai-1", "status": "opened" }
```
````

- [ ] **Step 2: Run Remote verification**

Run:

```bash
npm --prefix remote run test:server
npm --prefix remote run typecheck
```

Expected: server tests pass and TypeScript typecheck passes.

- [ ] **Step 3: Run Zig verification**

Run on Windows with Zig 0.15.2:

```powershell
zig build test
zig build
```

Expected: tests pass and `zig-out\bin\phantty.exe` exists.

- [ ] **Step 4: Run Windows path compatibility checks**

Because this plan only modifies existing files and creates this plan document, no new application source paths are introduced. If execution creates any new files beyond the planned files, run the AGENTS.md Windows path and symlink checks before finishing.

- [ ] **Step 5: Commit docs and verification notes**

Run:

```bash
git add remote/README.md
git commit -m "docs: describe remote ai agent auto-open"
```

## Self-Review

- Spec coverage: Task 1 adds request/result messaging. Task 2 implements existing-AI, auto-open, no-profile, failed, timeout, `/ai`, and `/term` behavior. Task 3 implements Phantty Remote protocol parsing and result serialization. Task 4 moves creation onto the UI thread and uses the default Agent profile path. Task 5 documents behavior and relay messages.
- Placeholder scan: no placeholder sections, no deferred implementation notes, and every code-changing step includes concrete code.
- Type consistency: result statuses are `opened`, `no-profile`, and `failed` in TypeScript JSON; Zig maps them with `AiAgentOpenStatus.opened`, `.no_profile`, and `.failed`.
