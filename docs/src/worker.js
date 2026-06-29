export const ONLINE_TTL_MS = 2 * 60 * 1000;

const LATEST_DOWNLOADS = new Set([
  "wispterm-windows-portable.zip",
  "wispterm-windows-portable-compat.zip",
  "wispterm-windows-portable-no-webview.zip",
  "wispterm-macos-aarch64.dmg",
  "wispterm-macos-x86_64.dmg",
  "wispterm-linux-x86_64.AppImage",
]);

const STATS_SNIPPET = `
<div class="cloudflare-stats" data-wispterm-stats hidden>
  <span><span data-stat-label="online">Online</span> <strong data-stat="online">-</strong></span>
  <span><span data-stat-label="visitors">Visitors</span> <strong data-stat="visitors">-</strong></span>
  <span><span data-stat-label="views">Views</span> <strong data-stat="views">-</strong></span>
</div>
<style>
  .cloudflare-stats {
    border-top: 1px solid var(--border);
    color: var(--fg-muted);
    display: flex;
    flex-wrap: wrap;
    font-size: 0.88rem;
    gap: 14px 22px;
    justify-content: center;
    margin-top: 16px;
    padding-top: 14px;
  }
  .cloudflare-stats[hidden] { display: none; }
  .cloudflare-stats strong { color: var(--accent); font-family: var(--font-mono); }
</style>
<script type="module">
(() => {
  const downloadLinks = document.querySelectorAll("[data-cloudflare-download]");
  downloadLinks.forEach((link) => {
    const href = link.getAttribute("data-cloudflare-download");
    if (href) link.setAttribute("href", href);
    link.removeAttribute("target");
    link.removeAttribute("rel");
  });

  const root = document.querySelector("[data-wispterm-stats]");
  if (!root) return;

  const zh = (document.documentElement.lang || navigator.language || "").toLowerCase().startsWith("zh");
  const labels = zh
    ? { online: "当前在线", visitors: "历史访客", views: "访问次数" }
    : { online: "Online", visitors: "Visitors", views: "Views" };
  for (const [key, label] of Object.entries(labels)) {
    const el = root.querySelector('[data-stat-label="' + key + '"]');
    if (el) el.textContent = label;
  }

  const visitorKey = "wispterm_docs_visitor_id";
  let visitorId = localStorage.getItem(visitorKey);
  if (!/^[A-Za-z0-9_-]{8,128}$/.test(visitorId || "")) {
    visitorId = crypto.randomUUID ? crypto.randomUUID() : Date.now() + "-" + Math.random().toString(36).slice(2);
    localStorage.setItem(visitorKey, visitorId);
  }

  const update = (stats) => {
    for (const key of ["online", "visitors", "views"]) {
      const el = root.querySelector('[data-stat="' + key + '"]');
      if (el) el.textContent = Number(stats[key] || 0).toLocaleString();
    }
    root.hidden = false;
  };

  const post = async (path) => {
    const res = await fetch(path, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ visitorId }),
      keepalive: true,
    });
    if (res.ok) update(await res.json());
  };

  post("/api/stats/visit").catch(() => {});
  window.setInterval(() => post("/api/stats/heartbeat").catch(() => {}), 30000);
})();
</script>`;

export function injectStatsSnippet(html) {
  if (html.includes("data-wispterm-stats")) return html;
  if (/<\/footer>/i.test(html)) return html.replace(/<\/footer>/i, `${STATS_SNIPPET}\n</footer>`);
  if (/<\/body>/i.test(html)) return html.replace(/<\/body>/i, `${STATS_SNIPPET}\n</body>`);
  return `${html}\n${STATS_SNIPPET}`;
}

export function pruneActiveVisitors(active, now) {
  const fresh = {};
  for (const [visitorId, lastSeen] of Object.entries(active || {})) {
    if (typeof lastSeen === "number" && now - lastSeen <= ONLINE_TTL_MS) {
      fresh[visitorId] = lastSeen;
    }
  }
  return fresh;
}

