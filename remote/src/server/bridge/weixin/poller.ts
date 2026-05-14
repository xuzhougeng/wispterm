import { routeWeixinText, type RoutedSession } from "./agent.js";
import type { WeixinBindingStore } from "./binding.js";
import { WeixinClient } from "./client.js";
import type { WeixinBindingRecord, WeixinMessage } from "./types.js";

export const WEIXIN_SESSION_EXPIRED_ERRCODE = -14;

export type HandleDecision = { ok: boolean; reason: string };

export type ProcessUpdatesInput = {
  binding: WeixinBindingRecord;
  messages: WeixinMessage[];
  routeText: (text: string) => Promise<{ text: string }>;
  sendText: (toUserId: string, text: string, contextToken: string) => Promise<void>;
};

export function shouldHandleWeixinMessage(binding: WeixinBindingRecord, message: WeixinMessage): HandleDecision {
  const from = (message.from_user_id ?? "").trim();
  const to = (message.to_user_id ?? "").trim();
  if ((message.group_id ?? "").trim()) return { ok: false, reason: "group_message" };
  if (!from) return { ok: false, reason: "missing_sender" };
  if (binding.account_id && from === binding.account_id) return { ok: false, reason: "bot_echo" };
  if (binding.user_id && from !== binding.user_id) return { ok: false, reason: "unexpected_sender" };
  if (binding.account_id && to && to !== binding.account_id) return { ok: false, reason: "unexpected_recipient" };
  return { ok: true, reason: "" };
}

export function extractWeixinText(message: WeixinMessage): string {
  for (const item of message.item_list ?? []) {
    if (item.type === 1 && item.text_item?.text?.trim()) return item.text_item.text.trim();
    if (item.type === 3 && item.voice_item?.text?.trim()) return item.voice_item.text.trim();
  }
  return "";
}

export async function processWeixinUpdates(input: ProcessUpdatesInput): Promise<void> {
  for (const message of input.messages) {
    if (!shouldHandleWeixinMessage(input.binding, message).ok) continue;
    const text = extractWeixinText(message);
    if (!text) continue;
    const reply = await input.routeText(text);
    if (reply.text.trim()) {
      await input.sendText(message.from_user_id ?? "", reply.text.trim(), message.context_token ?? "");
    }
  }
}

export class WeixinPoller {
  private timer: NodeJS.Timeout | null = null;
  private running = false;

  constructor(
    private readonly store: WeixinBindingStore,
    private readonly sessions: () => RoutedSession[],
    private readonly logger: Pick<Console, "log" | "warn" | "error"> = console,
  ) {}

  start(): void {
    if (this.timer) return;
    this.timer = setTimeout(() => void this.tick(), 0);
  }

  stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private schedule(ms: number): void {
    this.stop();
    this.timer = setTimeout(() => void this.tick(), ms);
  }

  private async tick(): Promise<void> {
    if (this.running) return this.schedule(1000);
    this.running = true;
    try {
      const settings = await this.store.loadSettings();
      const binding = await this.store.loadBinding();
      if (!settings.enabled || !binding?.token) return this.schedule(5000);

      const client = new WeixinClient({ baseUrl: binding.base_url, token: binding.token });
      const buf = await this.store.loadSyncBuf();
      const updates = await client.getUpdates(buf);
      if (updates.errcode === WEIXIN_SESSION_EXPIRED_ERRCODE) {
        await this.store.saveSettings({ ...settings, enabled: false });
        this.logger.warn("weixin session expired; bridge disabled");
        return this.schedule(30000);
      }
      if (typeof updates.get_updates_buf === "string") await this.store.saveSyncBuf(updates.get_updates_buf);
      await processWeixinUpdates({
        binding,
        messages: updates.msgs ?? [],
        routeText: async (text) => routeWeixinText({
          text,
          settings,
          sessions: this.sessions(),
          saveTargetSession: async (key) => {
            await this.store.saveSettings({ ...(await this.store.loadSettings()), target_session: key });
          },
        }),
        sendText: (to, text, contextToken) => client.sendTextMessage(to, text, contextToken),
      });
      return this.schedule(Math.max(1000, updates.longpolling_timeout_ms ?? 1000));
    } catch (err) {
      this.logger.warn("weixin poll failed", err);
      return this.schedule(5000);
    } finally {
      this.running = false;
    }
  }
}
