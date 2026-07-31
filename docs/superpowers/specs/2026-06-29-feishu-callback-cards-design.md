# 飞书交互回调卡片 — 设计

日期:2026-06-29
分支:feat/feishu-channel
关联:GitHub #404;接续 `2026-06-28-feishu-streaming-card-design.md`(流式进度卡片,已实现 S1–S5),**共用 `feishu/card.zig`**。

## 背景与目标

流式进度卡片已上线(AI 处理飞书消息时实时刷 tool 进度、收尾写最终答案)。但**卡片不可交互**:用户要停止本次处理只能打字发 `/stop`;审批/提问仍是文本提示 + 打字回复。S5 去掉 inline ack 后,`/stop` 提示也随之消失,发现性变差。

目标:用 **`card.action.trigger`** 回调实现**卡片内点击操作**,三种按钮:
1. **停止按钮** —— 加在流式进度卡片上,点击 = 现有 `/stop`(给副驾发 ESC 中止 + cancelEpisode),卡片定格「⏹ 已停止」。
2. **审批按钮**(✅ 批准 / ❌ 拒绝)—— 替换文本审批提示。
3. **提问按钮**(每个选项一个)—— 替换文本提问提示。

## 范围

**做**:card.action.trigger 入站处理 + 三种按钮 + 点击后 resolve + 3 秒内回 toast/更新卡片。
**保留**:打字回复老路——提问的**自由文本**答案按钮覆盖不了,且作兜底/向后兼容。
**非目标**:不做 AI 自由发任意卡片;不做按钮之外的卡片组件(输入框/下拉等)。

## 先去风险:两个 Spike(实现计划第 0 步)

CardKit 回调 + 流式交互文档不全,以下为关键未知,实现前用一次性 spike 锤死(仿之前 M0 / CardKit spike):

### Spike A:card.action.trigger 帧 + 响应 envelope
- 点击事件经长连接 **event 帧**(`event_type == card.action.trigger`,见协议笔记 §3)到达——抓真实 payload,确认字段路径:**action value**(按钮自定义数据)、**open_id/user**、**message_id/card_id**、token。
- **3 秒内响应**:沿同条 WS 怎么回 toast/更新卡片?是否复用收到的帧(像 ACK 把 payload 换成 `{"toast":...,"card":...}`)?确认响应 envelope 形状。

### Spike B:⚠️ 流式卡片上的按钮可点性(本期最大风险)
- CardKit 文档:「流式模式须先关掉才能处理卡片回调」。
- spike:发一张 `streaming_mode:true` 且带一个按钮的卡片,点击,看 card.action.trigger 是否到达 + 能否在响应里更新卡片。
- **结果决定进度卡片形态(设计岔路,spike 后与用户确认)**:
  - 流式中按钮**可点** → 保留 streaming_mode + 停止按钮(理想)。
  - **不可点** → 进度卡片改用**常规卡片每 ~3s 整体更新**(不开 streaming_mode,改 `streamCardContent` 为「PATCH 整卡内容」)替代流式;按钮恒可点,仅损失打字机微动画(本就每 3s 推一次,影响小)。
- 审批/提问卡片是**独立静态卡片**(非流式),无此冲突;风险仅在停止按钮。

## 架构 / 单元(沿现有边界,复用流式卡片那套)

### `feishu/card.zig`(已存在,扩展;纯函数 + 离线单测)
- `buildApprovalCard(desc) ![]u8` —— header + 说明 + 两按钮(value `{"act":"approval","decision":"approve"|"reject"}`)。
- `buildQuestionCard(question, options) ![]u8` —— 每选项一按钮(value `{"act":"question","option":N}`)。
- 流式卡片加停止按钮:`buildStreamingCard` 增一个停止按钮(value `{"act":"stop"}`),或新增 `buildStreamingCardWithStop`。
- `buildResolvedCard(text) ![]u8` —— 已处理态(如「✅ 已批准」「⏹ 已停止」「已选: 选项B」),按钮移除/置灰。
- `buildCallbackResponse(toast_text, card_json) ![]u8` —— 回调响应 payload(toast + 可选更新卡片),形状以 Spike A 为准。
- 按钮 value 用 `std.json.Stringify` 构造;解析在 codec。

