import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { handleWeixinRoute } from "../../src/server/bridge/weixin/routes.js";
import { WeixinBindingStore } from "../../src/server/bridge/weixin/binding.js";

const BINDING = {
  token: "secret-token",
  base_url: "https://ilink.example",
  user_id: "user@im.wechat",
  account_id: "bot@im.bot",
  bound_at: "2026-05-14T00:00:00Z",
};

function fakeReq(method: string, path: string, body = "") {
  return {
    method,
    url: path,
    async *[Symbol.asyncIterator]() {
      if (body) yield Buffer.from(body);
    },
  };
}

function fakeRes() {
  const headers = new Map<string, string>();
  return {
    statusCode: 0,
    body: "",
    setHeader(name: string, value: string) {
      headers.set(name.toLowerCase(), value);
    },
    end(chunk: string) {
      this.body += chunk;
    },
    headers,
  };
}

function jsonBody(res: { body: string }) {
  return JSON.parse(res.body) as Record<string, unknown>;
}

async function routeContext(store: WeixinBindingStore, overrides: {
  createClient?: () => unknown;
  listSessions?: () => Array<{ key: string; connected: boolean }>;
  restartPoller?: () => void;
} = {}) {
  return {
    store,
    createClient: (overrides.createClient ?? (() => {
      throw new Error("not used");
    })) as never,
    listSessions: overrides.listSessions ?? (() => []),
    restartPoller: overrides.restartPoller ?? (() => {}),
  };
}

async function tempStore() {
  return new WeixinBindingStore(await mkdtemp(join(tmpdir(), "phantty-weixin-route-")));
}

test("GET /api/weixin/settings returns settings and binding summary", async () => {
  const store = await tempStore();
  await store.saveSettings({ enabled: true, target_session: "alpha", reply_timeout_ms: 60000 });
  await store.saveBinding(BINDING);
  const res = fakeRes();

  const handled = await handleWeixinRoute(fakeReq("GET", "/api/weixin/settings") as never, res as never, await routeContext(store));

  assert.equal(handled, true);
  assert.equal(res.statusCode, 200);
  const body = JSON.parse(res.body) as {
    settings: { enabled: boolean };
    binding: {
      bound: boolean;
      base_url?: string;
      user_id?: string;
      account_id?: string;
      bound_at?: string;
      token?: string;
    };
  };
  assert.equal(body.settings.enabled, true);
  assert.equal(body.binding.bound, true);
  assert.equal(body.binding.base_url, "https://ilink.example");
  assert.equal(body.binding.user_id, "user@im.wechat");
  assert.equal(body.binding.account_id, "bot@im.bot");
  assert.equal(body.binding.bound_at, "2026-05-14T00:00:00Z");
  assert.equal(body.binding.token, undefined);
});

test("PUT /api/weixin/settings persists normalized settings and restarts poller", async () => {
  const store = await tempStore();
  let restarts = 0;
  const res = fakeRes();

  const handled = await handleWeixinRoute(
    fakeReq("PUT", "/api/weixin/settings", JSON.stringify({
      enabled: true,
      target_session: " alpha ",
      reply_timeout_ms: 1000,
    })) as never,
    res as never,
    await routeContext(store, { restartPoller: () => { restarts += 1; } }),
  );

  assert.equal(handled, true);
  assert.equal(res.statusCode, 200);
  assert.equal(restarts, 1);
  assert.deepEqual(await store.loadSettings(), { enabled: true, target_session: "alpha", reply_timeout_ms: 60000 });
});

test("PUT /api/weixin/settings returns JSON 400 for bad JSON", async () => {
  const store = await tempStore();
  let restarts = 0;
  const res = fakeRes();

  const handled = await handleWeixinRoute(
    fakeReq("PUT", "/api/weixin/settings", "{bad json") as never,
    res as never,
    await routeContext(store, { restartPoller: () => { restarts += 1; } }),
  );

  assert.equal(handled, true);
  assert.equal(res.statusCode, 400);
  assert.equal(res.headers.get("content-type"), "application/json; charset=utf-8");
  assert.equal(res.headers.get("cache-control"), "no-store");
  assert.equal(jsonBody(res).error, "invalid json");
  assert.equal(restarts, 0);
});

test("POST /api/weixin/bind/start returns QR data URL", async () => {
  const store = await tempStore();
  const res = fakeRes();

  const handled = await handleWeixinRoute(fakeReq("POST", "/api/weixin/bind/start") as never, res as never, await routeContext(store, {
    createClient: () => ({
      getQRCode: async () => ({ ret: 0, qrcode: "qr-id", qrcode_img_content: "weixin://qr-content" }),
    }),
  }));

  assert.equal(handled, true);
  assert.equal(res.statusCode, 200);
  const body = jsonBody(res);
  assert.equal(body.qrcode, "qr-id");
  assert.equal(body.qrcode_content, "weixin://qr-content");
  assert.equal(body.status, "wait");
  assert.match(String(body.qrcode_data_url), /^data:image\/png;base64,/);
});

