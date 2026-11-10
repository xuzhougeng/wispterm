import type { LayoutState, LayoutTab, MobileInputMode, SurfaceView } from "./types";
import {
  readSavedDesktopPanelMode,
  readSavedMobileVisualZoom,
  readSavedSidebarCollapsed,
} from "./storage";

export const state = {
  socket: null as WebSocket | null,
  layoutState: null as LayoutState | null,
  selectedTabIndex: 0,
  selectedSurfaceId: null as string | null,
  surfaceViews: new Map<string, SurfaceView>(),
  notices: [] as string[],
  hasSeenLayout: false,
  kbdVisible: false,
  drawerOpen: false,
  sidebarCollapsed: readSavedSidebarCollapsed() ?? false,
  desktopPanelMode: readSavedDesktopPanelMode(),
  mobileInputMode: "edit" as MobileInputMode,
  mobileVisualZoom: readSavedMobileVisualZoom(),
  activeSessionKey: null as string | null,
};

export function currentTab(): LayoutTab | null {
  const layout = state.layoutState;
  if (!layout) return null;
  return (
    layout.tabs.find((tab) => tab.index === state.selectedTabIndex) ??
    layout.tabs.find((tab) => tab.index === layout.activeTab) ??
    layout.tabs[0] ??
    null
  );
}

export function activeSurfaceIdForInput(): string | null {
  const tab = currentTab();
  const surfaceId = state.selectedSurfaceId ?? tab?.surfaces[0]?.id ?? null;
  if (!surfaceId) return null;
  const surface = tab?.surfaces.find((candidate) => candidate.id === surfaceId);
  if (surface?.kind === "ai_chat") return null;
  return surface?.readOnly ? null : surfaceId;
}

export function pushNotice(message: string): void {
  state.notices = [...state.notices.slice(-5), message];
}

export function resetSurfaceViews(): void {
  state.surfaceViews = new Map();
}