export function latestDownloadKey(pathname) {
  const prefix = "/downloads/latest/";
  if (!pathname.startsWith(prefix)) return null;
  const file = pathname.slice(prefix.length);
  if (file.includes("/") || !LATEST_DOWNLOADS.has(file)) return null;
  return `latest/${file}`;
}

export class DocsStats {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/api/stats") {
      return json(await this.readStats(Date.now()));
    }

    if (request.method !== "POST") return json({ error: "method not allowed" }, 405);

    const visitorId = await readVisitorId(request);
    if (!visitorId) return json({ error: "invalid visitorId" }, 400);

    if (url.pathname === "/api/stats/visit") {
      return json(await this.recordVisit(visitorId, Date.now()));
    }
    if (url.pathname === "/api/stats/heartbeat") {
      return json(await this.recordHeartbeat(visitorId, Date.now()));
    }
    return json({ error: "not found" }, 404);
  }

  async recordVisit(visitorId, now) {
    const pageViews = (await this.state.storage.get("pageViews")) || 0;
    const visitors = (await this.state.storage.get("visitors")) || 0;
    const seenKey = `visitor:${visitorId}`;
    const seen = await this.state.storage.get(seenKey);

    const nextViews = pageViews + 1;
    const nextVisitors = seen ? visitors : visitors + 1;
    let active = pruneActiveVisitors(await this.state.storage.get("active"), now);
    active[visitorId] = now;

    await this.state.storage.put("pageViews", nextViews);
    await this.state.storage.put("visitors", nextVisitors);
    await this.state.storage.put("active", active);
    if (!seen) await this.state.storage.put(seenKey, now);

    return statsPayload(nextViews, nextVisitors, active);
  }

  async recordHeartbeat(visitorId, now) {
    let active = pruneActiveVisitors(await this.state.storage.get("active"), now);
    active[visitorId] = now;
    await this.state.storage.put("active", active);
    return this.readStats(now, active);
  }

  async readStats(now, active = null) {
    const pageViews = (await this.state.storage.get("pageViews")) || 0;
    const visitors = (await this.state.storage.get("visitors")) || 0;
    const fresh = active || pruneActiveVisitors(await this.state.storage.get("active"), now);
    if (!active) await this.state.storage.put("active", fresh);
    return statsPayload(pageViews, visitors, fresh);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/api/stats")) {
      const id = env.DOCS_STATS.idFromName("global");
      return env.DOCS_STATS.get(id).fetch(request);
    }
    if (url.pathname.startsWith("/downloads/latest/")) {
      return serveLatestDownload(url.pathname, env);
    }

    const response = await env.ASSETS.fetch(request);
    if (!shouldInjectStats(request, response)) return response;

    const headers = new Headers(response.headers);
    headers.delete("content-length");
    return new Response(injectStatsSnippet(await response.text()), {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};

async function serveLatestDownload(pathname, env) {
  const key = latestDownloadKey(pathname);
  if (!key) return new Response("Not found", { status: 404 });
  if (!env.DOCS_DOWNLOADS) return new Response("Downloads are not configured", { status: 503 });

  const object = await env.DOCS_DOWNLOADS.get(key);
  if (!object) return new Response("Not found", { status: 404 });

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("cache-control", headers.get("cache-control") || "public, max-age=300");
  headers.set("content-disposition", `attachment; filename="${key.slice("latest/".length)}"`);
  return new Response(object.body, { headers });
}

function shouldInjectStats(request, response) {
  if (request.method !== "GET") return false;
  const type = response.headers.get("content-type") || "";
  return type.includes("text/html");
}

function statsPayload(pageViews, visitors, active) {
  return {
    online: Object.keys(active || {}).length,
    visitors,
    views: pageViews,
  };
}

async function readVisitorId(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return null;
  }
  return isVisitorId(body && body.visitorId) ? body.visitorId : null;
}

function isVisitorId(value) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{8,128}$/.test(value);
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
    },
  });
}
