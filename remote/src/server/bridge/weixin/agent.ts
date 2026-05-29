import type { RemoteSession } from "../../session.js";
import type { WeixinSettings } from "./types.js";

export type RoutedSession = { key: string; session: RemoteSession };
export type WeixinRouteInput = {
  text: string;
  settings: WeixinSettings;
  sessions: RoutedSession[];
  saveTargetSession?: (key: string) => Promise<void>;
  aiAgentOpenTimeoutMs?: number;
};
export type WeixinAiFollowup = {
  session: RemoteSession;
  baselineTranscript: string;
};
export type WeixinRouteReply = {
  text: string;
  ai?: WeixinAiFollowup;
};

const AI_AGENT_OPEN_TIMEOUT_MS = 2000;
const AI_ACK_TEXT = "信息已收到，开始处理。\n发送 /stop 可停止本次处理。";
const ESC = "\x1b";
let nextAiAgentOpenSeq = 0;

export async function routeWeixinText(input: WeixinRouteInput): Promise<WeixinRouteReply> {
  const text = input.text.trim();
  if (!text) return { text: "" };
  if (isPing(text)) return { text: "pong" };

  const activeSessions = input.sessions.filter(({ session }) => session.isWispTermConnected());
  const [cmd, arg] = splitCommand(text);
  if (cmd === "/help") return { text: helpText() };
  if (cmd === "/sessions") return { text: sessionsText(input.sessions) };
  if (cmd === "/status") return { text: statusText(input.settings, activeSessions) };
  if (cmd === "/use") return useSession(arg, input, activeSessions);
  if (cmd && cmd !== "/term" && cmd !== "/keys" && cmd !== "/ai" && cmd !== "/stop") {
    return { text: `未知命令：${cmd}\n\n${helpText()}` };
  }
  if (cmd && cmd !== "/stop" && !arg) return { text: usageText(cmd) };

  const target = resolveTargetSession(input.settings, activeSessions);
  if (!target.session) return { text: target.error };

  if (cmd === "/stop") return stopAi(target.session);
  if (cmd === "/term") return sendTerminal(target.session, arg, true);
  if (cmd === "/keys") return sendTerminal(target.session, arg, false);
  if (cmd === "/ai") return sendAi(target.session, arg, input.aiAgentOpenTimeoutMs);
  return sendAi(target.session, text, input.aiAgentOpenTimeoutMs);
}

export function maskSessionKey(key: string): string {
  const trimmed = key.trim();
  if (trimmed.length <= 4) return `${trimmed}****`;
  return `${trimmed.slice(0, 4)}****`;
}

function splitCommand(text: string): [string, string] {
  const normalized = text.startsWith("／") ? `/${text.slice(1)}` : text;
  if (!normalized.startsWith("/")) return ["", normalized];
  const [command, ...rest] = normalized.split(/\s+/);
  return [command.toLowerCase(), rest.join(" ").trim()];
}

function resolveTargetSession(settings: WeixinSettings, sessions: RoutedSession[]): { session: RemoteSession | null; error: string } {
  const configured = settings.target_session.trim();
  if (configured) {
    const matched = sessions.find((candidate) => candidate.key === configured);
    if (!matched) return { session: null, error: `目标 Remote session 不在线：${maskSessionKey(configured)}。发送 /sessions 查看在线会话。` };
    return { session: matched.session, error: "" };
  }
  if (sessions.length === 1) return { session: sessions[0].session, error: "" };
  if (sessions.length === 0) return { session: null, error: "当前没有在线的 WispTerm Remote session。请先在 WispTerm 中启用 remote 并连接到该后台。" };
  return { session: null, error: `当前有多个在线 session：\n${sessionsText(sessions)}\n\n请先发送 \`/use <编号>\` 选择目标。` };
}

async function useSession(arg: string, input: WeixinRouteInput, activeSessions: RoutedSession[]): Promise<WeixinRouteReply> {
  const selector = arg.trim();
  if (!selector) return { text: sessionsText(input.sessions) + "\n\n发送 `/use <编号>` 选择目标，例如 `/use 1`。" };

  const selected = findSelectedSession(selector, input.sessions);
  if (!selected.session) return { text: `未找到 session：${selected.label}。发送 /sessions 查看可选项。` };
  const matched = activeSessions.find((candidate) => candidate.key === selected.session?.key);
  if (!matched) return { text: `该 session 不在线：${selected.label}。发送 /sessions 查看在线 session。` };
  await input.saveTargetSession?.(matched.key);
  return { text: `已选择 Remote session：${selected.label}` };
}

function nextAiAgentOpenRequestId(): string {
  nextAiAgentOpenSeq = (nextAiAgentOpenSeq + 1) % Number.MAX_SAFE_INTEGER;
  return `weixin-ai-${Date.now().toString(36)}-${nextAiAgentOpenSeq}`;
}

