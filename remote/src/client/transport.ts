import type { ConnectionStatus, MeResponse } from "./types";
import { state, currentTab, pushNotice } from "./state";
import { isLayoutMessage, normalizeLayout } from "./layout";
import { decodeHex, encodeHex, safeJson } from "./utils";
import { saveSessionKey } from "./storage";
import {
  connectionStatusConnecting,
  connectionStatusForLatency,
  connectionStatusOffline,
  connectionStatusWithoutPeer,
} from "./connection_status";
import {
  disposeSurfaceViews,
  reconcileSurfaceViews,
  writeLegacyOutput,
  writeSurfaceBytes,
} from "./surfaces";

const HEARTBEAT_INTERVAL_MS = 25_000;
const HEARTBEAT_WATCHDOG_MS = 50_000;
const RECONNECT_MIN_DELAY_MS = 1_000;
const RECONNECT_MAX_DELAY_MS = 30_000;

type TransportHooks = {
  onWorkspaceChanged: () => void;
  onNoticesChanged: () => void;
  onInputUiChanged: () => void;
  setStatus: (status: ConnectionStatus) => void;
};

let hooks: TransportHooks = {
  onWorkspaceChanged: () => {
    // wired by views/console
  },
  onNoticesChanged: () => {
    // wired by views/console
  },
  onInputUiChanged: () => {
    // wired by views/console
  },
  setStatus: () => {
    // wired by views/console
  },
};

export function setTransportHooks(next: TransportHooks): void {
  hooks = next;
}

const encoder = new TextEncoder();
let reconnectAttempts = 0;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let pingTimer: ReturnType<typeof setInterval> | null = null;
let watchdogTimer: ReturnType<typeof setInterval> | null = null;
let lastMessageAt = 0;
let lastPingSentAt = 0;
let lastLatencyMs: number | null = null;
let phanttyPeerConnected = false;

export function api(path: string, init?: RequestInit): Promise<Response> {
  return fetch(path, {
    credentials: "same-origin",
    headers: { "content-type": "application/json", ...(init?.headers ?? {}) },
    ...init,
  });
}

export async function loadMe(): Promise<MeResponse> {
  try {
    const res = await api("/api/me");
    if (!res.ok) return { authenticated: false };
    return (await res.json()) as MeResponse;
  } catch {
    return { authenticated: false };
  }
}

export function connect(sessionKey: string): void {
  if (!sessionKey) return;
  state.activeSessionKey = sessionKey;
  cancelReconnect();
  state.socket?.close();
  disposeSurfaceViews();
  state.layoutState = null;
  state.selectedSurfaceId = null;
  state.notices = [];
  state.hasSeenLayout = false;
  resetConnectionHealth();
  saveSessionKey(sessionKey);
  hooks.onWorkspaceChanged();
  hooks.onNoticesChanged();
  hooks.onInputUiChanged();

  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const ws = new WebSocket(`${protocol}//${location.host}/ws/browser?session=${encodeURIComponent(sessionKey)}`);
  state.socket = ws;
  hooks.setStatus(connectionStatusConnecting("Connecting..."));
  hooks.onInputUiChanged();

  ws.addEventListener("open", () => {
    if (state.socket !== ws) return;
    reconnectAttempts = 0;
    updateConnectionStatus();
    pushNotice("Connected. Waiting for Phantty layout...");
    hooks.onNoticesChanged();
    hooks.onInputUiChanged();
    startHeartbeat(ws);
  });

  ws.addEventListener("close", () => {
    const wasActive = state.socket === ws;
    if (!wasActive) return;
    stopHeartbeat();
    state.socket = null;
    resetConnectionHealth();
    if (state.activeSessionKey === sessionKey) {
      scheduleReconnect();
    } else {
      hooks.setStatus(connectionStatusOffline("Disconnected"));
    }
    hooks.onInputUiChanged();
  });

  ws.addEventListener("error", () => {
    if (state.socket === ws) {
      try { ws.close(); } catch { /* ignore */ }
    }
  });

  ws.addEventListener("message", (event) => {
    if (state.socket !== ws) return;
    if (typeof event.data !== "string") return;
    lastMessageAt = Date.now();
    const message = safeJson(event.data);
    if (!message) return;

    if (message.type === "pong" || message.type === "ping") {
      if (message.type === "ping") safeSocketSend(ws, { type: "pong" });
      else updateLatencyFromPong(message);
      return;
    }

    if (message.type === "peer-status") {
      phanttyPeerConnected = message.phanttyConnected === true;
      updateConnectionStatus();
      hooks.onInputUiChanged();
      return;
    }

    if (isLayoutMessage(message)) {
      phanttyPeerConnected = true;
      updateConnectionStatus();
      state.layoutState = normalizeLayout(message);
      if (!state.hasSeenLayout) {
        state.selectedTabIndex = state.layoutState.activeTab;
        state.hasSeenLayout = true;
      } else if (!state.layoutState.tabs.some((tab) => tab.index === state.selectedTabIndex)) {
        state.selectedTabIndex = state.layoutState.activeTab;
      }
      const activeTab = currentTab();
      if (!state.selectedSurfaceId || !activeTab?.surfaces.some((surface) => surface.id === state.selectedSurfaceId)) {
        state.selectedSurfaceId =
          activeTab?.focusedSurfaceId ?? activeTab?.surfaces[0]?.id ?? state.selectedSurfaceId;
      }
      reconcileSurfaceViews();
      hooks.onWorkspaceChanged();
      return;
    }

    if (message.type === "output" && typeof message.data === "string") {
      writeLegacyOutput(message.data);
    } else if (
      message.type === "output-bytes" &&
      message.encoding === "hex" &&
      typeof message.data === "string"
    ) {
      const surfaceId = typeof message.surfaceId === "string" ? message.surfaceId : state.selectedSurfaceId;
      const bytes = decodeHex(message.data);
      if (surfaceId && bytes) writeSurfaceBytes(surfaceId, bytes);
    } else if (message.type === "notice" && typeof message.message === "string") {
      pushNotice(message.message);
      hooks.onNoticesChanged();
    }
  });
}

