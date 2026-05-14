import test from "node:test";
import assert from "node:assert/strict";

import {
  processWeixinUpdates,
  shouldHandleWeixinMessage,
  WEIXIN_SESSION_EXPIRED_ERRCODE,
  WeixinPoller,
} from "../../src/server/bridge/weixin/poller.js";
import type { WeixinBindingRecord, WeixinMessage, WeixinSettings } from "../../src/server/bridge/weixin/types.js";

const binding: WeixinBindingRecord = {
  token: "s3cr3t",
  base_url: "https://ilink.example",
  user_id: "user@im.wechat",
  account_id: "bot@im.bot",
  bound_at: "2026-05-14T00:00:00Z",
};

test("shouldHandleWeixinMessage rejects group messages, bot echoes, and unexpected users", () => {
  assert.equal(shouldHandleWeixinMessage(binding, { group_id: "group", from_user_id: "user@im.wechat" }).ok, false);
  assert.equal(shouldHandleWeixinMessage(binding, { from_user_id: "bot@im.bot" }).reason, "bot_echo");
  assert.equal(shouldHandleWeixinMessage(binding, { from_user_id: "other@im.wechat" }).reason, "unexpected_sender");
  assert.equal(shouldHandleWeixinMessage(binding, { from_user_id: "user@im.wechat", to_user_id: "bot@im.bot" }).ok, true);
});

test("processWeixinUpdates extracts text and sends replies", async () => {
  const sent: Array<{ to: string; text: string; contextToken: string }> = [];
  const messages: WeixinMessage[] = [{
    from_user_id: "user@im.wechat",
    to_user_id: "bot@im.bot",
    context_token: "ctx",
    item_list: [{ type: 1, text_item: { text: "hello" } }],
  }];

  await processWeixinUpdates({
    binding,
    messages,
    routeText: async (text) => ({ text: `reply:${text}` }),
    sendText: async (to, text, contextToken) => {
      sent.push({ to, text, contextToken });
    },
  });

  assert.deepEqual(sent, [{ to: "user@im.wechat", text: "reply:hello", contextToken: "ctx" }]);
});

test("processWeixinUpdates isolates per-message route and send failures", async () => {
  const sent: Array<{ to: string; text: string; contextToken: string }> = [];
  const warnings: unknown[][] = [];
  const messages: WeixinMessage[] = [
    {
      from_user_id: "user@im.wechat",
      to_user_id: "bot@im.bot",
      context_token: "ctx1",
      item_list: [{ type: 1, text_item: { text: "route-fails" } }],
    },
    {
      from_user_id: "user@im.wechat",
      to_user_id: "bot@im.bot",
      context_token: "ctx2",
      item_list: [{ type: 1, text_item: { text: "send-fails" } }],
    },
    {
      from_user_id: "user@im.wechat",
      to_user_id: "bot@im.bot",
      context_token: "ctx3",
      item_list: [{ type: 1, text_item: { text: "ok" } }],
    },
  ];

  await processWeixinUpdates({
    binding,
    messages,
    routeText: async (text) => {
      if (text === "route-fails") throw new Error("route failed");
      return { text: `reply:${text}` };
    },
    sendText: async (to, text, contextToken) => {
      if (text === "reply:send-fails") throw new Error("send failed");
      sent.push({ to, text, contextToken });
    },
    logger: { warn: (...args: unknown[]) => warnings.push(args) },
  });

  assert.deepEqual(sent, [{ to: "user@im.wechat", text: "reply:ok", contextToken: "ctx3" }]);
  assert.equal(warnings.length, 2);
  assert.equal(warnings.some((args) => JSON.stringify(args).includes(binding.token)), false);
});

test("WeixinPoller disables settings when the iLink session expires", async () => {
  let savedSettings: WeixinSettings | null = null;
  const poller = new WeixinPoller(
    fakeStore({
      saveSettings: async (settings) => {
        savedSettings = settings;
      },
    }),
    () => [],
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => ({ ret: 0, errcode: WEIXIN_SESSION_EXPIRED_ERRCODE }),
        sendTextMessage: async () => {},
      }),
      scheduler: fakeScheduler(),
    },
  );

  await poller.runOnceForTest();

  assert.equal(savedSettings?.enabled, false);
});

