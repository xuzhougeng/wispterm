# 飞书 Channel 接入 Implementation Plan(M2 + M3-M4 概要)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task (fresh implementer + 两段式复审 per task). Steps use `- [ ]`.

**Goal:** 在已就位的 `chatops/` 中立核心之上,新增 `src/feishu/` 渠道,打通 p2p 文本闭环(M2),再加文件/卡片/群聊(M3)与接线收尾(M4)。

**Architecture:** `src/feishu/` 适配器:长连接接收侧把已验证的 spike(`src/feishu/spike/recv_event.zig` + `discover.zig`)**收编**为正式模块;入站事件经 `codec` 规范化 → `binding` 过滤 → `chatops.router.route(AppWindow.chatopsControl(), text, reply_ctx)` → 出站经 `feishu/rest` 发回。复用 `chatops/control.zig`(15 方法 vtable)、`chatops/router.zig`、`chatops/reply.zig`(`ReplyContext`/`AttachmentSender` sink)、共享 `chatops_bridge`。

**Tech Stack:** Zig 0.15.2;`std.http.Client`(自带 TLS;`.connect` 拿 TLS 流,`.fetch` 走 REST);**无第三方库**。

## Global Constraints

- **构建/测试**:快测 `zig build test`;**权威门 `zig build test-full -Dtarget=aarch64-macos`(必须带 target 才真跑;裸 test-full 仅编译)**;UI `zig build test-macos-ui`;裸 `zig build`=Windows。已知无关 flaky:`skill center tool import`(FileNotFound)。
- **长连接接收侧以 spike 为事实依据**:`src/feishu/spike/recv_event.zig`(pbbp2 编解码 + RFC6455 framing + 握手 + ping/pong + ACK + 6 单测,**已实连验证**)、`discover.zig`(token + 端点发现);协议笔记 `docs/superpowers/specs/feishu-longconn-protocol-notes.md`。坑:`std.http.Client.connect` 前必须 `client.ca_bundle.rescan(alloc)`。
- **复用 chatops,勿改其签名**:`chatops.router.route(allocator, ctrl: Control, raw_text, reply_context: ?reply.ReplyContext, out: *Reply)`;`AppWindow.chatopsControl()` 返回 `Control`;出站 sink = `chatops/reply.zig` 的 `AttachmentSender`(`send_attachment(ctx, kind, path, display_name, to_user_id, context_token)`)。
- **安全**:凭证(env `FEISHU_APP_ID`/`FEISHU_APP_SECRET` 或 config)与 token **绝不打印/落盘/提交**;wss query 含连接 token,日志/fixture 打码。
- **镜像 weixin 渠道结构**(集成契约见各任务“镜像”指引):Controller 由 App 持有、config 门控;onEvent→route→sendInput→applyChatInput;出站 reply sink。
- **不回归**:微信渠道继续工作;**不改**模型工具名 `weixin_send_attachment`(中立 sink 已自动按渠道路由)。
- 提交信息末尾:`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

## Scope / 分解

本文件 **M2 详细可执行**(p2p 文本闭环,一个可测试里程碑);**M3/M4 为概要**,待 M2 落地、`src/feishu/` 模块 API 定型后再出 bite-sized 详细计划(避免对未定型接口写虚构步骤)。

---

## M2 — 入站文本闭环(p2p 文本 → AI → 文本回)

依赖序:M2.1/M2.2/M2.3 可并行起步 → M2.4/M2.5/M2.6 → M2.7 → M2.8 → M2.E2E。每任务一 commit + 两段式复审。

### Task M2.1: `src/feishu/pbbp2.zig` — 收编 Frame 编解码
**Files:** Create `src/feishu/pbbp2.zig`(+ tests)。
**来源:** 把 `spike/recv_event.zig` 的 `Frame`/`Hdr`、`parseFrame`/`parseHeader`/`readVarint`/`readLenDelim`/`skipField`、`encodeFrame`/`append*`/`encodeHeader`、`buildPingFrame`/`buildAck` 抽成干净模块,**逐字搬实现**。
**Interface (Produces):** `pub const Frame`、`pub const Header`、`decode(arena, []const u8) !Frame`、`encode(arena, Frame) ![]u8`、`Frame.header(key) ?[]const u8`、`buildPing(arena, service_id: []const u8) ![]u8`、`buildAck(arena, recv: Frame) ![]u8`。
**Tests:** 搬 spike 的 3 个 pbbp2 单测(round-trip / ping / ack)。
- [ ] 搬实现 + 接口命名整理 → [ ] 搬单测 → [ ] `zig build test` 绿 → [ ] commit `feat(feishu): pbbp2 frame codec (harvested from M0 spike)`。

### Task M2.2: `src/feishu/ws.zig` — 收编 RFC6455 客户端 framing
**Files:** Create `src/feishu/ws.zig`(+ tests)。
**来源:** 搬 spike 的 `WsConn`(`writeBinary`/`readBinary`/`writePong`,掩码、长度编码、control 帧处理)+ `wsHandshake`(101 校验、读 `Handshake-Status`/`Handshake-Msg`)+ `takeOne`/`readLine`/`asciiHeaderIs`/`dupHeaderVal`/`parseWss`/`queryParam`/`stripQuery`。
**Interface:** `pub const Conn`(包 `*std.http.Client.Connection` + rng);`handshake(conn, host, path_query) !void`;`Conn.writeBinary([]const u8) !void`;`Conn.readBinary(arena) ![]u8`(内部处理 ping→pong、close→error.WsClosed);`parseWss(url) !WssUrl`、`queryParam`。
**Tests:** 搬 `parseWss` 测试;新增一个 frame mask/unmask round-trip 单测(对 `writeBinary` 产物用本地 unmask 校验 header+payload)。
- [ ] 搬实现 → [ ] 单测 → [ ] `zig build test` 绿 → [ ] commit `feat(feishu): RFC6455 websocket client framing (harvested)`。

### Task M2.3: `src/feishu/types.zig` — 飞书类型
**Files:** Create `src/feishu/types.zig`。
**Interface (Produces):** `Credentials{ app_id, app_secret }`;规范化入站 `IncomingMessage{ event_id, chat_id, sender_open_id, chat_type (enum p2p/group), message_type, text, message_id }`;解析用的 event/sender 子结构(供 codec)。
- [ ] 定义类型(参考协议笔记 §B `im.message.receive_v1` 字段)→ [ ] `zig build test` 绿 → [ ] commit `feat(feishu): channel types`。

### Task M2.4: `src/feishu/rest.zig` — REST(token/discovery/send/bot-info)
**Files:** Create `src/feishu/rest.zig`(+ tests for payload building / token-cache logic)。
**来源:** `discover.zig` 的 `httpsPost` + 端点发现;协议笔记 §1/§B 的 token + send。
**Interface:** `tenantAccessToken(alloc, creds) !{ token, expire_s }`;一个小 `TokenCache`(剩余 <30min 才刷新);`discoverWsEndpoint(alloc, creds) !{ url, ping_interval }`;`sendText(alloc, token, receive_id_type, receive_id, text) !void`(POST `im/v1/messages`,content=`{"text":..}` JSON 串);`getBotOpenId(alloc, token) ![]const u8`(GET `bot/v3/info`)。
**Tests:** payload JSON 构造 + TokenCache 刷新阈值逻辑(注入假时钟/假 expire,**不**打网络)。
- [ ] 实现 → [ ] 单测(离线)→ [ ] `zig build test` 绿 → [ ] commit `feat(feishu): REST client (token cache, discovery, send text)`。

### Task M2.5: `src/feishu/codec.zig` — 事件 ↔ 中立类型
**Files:** Create `src/feishu/codec.zig`(+ tests)。
**Interface:** `parseReceiveV1(arena, payload_json) !IncomingMessage`(取 header.event_id/event_type、event.message.{message_id,chat_id,chat_type,message_type,content},content 是 JSON 串需二次解析取 `text`;sender.sender_id.open_id);`buildTextContent(text) → []const u8`(给 rest.sendText 用)。
**来源:** spike `extractMessageText` 是糙版;这里用 `std.json` 正经解析。
**Tests:** 用 spike 测试里的 receive_v1 形状 JSON + 合成样本断言;待 M2.E2E 抓到真 `fixtures/02_event_data_frame.bin` 后补一条真帧解码断言。
- [ ] 实现 → [ ] 单测 → [ ] `zig build test` 绿 → [ ] commit `feat(feishu): event codec (receive_v1 -> IncomingMessage)`。

### Task M2.6: `src/feishu/binding.zig` + 状态持久化
**Files:** Create `src/feishu/binding.zig`、`src/feishu/state_store.zig`(+ tests)。
**Interface:** `shouldHandle(msg: IncomingMessage, cfg) bool` — **v1 仅 p2p**(群聊 @ 留 M3);非用户消息/回声过滤;可选 `allowed_user` allowlist;`event_id` 去重(最近 N 个 id 的 set,幂等)。`state_store`:持久化 binding + token 缓存 + 已见 event_id(JSON,镜像 `weixin/state_store.zig`)。
**Tests:** shouldHandle 各分支 + event_id 去重。
- [ ] 实现 → [ ] 单测 → [ ] `zig build test` 绿 → [ ] commit `feat(feishu): inbound filter + dedup + state store`。

### Task M2.7: `src/feishu/longconn.zig` — 长连接编排(生产版)
**Files:** Create `src/feishu/longconn.zig`。
**来源:** spike `recv_event.zig` 的 `main()` 流程提炼为可复用客户端。
**Interface:** `pub const Client`;`start(self, creds, on_event: *const fn(ctx, IncomingMessage) void, ctx) !void`(在调用线程或自起线程跑:discover→`std.http.Client.connect`+`ca_bundle.rescan`→`ws.handshake`→起 ping 周期(`ping_interval`)→读循环:`ws.readBinary`→`pbbp2.decode`→Data 帧则 `pbbp2.buildAck` 回 ACK + 调 `on_event`(payload 交 codec)→Control 帧记日志);`stop(self)`;断线 **重连 + backoff**(ClientConfig:nonce/interval/无限)。
**Tests:** 无法离线测真连;对“帧分发”逻辑(给定一串解码后的 Frame,Data→on_event+ack、ping→pong)写注入式单测。真连验证留 M2.E2E。
- [ ] 实现 → [ ] 注入式单测 → [ ] `zig build test` 绿 → [ ] commit `feat(feishu): long-connection client (discover/handshake/recv/ack/ping/reconnect)`。

### Task M2.8: `src/feishu/controller.zig` + reply sink + app 接线
**Files:** Create `src/feishu/controller.zig`;Modify `src/App.zig`(`startFeishu`)、`src/config.zig`(键)、`src/i18n.zig`(字符串)。镜像 `weixin/controller.zig` + `App.zig:374-390 startWeixin`。
**Interface/行为:** `Controller.create/start/stop/destroy`,App 持有,`feishu-enabled` 门控;start 起 `longconn` 线程;`on_event` 回调:`codec.parseReceiveV1` → `binding.shouldHandle` → 构造 `reply.ReplyContext{ sender=feishuSender, to_user_id=chat_id/open_id, context_token=… }` → `chatops.router.route(AppWindow.chatopsControl(), msg.text, reply_ctx, &reply)` → 用 `rest.sendText` 把 `reply.text` 发回飞书。**feishu reply sink** = 实现 `AttachmentSender.send_attachment`(v1:文本经 rest;文件留 M3)。config 键:`feishu-enabled`/`feishu-app-id`/`feishu-app-secret`/`feishu-allowed-user`。i18n:飞书状态/提示串。
**Tests:** 注入式:喂一个 IncomingMessage,mock Control + mock sender,断言 route 被调 + sender 收到回复(镜像 weixin agent 测试)。
- [ ] 实现 controller + sink → [ ] App/config/i18n 接线 → [ ] 注入式单测 → [ ] `zig build test-full -Dtarget=aarch64-macos` 绿 → [ ] commit `feat(feishu): controller + reply sink + app wiring`。

### Task M2.E2E: 真连闭环 + 抓 fixture②
**前置:** 用户配好飞书后台(长连接事件订阅、`im` 权限)+ 凭证在 env/config。
- [ ] 启用 `feishu-enabled` 跑 app;用户私聊 bot 一条文本 → 观察 AI 回复发回飞书。
- [ ] 抓 `fixtures/02_event_data_frame.bin`(真 event 帧),回填 M2.5 codec 真帧断言。
- [ ] 记录结果到 ledger。

---

## M3 概要(待 M2 后出详细计划;三块较独立,可 workflow 并行)
- `src/feishu/media.zig`:图片/文件上传(`im/v1/images|files` → key)+ 入站资源下载(`im/v1/messages/:id/resources/:key`);扩展 reply sink 的 `send_attachment` 走文件。
- `src/feishu/card.zig`:交互卡片构造 + `card.action.trigger`(走 `event` 帧)回调;approval/问题经 ReplySink 渲染为卡片按钮(spec §5:sink 上加可选 `presentApproval`/`presentQuestion`,默认回退文本,**不引入 ChannelCapabilities**)。longconn 的 on_event 增加 card.action 分发。
- 群聊 @:`binding` 放开 group + 比对 bot open_id(`mentions[].id.open_id == 自身`);`getBotOpenId` 启动时取一次。

## M4 概要(接线收尾)
- 重连硬化、token 失效重取、错误面向用户化;notify-forward(镜像 weixin)。
- 渠道显示名参数化:把 router/`chatops/control.zig` 里残留的“微信直连/WeChat”串改为按渠道传入(解决 M1 留下的 Minor)。
- 文档 + `feishu-enabled` 默认关 + 配置说明。
- spike 目录 `src/feishu/spike/` 收编完成后删除。

---

## Self-Review
- M2 各 spec 模块(§4.2 controller/longconn/pbbp2/ws/rest/codec/binding/state_store/types + reply sink)→ M2.1-M2.8 覆盖 ✓;文件/卡片/群聊明确归 M3 ✓;§6 应用配置前置 → M2.E2E 前置 ✓。
- 无占位符:harvest 任务指明 spike 来源;新逻辑任务给了接口与离线测试策略;真连相关诚实标注留 E2E。
- 类型一致:`IncomingMessage`/`Credentials`(M2.3)被 M2.5/M2.7/M2.8 一致引用;`reply.ReplyContext`/`AttachmentSender`/`chatops.router.route`/`chatopsControl()` 与 M1 落地的 API 对齐。
