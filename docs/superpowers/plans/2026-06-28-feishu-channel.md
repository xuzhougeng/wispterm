# 飞书 Channel 接入 Implementation Plan(M0 + M1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 WispTerm 新增飞书(Feishu)IM channel,先打通"协议可行性(M0 spike)"与"中立 chatops 基础重构(M1)"两块基石。

**Architecture:** 共享 chatops 核心(中立 `ReplyContext` + router + `Control` vtable + UI 桥)+ 每渠道适配器。飞书用纯 Zig 原生长连接(逆向自飞书官方 Go/Python SDK),关在 `src/feishu/longconn.zig` 接口之后。M1 把现有微信代码里渠道中立的部分抬到 `src/chatops/`,使飞书成为第二个真实调用者。

**Tech Stack:** Zig;`std.http.Client`(REST)、平台原生 WS(`platform/remote_transport_*`,M2 泛化);设计依据见 spec `docs/superpowers/specs/2026-06-28-feishu-channel-design.md`。

## Global Constraints

- **构建/测试命令(关键,来自项目约定)**:
  - 快测:`zig build test`
  - **全量原生 macOS 测试(weixin / assistant / ai_chat 测试在此二进制里):`zig build test-full -Dtarget=aarch64-macos`** —— 注意:**裸 `zig build test-full` 只编译不运行**这些测试,必须带 `-Dtarget=aarch64-macos` 才真正跑。
  - UI 测试:`zig build test-macos-ui`
  - 注意:默认 `zig build` 目标是 **Windows**。
- 镜像现有 `src/weixin/` 结构;复用 `src/weixin/control.zig` 的 `Control` vtable(15 方法,渠道中立)。
- **不改**模型可见工具名 `weixin_send_attachment`(`src/assistant/conversation/protocol.zig:774`);**不引入** `ChannelCapabilities` 矩阵。
- 长连接线协议**无公开规范**,一切以 `oapi-sdk-go`(`ws/` 包)/ `oapi-sdk-python` 源码为事实依据。
- Linux 暂不支持(无原生 WS/TLS 封装)。
- M1 全部任务**行为不变**:验收标准是现有测试套件保持绿色 + 微信功能不回归。

## Scope Check / 分解说明

本特性按里程碑分解为独立计划(技能 Scope Check 要求每个计划独立产出可测试成果):
- **本文件 = M0 + M1**,完全可确定、可执行。
- **M2(入站文本闭环)/ M3(文件+卡片+群聊)/ M4(接线收尾)** 的详细 TDD 计划**待 M0 完成后再写**——因为 M2 的 `longconn`/`pbbp2` 任务结构取决于 M0 实测出的帧格式、ACK 细节、以及"原生 WS 能否满足"(spec §9)。提前写只会是虚构。M2-M4 任务轮廓见文末 §M2-M4 Outline。

---

## M0 — 长连接可行性 Spike(discovery,杀掉最大未知数)

> **性质说明**:M0 是探索性 spike,不是红-绿 TDD——你在逆向一个无文档协议,断言对象在看到真实帧之前未知。每个任务以**具体动作 + 真连验证**收尾,并**产出供 M2 复用的 fixture 与协议笔记**。代码可写在 `src/feishu/spike/`(M2 转正后清理),允许糙。

### Task M0.1: 从官方 SDK 源码提炼协议事实

**Files:**
- Create: `docs/superpowers/specs/feishu-longconn-protocol-notes.md`(协议笔记,M2 实现的事实依据)

**Interfaces:**
- Produces: 协议笔记,含端点发现请求/响应、`pbbp2.Frame` proto 定义、method 常量(Control=0/Data=1)、header 键(`type`/`sum`/`seq`/`biz_rt`/`Handshake-Status`)、ping/pong、ACK response frame 构造、payload 是否加密及算法。

