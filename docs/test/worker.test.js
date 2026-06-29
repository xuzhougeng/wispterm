import assert from "node:assert/strict";
import test from "node:test";

import {
  ONLINE_TTL_MS,
  injectStatsSnippet,
  pruneActiveVisitors,
} from "../src/worker.js";

test("injectStatsSnippet inserts the Cloudflare stats block before the footer closes", () => {
  const html = "<main>Docs</main><footer>Foot</footer>";
  const out = injectStatsSnippet(html);

  assert.match(out, /data-wispterm-stats/);
  assert.match(out, /<footer>Foot[\s\S]*data-wispterm-stats[\s\S]*<\/footer>/);
});

test("injectStatsSnippet is idempotent", () => {
  const once = injectStatsSnippet("<body><footer></footer></body>");
  assert.equal(injectStatsSnippet(once), once);
});

test("pruneActiveVisitors keeps only recent heartbeats", () => {
  const now = 10 * ONLINE_TTL_MS;
  const active = {
    fresh: now,
    edge: now - ONLINE_TTL_MS,
    stale: now - ONLINE_TTL_MS - 1,
  };

  assert.deepEqual(pruneActiveVisitors(active, now), {
    fresh: now,
    edge: now - ONLINE_TTL_MS,
  });
});
