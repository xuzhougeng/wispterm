import type { RemoteSession } from "../../session.js";
import type { WeixinSettings } from "./types.js";

export type RoutedSession = { key: string; session: RemoteSession };
export type WeixinRouteInput = {
  text: string;
  settings: WeixinSettings;
  sessions: RoutedSession[];
  saveTargetSession?: (key: string) => Promise<void>;
};
export type WeixinRouteReply = { text: string };

export async function routeWeixinText(input: WeixinRouteInput): Promise<WeixinRouteReply> {
  const text = input.text.trim();
  if (!text) return { text: "" };

  const activeSessions = input.sessions.filter(({ session }) => session.isPhanttyConnected());
  const [cmd, arg] = splitCommand(text);
  if (cmd === "/help") return { text: helpText() };
  if (cmd === "/sessions") return { text: sessionsText(input.sessions) };
  if (cmd === "/status") return { text: statusText(input.settings, input.sessions) };
  if (cmd === "/use") return useSession(arg, input);

  const target = resolveTargetSession(input.settings, activeSessions);
  if (!target.session) return { text: target.error };

  if (cmd === "/term") return sendTerminal(target.session, arg, true);
  if (cmd === "/keys") return sendTerminal(target.session, arg, false);
  if (cmd === "/ai") return sendAi(target.session, arg);
  if (cmd.startsWith("/")) return { text: `未知命令：${cmd}\n\n${helpText()}` };
  return sendAi(target.session, text);
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
  if (sessions.length === 0) return { session: null, error: "当前没有在线的 Phantty Remote session。请先在 Phantty 中启用 remote 并连接到该后台。" };
  return { session: null, error: `当前有多个在线 session：\n${sessionsText(sessions)}\n\n请先发送 \`/use <session>\` 选择目标。` };
}

async function useSession(arg: string, input: WeixinRouteInput): Promise<WeixinRouteReply> {
  const key = arg.trim();
  if (!key) return { text: sessionsText(input.sessions) + "\n\n发送 `/use <完整 session>` 选择目标。" };
  const matched = input.sessions.find((candidate) => candidate.key === key);
  if (!matched) return { text: `未找到在线 session：${maskSessionKey(key)}。` };
  await input.saveTargetSession?.(key);
  return { text: `已选择 Remote session：${maskSessionKey(key)}` };
}

function sendAi(session: RemoteSession, text: string): WeixinRouteReply {
  const ai = session.findAiChatSurface();
  if (!ai) return { text: "当前 Remote session 没有 AI Chat tab。请先在 Phantty 打开 AI Chat，或使用 `/term <命令>` 显式发送到终端。" };
  if (!session.sendInput(ai.id, `${text}\r`)) return { text: "Phantty 当前离线，无法发送给 AI Agent。" };
  return { text: "已发送给 Phantty AI Agent，等待结果中。" };
}

function sendTerminal(session: RemoteSession, text: string, enter: boolean): WeixinRouteReply {
  const terminal = session.findDefaultWritableSurface();
  if (!terminal) return { text: "当前 Remote session 没有可写终端 surface。" };
  const payload = enter ? `${text}\r` : text;
  if (!session.sendInput(terminal.id, payload)) return { text: "Phantty 当前离线，无法发送到终端。" };
  return { text: `已发送到终端：${terminal.title}` };
}

function sessionsText(sessions: RoutedSession[]): string {
  if (sessions.length === 0) return "当前没有在线 Remote session。";
  return sessions.map(({ key, session }) => `- ${maskSessionKey(key)} ${session.isPhanttyConnected() ? "online" : "offline"}`).join("\n");
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
    "Phantty Weixin Bridge 命令：",
    "/status 查看状态",
    "/sessions 查看在线 Remote session",
    "/use <session> 选择目标 session",
    "/ai <内容> 发送给 AI Agent",
    "/term <命令> 显式发送到终端并回车",
    "/keys <文本> 显式发送原始文本到终端",
    "普通文本默认发送给 AI Agent。",
  ].join("\n");
}