### `feishu/codec.zig`(扩展)
- `parseCardAction(payload) !CardAction` → `{ action_value: []const u8 (或已解析的 act/decision/option), open_id, message_id/card_id }`。字段路径以 Spike A fixture 为准。

### `feishu/controller.zig` onEvent(扩展)
- 按 `event_type` 分派:`im.message.receive_v1`(现有)/ `card.action.trigger`(新 → `handleCardAction`)。
- `handleCardAction`:parseCardAction → 映射 →
  - `stop` → `self.progress.cancelEpisode()`(+ 给副驾发 ESC 中止,复用 /stop 的 `stopAi` 等价逻辑);
  - `approval` → `control.resolveAiApproval(approve)`;
  - `question` → `control.resolveAiQuestion(.{ .option = N })`;
  - → 构造响应(toast + 更新卡片为已处理态)→ 沿长连接回(3 秒内)。
- resolve 返回 false(已处理/已失效/无 pending)→ toast「该操作已处理或已失效」。

### `feishu/longconn.zig` / `pbbp2.zig`(扩展)
- 现有 ACK 把 payload 写死 `{"code":200}`;**泛化**成可回任意 payload,card.action.trigger 的 toast/card 响应走这条帧(形状以 Spike A 为准)。

### `feishu/progress.zig`(扩展)
- 审批/提问动作:从 send_sink 发文本,改为发**交互卡片**(`buildApprovalCard`/`buildQuestionCard` → 作为独立 interactive 消息发送)。文本兜底保留(自由文本答案)。
- 流式进度卡片:初始内容含**停止按钮**(经 card.zig)。进度卡片形态(streaming vs 常规更新)按 Spike B 定。

## 数据流

```
点击按钮 → card.action.trigger event 帧 → onEvent 分派 → handleCardAction
  → codec.parseCardAction → 映射 act:
      stop → progress.cancelEpisode (+ESC 中止副驾)
      approval/approve|reject → control.resolveAiApproval(bool)
      question/option N → control.resolveAiQuestion(.option=N)
  → 构造响应(toast + 更新卡片为已处理态)
  → 沿同条 WS 3 秒内回(复用帧,payload=响应 envelope)
```

## 已知限制(v1 接受)
- 按钮 `value` 不带 generation/nonce:点**过期卡片**会 resolve「当前 pending」(同现有文本回复语义);resolve 返回 false 时 toast「已处理/已失效」。加 generation 需动 Control vtable,YAGNI,留后。
- 提问自由文本答案仍走打字回复(按钮只覆盖预设选项)。

## 计划分期
spike(A+B)→ 核心(card.zig 按钮/响应 + codec.parseCardAction + controller 分派 + longconn 响应帧泛化)→ **停止按钮**(顺带按 Spike B 定进度卡片形态,先打通端到端)→ 审批按钮 → 提问按钮。每块 subagent 实现 + 复审。

## 测试
- `card.zig` 按钮/resolved/响应构造、`parseCardAction`:纯函数离线单测(用 Spike A fixture)。
- `handleCardAction`:可注入 control + 假 card.action.trigger 帧,断言映射到正确 resolve + 响应构造;resolve=false 的 toast 分支。
- longconn 响应帧泛化:复用现有 pbbp2 测试模式。
- **内存/并发**:沿用教训——不借用 per-call arena 跨锁/跨 HTTP;token 经 self.allocator(非 arena);card_id/value 所有权清晰。
- E2E:真点停止/批准/提问各一次,看 resolve 生效 + 卡片更新 + toast。

## 待 spike 解决的开放问题
- card.action.trigger payload 确切字段路径 + 响应 envelope 形状(Spike A)。
- 流式卡片按钮可点性 → 进度卡片是否保留 streaming_mode(Spike B,岔路与用户确认)。
