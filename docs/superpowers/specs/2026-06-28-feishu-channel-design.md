# 飞书(Feishu)Channel 接入 — 设计文档

- **日期**: 2026-06-28
- **状态**: 设计已批准,待落实现计划(writing-plans)
- **关联**: issue [#404](https://github.com/xuzhougeng/wispterm/issues/404),分支 `feat/feishu-channel`
- **背景**: 微信(`src/weixin/`)channel 已存在并验证了"聊天入口远控 WispTerm"这一能力。本设计新增飞书作为**第二个** IM channel,复用现有远控能力(状态查询、会话切换、任务下发、审批、AI 进度回传、终端控制)。第二个渠道的出现使 #404 提出的"中立 chatops 核心 + 每渠道适配器"边界从推测变为有两个真实实现支撑的提取。

---

## 1. 目标与范围

**v1 = 完整版:**
- 文本消息收发(p2p 私聊 + 群聊 @ 机器人)
- 文件 / 图片收发
- 交互卡片(approval 用按钮,而非纯文本 Y/N)
- 复用现有命令面:`/ai` `/term` `/status` `/sessions` `/switch` `/stop` + approval/问题回复 + AI 进度 checkpoint

**非目标(v1 之外):**
- Linux 支持(无原生 WS/TLS 封装,见 §9)
- Go sidecar 方案(保留为 longconn 接口之后的备选,见 §2)
- `src/channels/` 目录统一(延后到第三个渠道)
- 商店应用(长连接仅自建应用可用)

---

## 2. 关键决策与被否方案

**传输 = 方案 A:纯 Zig 原生长连接(WebSocket)。**

- **理由**:WispTerm 的"单 Zig 二进制"产品特性;长连接是飞书官方为"无公网 URL 桌面端"明确推荐的方式,且**仅企业自建应用**可用;交互卡片/文件/群聊在长连接下全部可用(卡片按钮回调走同一条 WS,见附录 A §5)。
- **已知并接受的代价**:飞书长连接**线协议官方不公开**,需对照官方 Go/Python SDK 源码逆向实现(~800–1500 行,复杂度 ⭐⭐⭐,飞书改线协议时易碎)。
- **风险缓解**:协议代码关在 `feishu/longconn.zig` 接口之后(可单测、可替换);M0 先做真连 spike 验证;`pbbp2`/`codec` 用录制字节做单测;接口保留日后切换到 sidecar 的可能。

**被否方案:**
- **C(Go sidecar 跑官方 SDK 长连接 + 本地 IPC)**:工作量/风险最低,但引入 Go 静态二进制 + 子进程,破坏单二进制特性。**保留**为 `longconn` 接口之后的备选——若日后嫌原生维护成本高可同接口替换。
- **B(现有 remote 中继接 webhook)**:需中继在线、与远控功能耦合、且要改中继的单向消息模型;桌面端没连中继时收不到飞书事件。

**凭证**:已有自建应用 + 测试环境 → 可尽早做真连 spike 验证逆向协议。

---

## 3. 架构:共享 chatops 核心 + 每渠道适配器

```
                  ┌──────────────────────────┐
   微信 iLink ───▶│ src/weixin/  (已存在,基本不动) │─┐
                  └──────────────────────────┘ │
                  ┌──────────────────────────┐ │   ┌───────────────────────────────┐
   飞书长连接 ───▶│ src/feishu/  (新增)          │─┼──▶│ chatops 共享核心                  │
                  └──────────────────────────┘ │   │  router  (命令/approval/问题/进度)│
                                                │   │  reply   (中立 ReplyContext)      │
                                                │   │  chatops_bridge (Control vtable)  │
                                                │   └────────────────┬──────────────────┘
                                                │                    ▼
                                                └──────────▶  AI Session / 终端 surface
```

**原则**:飞书不重写控制面,只新增协议适配 + 复用渠道中立的 `Control` vtable(`src/weixin/control.zig` 的 15 方法,Step 0 后抬到中立位置)。

---

## 4. 组件

### 4.1 Step 0 基础改造(行为不变;因飞书是真正的第二调用者,提取才成立)

| 改动 | 说明 | 微信参照 |
|---|---|---|
| `src/chatops/reply.zig`(新) | 中立 `ReplyContext`/`QuestionReply`/`AttachmentSender`/`AttachmentKind`;`weixin/types.zig` 重导出以收窄 blast radius | `src/weixin/types.zig:89-173` |
| assistant 解耦 | `WeixinReplyContext`→`ReplyContext`、`applyWeixinInput`→`applyChatInput`、import 改指 `chatops/reply.zig` | `src/assistant/conversation/types.zig:224` / `session.zig:1647` |
| `src/chatops/router.zig`(从 `weixin/agent.zig` 抽出) | 渠道中立命令路由 + approval/问题解析 + AI 进度 | `src/weixin/agent.zig:80-255` |
| `src/appwindow/chatops_bridge.zig`(从 `weixin_bridge.zig` 改名) | 共享 Control 实现 + UI 线程 marshal,两渠道共用;globals 本为 app 级,机械改名;thread-op `.weixin_control`→`.chatops_control` | `src/appwindow/weixin_bridge.zig` |

**不改**:`weixin-*` 配置键、i18n、**模型可见工具名 `weixin_send_attachment`**(`protocol.zig:774`)。ReplyContext 中立化后,该工具调用 `sender.sendAttachment` 已自动按渠道路由,只需放宽其描述措辞——避免改动 AI 工具契约。

`AttachmentKind.uploadMediaType()` 是 weixin 专属方法,留在 weixin 侧或飞书忽略。

### 4.2 新建 `src/feishu/`(镜像 weixin 文件拆分,平级目录)

| 文件 | 职责 | 镜像 |
|---|---|---|
| `controller.zig` | 生命周期(create/start/stop/destroy),App 持有,`feishu-enabled` 门控;起线程跑 longconn,onEvent → 规范化 → 路由 | `weixin/controller.zig` |
| `longconn.zig` | **★硬骨头★** 端点发现 → WSS → pbbp2 帧 → 握手 → 3秒 ACK → 心跳 120s → 重连 → 分片重组 → payload 解密。接口:`start(creds, onEvent)` | (无,新协议) |
| `pbbp2.zig` | 手写 protobuf `Frame` 编解码(就一个 message),对照 Go/Python SDK 源码;录制字节单测 | (无) |
| `ws_transport.zig` | 把现有原生 WS(NSURLSession/WinHttp)泛化成可连**任意 wss + 自定义头**;Linux v1 不支持 | `platform/remote_transport_*.zig` |
| `rest.zig` | `tenant_access_token` 取/缓存/刷新、发消息(text/post/card)、上传图片文件、下载消息资源、取 bot open_id | `weixin/ilink_client.zig` |
| `codec.zig` | 事件 JSON ↔ 中立类型(`im.message.receive_v1` / `card.action.trigger`;构造发送 payload) | `weixin/ilink_codec.zig` |
| `binding.zig` | 过滤/鉴权:p2p allowlist、群聊比对 bot open_id 判 @、owner 绑定 | `weixin/binding.zig` |
| `state_store.zig` | 持久化凭证/绑定/token 缓存 + `event_id` 去重 | `weixin/state_store.zig` |
| `media.zig` / `media_inbound.zig` | 文件/图片上传 + 入站下载(REST) | `weixin/media*.zig` |
| `card.zig` | 交互卡片构造 + `card.action.trigger` 回调处理(approval 用按钮) | (无) |
| `types.zig` | 飞书专属类型(事件、消息内容、卡片 payload) | `weixin/types.zig` |

注:飞书是**推送**不是轮询,故**无** `poller.zig`——`controller` 起线程跑 `longconn`,其 `onEvent` 回调驱动后续。

---

## 5. 数据流

**入站:**
```
longconn(线程) → pbbp2 帧 → 解密 → JSON 事件
  → codec 规范化 → binding.shouldHandle(p2p 放行 / 群聊比对 bot open_id)
  →(有媒体则 rest 下载存盘转文本提示)
  → chatops.router.route(control, text, reply_context{飞书 sink})
  → control.sendInput(ai_surface, text, reply_context)   [共享 bridge → UI 线程]
  → session.applyChatInput(...)
  → 3 秒内回 ACK 帧(入队即 ACK;event_id 去重保幂等)
```

**出站:**
```
AI 文本 / 调 send_attachment 工具 → reply_context.sender(飞书 sink)→ rest.sendMessage / uploadFile+sendMessage
AI 进度 checkpoint / approval(卡片按钮)/ 问题选择 → chatops.router(共享)→ 飞书 sink
```

> **approval/问题的渲染下放到渠道 ReplySink**:router 只产出抽象的 approval/question 请求,由各渠道 sink 决定呈现——微信渲染为文本 Y/N,飞书渲染为交互卡片按钮。sink 上加一个可选 `presentApproval`/`presentQuestion` 方法(默认回退纯文本),**不引入 ChannelCapabilities 矩阵**(YAGNI;真出现第三种渲染差异时再抽)。

---

## 6. 飞书应用配置前置(用户在飞书开放平台后台完成)

- 应用类型:**企业自建应用**
- 事件订阅模式:**长连接**
- 订阅事件:`im.message.receive_v1`
- 卡片回调:启用**「卡片回传交互」(新)**,**不要**用旧版「消息卡片回传交互(webhook)」
- 权限 scope:`im:message`(收发)、`im:message.p2p_msg`(私聊收)、`im:message.group_at_msg`(群聊收 @)或 `im:message.group_msg`(群全量,敏感需审批)、`im:resource`(文件)、获取机器人信息
- 取 bot 自身 open_id(用于群聊 @ 判定):`GET /open-apis/bot/v3/info`

---

## 7. 风险隔离与测试

- **逆向协议风险** → **M0 先做连接 spike**:真连测试租户,收到并解码一条 `im.message.receive_v1` 打日志,先证通"端点发现 + WSS + 握手 + 帧解码 + 解密",再铺其余。
- **单测**:`pbbp2` 对录制帧字节、`codec` 对录制事件样本、`rest` payload 构造、`binding` @ 比对逻辑。
- **集成**:规范化事件 → mock `Control` → 断言 `sendInput` 被调(镜像 weixin 测试)。
- **E2E**:测试租户私聊发消息 → WispTerm AI 回到飞书。

---

## 8. 里程碑(先杀风险)

| | 内容 | 备注 |
|---|---|---|
| **M0** | 长连接 spike:真连飞书收一条消息解码打日志;**并验证飞书 wss 握手是否需要自定义 upgrade 头** | 杀掉最大未知数(见 §9) |
| **M1** | Step 0 基础:中立类型搬迁 + assistant 改名 + bridge 泛化 + 抽 router | 行为不变,weixin 测试保绿 |
| **M2** | 入站文本闭环:controller + longconn + codec + binding + rest token/send | p2p 文本进 → AI → 文本回 |
| **M3** | 完整版:文件收发 + 交互卡片(approval 按钮)+ 群聊 @ | 三块较独立,**workflow 并行实现** |
| **M4** | 接线收尾:config / i18n / 持久化 / 重连硬化 / notify-forward | |

dynamic workflow 主要用在 M3(三块独立模块并行写 + 逐块验证),M2 的 longconn/codec/rest/binding 也可在 M1 后并行。

---

## 9. 待办 / 延后 / 不确定

- **Linux**:无原生 WS/TLS 封装,v1 不支持(`remote_transport_unsupported.zig`)。
- **`channels/` 目录统一**:延后到第三个渠道。
- **sidecar 备选**:保留在 `longconn` 接口之后,同接口可替换。
- **需实测确认的不确定项**:
  - Lark 国际版卡片回调是否经 WS 下发(Feishu 已文档化支持;Lark 文档更保守)。
  - 收侧 `@_all`(@所有人)占位符官方未文档化——用"匹配 bot 自身 open_id"规避,不假设 `@_all`。
  - **原生 WS 能否满足**:飞书 wss 若需在 upgrade 阶段加自定义头,macOS `NSURLSessionWebSocketTask` / Windows WinHttp 的现有封装可能加不了 → 则 `ws_transport` 需退到裸 TCP+TLS WS(工作量显著上升)。由 M0 验证。
- **长连接线协议全部源自 SDK 源码,非公开规范**,实现以 `oapi-sdk-go` / `oapi-sdk-python` 源码为准。

---

## 附录 A:飞书长连接协议要点(逆向自 oapi-sdk-go / oapi-sdk-python)

> 官方文档只讲"集成 SDK + 3 秒处理 + 50 连接上限",不公布 frame/握手/ACK 格式。以下来自 SDK 源码,二者实现一致。

1. **端点发现(先 HTTP 后 WSS)**:`POST {domain}/callback/ws/endpoint`,body `{"AppID":..., "AppSecret":...}`,响应 `data.URL` 是**动态 `wss://` 地址(每次不同,勿硬编码)**,并下发 `ClientConfig`(覆盖重连/心跳默认)。错误码:`AuthFailed=514`、`ExceedConnLimit=1000040350`(对应每 app 50 连接上限)。
2. **鉴权握手**:鉴权在上面 HTTP POST 完成;WSS 握手结果经 frame header `Handshake-Status` / `Handshake-Autherrcode` 回传。
3. **Frame = Protobuf**(`pbbp2.Frame`,WS 二进制帧)。字段:`SeqID`、`service`、`method`(`Control=0`/`Data=1`)、`headers`(key/value)、`payload`。业务类型在 header `type`:`ping`/`pong`/`event`/`card`。`sum`/`seq` header 用于大消息分片重组。payload 加解密由 SDK 自动(自实现需对照源码确认算法)。
4. **ACK(必需)**:收到 Data 帧后必须沿同一条 WS 回写 response frame(`NewResponseByCode(200)` 进 payload,header 加 `biz_rt`)。对应"3 秒内处理"。
5. **心跳**:客户端**主动发 ping**(Control 帧),默认 **120s**(可被 `ClientConfig.PingInterval` 覆盖);服务端回 `type=pong`。
6. **重连**:默认开启;`reconnectNonce=30`(首连前 0–30s 抖动)、`reconnectInterval=120s`、`reconnectCount=-1`(无限)。
7. **卡片按钮回调(无需公网端点)**:走 `event` 帧、`header.event_type == "card.action.trigger"`(注意:SDK 里的 `card` 帧是 no-op 保留)。处理器同步返回的响应经同一 WS 写回(3 秒内);也可仅快速 ACK,卡片更新后续用 `event.token` + 消息更新 REST 异步做。**必须订阅「新」卡片回传交互**。
8. **官方 SDK 无 Zig/Rust/C**,仅 Go/Python/Java/Node(Node 标 DEPRECATED)。逆向以 `github.com/larksuite/oapi-sdk-go`(`ws/` 包:client.go + pbbp2 + const)与 `oapi-sdk-python` 为准。

**文档**:长连接配置 https://open.feishu.cn/document/event-subscription-guide/event-subscription-configure-/request-url-configuration-case · SDK 列表 https://open.feishu.cn/document/server-docs/server-side-sdk

---

## 附录 B:飞书 REST 要点

- **Token**:`POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal`,body `{"app_id","app_secret"}`,响应 `{"code":0,"tenant_access_token":"t-...","expire":7200}`(秒,最长 2h)。**剩余 < 30min 才返回新 token**,须本地缓存定时刷新,勿每次调用都换。携带:`Authorization: Bearer t-xxxx`。
- **接收事件** `im.message.receive_v1`:`header.event_id`(幂等去重)、`message.message_id`(om_)、`chat_id`(oc_)、`sender.sender_id.open_id`(ou_)、`chat_type`(`p2p`/`group`)、`message_type`、`content`(**JSON 字符串需二次解析**,text 形如 `{"text":"@_user_1 hello"}`)、`mentions[]`。
- **发送** `POST .../im/v1/messages?receive_id_type=open_id|chat_id|...`,body `{receive_id, msg_type, content(JSON 字符串), uuid?}`。三种 payload:text `{"text":"..."}`、post 富文本(行数组 → 行内节点)、interactive 卡片(`msg_type=interactive`,无独立发卡端点)。
- **文件**:上传图片 `POST .../im/v1/images`(≤10MB)→ `image_key`;文件 `POST .../im/v1/files`(≤30MB)→ `file_key`。下载**收到的**资源:`GET .../im/v1/messages/:message_id/resources/:file_key?type=image|file`(≤100MB,key 与 message_id 必须匹配)。
- **群聊 @**:`mentions[i]` 的 `key`=`@_user_N` 对应 `content.text` 占位符;比对 `mentions[i].id.open_id == bot open_id` 判"是否 @ 我"(无现成布尔字段)。

**文档**:接收 https://open.feishu.cn/document/server-docs/im-v1/message/events/receive · 发送 https://open.feishu.cn/document/server-docs/im-v1/message/create · Token https://open.feishu.cn/document/server-docs/authentication-management/access-token/tenant_access_token_internal · 卡片回调 https://open.feishu.cn/document/feishu-cards/card-callback-communication
