import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { handleWeixinRoute } from "../../src/server/bridge/weixin/routes.js";
import { WeixinBindingStore } from "../../src/server/bridge/weixin/binding.js";

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

test("GET /api/weixin/settings returns settings and binding summary", async () => {
  const dir = await mkdtemp(join(tmpdir(), "phantty-weixin-route-"));
  const store = new WeixinBindingStore(dir);
  await store.saveSettings({ enabled: true, target_session: "alpha", reply_timeout_ms: 60000 });
  await store.saveBinding({
    token: "secret-token",
    base_url: "https://ilink.example",
    user_id: "user@im.wechat",
    account_id: "bot@im.bot",
    bound_at: "2026-05-14T00:00:00Z",
  });
  const res = fakeRes();

  const handled = await handleWeixinRoute(fakeReq("GET", "/api/weixin/settings") as never, res as never, {
    store,
    createClient: () => {
      throw new Error("not used");
    },
    listSessions: () => [],
    restartPoller: () => {},
  });

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
