import test from "node:test";
import assert from "node:assert/strict";

import { routeWeixinText, maskSessionKey } from "../../src/server/bridge/weixin/agent.js";
import { RemoteSession } from "../../src/server/session.js";

class FakeSocket {
  readyState = 1;
  private listeners = new Map<string, Array<(raw?: unknown) => void>>();

  send(payload: string): void {
    sent.push(JSON.parse(payload));
  }

  on(event: string, fn: (raw?: unknown) => void): void {
    const list = this.listeners.get(event) ?? [];
    list.push(fn);
    this.listeners.set(event, list);
  }

  emit(event: string, raw?: unknown): void {
    if (event === "error" && !this.listeners.has(event)) {
      throw raw instanceof Error ? raw : new Error("Unhandled error event");
    }
    for (const fn of this.listeners.get(event) ?? []) fn(raw);
  }

  close(): void {
    this.readyState = 3;
    this.emit("close");
  }

  ping(): void {}
}

class ThrowingSocket extends FakeSocket {
  send(_payload: string): void {
    throw new Error("send failed");
  }
}

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

function offlineSessionWithLayout(): RemoteSession {
  const session = sessionWithLayout();
  session.phantty = null;
  return session;
}

function phanttySocket(session: RemoteSession): FakeSocket {
  assert.ok(session.phantty);
  return session.phantty as never as FakeSocket;
}

async function waitForSentType(type: string): Promise<Record<string, unknown>> {
  for (let i = 0; i < 50; i += 1) {
    const message = sent.find((candidate) => (candidate as { type?: string }).type === type);
    if (message) return message as Record<string, unknown>;
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  assert.fail(`timed out waiting for sent message type ${type}`);
}

let sent: unknown[] = [];

test("maskSessionKey keeps only a short prefix", () => {
  assert.equal(maskSessionKey("abcdef123456"), "abcd****");
});

test("plain text routes to ai chat with carriage return", async () => {
  sent = [];
  const reply = await routeWeixinText({
    text: "summarize current work",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session: sessionWithLayout() }],
  });
  assert.equal(reply.text, "信息已收到，开始处理。");
  assert.equal(reply.ai?.baselineTranscript, "AI\nready");
  assert.equal((sent[0] as { surfaceId: string }).surfaceId, "aichat0000000000");
  assert.equal((sent[0] as { data: string }).data, "73756d6d6172697a652063757272656e7420776f726b0d");
});

test("plain text auto-opens AI Agent when no AI Chat exists", async () => {
  sent = [];
  const session = sessionWithoutAiChat();
  const pending = routeWeixinText({
    text: "summarize current work",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session }],
    aiAgentOpenTimeoutMs: 100,
  });

  const openRequest = await waitForSentType("open-ai-agent");
  assert.match(openRequest.requestId as string, /^weixin-ai-/);
  phanttySocket(session).emit(
    "message",
    Buffer.from(JSON.stringify({
      type: "open-ai-agent-result",
      requestId: openRequest.requestId,
      status: "opened",
    })),
  );
  session.applyLayout({
    type: "layout",
    activeTab: 0,
    tabs: [{
      index: 0,
      focusedSurfaceId: "aichat-new",
      surfaces: [
        { id: "term1", title: "PowerShell", kind: "terminal", readOnly: false },
        { id: "aichat-new", title: "AI Agent", kind: "ai_chat", snapshot: "AI\nnew session" },
      ],
    }],
  });

  const reply = await pending;
  assert.equal(reply.text, "信息已收到，开始处理。");
  assert.equal(reply.ai?.baselineTranscript, "AI\nnew session");
  assert.equal((sent.at(-1) as { surfaceId: string }).surfaceId, "aichat-new");
  assert.equal((sent.at(-1) as { data: string }).data, "73756d6d6172697a652063757272656e7420776f726b0d");
});

test("/ai auto-opens AI Agent and sends only the command content", async () => {
  sent = [];
  const session = sessionWithoutAiChat();
  const pending = routeWeixinText({
    text: "/ai check status",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session }],
    aiAgentOpenTimeoutMs: 100,
  });

  const openRequest = await waitForSentType("open-ai-agent");
  phanttySocket(session).emit(
    "message",
    Buffer.from(JSON.stringify({
      type: "open-ai-agent-result",
      requestId: openRequest.requestId,
      status: "opened",
    })),
  );
  session.applyLayout({
    type: "layout",
    activeTab: 0,
    tabs: [{
      index: 0,
      focusedSurfaceId: "aichat-new",
      surfaces: [
        { id: "term1", title: "PowerShell", kind: "terminal", readOnly: false },
        { id: "aichat-new", title: "AI Agent", kind: "ai_chat", snapshot: "" },
      ],
    }],
  });

  const reply = await pending;
  assert.equal(reply.text, "信息已收到，开始处理。");
  assert.equal((sent.at(-1) as { surfaceId: string }).surfaceId, "aichat-new");
  assert.equal((sent.at(-1) as { data: string }).data, "636865636b207374617475730d");
});

