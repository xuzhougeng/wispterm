# 飞书长连接协议笔记(M0 实测 + SDK 逆向)

> 来源:M0 spike(真连飞书测试租户)+ 官方 `larksuite/oapi-sdk-go` `v3_main/ws/` 生成代码。线协议无公开规范,**实现以此为事实依据**。状态:WSS+握手+ping/pong 已实连打通;pbbp2 解码器 6/6 离线单测过;真实 event 接收待一条真 DM 闭环。

## 1. REST 入口(已实测 ✅)

**tenant_access_token**:`POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal`,body `{"app_id":..,"app_secret":..}`,resp `{"code":0,"tenant_access_token":"t-..","expire":<秒,≈7200>}`。`Authorization: Bearer t-..`。剩余 <30min 才换新,本地缓存定时刷新。

**长连接端点发现**:`POST https://open.feishu.cn/callback/ws/endpoint`,body `{"AppID":..,"AppSecret":..}` —— **键名首字母大写**(SDK 约定;小写→514 AuthFailed)。resp `data.URL` = `wss://msg-frontier.feishu.cn/ws/v2?<query 含连接 token>`(**每次不同,勿硬编码,query 含敏感 token 勿落盘/打印**),`data.ClientConfig{ReconnectCount=-1, ReconnectInterval, ReconnectNonce, PingInterval}`(覆盖默认值)。错误码:`514`=AuthFailed、`1000040350`=ExceedConnLimit(每 app ≤50 连接)。

## 2. WSS 握手(已实测 ✅)

- 连 `data.URL`,**鉴权全在 URL query,不需要任何自定义 upgrade 头**。
- 成功 = 标准 WebSocket 升级 **HTTP 101**。
- 失败:读 HTTP 响应头 `Handshake-Status`(如 514)/ `Handshake-Autherrcode`(如 1000040350)。

## 3. pbbp2 Frame(protobuf,WS 二进制帧;字段号来自 SDK 生成代码)

```
Frame {
  1  SeqID            varint
  2  LogID            varint
  3  service          varint
  4  method           varint   // 0 = Control, 1 = Data
  5  headers          repeated Header   // message
  6  payload_encoding string
  7  payload_type     string
  8  payload          bytes
  9  LogIDNew         (string/varint, 见 SDK)
}
Header { 1 key: string; 2 value: string }
```

- 业务类型放在 **Header `type`**:`ping` / `pong` / `event` / `card`(注:SDK 里 `card` 帧保留未用;卡片回调实际走 `event` 帧 + `event_type==card.action.trigger`)。
- 大消息分片:Header `sum`(总片数)/`seq`(片序号)重组。
- **payload = 明文 JSON,无加密、无 gzip**(实测确认)。event 帧 payload 即 `im.message.receive_v1` 等事件 JSON。

## 4. ACK(必需,3 秒内)

收到 Data 帧后,沿同一条 WS 回写一个 response frame:**复用收到的 frame**,把 `payload` 换成 `{"code":200}`,并加 Header `biz_rt`(业务耗时)。

## 5. 心跳

客户端**主动发 ping**(Control 帧,周期 = `ClientConfig.PingInterval`),服务端回 `type=pong`(已实测收到 pong)。重连默认参数见 `ClientConfig`(`ReconnectCount=-1` 无限)。

## 6. Zig 实现路径(已实测,M2 据此实现)

- **无需第三方库**。最省力:`std.http.Client.connect(host, 443, .tls)` 拿到 TLS 连接,其 `.reader()/.writer()` 是透明 `std.Io` 流;在其上**手写 RFC6455 握手 + 帧编解码 + 手写 pbbp2 编解码**,合计约 **120 行**。
- ⚠️ **坑(已解)**:`std.http.Client.connect()` 不像 `.fetch()` 自动加载系统根证书 → 首连报 `TlsCertificateNotVerified`。修复:connect 前 `try client.ca_bundle.rescan(alloc);`(一行)。
- **Linux 重估**:既然走 std TLS(跨平台)而非平台原生 WS,**Linux 很可能也能跑**——与 spec §9 原先"Linux 不支持"的判断相反,M2 时验证后可能解除该限制。
- 复现:`FEISHU_APP_ID=.. FEISHU_APP_SECRET=.. zig run src/feishu/spike/recv_event.zig`;离线单测 `zig test src/feishu/spike/recv_event.zig`(6/6)。spike 代码在 worktree 分支 `worktree-agent-ae4c8fdd5326c35a6`(M2 时收编)。

## 7. 环境

- Zig **0.15.2**。`std.http.Client` 自带 TLS。
- HTTP 写法参考仓库现有 `src/weixin/ilink_client.zig`(`client.fetch` + `std.Io.Writer.Allocating`)。

## 8. CardKit 流式卡片（spike 实测确认,2026-06-28）

实测 `src/feishu/spike/cardkit.zig`,真凭证打通。鉴权统一 `Authorization: Bearer {tenant_access_token}`。

- **建卡**:`POST /open-apis/cardkit/v1/cards`,body `{"type":"card_json","data":"<卡片 JSON 2.0 字符串>"}`(注意 data 是**字符串化**的卡片 JSON,不是嵌套对象)→ `200 {"code":0,"data":{"card_id":"7656..."},...}`。
  - 卡片 JSON 2.0 实测可用最小形:`{"schema":"2.0","config":{"streaming_mode":true},"body":{"elements":[{"tag":"markdown","element_id":"md","content":"处理中…"}]}}`。
- **流式更新元素**:**`PUT`**(不是 POST!POST→404)`/open-apis/cardkit/v1/cards/:card_id/elements/:element_id/content`,body `{"content":"...","sequence":N}`(sequence 递增)→ `200 {"code":0,"data":{},...}`。
- **关流**:`PATCH /open-apis/cardkit/v1/cards/:card_id/settings`,body `{"settings":"{\"config\":{\"streaming_mode\":false}}","sequence":N}`→ `200 {"code":0,...}`。
- **限流**:单卡 10 次/秒;**流式模式 10 分钟自动关**;需飞书客户端 7.20+。
- **stream/close 不需要 chat_id**——打的是 card_id 实体;只有「把卡发到会话给人看」才需 chat_id。
- **待确认(非阻塞)**:把卡发到会话的 im 消息形状(`msg_type:"interactive"` + content 引用 card_id 的确切结构)。`GET /open-apis/im/v1/chats` 实测返回空(bot 不在任何群,p2p DM 不列出),spike 拿不到 chat_id。**运行时 onEvent 本就有 msg.chat_id**,故 send 形状在 Task 5 E2E 用真实 chat_id 自然验证。当前最佳猜测:content=`{"type":"card","data":{"card_id":"..."}}`。
- 复现:`source ~/.zshrc && zig run src/feishu/spike/cardkit.zig`(可选 `FEISHU_TEST_CHAT_ID=<id>` 触发 send+可视化)。**spike 打印含 token 的 TOKEN 响应已 redact**,勿存原始 token。