test("WeixinPoller discards updates after stop during an in-flight poll", async () => {
  const events: string[] = [];
  let releaseUpdates!: () => void;
  const scheduler = fakeScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSyncBuf: async (value) => {
        events.push(`save:${value}`);
      },
    }),
    () => [{
      key: "alpha",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        sendInput: () => true,
      },
    }] as never,
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => {
          await new Promise<void>((resolve) => {
            releaseUpdates = resolve;
          });
          return {
            ret: 0,
            get_updates_buf: "next-cursor",
            longpolling_timeout_ms: 1000,
            msgs: [
              {
                from_user_id: "user@im.wechat",
                to_user_id: "bot@im.bot",
                context_token: "ctx1",
                item_list: [{ type: 1, text_item: { text: "first" } }],
              },
              {
                from_user_id: "user@im.wechat",
                to_user_id: "bot@im.bot",
                context_token: "ctx2",
                item_list: [{ type: 1, text_item: { text: "second" } }],
              },
            ],
          };
        },
        sendTextMessage: async (_to, text) => {
          events.push(`send:${text}`);
          if (text.includes("first")) throw new Error("send failed");
        },
      }),
      scheduler,
    },
  );

  const run = poller.runOnceForTest();
  await new Promise<void>((resolve) => setImmediate(resolve));
  poller.stop();
  releaseUpdates();
  await run;

  assert.deepEqual(events, []);
  assert.equal(scheduler.scheduledCount(), 0);
});

test("WeixinPoller stops message processing before send when stopped during routing", async () => {
  const events: string[] = [];
  let releaseRoute!: () => void;
  let routeStartedResolve!: () => void;
  const routeStarted = new Promise<void>((resolve) => {
    routeStartedResolve = resolve;
  });
  const scheduler = fakeScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSettings: async () => {
        events.push("route:save-target");
        await new Promise<void>((resolve) => {
          releaseRoute = resolve;
          routeStartedResolve();
        });
      },
      saveSyncBuf: async (value) => {
        events.push(`save:${value}`);
      },
    }),
    () => [{
      key: "alpha",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        sendInput: () => true,
      },
    }] as never,
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => ({
          ret: 0,
          get_updates_buf: "next-cursor",
          longpolling_timeout_ms: 1000,
          msgs: [{
            from_user_id: "user@im.wechat",
            to_user_id: "bot@im.bot",
            context_token: "ctx1",
            item_list: [{ type: 1, text_item: { text: "/use alpha" } }],
          }],
        }),
        sendTextMessage: async (_to, text) => {
          events.push(`send:${text}`);
        },
      }),
      scheduler,
    },
  );

  const run = poller.runOnceForTest();
  await routeStarted;
  poller.stop();
  releaseRoute();
  await run;

  assert.deepEqual(events, ["route:save-target"]);
  assert.equal(scheduler.scheduledCount(), 0);
});

test("WeixinPoller does not save cursor after stop during an in-flight send", async () => {
  const events: string[] = [];
  let releaseSend!: () => void;
  let sendStartedResolve!: () => void;
  const sendStarted = new Promise<void>((resolve) => {
    sendStartedResolve = resolve;
  });
  const scheduler = fakeScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSyncBuf: async (value) => {
        events.push(`save:${value}`);
      },
    }),
    () => [{
      key: "alpha",
      session: {
        isPhanttyConnected: () => true,
        findAiChatSurface: () => ({ id: "ai", title: "AI", kind: "ai_chat" }),
        sendInput: () => true,
      },
    }] as never,
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => ({
          ret: 0,
          get_updates_buf: "next-cursor",
          longpolling_timeout_ms: 1000,
          msgs: [{
            from_user_id: "user@im.wechat",
            to_user_id: "bot@im.bot",
            context_token: "ctx1",
            item_list: [{ type: 1, text_item: { text: "hello" } }],
          }],
        }),
        sendTextMessage: async (_to, text) => {
          events.push(`send:${text}`);
          sendStartedResolve();
          await new Promise<void>((resolve) => {
            releaseSend = resolve;
          });
        },
      }),
      scheduler,
    },
  );

  const run = poller.runOnceForTest();
  await sendStarted;
  poller.stop();
  releaseSend();
  await run;

  assert.deepEqual(events, ["send:已发送给 Phantty AI Agent，等待结果中。"]);
  assert.equal(scheduler.scheduledCount(), 0);
});