test("AI Agent open no-profile result returns setup guidance", async () => {
  sent = [];
  const session = sessionWithoutAiChat();
  const pending = routeWeixinText({
    text: "hello ai",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session }],
    aiAgentOpenTimeoutMs: 100,
  });

  const openRequest = await waitForSentType("open-ai-agent");
  phanttySocket(session).emit(
    "message",
    Buffer.from(JSON.stringify({
      type: "open-ai-agent-result",
      requestId: openRequest.requestId,
      status: "no-profile",
    })),
  );

  assert.equal(await pending.then((reply) => reply.text), "Phantty 尚未配置 AI Chat profile。请先在桌面端创建 AI Chat profile。");
});

test("AI Agent open failed result returns retry guidance", async () => {
  sent = [];
  const session = sessionWithoutAiChat();
  const pending = routeWeixinText({
    text: "hello ai",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session }],
    aiAgentOpenTimeoutMs: 100,
  });

  const openRequest = await waitForSentType("open-ai-agent");
  phanttySocket(session).emit(
    "message",
    Buffer.from(JSON.stringify({
      type: "open-ai-agent-result",
      requestId: openRequest.requestId,
      status: "failed",
    })),
  );

  assert.equal(await pending.then((reply) => reply.text), "Phantty 无法打开 AI Agent。请检查桌面端配置后重试。");
});

test("AI Agent open offline result returns offline message", async () => {
  sent = [];
  const session = sessionWithoutAiChat();
  session.attachPhantty(new ThrowingSocket() as never);

  const reply = await routeWeixinText({
    text: "hello ai",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session }],
    aiAgentOpenTimeoutMs: 100,
  });

  assert.equal(reply.text, "Phantty 当前离线，无法打开 AI Agent。");
});

test("opened AI Agent result without later AI Chat layout returns layout timeout message", async () => {
  sent = [];
  const session = sessionWithoutAiChat();
  const pending = routeWeixinText({
    text: "hello ai",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session }],
    aiAgentOpenTimeoutMs: 5,
  });

  const openRequest = await waitForSentType("open-ai-agent");
  phanttySocket(session).emit(
    "message",
    Buffer.from(JSON.stringify({
      type: "open-ai-agent-result",
      requestId: openRequest.requestId,
      status: "opened",
    })),
  );

  assert.equal(await pending.then((reply) => reply.text), "已请求 Phantty 打开 AI Agent，但未等到 AI Chat tab。请检查桌面端配置后重试。");
});

test("AI Agent open request timeout returns layout timeout message", async () => {
  sent = [];
  const reply = await routeWeixinText({
    text: "hello ai",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session: sessionWithoutAiChat() }],
    aiAgentOpenTimeoutMs: 5,
  });

  assert.equal(reply.text, "已请求 Phantty 打开 AI Agent，但未等到 AI Chat tab。请检查桌面端配置后重试。");
});

test("/term against session without AI Chat sends to terminal and does not open AI Agent", async () => {
  sent = [];
  const reply = await routeWeixinText({
    text: "/term pwd",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session: sessionWithoutAiChat() }],
    aiAgentOpenTimeoutMs: 100,
  });

  assert.match(reply.text, /已发送到终端/);
  assert.equal(sent.some((message) => (message as { type?: string }).type === "open-ai-agent"), false);
  assert.equal((sent.at(-1) as { surfaceId: string }).surfaceId, "term1");
  assert.equal((sent.at(-1) as { data: string }).data, "7077640d");
});

test("/ping replies pong without resolving a target session", async () => {
  sent = [];
  const reply = await routeWeixinText({
    text: "/ping",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [],
  });

  assert.equal(reply.text, "pong");
  assert.equal(reply.ai, undefined);
  assert.equal(sent.length, 0);
});

test("plain ping replies pong for quick binding checks", async () => {
  sent = [];
  const reply = await routeWeixinText({
    text: "ping",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [],
  });

  assert.equal(reply.text, "pong");
  assert.equal(reply.ai, undefined);
  assert.equal(sent.length, 0);
});

test("/term routes to writable terminal with carriage return", async () => {
  sent = [];
  const reply = await routeWeixinText({
    text: "/term pwd",
    settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session: sessionWithLayout() }],
  });
  assert.match(reply.text, /已发送到终端/);
  assert.equal((sent[0] as { surfaceId: string }).surfaceId, "term1");
  assert.equal((sent[0] as { data: string }).data, "7077640d");
});

