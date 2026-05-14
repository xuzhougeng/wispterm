import test from "node:test";
import assert from "node:assert/strict";

import { routeWeixinText, maskSessionKey } from "../../src/server/bridge/weixin/agent.js";
import { RemoteSession } from "../../src/server/session.js";

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
  session.phantty = { readyState: 1, send: (payload: string) => { sent.push(JSON.parse(payload)); } } as never;
  return session;
}

function offlineSessionWithLayout(): RemoteSession {
  const session = sessionWithLayout();
  session.phantty = null;
  return session;
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
  assert.match(reply.text, /alph\*\*\*\* online/);
  assert.match(reply.text, /beta\*\*\*\* offline/);
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
  assert.match(reply.text, /未找到在线 session：alph\*\*\*\*/);
  assert.equal(saved, "");
});
