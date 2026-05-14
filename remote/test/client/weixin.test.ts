import test from "node:test";
import assert from "node:assert/strict";

import {
  bridgeStatusText,
  normalizeWeixinSettings,
  pollWeixinBindStatus,
  saveWeixinSettings,
} from "../../src/client/weixin";

const originalFetch = globalThis.fetch;

test.afterEach(() => {
  globalThis.fetch = originalFetch;
});

test("normalizeWeixinSettings applies defaults", () => {
  assert.deepEqual(normalizeWeixinSettings({}), {
    enabled: false,
    target_session: "",
    reply_timeout_ms: 60000,
  });
});

test("bridgeStatusText describes binding and target state", () => {
  assert.equal(
    bridgeStatusText(
      { enabled: true, target_session: "abcdef", reply_timeout_ms: 60000 },
      { bound: true, user_id: "user@im.wechat" },
    ),
    "Ready · user@im.wechat · target abcd**** · send /ping to test",
  );
});

test("bridgeStatusText points disabled bound users to the bridge switch", () => {
  assert.equal(
    bridgeStatusText(
      { enabled: false, target_session: "abcdef", reply_timeout_ms: 60000 },
      { bound: true, user_id: "user@im.wechat" },
    ),
    "Disabled · bound to user@im.wechat · turn on Bridge",
  );
});

test("saveWeixinSettings returns the PUT response shape", async () => {
  const saved = { enabled: true, target_session: "abcdef", reply_timeout_ms: 30000 };
  globalThis.fetch = async (input, init) => {
    assert.equal(input, "/api/weixin/settings");
    assert.equal(init?.method, "PUT");
    assert.equal(init?.body, JSON.stringify(saved));
    return Response.json({ success: true, settings: saved });
  };

  const response = await saveWeixinSettings(saved);

  assert.deepEqual(response, { success: true, settings: saved });
});

test("pollWeixinBindStatus preserves server error messages", async () => {
  globalThis.fetch = async () => Response.json({ error: "qrcode required" }, { status: 400 });

  await assert.rejects(
    pollWeixinBindStatus(""),
    (error) => error instanceof Error && error.message === "qrcode required",
  );
});