- [ ] **Step 1**: 获取并精读 `github.com/larksuite/oapi-sdk-go` 的 `ws/` 包(`client.go`、`pbbp2/`、`const.go`)与 `oapi-sdk-python` 对应实现。
- [ ] **Step 2**: 把以下逐项写进协议笔记(附 SDK 源码文件:行引用):
  - 端点发现:`POST {domain}/callback/ws/endpoint`,请求 body 字段,响应 `data.URL` / `ClientConfig` 字段,错误码(`AuthFailed=514`、`ExceedConnLimit=1000040350`)。
  - `pbbp2.Frame` 的字段与 wire 编号;`method` 取值;业务 header 键。
  - 收到 Data 帧后 ACK response frame 的精确构造(`NewResponseByCode(200)` 进 payload、`biz_rt` header)。
  - ping(Control 帧,默认 120s)/pong;重连默认值。
  - **payload 是否加密**:确认事件 payload 是明文 JSON 还是加密(若加密,记录算法/密钥来源)。
- [ ] **Step 3 (verify)**: 笔记中每条事实都能指到 SDK 源码具体位置;无"大概"。Commit 笔记。

### Task M0.2: Zig 实现 token + 端点发现

**Files:**
- Create: `src/feishu/spike/discover.zig`

**Interfaces:**
- Consumes: 飞书 `app_id`/`app_secret`(从环境变量或本地文件读,勿硬编码进源码)。
- Produces: `fn discoverWsUrl(alloc, app_id, app_secret) ![]const u8` 返回动态 `wss://` 地址。

- [ ] **Step 1**: 用 `std.http.Client` 实现 `POST /open-apis/auth/v3/tenant_access_token/internal`,解析 `tenant_access_token`。
- [ ] **Step 2**: 实现 `POST {domain}/callback/ws/endpoint`(body `{"AppID","AppSecret"}`),解析 `data.URL`。
- [ ] **Step 3 (verify)**: 一个 `main`/test 入口用**真实测试租户凭证**调用,**打印出 wss URL**。看到合法 `wss://...` = 凭证 + 端点发现通。
- [ ] **Step 4**: Commit spike。

### Task M0.3: 连上 WSS(回答"原生 WS 够不够")

**Files:**
- Create: `src/feishu/spike/ws_connect.zig`

- [ ] **Step 1**: 尝试用平台原生 WS 连 M0.2 拿到的 wss URL(macOS `NSURLSessionWebSocketTask` 路径,参照 `src/platform/remote_transport_macos.zig`)。
- [ ] **Step 2 (关键验证)**: 判断飞书 wss 握手**是否需要自定义 upgrade 头**(spec §9)。若原生封装加不了所需头 → 在笔记中标"需裸 TCP+TLS WS",并评估改动量。
- [ ] **Step 3 (verify)**: 连接建立、能收到原始二进制帧(哪怕还没解码)。日志打印收到的字节数/前若干字节。
- [ ] **Step 4**: Commit + 在协议笔记记录"原生 WS 是否可行"的结论。

### Task M0.4: 最小 pbbp2 解码 + 收到真实消息

**Files:**
- Create: `src/feishu/spike/frame_peek.zig`
- Create: `src/feishu/testdata/`(存抓到的真实帧字节,供 M2 单测 fixture)

- [ ] **Step 1**: 按 M0.1 笔记,最小实现 `pbbp2.Frame` 解码,足以区分 ping 帧与 event 帧、取出 header `type` 与 payload。
- [ ] **Step 2**: 实现"收到 Data 帧 → 回 ACK response 帧"(否则飞书判失败重投)。
- [ ] **Step 3**: 实现 ping 心跳(120s),维持连接。
- [ ] **Step 4 (verify)**: 从飞书测试租户给机器人**私聊发一条文本**;spike 在日志里**打印出解码后的事件 JSON(含 message content 文本)**。看到真实消息 = 端点发现+WSS+握手+帧解码+ACK 全通。
- [ ] **Step 5**: 把这次会话抓到的**原始帧字节存进 `src/feishu/testdata/`**(endpoint 发现响应、一个 event 帧、一个 ping 帧),作为 M2 `pbbp2`/`codec` 单测 fixture。
- [ ] **Step 6**: Commit。

### Task M0.5: 收口 — 更新 spec,解锁 M2 规划

