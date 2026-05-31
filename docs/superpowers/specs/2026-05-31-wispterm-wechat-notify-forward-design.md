# 设计：把 WispTerm 通知转发到已绑定的微信（A2 标记式）

> 状态：已通过 brainstorming 评审，待写实现计划。
> 日期：2026-05-31
> 范围：在「OSC 桌面通知（feature #1）」与「notify-setup skill（feature #2）」之上，新增 **feature #3：把 agent 通知额外转发到 WispTerm 已绑定的微信 owner**。复用 `src/weixin/` 既有 iLink 绑定与发送链路，不引入任何第三方中转服务（ServerChan / PushPlus 等）。

## 1. 背景与动机

`wispterm-notify-setup` skill 目前只让 Claude Code / Codex 在「完成 / 需确认」时弹一条 WispTerm 桌面通知（OSC 777 toast + 标题栏铃铛）。这要求人盯着屏幕。诉求是：人离开工位时，也能在**微信**上收到「任务完成 / 需要你操作」的主动通知。

微信对个人号没有开放推送 API，常规做法是接 ServerChan / PushPlus 等中转。但 WispTerm **本体已经内置了一套微信 iLink 直连**（`src/weixin/`，扫码登录 → 绑定 owner → 双向收发）。因此本设计直接**复用这套已绑定的微信通道**：不注册外部服务、不在 shell 里保管 token、跨平台可用。

## 2. 关键发现（已存在、可复用的基础设施）

- **微信发送原语已存在**：`src/weixin/ilink_client.zig:87` `sendText(to_user_id, text, context_token)` → POST `/ilink/bot/sendmessage`。poller 已在自有线程上用它给 owner 回消息——「给微信推一条」是已解决的能力，只是缺一个「通知触发」的接线。
- **绑定与 owner 已持久化**：`src/weixin/controller.zig` 持有活动 `ilink.Client`（base_url + bot_token）与绑定的 `owner`；App 全局 `App.weixin_controller`（`src/App.zig:92`），由 `weixin-direct-enabled` 配置开启（`src/App.zig:305`），状态落盘 `~/.config/wispterm/weixin.json`（0600，`src/weixin/state_store.zig`）。owner 来自首条入站消息 auto-bind，或被 `weixin-allowed-user` 钉死（`src/weixin/binding.zig:41` `ownerForBind`）。
- **通知解析/出队链路已存在**：notify 脚本发 OSC 777 → ghostty VT 核心解析成 `show_desktop_notification {title, body}` → `src/Surface.zig:140` `VtHandler.vt` 调 `notification.ingest()` 压入**每 surface** 的 `notif_queue` → 主线程在 `AppWindow.handleNotification`（`src/AppWindow.zig:3474`，调用点 `:4045`）出队 → `decideRoute` 决定 toast / badge / none。**转发分支正好挂在这里。**
- **主线程可达 controller**：`handleNotification` 是 UI 线程函数；UI 线程的 `g_app: ?*App`（`src/AppWindow.zig:308`，init 时 `:94` 赋值）可拿到 `App.weixin_controller`。`window_focused`（`src/AppWindow.zig` 全局）与 `is_active_surface`（出队点已在算）都现成。
- **ghostty OSC 777 文法约束（决定标记机制）**：`rxvt_extension.zig:30-37`——`777;notify;title;body` 中 `title` 取到**第二个 `;`**，而 **`body` = 其后的全部剩余字符串**（含任何后续 `;`）。所以**不能**简单加第 4 个 `;` 字段（会被并进 body、污染 toast）。且 WispTerm **只看 ghostty 解析后的 `{title, body}`**，看不到原始 OSC 字节（未知 OSC 被 ghostty 丢弃），故「私有 OSC 旁路」在不 fork 固定版 ghostty 的前提下不可行（feature #1 spec 已否决在原始字节流里识别）。

## 3. 已确认的设计决策

1. **方案 A2（标记式内部转发）**：WispTerm 内部把**带标记的** agent 通知转发给已绑定微信 owner，而非接第三方中转（A1=转发所有 OSC 777 被否；B=脚本自行 POST 被否：会在 shell 重写 iLink 协议 + 读 0600 密钥、易随 Zig 客户端漂移）。
2. **转发哪些事件**：**全部**——Claude Code `Stop` / Codex `agent-turn-complete`（完成）与 Claude Code `Notification`（需确认/输入）都转发。
3. **焦点门控**：**只在你没看着它时推**——`window_focused && is_active_surface` 为真时不推（你正盯着这个 pane，已经看到了），其余（窗口失焦 / 在别的 tab / 后台 surface）才推。镜像 feature #1 的 toast 抑制矩阵。
4. **标记机制：零宽标记藏进 body**。notify 脚本在 OSC 777 的 body 末尾追加一个 **U+200B（零宽空格）**；WispTerm 在 `ingest` 时检测并**剥离**它，置位 `forward_wechat`。零宽空格：① 过得了脚本 sanitize（不在被删字节集、非 `;`）；② 过得了 ghostty（可打印、无 `;`）；③ 在任何渲染器里不可见——即便某旧 WispTerm 还不剥离它，toast 也不露馅。**脚本保持「哑」：所有 agent 事件无条件加标记，是否真转发由 WispTerm 端策略决定。**（备选：显式可见标签如 `\u{200B}WT`，更直观但旧构建会露出 `WT`——否决，取纯零宽。）
5. **主动推送用空 `context_token`**：本通知是无来由的主动推送（非对某条入站消息的回复），`sendText(owner, text, "")`。`buildSendTextBody`（`ilink_codec.zig:33`）原样序列化，结构上成立；服务端是否接受空值列为运行期手验项。
6. **配置开关** `weixin-notify-forward: bool = false`（opt-in）。关 / 无绑定 / owner 未绑 → 静默跳过转发，完全不影响既有 toast/badge。

