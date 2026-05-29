import test from "node:test";
import assert from "node:assert/strict";

import { RemoteSession } from "../../src/server/session";

class FakeSocket {
  readyState = 1;
  sent: string[] = [];
  listeners = new Map<string, Array<(raw?: unknown) => void>>();
  send(payload: string): void {
    this.sent.push(payload);
  }
  close(): void {}
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
}

class ThrowingSocket extends FakeSocket {
  send(_payload: string): void {
    throw new Error("send failed");
  }
}

test("RemoteSession finds ai chat and writable terminal surfaces from latest layout", () => {
  const session = new RemoteSession("alpha");
  session.applyLayout({
    type: "layout",
    activeTab: 0,
    tabs: [
      {
        index: 0,
        focusedSurfaceId: "term1",
        surfaces: [
          { id: "term1", title: "PowerShell", focused: true, kind: "terminal", readOnly: false },
          { id: "aichat0000000000", title: "AI", kind: "ai_chat", snapshot: "You\nhello\n\nAI\nhi" },
        ],
      },
    ],
  });

  assert.deepEqual(session.findAiChatSurface(), { id: "aichat0000000000", title: "AI" });
  assert.deepEqual(session.findDefaultWritableSurface(), { id: "term1", title: "PowerShell" });
  assert.equal(session.latestAiChatTranscript(), "You\nhello\n\nAI\nhi");
});

test("RemoteSession prefers writable terminal surfaces in the active tab", () => {
  const session = new RemoteSession("alpha");
  session.applyLayout({
    type: "layout",
    activeTab: 1,
    tabs: [
      {
        index: 0,
        focusedSurfaceId: "inactive-focused",
        surfaces: [
          {
            id: "inactive-focused",
            title: "Inactive Focused",
            focused: true,
            kind: "terminal",
            readOnly: false,
          },
        ],
      },
      {
        index: 1,
        focusedSurfaceId: "active-terminal",
        surfaces: [
          { id: "active-ai", title: "Active AI", focused: true, kind: "ai_chat", readOnly: false },
          { id: "active-terminal", title: "Active Terminal", kind: "terminal", readOnly: false },
        ],
      },
    ],
  });

  assert.deepEqual(session.findDefaultWritableSurface(), {
    id: "active-terminal",
    title: "Active Terminal",
  });
});

test("RemoteSession notifies layout listeners and supports unsubscribe", () => {
  const session = new RemoteSession("alpha");
  let calls = 0;
  const unsubscribe = session.onLayout(() => {
    calls += 1;
  });

  session.applyLayout({ type: "layout", activeTab: 0, tabs: [] });
  unsubscribe();
  session.applyLayout({ type: "layout", activeTab: 0, tabs: [] });

  assert.equal(calls, 1);
});

test("RemoteSession sends utf8 input bytes to connected WispTerm socket", () => {
  const session = new RemoteSession("alpha");
  const wispterm = new FakeSocket();
  session.attachWispTerm(wispterm as never);

  assert.equal(session.sendInput("surface1", "pwd\r"), true);
  assert.equal(wispterm.sent.length, 1);
  assert.deepEqual(JSON.parse(wispterm.sent[0]), {
    type: "input-bytes",
    surfaceId: "surface1",
    encoding: "hex",
    data: "7077640d",
  });
});

test("RemoteSession refuses input when WispTerm socket is disconnected", () => {
  const session = new RemoteSession("alpha");
  assert.equal(session.sendInput("surface1", "pwd\r"), false);
});

test("RemoteSession refuses input when WispTerm socket is not open or send fails", () => {
  const session = new RemoteSession("alpha");
  const closedWispTerm = new FakeSocket();
  closedWispTerm.readyState = 3;
  session.attachWispTerm(closedWispTerm as never);

  assert.equal(session.sendInput("surface1", "pwd\r"), false);

  const throwingWispTerm = new ThrowingSocket();
  session.attachWispTerm(throwingWispTerm as never);

  assert.equal(session.sendInput("surface1", "pwd\r"), false);
});

test("RemoteSession handles WispTerm socket errors without throwing", () => {
  const session = new RemoteSession("alpha");
  const wispterm = new FakeSocket();
  session.attachWispTerm(wispterm as never);

  assert.doesNotThrow(() => wispterm.emit("error", new Error("invalid websocket frame")));
});

test("RemoteSession handles browser socket errors without throwing", () => {
  const session = new RemoteSession("alpha");
  const browser = new FakeSocket();
  session.attachBrowser(browser as never);

  assert.doesNotThrow(() => browser.emit("error", new Error("invalid websocket frame")));
});