export function disconnect(): void {
  state.activeSessionKey = null;
  cancelReconnect();
  stopHeartbeat();
  reconnectAttempts = 0;
  if (state.socket) {
    try { state.socket.close(); } catch { /* ignore */ }
    state.socket = null;
  }
  resetConnectionHealth();
  hooks.setStatus(connectionStatusOffline("Disconnected"));
}

export function sendInputBytes(surfaceId: string, data: string): void {
  const ws = state.socket;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(
    JSON.stringify({
      type: "input-bytes",
      surfaceId,
      encoding: "hex",
      data: encodeHex(encoder.encode(data)),
    }),
  );
}

export function kickReconnectIfIdle(): void {
  if (!state.activeSessionKey) return;
  const ws = state.socket;
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
  cancelReconnect();
  reconnectAttempts = 0;
  connect(state.activeSessionKey);
}

function startHeartbeat(ws: WebSocket): void {
  stopHeartbeat();
  lastMessageAt = Date.now();
  sendHeartbeatPing(ws);
  pingTimer = setInterval(() => {
    if (ws.readyState !== WebSocket.OPEN) return;
    sendHeartbeatPing(ws);
  }, HEARTBEAT_INTERVAL_MS);
  watchdogTimer = setInterval(() => {
    if (ws.readyState !== WebSocket.OPEN) return;
    if (Date.now() - lastMessageAt > HEARTBEAT_WATCHDOG_MS) {
      try { ws.close(4000, "heartbeat timeout"); } catch { /* ignore */ }
    }
  }, 5_000);
}

function stopHeartbeat(): void {
  if (pingTimer !== null) {
    clearInterval(pingTimer);
    pingTimer = null;
  }
  if (watchdogTimer !== null) {
    clearInterval(watchdogTimer);
    watchdogTimer = null;
  }
}

function scheduleReconnect(): void {
  if (!state.activeSessionKey) return;
  cancelReconnect();
  const exponent = Math.min(reconnectAttempts, 5);
  const delay = Math.min(RECONNECT_MAX_DELAY_MS, RECONNECT_MIN_DELAY_MS * 2 ** exponent);
  reconnectAttempts += 1;
  hooks.setStatus(connectionStatusConnecting(`Reconnecting in ${Math.round(delay / 1000)}s...`));
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    if (state.activeSessionKey) connect(state.activeSessionKey);
  }, delay);
}

function cancelReconnect(): void {
  if (reconnectTimer !== null) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
}

function safeSocketSend(ws: WebSocket, payload: unknown): void {
  try {
    ws.send(JSON.stringify(payload));
  } catch {
    // Ignore — close handler will retry via reconnect.
  }
}

function sendHeartbeatPing(ws: WebSocket): void {
  lastPingSentAt = Date.now();
  safeSocketSend(ws, { type: "ping", at: lastPingSentAt });
}

function updateLatencyFromPong(message: { at?: unknown }): void {
  const sentAt = typeof message.at === "number" ? message.at : lastPingSentAt;
  if (sentAt <= 0) return;
  lastLatencyMs = Date.now() - sentAt;
  updateConnectionStatus();
}

function updateConnectionStatus(): void {
  const ws = state.socket;
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    hooks.setStatus(connectionStatusOffline("Disconnected"));
    return;
  }
  if (!phanttyPeerConnected) {
    hooks.setStatus(connectionStatusWithoutPeer(lastLatencyMs));
    return;
  }
  if (lastLatencyMs === null) {
    hooks.setStatus(connectionStatusConnecting("Connected · measuring latency..."));
    return;
  }
  hooks.setStatus(connectionStatusForLatency(lastLatencyMs));
}

function resetConnectionHealth(): void {
  lastPingSentAt = 0;
  lastLatencyMs = null;
  phanttyPeerConnected = false;
}