- [ ] **Step 1**: 用 M0 实测结论回填 spec §9 不确定项(原生 WS 结论、payload 加密与否、Lark 暂不验)。
- [ ] **Step 2**: 在协议笔记给出 M2 `longconn`/`pbbp2`/`ws_transport` 的最终接口形状建议。
- [ ] **Step 3 (gate)**: M0 完成 = 协议可行性已证 + fixture 已抓 + 接口已定。**此时回到 writing-plans 产出 M2-M4 详细计划。**

---

## M1 — Step 0 基础重构(行为不变,可与 M0 并行)

> 全部任务验收 = `zig build test-full -Dtarget=aarch64-macos` 与 `zig build test` 绿、微信功能不回归。每个任务一个 commit。

### Task M1.1: 抽出中立 reply 类型

**Files:**
- Create: `src/chatops/reply.zig`
- Modify: `src/weixin/types.zig`(改为重导出,见 Step 3)
- Modify: `src/weixin/ilink_codec.zig` 或 `media.zig`(承接 weixin 专属 `uploadMediaType`)

**Interfaces:**
- Produces: `chatops.reply.{ReplyContext, QuestionReply, AttachmentSender, AttachmentKind}` —— 签名与现 `weixin/types.zig` 同名类型完全一致(供 M1.2 及 M2 飞书 sink 复用)。

- [ ] **Step 1**: 创建 `src/chatops/reply.zig`,把这四个**渠道中立**类型从 `weixin/types.zig` 整体搬过来(逐字保留字段与方法):

```zig
const std = @import("std");

pub const AttachmentKind = enum {
    file,
    image,
    voice,
    pub fn parse(s: []const u8) ?AttachmentKind { /* 原 weixin/types.zig 实现逐字搬来 */ }
    pub fn name(self: AttachmentKind) []const u8 { /* 同上 */ }
    // 注意:weixin 专属的 uploadMediaType() 不要搬来,改放 weixin 侧(见 Step 2)
};

pub const AttachmentSender = struct {
    ctx: *anyopaque,
    send_attachment: *const fn (ctx: *anyopaque, kind: AttachmentKind, path: []const u8, display_name: []const u8, to_user_id: []const u8, context_token: []const u8) anyerror!void,
    pub fn sendAttachment(self: AttachmentSender, kind: AttachmentKind, path: []const u8, display_name: []const u8, to_user_id: []const u8, context_token: []const u8) !void {
        return self.send_attachment(self.ctx, kind, path, display_name, to_user_id, context_token);
    }
};

pub const ReplyContext = struct {
    sender: AttachmentSender,
    to_user_id: []const u8,
    context_token: []const u8,
    model_context: []const u8 = "",
};

pub const QuestionReply = union(enum) {
    option: usize,
    custom: []const u8,
    ignore,
};
```

- [ ] **Step 2**: 把 weixin 专属的 `AttachmentKind.uploadMediaType()`(返回 1/3 的飞书无关 media 类型)改成 weixin 侧自由函数,如 `weixin.uploadMediaTypeFor(kind: chatops.AttachmentKind) i64`,更新其调用点(`ilink_client.zig` 上传处)。
- [ ] **Step 3**: 把 `weixin/types.zig` 里这四个类型改为重导出:

```zig
const reply = @import("../chatops/reply.zig");
pub const AttachmentKind = reply.AttachmentKind;
pub const AttachmentSender = reply.AttachmentSender;
pub const ReplyContext = reply.ReplyContext;
pub const QuestionReply = reply.QuestionReply;
```
(其余 weixin 专属类型 `Message`/`GetUpdatesResult`/`QrCode`/`Settings`/`Binding` 等留在原处。把原本针对这四类型的单测一并迁到 `chatops/reply.zig`。)

- [ ] **Step 4 (verify)**: `zig build test-full -Dtarget=aarch64-macos` 绿。
- [ ] **Step 5**: Commit `refactor(chatops): extract channel-neutral reply types`。

### Task M1.2: assistant 与渠道解耦改名

