import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";

import type { LayoutSurface, SurfaceView } from "./types";
import { isMobileRemoteShell, shouldUseViewportFit } from "./mobile_layout";
import { focusMobileTextInput } from "./mobile_text_input";
import { cursorMoveSequence, emptyState, shortSurfaceId, validPositiveInteger } from "./utils";
import { activeSurfaceIdForInput, currentTab, resetSurfaceViews, state } from "./state";
import { getTerminalPalette, subscribeToTheme } from "./theme";

const PENDING_OUTPUT_LIMIT = 128 * 1024;

type InputHandler = (surfaceId: string, data: string) => void;
let inputHandler: InputHandler = () => {
  // no-op until transport registers
};

export function setSurfaceInputHandler(handler: InputHandler): void {
  inputHandler = handler;
}

subscribeToTheme((palette) => {
  for (const view of state.surfaceViews.values()) {
    view.term.options.theme = palette;
    if (view.opened && view.term.rows > 0) {
      view.term.refresh(0, view.term.rows - 1);
    }
  }
});

export function ensureSurfaceView(surfaceId: string): SurfaceView {
  const existing = state.surfaceViews.get(surfaceId);
  if (existing) return existing;

  const host = document.createElement("div");
  host.className = "terminal-host";
  const panel = document.createElement("section");
  panel.className = "remote-panel";
  panel.dataset.surfaceId = surfaceId;
  const header = document.createElement("div");
  header.className = "panel-header";
  const title = document.createElement("span");
  const meta = document.createElement("small");
  header.appendChild(title);
  header.appendChild(meta);
  const mount = document.createElement("div");
  mount.className = "terminal-mount";
  mount.appendChild(host);
  panel.appendChild(header);
  panel.appendChild(mount);

  const selectThis = (): void => {
    state.selectedSurfaceId = surfaceId;
    renderRemotePanels();
  };
  panel.addEventListener("pointerdown", selectThis);
  panel.addEventListener("click", () => {
    selectThis();
    if (!focusMobileTextInput()) ensureSurfaceView(surfaceId).term.focus();
  });

  const fit = new FitAddon();
  const term = new Terminal({
    cursorBlink: true,
    cursorInactiveStyle: "outline",
    cursorStyle: "bar",
    cursorWidth: 2,
    convertEol: true,
    disableStdin: false,
    fontFamily: '"JetBrains Mono", "Cascadia Mono", monospace',
    fontSize: 13,
    scrollback: 0,
    theme: getTerminalPalette(),
  });
  term.loadAddon(fit);

  const view: SurfaceView = {
    panel,
    title,
    meta,
    host,
    term,
    fit,
    decoder: new TextDecoder(),
    disposeInput: term.onData((data) => inputHandler(surfaceId, data)),
    disposeMiddleClickGesture: null,
    resizeObserver: null,
    fitQueued: false,
    hasLiveOutput: false,
    snapshotApplied: false,
    opened: false,
    pendingOutput: "",
    remoteCols: null,
    remoteRows: null,
  };
  view.disposeMiddleClickGesture = bindTwoFingerMiddleClick(view);
  state.surfaceViews.set(surfaceId, view);
  return view;
}

