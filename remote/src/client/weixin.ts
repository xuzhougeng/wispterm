import { maskSessionKey } from "./storage";

export type WeixinSettings = {
  enabled: boolean;
  target_session: string;
  reply_timeout_ms: number;
};

export type WeixinBindingSummary = {
  bound: boolean;
  user_id?: string;
  account_id?: string;
  base_url?: string;
  bound_at?: string;
};

export type WeixinSettingsResponse = {
  settings: WeixinSettings;
  binding: WeixinBindingSummary;
  sessions: Array<{ key: string; connected: boolean }>;
};

export type WeixinSaveSettingsResponse = {
  success: boolean;
  settings: WeixinSettings;
};

export type WeixinBindStartResponse = {
  qrcode: string;
  qrcode_content: string;
  qrcode_data_url: string;
  status: string;
};

function weixinApi(path: string, init?: RequestInit): Promise<Response> {
  return fetch(path, {
    credentials: "same-origin",
    headers: { "content-type": "application/json", ...(init?.headers ?? {}) },
    ...init,
  });
}

async function weixinApiJson<T>(res: Response, fallback: string): Promise<T> {
  if (res.ok) return (await res.json()) as T;

  let errorMessage = "";
  try {
    const body = (await res.json()) as { error?: unknown };
    if (typeof body.error === "string" && body.error.length > 0) {
      errorMessage = body.error;
    }
  } catch {
    // Ignore invalid or empty error bodies and use the endpoint-specific fallback.
  }

  if (errorMessage) throw new Error(errorMessage);
  throw new Error(fallback);
}

async function throwWeixinApiError(res: Response, fallback: string): Promise<never> {
  await weixinApiJson<unknown>(res, fallback);
  throw new Error(fallback);
}

export function normalizeWeixinSettings(input: Partial<WeixinSettings>): WeixinSettings {
  return {
    enabled: input.enabled === true,
    target_session: String(input.target_session ?? "").trim(),
    reply_timeout_ms: Number.isFinite(input.reply_timeout_ms) ? Number(input.reply_timeout_ms) : 60000,
  };
}

export function bridgeStatusText(settings: WeixinSettings, binding: WeixinBindingSummary): string {
  if (!binding.bound) return "Not bound · scan to bind Weixin";
  if (!settings.enabled) return "Bound · turn on Bridge";

  const parts = ["Bound"];
  if (settings.target_session) parts.push(maskSessionKey(settings.target_session));
  parts.push("/ping to test");
  return parts.join(" · ");
}

export function bindActionText(binding: WeixinBindingSummary): "Bind" | "Unbind" {
  return binding.bound ? "Unbind" : "Bind";
}

export async function fetchWeixinSettings(): Promise<WeixinSettingsResponse> {
  const res = await weixinApi("/api/weixin/settings");
  return weixinApiJson<WeixinSettingsResponse>(res, "Failed to load Weixin settings");
}

export async function saveWeixinSettings(settings: WeixinSettings): Promise<WeixinSaveSettingsResponse> {
  const res = await weixinApi("/api/weixin/settings", { method: "PUT", body: JSON.stringify(settings) });
  return weixinApiJson<WeixinSaveSettingsResponse>(res, "Failed to save Weixin settings");
}

export async function startWeixinBind(): Promise<WeixinBindStartResponse> {
  const res = await weixinApi("/api/weixin/bind/start", { method: "POST" });
  return weixinApiJson<WeixinBindStartResponse>(res, "Failed to start Weixin binding");
}

export async function pollWeixinBindStatus(
  qrcode: string,
): Promise<{ status: string; message?: string; binding: WeixinBindingSummary }> {
  const res = await weixinApi(`/api/weixin/bind/status?qrcode=${encodeURIComponent(qrcode)}`);
  return weixinApiJson<{ status: string; message?: string; binding: WeixinBindingSummary }>(
    res,
    "Failed to poll Weixin binding",
  );
}

export async function unbindWeixin(): Promise<void> {
  const res = await weixinApi("/api/weixin/bind", { method: "DELETE" });
  if (!res.ok) await throwWeixinApiError(res, "Failed to unbind Weixin");
}
