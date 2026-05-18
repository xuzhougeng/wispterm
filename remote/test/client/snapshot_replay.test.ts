import test from "node:test";
import assert from "node:assert/strict";

import {
  shouldBufferLiveOutputForInitialSnapshot,
  shouldFlushBufferedOutput,
  shouldScheduleInitialSnapshotReplay,
} from "../../src/client/snapshot_replay";

test("initial terminal snapshot is still scheduled after live output arrives first", () => {
  assert.equal(
    shouldScheduleInitialSnapshotReplay({
      hasSnapshot: true,
      snapshotApplied: false,
      initialSnapshotPending: false,
      hasLiveOutput: true,
    }),
    true,
  );
});

test("live output buffers while initial snapshot replay is pending", () => {
  assert.equal(
    shouldBufferLiveOutputForInitialSnapshot({
      opened: true,
      initialSnapshotPending: true,
    }),
    true,
  );
  assert.equal(
    shouldBufferLiveOutputForInitialSnapshot({
      opened: true,
      initialSnapshotPending: false,
    }),
    false,
  );
});

test("buffered output waits until pending initial snapshot replay completes", () => {
  assert.equal(
    shouldFlushBufferedOutput({
      opened: true,
      initialSnapshotPending: true,
      hasPendingOutput: true,
    }),
    false,
  );
  assert.equal(
    shouldFlushBufferedOutput({
      opened: true,
      initialSnapshotPending: false,
      hasPendingOutput: true,
    }),
    true,
  );
});
