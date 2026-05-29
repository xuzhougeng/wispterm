import {
  WEIXIN_BOT_TYPE,
  WEIXIN_CHANNEL_VERSION,
  WEIXIN_DEFAULT_BASE_URL,
  type WeixinGetUpdatesResponse,
  type WeixinQRCodeResponse,
  type WeixinQRCodeStatusResponse,
  type WeixinSendMessageResponse,
} from "./types.js";

export type WeixinClientOptions = {
  baseUrl?: string;
  token?: string;
  fetchImpl?: typeof fetch;
};

export class WeixinClient {
  private readonly baseUrl: string;
  private readonly token: string;
  private readonly fetchImpl: typeof fetch;

  constructor(options: WeixinClientOptions = {}) {
    this.baseUrl = (options.baseUrl || WEIXIN_DEFAULT_BASE_URL).replace(/\/+$/, "");
    this.token = options.token ?? "";
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  getBaseUrl(): string {
    return this.baseUrl;
  }

  async getQRCode(): Promise<WeixinQRCodeResponse> {
    const res = await this.fetchImpl(`${this.baseUrl}/ilink/bot/get_bot_qrcode?bot_type=${WEIXIN_BOT_TYPE}`, {
      headers: this.headers(),
    });
    return this.decodeJson<WeixinQRCodeResponse>(res, "get_bot_qrcode");
  }

  async getQRCodeStatus(qrcode: string): Promise<WeixinQRCodeStatusResponse> {
    const url = `${this.baseUrl}/ilink/bot/get_qrcode_status?qrcode=${encodeURIComponent(qrcode)}`;
    const res = await this.fetchImpl(url, { headers: this.headers({ "iLink-App-ClientVersion": "1" }) });
    return this.decodeJson<WeixinQRCodeStatusResponse>(res, "get_qrcode_status");
  }

  async getUpdates(buf: string): Promise<WeixinGetUpdatesResponse> {
    return this.post<WeixinGetUpdatesResponse>("/ilink/bot/getupdates", {
      get_updates_buf: buf,
      base_info: { channel_version: WEIXIN_CHANNEL_VERSION },
    });
  }

  async sendTextMessage(toUserId: string, text: string, contextToken = ""): Promise<void> {
    const result = await this.post<WeixinSendMessageResponse>("/ilink/bot/sendmessage", {
      msg: {
        to_user_id: toUserId,
        client_id: `wispterm-weixin-${Date.now()}-${Math.floor(Math.random() * 100000)}`,
        message_type: 2,
        message_state: 2,
        context_token: contextToken,
        item_list: [{ type: 1, text_item: { text } }],
      },
      base_info: { channel_version: WEIXIN_CHANNEL_VERSION },
    });
    if (result.ret !== undefined && result.ret !== 0) {
      throw new Error(`sendmessage ret=${result.ret} errcode=${result.errcode ?? 0}: ${result.message ?? ""}`);
    }
  }

  private async post<T>(path: string, body: unknown): Promise<T> {
    const res = await this.fetchImpl(`${this.baseUrl}${path}`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(body),
    });
    return this.decodeJson<T>(res, path);
  }

  private headers(extraHeaders: Record<string, string> = {}): Record<string, string> {
    const headers: Record<string, string> = {
      "content-type": "application/json",
      AuthorizationType: "ilink_bot_token",
      "X-WECHAT-UIN": Buffer.from(String(Math.floor(Math.random() * 2 ** 32))).toString("base64"),
      ...extraHeaders,
    };
    if (this.token) headers.Authorization = `Bearer ${this.token}`;
    return headers;
  }

  private async decodeJson<T>(res: Response, label: string): Promise<T> {
    if (!res.ok) throw new Error(`iLink API ${label} returned ${res.status}`);
    return (await res.json()) as T;
  }
}