export function renderRemotePanels(): void {
  const panelsRoot = document.querySelector<HTMLDivElement>("#remote-panels");
  const titleRoot = document.querySelector<HTMLSpanElement>("#workspace-title");
  if (!panelsRoot) return;

  const tab = currentTab();
  if (!tab || tab.surfaces.length === 0) {
    panelsRoot.className = "panels-stage empty";
    delete panelsRoot.dataset.mobileMode;
    panelsRoot.replaceChildren(emptyState("No panels for this tab yet."));
    const fallback = "Remote workspace";
    if (titleRoot) titleRoot.textContent = fallback;
    const mobileTitleRoot = document.querySelector<HTMLSpanElement>("#mobile-workspace-title");
    if (mobileTitleRoot) mobileTitleRoot.textContent = fallback;
    return;
  }

  const tabTitle = tab.title || `Tab ${tab.index + 1}`;
  if (titleRoot) titleRoot.textContent = tabTitle;
  const mobileTitleRoot = document.querySelector<HTMLSpanElement>("#mobile-workspace-title");
  if (mobileTitleRoot) mobileTitleRoot.textContent = tabTitle;
  panelsRoot.className = "panels-stage";
  panelsRoot.dataset.mobileMode = "single";
  panelsRoot.querySelectorAll(".empty-state").forEach((node) => node.remove());
  const visible = new Set(tab.surfaces.map((surface) => surface.id));

  for (const surface of tab.surfaces) {
    const view = ensureSurfaceView(surface.id);
    view.panel.className = `remote-panel${surface.id === state.selectedSurfaceId ? " selected" : ""}`;
    view.panel.style.left = `${(surface.x ?? 0) * 100}%`;
    view.panel.style.top = `${(surface.y ?? 0) * 100}%`;
    view.panel.style.width = `${Math.max(0.05, surface.w ?? 1) * 100}%`;
    view.panel.style.height = `${Math.max(0.05, surface.h ?? 1) * 100}%`;
    view.panel.dataset.surfaceId = surface.id;
    view.title.textContent = surface.title || shortSurfaceId(surface.id);
    view.remoteCols = validPositiveInteger(surface.cols);
    view.remoteRows = validPositiveInteger(surface.rows);
    const grid = view.remoteCols && view.remoteRows ? `${view.remoteCols}×${view.remoteRows}` : null;
    const stateLabel = surface.focused ? "focused" : shortSurfaceId(surface.id);
    view.meta.textContent = grid ? `${grid} · ${stateLabel}` : stateLabel;

    if (view.panel.parentElement !== panelsRoot) {
      panelsRoot.appendChild(view.panel);
    }

    if (!view.opened) {
      view.term.open(view.host);
      view.opened = true;
      view.resizeObserver = new ResizeObserver(() => scheduleFit(view));
      view.resizeObserver.observe(view.host);
      flushPendingOutput(view);
    }
    updateSurfaceCursor(view, surface.id);
    applyInitialSnapshot(view, surface);
    scheduleFit(view);

    if (surface.id === state.selectedSurfaceId && document.activeElement && view.panel.contains(document.activeElement)) {
      view.term.focus();
    }
  }

  for (const [surfaceId, view] of state.surfaceViews) {
    if (!visible.has(surfaceId) && view.panel.parentElement === panelsRoot) {
      view.panel.remove();
    }
  }
}

export function focusAndFitSelectedSurface(): void {
  const id = state.selectedSurfaceId;
  if (!id) return;
  const view = state.surfaceViews.get(id);
  if (!view) return;
  if (!focusMobileTextInput()) view.term.focus();
  scheduleFit(view);
}

export function reconcileSurfaceViews(): void {
  if (!state.layoutState) return;
  const live = new Set(state.layoutState.tabs.flatMap((tab) => tab.surfaces.map((surface) => surface.id)));
  for (const [surfaceId, view] of state.surfaceViews) {
    if (!live.has(surfaceId)) {
      view.resizeObserver?.disconnect();
      view.disposeInput.dispose();
      view.disposeMiddleClickGesture?.();
      view.term.dispose();
      state.surfaceViews.delete(surfaceId);
    }
  }
}

export function disposeSurfaceViews(): void {
  for (const view of state.surfaceViews.values()) {
    view.resizeObserver?.disconnect();
    view.disposeInput.dispose();
    view.disposeMiddleClickGesture?.();
    view.term.dispose();
  }
  resetSurfaceViews();
}

export function writeSurfaceBytes(surfaceId: string, bytes: Uint8Array): void {
  const view = ensureSurfaceView(surfaceId);
  view.hasLiveOutput = true;
  writeSurfaceText(view, view.decoder.decode(bytes, { stream: true }));
}

export function writeLegacyOutput(data: string): void {
  const surfaceId = state.selectedSurfaceId ?? currentTab()?.surfaces[0]?.id ?? "legacy";
  const view = ensureSurfaceView(surfaceId);
  view.hasLiveOutput = true;
  writeSurfaceText(view, data);
}

export function focusActiveSurface(): void {
  const id = activeSurfaceIdForInput();
  if (id) state.surfaceViews.get(id)?.term.focus();
}

export function refitAllSurfaces(): void {
  for (const view of state.surfaceViews.values()) scheduleFit(view);
}

export function updateSurfaceCursors(): void {
  for (const [surfaceId, view] of state.surfaceViews) {
    view.term.options.disableStdin = false;
    updateSurfaceCursor(view, surfaceId);
  }
}

function updateSurfaceCursor(view: SurfaceView, surfaceId: string): void {
  const selected = surfaceId === state.selectedSurfaceId;
  view.term.options.cursorBlink = selected;
  view.term.options.cursorInactiveStyle = selected ? "outline" : "none";
}

function fitOrResize(view: SurfaceView): void {
  const useViewportFit = shouldUseViewportFit(isMobileRemoteShell());
  if (!useViewportFit && view.remoteCols && view.remoteRows) {
    if (view.term.cols !== view.remoteCols || view.term.rows !== view.remoteRows) {
      view.term.resize(view.remoteCols, view.remoteRows);
    }
    return;
  }

  view.fit.fit();
}