## 4. 架构与数据流

```
notify.sh (hook)  ──OSC 777;notify;<title>;<body>\u{200B}──▶  PTY (agent pane)
   ▶ ghostty 解析 ▶ VtHandler.vt(.show_desktop_notification {title, body})   [reader 线程]
        │  notification.ingest(): 检测并剥离尾部 \u{200B} → forward_wechat=true
        │  notif_queue.push(Item{ title, body(已净化), forward_wechat })
        ▼
   AppWindow.handleNotification(surface, is_active_surface)                    [主线程]
        │  既有：shouldDeliver → decideRoute → toast / badge（body 已无标记，显示干净）
        │  新增转发门控（与 toast/badge 相互独立）：
        │     item.forward_wechat
        │  && g_desktop... 无关；读 weixin-notify-forward == true
        │  && g_app.weixin_controller 存在且 has_token && has_owner
        │  && !(window_focused && is_active_surface)
        ▼
   controller.enqueueNotify(title, body)   ──拷贝入有界队列──▶  发送线程
        ▼
   ilink Client.sendText(owner, "<title>\n<body>", "")   → POST /ilink/bot/sendmessage
                                                            （失败仅 log，绝不影响 UI/agent）
```

要点：通知挂在 agent pane 对应的 surface 上，焦点门控天然用该 surface 的 active/focused 状态；微信 owner 是 App 全局唯一绑定，一人一微信，语义自洽。

## 5. 标记机制（细化）

- **notify 脚本侧**：现 `printf '\033]777;notify;%s;%s\007' "$title" "$body"`。改为在 body 之后、BEL 之前追加 `\u{200B}`（UTF-8 字节 `E2 80 8B`）。标记在 `sanitize` **之后**追加，长度上限照旧（标记本身极短，可忽略或并入截断预算）。脚本所有事件路径（Stop / Notification / Codex）都加。
- **WispTerm 侧**：`notification.ingest` / `makeItem` 在拷贝 body 前，若 body 以 `\u{200B}` 结尾则剥离该 3 字节并置 `Item.forward_wechat = true`；否则 `false`。剥离发生在入队前 → `contentHash(title, body)` 去重基于净化后的 body，稳定；toast / 微信消息都拿到干净 body。

## 6. WispTerm 侧改动（Zig）

### 6.1 `src/notification.zig`
- `Item` 加字段 `forward_wechat: bool = false`。
- `makeItem(title, body)`：检测 body 尾部 `\u{200B}` → 剥离 + 置位（纯逻辑，可原生单测）。
- `ingest` 透传该位（仍是 `push(makeItem(...))`）。

### 6.2 `src/AppWindow.zig` `handleNotification`
- 在既有 `switch (route)` 之后（或并行）加转发判定。**注意**：转发与 `route`（toast/badge/none）**独立**——例如 `route==.none` 是因 `desktop-notifications=false` 或去重/限流；转发应遵循自己的门控（第 4 节）。实现期明确：转发是否也受 `shouldDeliver` 去重约束？**取「是」**——复用同一 `shouldDeliver` 结果做转发去重，避免快速重复推送轰炸微信/手机（与 toast 共用 last_notif 去重状态即可）。
- 门控：`item.forward_wechat && weixinForwardEnabled() && ctrl.has_token && ctrl.has_owner && !(window_focused && is_active_surface)` → `ctrl.enqueueNotify(item.title(), item.body())`。
- 取 controller：`if (g_app) |app| if (app.weixin_controller) |ctrl| ...`；`weixin-notify-forward` 经 `g_desktop_notifications` 同款 threadlocal 缓存或直接读 config 缓存（实现期与现有 config 取用点对齐）。

### 6.3 `src/weixin/controller.zig`
- 新增 `pub fn enqueueNotify(self: *Controller, title: []const u8, body: []const u8) void`：
  - **绝不在主线程做网络 I/O**。拷贝 `"<title>\n<body>"`（截断至合理上限）入一个互斥有界队列；由一个**轻量发送线程**消费（绑定激活时随 poller 一并启动 / 停止；poller 自身在长轮询 getupdates，不复用它做发送）。
  - 消费端调 `self.client.sendText(self.owner, msg, "")`；`owner.len==0` 时直接丢弃。
  - 失败（网络 / `IlinkSendMessageFailed`）只 `std.debug.print` log，不向上抛、不阻塞。
  - 队列满（如容量 8）丢最旧，语义同 `notification.Queue`。
