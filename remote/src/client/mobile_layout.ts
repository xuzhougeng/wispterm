export const MOBILE_REMOTE_MEDIA_QUERY =
  "(max-width: 860px), (pointer: coarse) and (max-width: 1024px)";

export type SurfaceFitMode = "remote-grid" | "viewport";

export function fitModeForSurface(isMobile: boolean): SurfaceFitMode {
  return isMobile ? "viewport" : "remote-grid";
}

export function shouldUseViewportFit(isMobile: boolean): boolean {
  return fitModeForSurface(isMobile) === "viewport";
}

export function isMobileRemoteShell(win: Pick<Window, "matchMedia"> = window): boolean {
  return win.matchMedia(MOBILE_REMOTE_MEDIA_QUERY).matches;
}
