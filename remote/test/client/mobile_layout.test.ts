import test from "node:test";
import assert from "node:assert/strict";

import {
  MOBILE_REMOTE_MEDIA_QUERY,
  fitModeForSurface,
  shouldUseViewportFit,
} from "../../src/client/mobile_layout";

test("mobile media query matches the responsive CSS breakpoint", () => {
  assert.equal(
    MOBILE_REMOTE_MEDIA_QUERY,
    "(max-width: 860px), (pointer: coarse) and (max-width: 1024px)",
  );
});

test("fitModeForSurface uses viewport fitting on mobile", () => {
  assert.equal(fitModeForSurface(true), "viewport");
});

test("fitModeForSurface preserves remote-grid sizing on desktop", () => {
  assert.equal(fitModeForSurface(false), "remote-grid");
});

test("shouldUseViewportFit is true only for mobile surfaces", () => {
  assert.equal(shouldUseViewportFit(true), true);
  assert.equal(shouldUseViewportFit(false), false);
});