test("targeted commands with empty args return usage and send nothing", async () => {
  for (const command of ["/term", "/ai", "/keys"]) {
    sent = [];
    const reply = await routeWeixinText({
      text: command,
      settings: { enabled: true, target_session: "alpha-secret", reply_timeout_ms: 10000 },
      sessions: [{ key: "alpha-secret", session: sessionWithLayout() }],
    });
    assert.match(reply.text, /用法：/);
    assert.equal(sent.length, 0);
  }
});

test("router asks user to choose session when multiple sessions exist and no target is configured", async () => {
  const reply = await routeWeixinText({
    text: "hello",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [
      { key: "alpha-secret", session: sessionWithLayout() },
      { key: "beta-secret", session: sessionWithLayout() },
    ],
  });
  assert.match(reply.text, /请先发送 `\/use/);
});

test("/status reports connected session count", async () => {
  const reply = await routeWeixinText({
    text: "/status",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [
      { key: "alpha-secret", session: sessionWithLayout() },
      { key: "beta-secret", session: offlineSessionWithLayout() },
    ],
  });
  assert.match(reply.text, /在线 session：1/);
});

test("/sessions lists all remote sessions without claiming only online sessions", async () => {
  const reply = await routeWeixinText({
    text: "/sessions",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [
      { key: "alpha-secret", session: sessionWithLayout() },
      { key: "beta-secret", session: offlineSessionWithLayout() },
    ],
  });
  assert.match(reply.text, /Remote session：/);
  assert.doesNotMatch(reply.text, /在线 Remote session/);
  assert.match(reply.text, /1\. alph\*\*\*\* online/);
  assert.match(reply.text, /2\. beta\*\*\*\* offline/);
  assert.match(reply.text, /\/use <编号>/);
});

test("/help describes sessions with neutral wording", async () => {
  const reply = await routeWeixinText({
    text: "/help",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [],
  });
  assert.match(reply.text, /\/sessions 查看 Remote session/);
  assert.doesNotMatch(reply.text, /\/sessions 查看在线 Remote session/);
});

test("unknown slash command returns help before resolving a target session", async () => {
  const reply = await routeWeixinText({
    text: "/bogus",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [
      { key: "alpha-secret", session: sessionWithLayout() },
      { key: "beta-secret", session: sessionWithLayout() },
    ],
  });
  assert.match(reply.text, /未知命令：\/bogus/);
  assert.match(reply.text, /Phantty Weixin Bridge 命令/);
});

test("/use refuses offline sessions and does not save them", async () => {
  let saved = "";
  const reply = await routeWeixinText({
    text: "/use alpha-secret",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [{ key: "alpha-secret", session: offlineSessionWithLayout() }],
    saveTargetSession: async (key) => {
      saved = key;
    },
  });
  assert.match(reply.text, /该 session 不在线：alph\*\*\*\*/);
  assert.equal(saved, "");
});

test("/use accepts a numbered session from /sessions output", async () => {
  let saved = "";
  const reply = await routeWeixinText({
    text: "/use 2",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [
      { key: "alpha-secret", session: sessionWithLayout() },
      { key: "beta-secret", session: sessionWithLayout() },
    ],
    saveTargetSession: async (key) => {
      saved = key;
    },
  });

  assert.match(reply.text, /已选择 Remote session：#2 beta\*\*\*\*/);
  assert.equal(saved, "beta-secret");
});

test("/use still accepts a full session key", async () => {
  let saved = "";
  const reply = await routeWeixinText({
    text: "/use beta-secret",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [
      { key: "alpha-secret", session: sessionWithLayout() },
      { key: "beta-secret", session: sessionWithLayout() },
    ],
    saveTargetSession: async (key) => {
      saved = key;
    },
  });

  assert.match(reply.text, /已选择 Remote session：beta\*\*\*\*/);
  assert.equal(saved, "beta-secret");
});

test("/use numbered session refuses offline and out-of-range targets", async () => {
  let saved = "";
  const offline = await routeWeixinText({
    text: "/use 2",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [
      { key: "alpha-secret", session: sessionWithLayout() },
      { key: "beta-secret", session: offlineSessionWithLayout() },
    ],
    saveTargetSession: async (key) => {
      saved = key;
    },
  });
  assert.match(offline.text, /该 session 不在线：#2 beta\*\*\*\*/);

  const missing = await routeWeixinText({
    text: "/use 3",
    settings: { enabled: true, target_session: "", reply_timeout_ms: 10000 },
    sessions: [
      { key: "alpha-secret", session: sessionWithLayout() },
      { key: "beta-secret", session: sessionWithLayout() },
    ],
    saveTargetSession: async (key) => {
      saved = key;
    },
  });
  assert.match(missing.text, /未找到 session：#3/);
  assert.equal(saved, "");
});