test("RemoteSession reports WispTerm peer status to browsers", () => {
  const session = new RemoteSession("alpha");
  const browser = new FakeSocket();
  session.attachBrowser(browser as never);

  assert.deepEqual(JSON.parse(browser.sent.at(-1) ?? "{}"), {
    type: "peer-status",
    wisptermConnected: false,
  });

  const wispterm = new FakeSocket();
  session.attachWispTerm(wispterm as never);

  assert.deepEqual(JSON.parse(browser.sent.at(-1) ?? "{}"), {
    type: "peer-status",
    wisptermConnected: true,
  });

  wispterm.emit("close");

  assert.deepEqual(JSON.parse(browser.sent.at(-1) ?? "{}"), {
    type: "peer-status",
    wisptermConnected: false,
  });
});

test("RemoteSession requests AI Agent open and resolves the matching result", async () => {
  const session = new RemoteSession("alpha");
  const wispterm = new FakeSocket();
  session.attachWispTerm(wispterm as never);

  const pending = session.requestAiAgentOpen("req-1", 50);
  assert.deepEqual(JSON.parse(wispterm.sent.at(-1) ?? "{}"), {
    type: "open-ai-agent",
    requestId: "req-1",
  });

  wispterm.emit(
    "message",
    Buffer.from(
      JSON.stringify({
        type: "open-ai-agent-result",
        requestId: "req-1",
        status: "opened",
      }),
    ),
  );

  assert.equal(await pending, "opened");
});

test("RemoteSession ignores AI Agent open results with unknown statuses", async () => {
  const session = new RemoteSession("alpha");
  const wispterm = new FakeSocket();
  session.attachWispTerm(wispterm as never);

  const pending = session.requestAiAgentOpen("req-invalid", 10);
  wispterm.emit(
    "message",
    Buffer.from(
      JSON.stringify({
        type: "open-ai-agent-result",
        requestId: "req-invalid",
        status: "bogus",
      }),
    ),
  );

  assert.equal(await pending, "timeout");
});

test("RemoteSession AI Agent open request times out without a matching result", async () => {
  const session = new RemoteSession("alpha");
  const wispterm = new FakeSocket();
  session.attachWispTerm(wispterm as never);

  assert.equal(await session.requestAiAgentOpen("req-timeout", 5), "timeout");
});

test("RemoteSession AI Agent open request reports offline when WispTerm is disconnected", async () => {
  const session = new RemoteSession("alpha");

  assert.equal(await session.requestAiAgentOpen("req-offline", 5), "offline");
});

test("RemoteSession AI Agent open request reports offline when send fails", async () => {
  const session = new RemoteSession("alpha");
  const wispterm = new ThrowingSocket();
  session.attachWispTerm(wispterm as never);

  assert.equal(await session.requestAiAgentOpen("req-send-fails", 50), "offline");
});

test("RemoteSession consumes AI Agent open results without broadcasting them to browsers", () => {
  const session = new RemoteSession("alpha");
  const browser = new FakeSocket();
  const wispterm = new FakeSocket();
  session.attachBrowser(browser as never);
  session.attachWispTerm(wispterm as never);
  const sentBefore = browser.sent.length;

  wispterm.emit(
    "message",
    Buffer.from(
      JSON.stringify({
        type: "open-ai-agent-result",
        requestId: "req-unmatched",
        status: "opened",
      }),
    ),
  );

  assert.equal(browser.sent.length, sentBefore);
});

test("RemoteSession resolves pending AI Agent open requests offline when WispTerm closes", async () => {
  const session = new RemoteSession("alpha");
  const wispterm = new FakeSocket();
  session.attachWispTerm(wispterm as never);

  const pending = session.requestAiAgentOpen("req-close", 50);
  wispterm.emit("close");

  assert.equal(await pending, "offline");
});

test("RemoteSession resolves pending AI Agent open requests offline when WispTerm errors", async () => {
  const session = new RemoteSession("alpha");
  const wispterm = new FakeSocket();
  session.attachWispTerm(wispterm as never);

  const pending = session.requestAiAgentOpen("req-error", 50);
  wispterm.emit("error", new Error("socket failed"));

  assert.equal(await pending, "offline");
});

test("RemoteSession resolves pending AI Agent open requests offline when WispTerm is replaced", async () => {
  const session = new RemoteSession("alpha");
  const firstWispTerm = new FakeSocket();
  const nextWispTerm = new FakeSocket();
  session.attachWispTerm(firstWispTerm as never);

  const pending = session.requestAiAgentOpen("req-replaced", 50);
  session.attachWispTerm(nextWispTerm as never);

  assert.equal(await pending, "offline");
});
