import test from "node:test";
import assert from "node:assert/strict";

import { processWeixinUpdates, shouldHandleWeixinMessage } from "../../src/server/bridge/weixin/poller.js";
import type { WeixinBindingRecord, WeixinMessage } from "../../src/server/bridge/weixin/types.js";

const binding: WeixinBindingRecord = {
  token: "token",
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
