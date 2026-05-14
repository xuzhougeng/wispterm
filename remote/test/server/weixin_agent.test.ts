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
  assert.match(reply.text, /已发送给 Phantty AI Agent/);
  assert.equal((sent[0] as { surfaceId: string }).surfaceId, "aichat0000000000");
  assert.equal((sent[0] as { data: string }).data, "73756d6d6172697a652063757272656e7420776f726b0d");
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