async function sendAi(session: RemoteSession, text: string, timeoutMs = AI_AGENT_OPEN_TIMEOUT_MS): Promise<WeixinRouteReply> {
  const ai = session.findAiChatSurface();
  if (ai) return sendAiToSurface(session, ai, text);

  const result = await session.requestAiAgentOpen(nextAiAgentOpenRequestId(), timeoutMs);
  if (result === "no-profile") return { text: "WispTerm 尚未配置 AI Chat profile。请先在桌面端创建 AI Chat profile。" };
  if (result === "failed") return { text: "WispTerm 无法打开 AI Agent。请检查桌面端配置后重试。" };
  if (result === "offline") return { text: "WispTerm 当前离线，无法打开 AI Agent。" };
  if (result === "timeout") return { text: "已请求 WispTerm 打开 AI Agent，但未等到 AI Chat tab。请检查桌面端配置后重试。" };

  const openedAi = await waitForAiChatSurface(session, timeoutMs);
  if (!openedAi) {
    if (!session.isWispTermConnected()) return { text: "WispTerm 当前离线，无法打开 AI Agent。" };
    return { text: "已请求 WispTerm 打开 AI Agent，但未等到 AI Chat tab。请检查桌面端配置后重试。" };
  }
  return sendAiToSurface(session, openedAi, text);
}

function sendAiToSurface(session: RemoteSession, ai: { id: string; title: string }, text: string): WeixinRouteReply {
  const baselineTranscript = session.latestAiChatTranscript();
  if (!session.sendInput(ai.id, `${text}\r`)) return { text: "WispTerm 当前离线，无法发送给 AI Agent。" };
  return {
    text: AI_ACK_TEXT,
    ai: {
      session,
      baselineTranscript,
    },
  };
}

function stopAi(session: RemoteSession): WeixinRouteReply {
  const ai = session.findAiChatSurface();
  if (!ai) return { text: "当前没有 AI Agent 可停止。" };
  if (!session.sendInput(ai.id, ESC)) return { text: "WispTerm 当前离线，无法停止 AI Agent。" };
  return { text: "已发送停止指令。" };
}

async function waitForAiChatSurface(session: RemoteSession, timeoutMs: number): Promise<{ id: string; title: string } | null> {
  const existing = session.findAiChatSurface();
  if (existing) return existing;

  return await new Promise((resolve) => {
    let settled = false;
    let unsubscribe: () => void = () => {};
    let timer: ReturnType<typeof setTimeout>;

    const cleanup = (): void => {
      if (timer) clearTimeout(timer);
      unsubscribe();
    };

    const settle = (ai: { id: string; title: string } | null): void => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(ai);
    };

    const check = (): void => {
      const ai = session.findAiChatSurface();
      if (ai) settle(ai);
    };

    timer = setTimeout(() => settle(null), Math.max(0, timeoutMs));
    unsubscribe = session.onLayout(check);
    check();
  });
}

function sendTerminal(session: RemoteSession, text: string, enter: boolean): WeixinRouteReply {
  const terminal = session.findDefaultWritableSurface();
  if (!terminal) return { text: "当前 Remote session 没有可写终端 surface。" };
  const payload = enter ? `${text}\r` : text;
  if (!session.sendInput(terminal.id, payload)) return { text: "WispTerm 当前离线，无法发送到终端。" };
  return { text: `已发送到终端：${terminal.title}` };
}

function sessionsText(sessions: RoutedSession[]): string {
  if (sessions.length === 0) return "当前没有在线 Remote session。";
  return [
    "Remote session：",
    ...sessions.map(({ key, session }, index) => `${index + 1}. ${maskSessionKey(key)} ${session.isWispTermConnected() ? "online" : "offline"}`),
    "",
    "发送 `/use <编号>` 切换目标，例如 `/use 1`。",
  ].join("\n");
}

function findSelectedSession(selector: string, sessions: RoutedSession[]): { session: RoutedSession | null; label: string } {
  const index = parseSessionIndex(selector);
  if (index !== null) {
    const session = sessions[index - 1] ?? null;
    return { session, label: session ? `#${index} ${maskSessionKey(session.key)}` : `#${index}` };
  }

  const session = sessions.find((candidate) => candidate.key === selector) ?? null;
  return { session, label: session ? maskSessionKey(session.key) : maskSessionKey(selector) };
}

function parseSessionIndex(value: string): number | null {
  if (!/^[1-9]\d*$/.test(value)) return null;
  const index = Number(value);
  return Number.isSafeInteger(index) ? index : null;
}

function statusText(settings: WeixinSettings, sessions: RoutedSession[]): string {
  return [
    `微信桥接：${settings.enabled ? "已开启" : "已关闭"}`,
    `目标 session：${settings.target_session ? maskSessionKey(settings.target_session) : "未选择"}`,
    `在线 session：${sessions.length}`,
  ].join("\n");
}

function helpText(): string {
  return [
    "WispTerm Weixin Bridge 命令：",
    "/ping 验证微信绑定",
    "/status 查看状态",
    "/sessions 查看 Remote session",
    "/use <编号> 选择目标 session，也支持完整 session key",
    "/ai <内容> 发送给 AI Agent",
    "/stop 停止当前 AI Agent 处理",
    "/term <命令> 显式发送到终端并回车",
    "/keys <文本> 显式发送原始文本到终端",
    "普通文本默认发送给 AI Agent。",
  ].join("\n");
}

function isPing(text: string): boolean {
  const normalized = text.trim().toLowerCase();
  return normalized === "ping" || normalized === "/ping" || normalized === "／ping";
}

function usageText(cmd: string): string {
  if (cmd === "/term") return "用法：/term <命令>\n显式发送到终端并回车。";
  if (cmd === "/keys") return "用法：/keys <文本>\n显式发送原始文本到终端，不自动回车。";
  if (cmd === "/ai") return "用法：/ai <内容>\n发送给 AI Agent。";
  return helpText();
}