test("WeixinPoller start is idempotent while getUpdates is in flight", async () => {
  const events: string[] = [];
  let releaseUpdates!: () => void;
  let updatesStartedResolve!: () => void;
  const updatesStarted = new Promise<void>((resolve) => {
    updatesStartedResolve = resolve;
  });
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSyncBuf: async (value) => {
        events.push(`save:${value}`);
      },
    }),
    () => [],
    { warn: () => {} },
    {
      createClient: () => ({
        getUpdates: async () => {
          updatesStartedResolve();
          await new Promise<void>((resolve) => {
            releaseUpdates = resolve;
          });
          return {
            ret: 0,
            get_updates_buf: "next-cursor",
            longpolling_timeout_ms: 1234,
            msgs: [],
          };
        },
        sendTextMessage: async () => {},
      }),
      scheduler,
    },
  );

  poller.start();
  assert.equal(scheduler.scheduledCount(), 1);
  scheduler.fire(0);
  await updatesStarted;
  poller.start();
  releaseUpdates();
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.deepEqual(events, ["save:next-cursor"]);
  assert.equal(scheduler.scheduledCount(), 2);
  assert.deepEqual(scheduler.delays(), [0, 1234]);
});

test("WeixinPoller ignores stale getUpdates rejection after restart", async () => {
  const warnings: unknown[][] = [];
  let rejectUpdates!: (err: Error) => void;
  let updatesStartedResolve!: () => void;
  const updatesStarted = new Promise<void>((resolve) => {
    updatesStartedResolve = resolve;
  });
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore(),
    () => [],
    { warn: (...args: unknown[]) => warnings.push(args) },
    {
      createClient: () => ({
        getUpdates: async () => {
          updatesStartedResolve();
          await new Promise<void>((_resolve, reject) => {
            rejectUpdates = reject;
          });
          return { ret: 0, msgs: [] };
        },
        sendTextMessage: async () => {},
      }),
      scheduler,
    },
  );

  poller.start();
  scheduler.fire(0);
  await updatesStarted;
  poller.stop();
  poller.start();
  rejectUpdates(new Error("old poll failed"));
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.equal(warnings.length, 0);
  assert.equal(scheduler.scheduledCount(), 2);
  assert.deepEqual(scheduler.delays(), [0, 0]);
});

test("WeixinPoller ignores stale session-expired scheduling after restart", async () => {
  const warnings: unknown[][] = [];
  let releaseSave!: () => void;
  let saveStartedResolve!: () => void;
  const saveStarted = new Promise<void>((resolve) => {
    saveStartedResolve = resolve;
  });
  const scheduler = fakeManualScheduler();
  const poller = new WeixinPoller(
    fakeStore({
      saveSettings: async () => {
        saveStartedResolve();
        await new Promise<void>((resolve) => {
          releaseSave = resolve;
        });
      },
    }),
    () => [],
    { warn: (...args: unknown[]) => warnings.push(args) },
    {
      createClient: () => ({
        getUpdates: async () => ({ ret: 0, errcode: WEIXIN_SESSION_EXPIRED_ERRCODE }),
        sendTextMessage: async () => {},
      }),
      scheduler,
    },
  );

  poller.start();
  scheduler.fire(0);
  await saveStarted;
  poller.stop();
  poller.start();
  releaseSave();
  await new Promise<void>((resolve) => setImmediate(resolve));

  assert.equal(warnings.length, 0);
  assert.equal(scheduler.scheduledCount(), 2);
  assert.deepEqual(scheduler.delays(), [0, 0]);
});

function fakeStore(overrides: {
  saveSettings?: (settings: WeixinSettings) => Promise<void>;
  saveSyncBuf?: (value: string) => Promise<void>;
} = {}) {
  const settings: WeixinSettings = { enabled: true, target_session: "alpha", reply_timeout_ms: 10000 };
  return {
    loadSettings: async () => settings,
    loadBinding: async () => binding,
    loadSyncBuf: async () => "current-cursor",
    saveSettings: overrides.saveSettings ?? (async () => {}),
    saveSyncBuf: overrides.saveSyncBuf ?? (async () => {}),
  } as never;
}

function fakeScheduler() {
  let scheduled = 0;
  return {
    setTimeout: () => {
      scheduled += 1;
      return scheduled;
    },
    clearTimeout: () => {},
    scheduledCount: () => scheduled,
  };
}

function fakeManualScheduler() {
  const callbacks: Array<() => void> = [];
  const delayValues: number[] = [];
  return {
    setTimeout: (callback: () => void, ms: number) => {
      callbacks.push(callback);
      delayValues.push(ms);
      return callbacks.length;
    },
    clearTimeout: () => {},
    fire: (index: number) => callbacks[index]?.(),
    scheduledCount: () => callbacks.length,
    delays: () => delayValues,
  };
}
