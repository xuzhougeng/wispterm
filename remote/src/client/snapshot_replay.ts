export type InitialSnapshotReplayState = {
  hasSnapshot: boolean;
  snapshotApplied: boolean;
  initialSnapshotPending: boolean;
  hasLiveOutput: boolean;
};

export type LiveOutputBufferState = {
  opened: boolean;
  initialSnapshotPending: boolean;
};

export type BufferedOutputFlushState = {
  opened: boolean;
  initialSnapshotPending: boolean;
  hasPendingOutput: boolean;
};

export function shouldScheduleInitialSnapshotReplay(state: InitialSnapshotReplayState): boolean {
  if (!state.hasSnapshot) return false;
  if (state.snapshotApplied || state.initialSnapshotPending) return false;
  return true;
}

export function shouldBufferLiveOutputForInitialSnapshot(state: LiveOutputBufferState): boolean {
  return !state.opened || state.initialSnapshotPending;
}

export function shouldFlushBufferedOutput(state: BufferedOutputFlushState): boolean {
  return state.opened && !state.initialSnapshotPending && state.hasPendingOutput;
}
