import type { IncomingMessage, ServerResponse } from "node:http";
import QRCode from "qrcode";

import { WeixinClient } from "./client.js";
import type { WeixinBindingStore } from "./binding.js";
import { normalizeSettings } from "./binding.js";
import type { WeixinQRCodeStatusResponse, WeixinSettings } from "./types.js";

export type WeixinRouteContext = {
  store: WeixinBindingStore;
  createClient: (token: string, baseUrl?: string) => WeixinClient;
  listSessions: () => Array<{ key: string; connected: boolean }>;
  restartPoller: () => void;
};

export async function handleWeixinRoute(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: WeixinRouteContext,
): Promise<boolean> {
  const url = new URL(req.url ?? "/", "http://localhost");
  const method = (req.method ?? "GET").toUpperCase();

  if (url.pathname === "/api/weixin/settings" && method === "GET") {
    return sendJson(res, {
      settings: await ctx.store.loadSettings(),
      binding: await ctx.store.bindingSummary(),
      sessions: ctx.listSessions(),
    });
  }
  if (url.pathname === "/api/weixin/settings" && method === "PUT") {
    let body: unknown;
    try {
      body = await readJson<unknown>(req);
    } catch {
      return sendJson(res, { error: "invalid json" }, 400);
    }
    await ctx.store.saveSettings(normalizeSettings((body ?? {}) as Partial<WeixinSettings>));
    ctx.restartPoller();
    return sendJson(res, { success: true, settings: await ctx.store.loadSettings() });
  }
  if (url.pathname === "/api/weixin/bind/start" && method === "POST") {
    try {
      const qr = await ctx.createClient("").getQRCode();
      if (qr.ret !== 0 || !qr.qrcode || !qr.qrcode_img_content) {
        return sendJson(res, { error: "weixin qrcode unavailable" }, 502);
      }
      const dataUrl = await QRCode.toDataURL(qr.qrcode_img_content, { margin: 1, width: 240 });
      return sendJson(res, {
        qrcode: qr.qrcode,
        qrcode_content: qr.qrcode_img_content,
        qrcode_data_url: dataUrl,
        status: "wait",
      });
    } catch {
      return sendJson(res, { error: "weixin qrcode unavailable" }, 502);
    }
  }
  if (url.pathname === "/api/weixin/bind/status" && method === "GET") {
    const qrcode = url.searchParams.get("qrcode")?.trim() ?? "";
    if (!qrcode) return sendJson(res, { error: "qrcode required" }, 400);
    let status: WeixinQRCodeStatusResponse;
    try {
      status = await ctx.createClient("").getQRCodeStatus(qrcode);
    } catch {
      return sendJson(res, { error: "weixin qrcode status unavailable" }, 502);
    }
    if (status.ret !== 0) return sendJson(res, { error: "weixin qrcode status unavailable" }, 502);
    const persisted = await persistConfirmedStatus(status, ctx);
    if (!persisted.ok) return sendJson(res, { error: persisted.error }, 502);
    return sendJson(res, {
      status: normalizeStatus(status.status),
      message: status.message ?? "",
      binding: await ctx.store.bindingSummary(),
    });
  }
  if (url.pathname === "/api/weixin/bind" && method === "DELETE") {
    await ctx.store.clearBinding();
    ctx.restartPoller();
    return sendJson(res, { success: true });
  }
  if (url.pathname.startsWith("/api/weixin/")) {
    return sendJson(res, { error: "not found" }, 404);
  }
  return false;
}

async function persistConfirmedStatus(
  status: WeixinQRCodeStatusResponse,
  ctx: WeixinRouteContext,
): Promise<{ ok: true } | { ok: false; error: string }> {
  if (normalizeStatus(status.status) !== "confirmed") return { ok: true };
  const token = status.bot_token?.trim() ?? "";
  if (!token) return { ok: false, error: "confirmed weixin binding missing bot_token" };
  await ctx.store.saveBinding({
    token,
    base_url: status.baseurl?.trim() || ctx.createClient("").getBaseUrl(),
    user_id: status.ilink_user_id?.trim() ?? "",
    account_id: status.ilink_bot_id?.trim() ?? "",
    bound_at: new Date().toISOString(),
  });
  await ctx.store.saveSyncBuf("");
  ctx.restartPoller();
  return { ok: true };
}

function normalizeStatus(status = ""): string {
  const value = status.trim().toLowerCase();
  if (!value || value === "wait") return "wait";
  if (value === "scaned") return "scaned";
  if (value === "confirmed") return "confirmed";
  if (value === "expired") return "expired";
  return value;
}

async function readJson<T>(req: IncomingMessage): Promise<T | null> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  if (chunks.length === 0) return null;
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as T;
}

function sendJson(res: ServerResponse, body: unknown, status = 200): true {
  res.statusCode = status;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.setHeader("cache-control", "no-store");
  res.end(JSON.stringify(body));
  return true;
}