test("POST /api/weixin/bind/start returns JSON 502 for iLink failure", async () => {
  const store = await tempStore();
  const res = fakeRes();

  const handled = await handleWeixinRoute(fakeReq("POST", "/api/weixin/bind/start") as never, res as never, await routeContext(store, {
    createClient: () => ({
      getQRCode: async () => {
        throw new Error("upstream secret-token failed");
      },
    }),
  }));

  assert.equal(handled, true);
  assert.equal(res.statusCode, 502);
  assert.equal(res.headers.get("cache-control"), "no-store");
  assert.equal(jsonBody(res).error, "weixin qrcode unavailable");
  assert.doesNotMatch(res.body, /secret-token/);
});

test("GET /api/weixin/bind/status requires qrcode", async () => {
  const store = await tempStore();
  const res = fakeRes();

  const handled = await handleWeixinRoute(fakeReq("GET", "/api/weixin/bind/status") as never, res as never, await routeContext(store));

  assert.equal(handled, true);
  assert.equal(res.statusCode, 400);
  assert.equal(jsonBody(res).error, "qrcode required");
});

test("GET /api/weixin/bind/status returns JSON 502 for iLink failure", async () => {
  const store = await tempStore();
  const res = fakeRes();

  const handled = await handleWeixinRoute(
    fakeReq("GET", "/api/weixin/bind/status?qrcode=qr-id") as never,
    res as never,
    await routeContext(store, {
      createClient: () => ({
        getQRCodeStatus: async () => {
          throw new Error("upstream secret-token failed");
        },
      }),
    }),
  );

  assert.equal(handled, true);
  assert.equal(res.statusCode, 502);
  assert.equal(res.headers.get("cache-control"), "no-store");
  assert.equal(jsonBody(res).error, "weixin qrcode status unavailable");
  assert.doesNotMatch(res.body, /secret-token/);
});

test("GET /api/weixin/bind/status persists confirmed binding and clears sync buffer", async () => {
  const store = await tempStore();
  await store.saveSyncBuf("cursor");
  let restarts = 0;
  const res = fakeRes();

  const handled = await handleWeixinRoute(
    fakeReq("GET", "/api/weixin/bind/status?qrcode=qr-id") as never,
    res as never,
    await routeContext(store, {
      createClient: () => ({
        getBaseUrl: () => "https://default.example",
        getQRCodeStatus: async () => ({
          ret: 0,
          status: "confirmed",
          bot_token: "new-token",
          baseurl: "https://bound.example",
          ilink_user_id: "bound-user",
          ilink_bot_id: "bound-bot",
        }),
      }),
      restartPoller: () => { restarts += 1; },
    }),
  );

  assert.equal(handled, true);
  assert.equal(res.statusCode, 200);
  assert.equal(restarts, 1);
  assert.equal(await store.loadSyncBuf(), "");
  assert.equal((await store.loadBinding())?.token, "new-token");
  const body = jsonBody(res) as { binding: Record<string, unknown> };
  assert.equal(body.binding.bound, true);
  assert.equal(body.binding.base_url, "https://bound.example");
  assert.equal(body.binding.user_id, "bound-user");
  assert.equal(body.binding.account_id, "bound-bot");
  assert.equal(body.binding.token, undefined);
  assert.equal(typeof body.binding.bound_at, "string");
});

test("GET /api/weixin/bind/status confirmed without token returns JSON 502 without side effects", async () => {
  const store = await tempStore();
  await store.saveSyncBuf("cursor");
  let restarts = 0;
  const res = fakeRes();

  const handled = await handleWeixinRoute(
    fakeReq("GET", "/api/weixin/bind/status?qrcode=qr-id") as never,
    res as never,
    await routeContext(store, {
      createClient: () => ({
        getQRCodeStatus: async () => ({ ret: 0, status: "confirmed", bot_token: "" }),
      }),
      restartPoller: () => { restarts += 1; },
    }),
  );

  assert.equal(handled, true);
  assert.equal(res.statusCode, 502);
  assert.equal(jsonBody(res).error, "confirmed weixin binding missing bot_token");
  assert.equal(restarts, 0);
  assert.equal(await store.loadBinding(), null);
  assert.equal(await store.loadSyncBuf(), "cursor");
});

test("DELETE /api/weixin/bind clears binding and sync buffer and restarts poller", async () => {
  const store = await tempStore();
  await store.saveBinding(BINDING);
  await store.saveSyncBuf("cursor");
  let restarts = 0;
  const res = fakeRes();

  const handled = await handleWeixinRoute(
    fakeReq("DELETE", "/api/weixin/bind") as never,
    res as never,
    await routeContext(store, { restartPoller: () => { restarts += 1; } }),
  );

  assert.equal(handled, true);
  assert.equal(res.statusCode, 200);
  assert.equal(restarts, 1);
  assert.equal(await store.loadBinding(), null);
  assert.equal(await store.loadSyncBuf(), "");
});

test("unmatched /api/weixin route returns JSON 404", async () => {
  const store = await tempStore();
  const res = fakeRes();

  const handled = await handleWeixinRoute(fakeReq("GET", "/api/weixin/missing") as never, res as never, await routeContext(store));

  assert.equal(handled, true);
  assert.equal(res.statusCode, 404);
  assert.equal(res.headers.get("content-type"), "application/json; charset=utf-8");
  assert.equal(res.headers.get("cache-control"), "no-store");
  assert.equal(jsonBody(res).error, "not found");
});
