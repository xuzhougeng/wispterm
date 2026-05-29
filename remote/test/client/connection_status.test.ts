import test from "node:test";
import assert from "node:assert/strict";

import {
  HIGH_LATENCY_THRESHOLD_MS,
  connectionStatusForLatency,
  connectionStatusWithoutPeer,
  latencyDisclosureText,
} from "../../src/client/connection_status";

test("connection status uses red when WispTerm peer is not connected", () => {
  assert.deepEqual(connectionStatusWithoutPeer(null), {
    kind: "offline",
    text: "Not connected",
    latencyMs: null,
    detail: "Latency unavailable",
  });
  assert.deepEqual(connectionStatusWithoutPeer(42), {
    kind: "offline",
    text: "Not connected · relay 42 ms",
    latencyMs: 42,
    detail: "Relay latency: 42 ms",
  });
});

test("connection status maps 500ms threshold to low and high latency", () => {
  assert.equal(HIGH_LATENCY_THRESHOLD_MS, 500);
  assert.deepEqual(connectionStatusForLatency(499), {
    kind: "online",
    text: "Low latency · 499 ms",
    latencyMs: 499,
    detail: "Latency: 499 ms",
  });
  assert.deepEqual(connectionStatusForLatency(500), {
    kind: "online",
    text: "Low latency · 500 ms",
    latencyMs: 500,
    detail: "Latency: 500 ms",
  });
  assert.deepEqual(connectionStatusForLatency(501), {
    kind: "high-latency",
    text: "High latency · 501 ms",
    latencyMs: 501,
    detail: "Latency: 501 ms",
  });
});

test("latency disclosure rounds measurements for click feedback", () => {
  assert.equal(latencyDisclosureText(null), "Latency unavailable");
  assert.equal(latencyDisclosureText(123.6), "Latency: 124 ms");
});
