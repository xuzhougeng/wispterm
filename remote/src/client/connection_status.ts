import type { ConnectionStatus, StatusKind } from "./types";

export const HIGH_LATENCY_THRESHOLD_MS = 500;

export function connectionStatusForLatency(latencyMs: number): ConnectionStatus {
  const normalized = normalizeLatency(latencyMs);
  const kind: StatusKind = normalized > HIGH_LATENCY_THRESHOLD_MS ? "high-latency" : "online";
  const label = kind === "high-latency" ? "High latency" : "Low latency";
  return {
    kind,
    text: `${label} · ${normalized} ms`,
    latencyMs: normalized,
    detail: latencyDisclosureText(normalized),
  };
}

export function connectionStatusWithoutPeer(latencyMs: number | null): ConnectionStatus {
  if (latencyMs === null) {
    return {
      kind: "offline",
      text: "Not connected",
      latencyMs: null,
      detail: "Latency unavailable",
    };
  }

  const normalized = normalizeLatency(latencyMs);
  return {
    kind: "offline",
    text: `Not connected · relay ${normalized} ms`,
    latencyMs: normalized,
    detail: `Relay latency: ${normalized} ms`,
  };
}

export function connectionStatusConnecting(text = "Connecting..."): ConnectionStatus {
  return {
    kind: "connecting",
    text,
    latencyMs: null,
    detail: "Latency unavailable",
  };
}

export function connectionStatusOffline(text = "Disconnected"): ConnectionStatus {
  return {
    kind: "offline",
    text,
    latencyMs: null,
    detail: "Latency unavailable",
  };
}

export function latencyDisclosureText(latencyMs: number | null): string {
  if (latencyMs === null) return "Latency unavailable";
  return `Latency: ${normalizeLatency(latencyMs)} ms`;
}

function normalizeLatency(latencyMs: number): number {
  if (!Number.isFinite(latencyMs)) return 0;
  return Math.max(0, Math.round(latencyMs));
}
