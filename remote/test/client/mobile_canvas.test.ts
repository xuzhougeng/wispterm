import test from "node:test";
import assert from "node:assert/strict";

import {
  CANVAS_PAN_TAP_THRESHOLD,
  clampCanvasPan,
  defaultCanvasPan,
  isCanvasDrag,
  panCanvasBy,
  panCanvasByWheel,
  resizeCanvasPan,
  shouldStartCanvasPanDrag,
} from "../../src/client/mobile_canvas";

test("clampCanvasPan keeps an oversized canvas inside the viewport", () => {
  assert.deepEqual(
    clampCanvasPan({ x: -900, y: -500 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: -510, y: -400 },
  );
  assert.deepEqual(
    clampCanvasPan({ x: 80, y: 60 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: 0, y: 0 },
  );
});

test("clampCanvasPan disables panning when the canvas fits", () => {
  assert.deepEqual(
    clampCanvasPan({ x: -20, y: -20 }, { width: 900, height: 900 }, { width: 390, height: 500 }),
    { x: 0, y: 0 },
  );
});

test("defaultCanvasPan starts at the bottom-left of an oversized terminal canvas", () => {
  assert.deepEqual(
    defaultCanvasPan({ width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: 0, y: -400 },
  );
});

test("defaultCanvasPan can leave a bottom gutter for mobile clip edges", () => {
  assert.deepEqual(
    defaultCanvasPan(
      { width: 390, height: 500 },
      { width: 900, height: 900 },
      { bottomGutter: 12 },
    ),
    { x: 0, y: -412 },
  );
});

test("resizeCanvasPan keeps the bottom row visible when the viewport shrinks", () => {
  assert.deepEqual(
    resizeCanvasPan({
      pan: { x: 0, y: 0 },
      previousViewport: { width: 390, height: 920 },
      viewport: { width: 390, height: 500 },
      canvas: { width: 900, height: 900 },
      bottomGutter: 12,
    }),
    { x: 0, y: -412 },
  );
});

test("resizeCanvasPan preserves an intentionally panned-away canvas", () => {
  assert.deepEqual(
    resizeCanvasPan({
      pan: { x: 0, y: -120 },
      previousViewport: { width: 390, height: 500 },
      viewport: { width: 390, height: 460 },
      canvas: { width: 900, height: 900 },
      bottomGutter: 12,
    }),
    { x: 0, y: -120 },
  );
});

test("panCanvasBy accumulates drag deltas and clamps to available canvas", () => {
  assert.deepEqual(
    panCanvasBy({ x: 0, y: 0 }, { x: -220, y: -180 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: -220, y: -180 },
  );
  assert.deepEqual(
    panCanvasBy({ x: -480, y: -350 }, { x: -80, y: -100 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: -510, y: -400 },
  );
});

test("panCanvasByWheel maps wheel deltas to terminal canvas movement", () => {
  assert.deepEqual(
    panCanvasByWheel({ x: 0, y: 0 }, { x: 0, y: 180 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: 0, y: -180 },
  );
  assert.deepEqual(
    panCanvasByWheel({ x: -480, y: -350 }, { x: 80, y: 100 }, { width: 390, height: 500 }, { width: 900, height: 900 }),
    { x: -510, y: -400 },
  );
});

test("isCanvasDrag distinguishes tap jitter from canvas drag", () => {
  assert.equal(isCanvasDrag({ x: CANVAS_PAN_TAP_THRESHOLD - 1, y: 0 }), false);
  assert.equal(isCanvasDrag({ x: CANVAS_PAN_TAP_THRESHOLD + 1, y: 0 }), true);
});

test("shouldStartCanvasPanDrag uses touch primary drag on mobile and middle drag on desktop", () => {
  assert.equal(shouldStartCanvasPanDrag({ mobile: true, isPrimary: true, button: 0 }), true);
  assert.equal(shouldStartCanvasPanDrag({ mobile: true, isPrimary: true, button: 1 }), false);
  assert.equal(shouldStartCanvasPanDrag({ mobile: false, isPrimary: true, button: 0 }), false);
  assert.equal(shouldStartCanvasPanDrag({ mobile: false, isPrimary: true, button: 1 }), true);
  assert.equal(shouldStartCanvasPanDrag({ mobile: false, isPrimary: false, button: 1 }), false);
});