- 生命周期：发送线程在 `startWithBinding` 起、`stop` / `destroy*` 停（与现有 `stopForProcessExit` 的「超时则 detach」策略一致，避免退出阻塞在网络上）。`Status` 可加 `forward_thread_active` 便于诊断（可选）。

### 6.4 `src/config.zig`
- 新增 `weixin-notify-forward: bool = false`，与其它 `weixin-*` 键并列解析（`:806` 一带），写进 `--help`（`:1235` 一带）。语义上依赖 `weixin-direct-enabled=true` 才有意义。

## 7. notify-setup skill 改动（feature #2 的延伸）

- `plugins/skills/wispterm-notify-setup/scripts/wispterm-notify.sh`：OSC 777 body 末尾追加 `\u{200B}` 标记。
- `plugins/skills/wispterm-notify-setup/scripts/test-install.sh`：更新 OSC 断言——既验「body 带零宽标记」，也（用与 WispTerm 一致的剥离逻辑描述）说明剥离后内容干净；保证既有 5 项 notify 断言不破。
- `plugins/skills/wispterm-notify-setup/SKILL.md`：新增「微信转发」一节：
  - 前置：WispTerm 构建含本特性；`weixin-direct-enabled=true`；扫码绑定；**给 bot 发过至少一条消息**以 auto-bind owner（或配 `weixin-allowed-user`）；`weixin-notify-forward=true`。
  - 验证：沿用既有 echo 测试触发一条通知，确认手机微信收到。
  - 说明：仅在 WispTerm 内、绑定激活、owner 已绑、且你没盯着该 pane 时才推。

## 8. 测试

- **纯逻辑单测**（`notification.zig`，注册进 `test_fast.zig`，原生跑）：
  - `makeItem`：body 带 / 不带尾部 `\u{200B}` → `forward_wechat` 置位且标记被剥离 / 不置位且 body 原样；标记 + 截断边界。
  - controller `enqueueNotify`：入队 / 满了丢最旧 / `owner==""` 丢弃（队列逻辑可与网络解耦单测）。
- **集成测试**（`test-full`）：把带 `\u{200B}` 标记的 OSC 777 字节喂进 VtStream / VtHandler，断言 `surface.notif_queue` 出现**干净** title/body 且 `forward_wechat==true`；不带标记则为 false。Linux 即可，不碰网络。
- **脚本测试**：`test-install.sh` 全绿（含新的标记断言）。
- **回归**：`zig build test` + `zig build test-full` 不破（基线绿）。
- **手验（无 live endpoint，无法自动化）**：真实绑定下，触发完成 / 需确认 → 手机微信收到、内容干净；焦点在该 pane 时不推；窗口失焦 / 切 tab 时推；`weixin-notify-forward=false` 不推；owner 未绑时静默不崩。

## 9. 风险与前置校验

- **微信 direct 整条链路「UNVERIFIED AT RUNTIME」**：`src/App.zig` / `src/AppWindow.zig:2264` 注释自述「cross-compiles，但未跑过，无 live WeChat」。本特性建立其上，发送链路（含空 `context_token` 是否被服务端接受）需运行期手验。
- **线程边界**：发送绝不能跑在主线程 / reader 线程；进程退出时发送线程要能被取消 / detach，复用 `ThreadControl` 既有策略。
- **owner 时序**：用户从未给 bot 发过消息 → owner 为空 → 转发静默跳过（非错误）。skill 文档须强调「先发一条消息」。
- **标记鲁棒性**：零宽标记作为布尔 flag 依赖 notify→ghostty→WispTerm 全链不被中间层吞掉；本仓自产自销（用户即 WispTerm 作者），可接受。

## 10. 范围边界（YAGNI / 本期不做）

- 第三方中转（ServerChan / PushPlus / 企业微信机器人）。
- 脚本侧自行 POST iLink（方案 B）。
- 本地 IPC 控制 socket / 私有 OSC 旁路（需 fork 固定版 ghostty）。
- 节流策略升级——复用既有 `shouldDeliver` 去重 / 限流。
- 「转发哪些事件」的细粒度配置——本期固定「全部」。
- 微信消息富文本 / 点击跳转 / 多 owner / 群发。

## 11. 影响文件一览（预估）

- 改 `src/notification.zig`（`Item.forward_wechat` + `makeItem` 剥离 + 单测）。
- 改 `src/AppWindow.zig`（`handleNotification` 转发分支 + 读配置 + 取 `g_app.weixin_controller`）。
- 改 `src/weixin/controller.zig`（`enqueueNotify` + 发送线程 + 生命周期 + 单测）。
- 改 `src/config.zig`（`weixin-notify-forward` 开关 + `--help`）。
- 改 `src/test_fast.zig` / `src/test_main.zig`（注册新单测 / 集成测试）。
- 改 `plugins/skills/wispterm-notify-setup/scripts/wispterm-notify.sh`（追加标记）。
- 改 `plugins/skills/wispterm-notify-setup/scripts/test-install.sh`（标记断言）。
- 改 `plugins/skills/wispterm-notify-setup/SKILL.md`（微信转发文档）。