**Files:**
- Modify: `src/assistant/conversation/types.zig`(`:5` import、`:224` `WeixinReplyContext`、`:308` `weixin_reply_context`)
- Modify: `src/assistant/conversation/session.zig`(`:30` import、`:1647` `applyWeixinInput`、`pending_weixin_reply_context` 等)
- Modify: `src/assistant/conversation/request.zig`(若引用)
- Modify: 调用方 `src/appwindow/weixin_bridge.zig:198`(`session.applyWeixinInput` 调用)

**Interfaces:**
- Consumes: `chatops.reply.ReplyContext`(M1.1)。
- Produces: `Session.applyChatInput(self, data, ctx: chatops.reply.ReplyContext) bool`;`ChatRequest`/`ToolContext` 字段 `reply_context`。

- [ ] **Step 1**: import 改指 `../../chatops/reply.zig`;标识符改名(机械,全量):
  - `WeixinReplyContext` → `ReplyContext`
  - `applyWeixinInput` → `applyChatInput`
  - `pending_weixin_reply_context` → `pending_reply_context`;`clearPendingWeixinReplyContextLocked` → `clearPendingReplyContextLocked`
  - `weixin_reply_context`(字段)→ `reply_context`
- [ ] **Step 2**: 更新调用方 `weixin_bridge.zig` 改调 `applyChatInput`。
- [ ] **Step 3 (verify)**: `zig build test-full -Dtarget=aarch64-macos` 绿(含 `protocol.zig:1539` 那条工具 schema 测试——工具名 `weixin_send_attachment` 不变,该测试应仍过)。
- [ ] **Step 4**: Commit `refactor(assistant): decouple reply context from weixin`。

### Task M1.3: 抽出渠道中立 router

**Files:**
- Create: `src/chatops/router.zig`(从 `src/weixin/agent.zig:80-255` 抽渠道中立逻辑)
- Modify: `src/weixin/agent.zig`(改为薄 shim 转调 `chatops.router`,或直接让 poller 调 `chatops.router`)
- Modify: `src/weixin/poller.zig:338-370`(`routeAdapter` 改调 `chatops.router.route`)

**Interfaces:**
- Consumes: `weixin/control.zig` 的 `Control`、`chatops.reply.ReplyContext`。
- Produces: `chatops.router.route(alloc, control: Control, settings, text, reply_context: ReplyContext, out: *Reply) !void` 与 `sendAi(...)` —— 签名沿用现 `agent.zig`(`route`/`sendAi`/approval/question/progress 一并搬)。

- [ ] **Step 1**: 把 `agent.zig` 的命令解析(`/ai /term /status /sessions /switch /stop`)、approval/question 识别、AI 进度判定整体移到 `chatops/router.zig`;这些已不含微信专属逻辑(只依赖 `Control` + `ReplyContext`)。
- [ ] **Step 2**: `weixin/agent.zig` 保留为转调 shim(或删除并让 `poller.zig` 直接调 `chatops.router`,取更少代码者)。
- [ ] **Step 3**: 迁移 `agent.zig` 的相关单测到 `chatops/router.zig`。
- [ ] **Step 4 (verify)**: `zig build test-full -Dtarget=aarch64-macos` 绿;微信路由测试通过。
- [ ] **Step 5**: Commit `refactor(chatops): extract channel-neutral command router`。

### Task M1.4: 泛化 bridge 为 chatops_bridge(两渠道共用)

**Files:**
- Rename: `src/appwindow/weixin_bridge.zig` → `src/appwindow/chatops_bridge.zig`
- Modify: `src/appwindow/thread_message.zig`(`.weixin_control` → `.chatops_control`)
- Modify: `src/AppWindow.zig`(`:5210` 消息泵分支、`:4987` `weixinControl()` 导出)
- Modify: `src/App.zig:384`(传入 Control 处)

**Interfaces:**
- Produces: `chatops_bridge.control() Control`(原 `weixin_bridge.control()`),经 `AppWindow.chatopsControl()` 暴露;两个渠道 controller 共用同一 Control。

