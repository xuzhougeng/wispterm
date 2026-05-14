import test from "node:test";
import assert from "node:assert/strict";

import { WEB_VERSION, webVersionLabel } from "../../src/client/version";

test("web version is exposed for the remote UI", () => {
  assert.equal(WEB_VERSION, "v0.19.4");
  assert.equal(webVersionLabel(), "Web v0.19.4");
});

test("web version label prefers an injected build time", () => {
  assert.equal(webVersionLabel("2025 05 10 10:30"), "Web 2025 05 10 10:30");
});
