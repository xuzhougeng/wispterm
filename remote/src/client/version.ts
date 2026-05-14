export const WEB_VERSION = "v0.19.4";
export const WEB_BUILD_TIME = normalizedBuildTime(import.meta.env?.VITE_PHANTTY_WEB_BUILD_TIME);

export function webVersionLabel(buildTime: string | null = WEB_BUILD_TIME): string {
  return `Web ${normalizedBuildTime(buildTime) ?? WEB_VERSION}`;
}

function normalizedBuildTime(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}