- [ ] **Step 1**: 文件改名;内部标识符机械改名:`g_weixin_ui_handle`→`g_chatops_ui_handle`、`g_weixin_pinned_session`→`g_chatops_pinned_session`、`g_weixin_transcript_*`→`g_chatops_transcript_*`、`weixin_vtable`→`chatops_vtable`、`wx*` 函数名按需(或保留,内部细节)。
- [ ] **Step 2**: `thread_message.zig` 的 op tag `.weixin_control`→`.chatops_control`;`AppWindow.zig` 泵分支同步。
- [ ] **Step 3**: `AppWindow.weixinControl()` → `chatopsControl()`;`App.zig` 调用点同步(`startWeixin` 仍调它拿 Control)。
- [ ] **Step 4 (verify)**: `zig build test-full -Dtarget=aarch64-macos` 绿 + `zig build test-macos-ui` 绿;手测微信仍能收发(若有真机条件)。
- [ ] **Step 5**: Commit `refactor(appwindow): generalize weixin bridge to chatops bridge`。

---

## §M2-M4 Outline(待 M0 后出详细计划)

**M2 入站文本闭环**(可在 M1 后 + M0 定型后并行)
- `src/feishu/pbbp2.zig`:Frame 编解码(用 M0.4 fixture 做 TDD 单测)
- `src/feishu/ws_transport.zig`:按 M0.3 结论(原生 WS 泛化 或 裸 TCP+TLS)
- `src/feishu/longconn.zig`:端点发现+握手+ACK+心跳+重连,接口 `start(creds, onEvent)`
- `src/feishu/rest.zig`:token 缓存刷新 + 发文本消息 + 取 bot open_id
- `src/feishu/codec.zig`:`im.message.receive_v1` ↔ 中立类型(fixture 单测)
- `src/feishu/binding.zig`:p2p allowlist + 群 @ 比对 bot open_id
- `src/feishu/state_store.zig`:凭证/绑定/token/event_id 去重持久化
- `src/feishu/controller.zig`:生命周期,onEvent→codec→binding→chatops.router
- 飞书 `AttachmentSender`/text reply sink 实现
- E2E:测试租户私聊 → AI → 文本回飞书

**M3 完整版**(三块独立,workflow 并行)
- `src/feishu/media.zig` + `media_inbound.zig`:文件/图片上传下载
- `src/feishu/card.zig`:交互卡片 + `card.action.trigger` 回调;approval/question 经 ReplySink 渲染为卡片(spec §5 注)
- 群聊 @ 完整支持

**M4 接线收尾**
- `src/config.zig`:`feishu-enabled`/`feishu-app-id`/`feishu-app-secret`/`feishu-allowed-user`
- `src/App.zig`:`startFeishu()` 门控
- `src/i18n.zig`:飞书字符串
- 重连硬化、notify-forward、文档

---

## Self-Review

**Spec coverage(M0+M1 范围内)**:
- spec §4.1 Step 0 四项 → M1.1(类型)/M1.2(assistant)/M1.3(router)/M1.4(bridge) ✓
- spec §2 传输 A 可行性 → M0.1-M0.5 ✓
- spec §9 原生 WS 未知 → M0.3 Step 2 ✓;payload 加密未知 → M0.1 Step2 / M0.5 ✓
- spec §7 fixture 单测策略 → M0.4 Step5 抓 fixture,M2 用 ✓
- "不改工具名/不引入 capability" → Global Constraints + M1.2 Step3 验证 ✓
- spec §4.2 飞书模块、§5 数据流、§6 应用配置 → 属 M2-M4,已在 Outline 标注待规划 ✓(非遗漏,是有意分解)

**Placeholder scan**:M0 为 spike,代码块以"逐字搬来/按笔记实现"指明来源而非凭空;M1 新文件给了完整代码,改名给了精确映射表。无 TBD。

**Type consistency**:`chatops.reply.{ReplyContext,QuestionReply,AttachmentSender,AttachmentKind}` 在 M1.1 定义,M1.2/M1.3 及 Outline 一致引用;`applyChatInput`/`reply_context`/`chatopsControl()` 命名前后一致。

---

## Execution Handoff

见对话——计划保存于本文件,下面选执行方式。