function scheduleFit(view: SurfaceView): void {
  if (view.fitQueued) return;
  view.fitQueued = true;
  requestAnimationFrame(() => {
    view.fitQueued = false;
    if (!view.host.isConnected) return;
    try {
      fitOrResize(view);
      view.term.refresh(0, Math.max(0, view.term.rows - 1));
    } catch {
      // xterm can briefly report zero-sized panels while layout is settling.
    }
  });
}

function applyInitialSnapshot(view: SurfaceView, surface: LayoutSurface): void {
  if (view.snapshotApplied || view.hasLiveOutput || !surface.snapshot) return;
  view.snapshotApplied = true;
  requestAnimationFrame(() => {
    if (!view.host.isConnected || view.hasLiveOutput) return;
    try {
      fitOrResize(view);
    } catch {
      // xterm can briefly report zero-sized panels while layout is settling.
    }
    view.term.reset();
    view.term.write((surface.snapshot ?? "") + cursorMoveSequence(surface));
    view.term.refresh(0, Math.max(0, view.term.rows - 1));
  });
}

function writeSurfaceText(view: SurfaceView, text: string): void {
  if (!text) return;
  if (!view.opened) {
    view.pendingOutput = capPendingOutput(view.pendingOutput + text);
    return;
  }
  flushPendingOutput(view);
  view.term.write(text);
}

function flushPendingOutput(view: SurfaceView): void {
  if (!view.opened || !view.pendingOutput) return;
  const pending = view.pendingOutput;
  view.pendingOutput = "";
  view.term.write(pending);
}

function capPendingOutput(value: string): string {
  return value.length > PENDING_OUTPUT_LIMIT ? value.slice(value.length - PENDING_OUTPUT_LIMIT) : value;
}

function bindTwoFingerMiddleClick(view: SurfaceView): () => void {
  const host = view.host;
  const MOVE_THRESHOLD = 14;
  const TIME_THRESHOLD = 700;
  let active = false;
  let startTime = 0;
  let centroid: { x: number; y: number } | null = null;

  const onTouchStart = (event: TouchEvent): void => {
    if (event.touches.length === 2) {
      active = true;
      startTime = Date.now();
      const a = event.touches[0];
      const b = event.touches[1];
      centroid = { x: (a.clientX + b.clientX) / 2, y: (a.clientY + b.clientY) / 2 };
    } else if (event.touches.length > 2) {
      active = false;
      centroid = null;
    }
  };

  const onTouchMove = (event: TouchEvent): void => {
    if (!active || !centroid) return;
    if (event.touches.length !== 2) {
      active = false;
      return;
    }
    const a = event.touches[0];
    const b = event.touches[1];
    const cx = (a.clientX + b.clientX) / 2;
    const cy = (a.clientY + b.clientY) / 2;
    if (Math.hypot(cx - centroid.x, cy - centroid.y) > MOVE_THRESHOLD) {
      active = false;
    }
  };

  const onTouchEnd = (event: TouchEvent): void => {
    if (!active || !centroid) {
      if (event.touches.length === 0) {
        active = false;
        centroid = null;
      }
      return;
    }
    if (event.touches.length >= 2) return;
    const within = Date.now() - startTime <= TIME_THRESHOLD;
    const point = centroid;
    active = false;
    centroid = null;
    if (!within) return;
    event.preventDefault();
    dispatchMiddleClick(host, point.x, point.y);
  };

  const onTouchCancel = (): void => {
    active = false;
    centroid = null;
  };

  host.addEventListener("touchstart", onTouchStart, { passive: true });
  host.addEventListener("touchmove", onTouchMove, { passive: true });
  host.addEventListener("touchend", onTouchEnd, { passive: false });
  host.addEventListener("touchcancel", onTouchCancel, { passive: true });

  return () => {
    host.removeEventListener("touchstart", onTouchStart);
    host.removeEventListener("touchmove", onTouchMove);
    host.removeEventListener("touchend", onTouchEnd);
    host.removeEventListener("touchcancel", onTouchCancel);
  };
}

function dispatchMiddleClick(host: HTMLElement, clientX: number, clientY: number): void {
  const target =
    host.querySelector<HTMLElement>(".xterm-screen") ??
    host.querySelector<HTMLElement>(".xterm") ??
    host;
  const baseInit: MouseEventInit = {
    bubbles: true,
    cancelable: true,
    composed: true,
    view: window,
    clientX,
    clientY,
    screenX: clientX,
    screenY: clientY,
    button: 1,
  };
  target.dispatchEvent(new MouseEvent("mousedown", { ...baseInit, buttons: 4 }));
  target.dispatchEvent(new MouseEvent("mouseup", { ...baseInit, buttons: 0 }));
  target.dispatchEvent(new MouseEvent("auxclick", { ...baseInit, buttons: 0, detail: 1 }));
}
