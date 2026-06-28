# 飞书流式进度卡片 — 设计

日期:2026-06-28
分支:feat/feishu-channel
关联:GitHub #404(飞书 bot);本 spec 是「飞书交互卡片」两个子系统之一。

## 背景与目标

当前飞书 bot 在 AI 处理一条消息时:onEvent 发一条 inline 文本 ack(「信息已收到，开始处理。」),`progress.zig` 的 ProgressWorker 在后台轮询 AI transcript,完成时发**一条文本最终回复**。处理过程对飞书用户是**静默**的——看不到 AI 正在做什么(读文件、跑命令、搜索…)。

目标:用 **Feishu CardKit 流式卡片**把 AI 的 **tool 调用进度**实时反映到飞书,处理完成时把最终回答写入同一张卡片。一个 episode 一张流式卡片:干活时流式刷进度,收尾写最终回答并关流。**替代**当前「静默等待 + 一条文本最终回复」。

## 范围

**做**:
- AI episode 开始 → 后台 worker 创建流式卡片并发到会话(立即「处理中」反馈)。
- 每次轮询(沿用 worker 现有 ~3s 节奏)→ 渲染当前进度(tool/reasoning/assistant sections)→ 流式推到卡片。
- episode 完成 → 把最终回答写入同一张卡片 → 关流。
- episode 出错 / `/stop` → 卡片写最终态 +关流。

**不做(非目标)**:
- 审批/提问**暂仍走文本独立消息**——交互**回调卡片**(card.action.trigger)是**单独的下一子系统**(另一份 spec)。
- 不让 AI 发任意自定义卡片。
- 不做「进度卡片末尾直接带审批按钮」——那需要「先关流再处理回调」(CardKit 约束),留到回调卡片子系统与本系统集成时再做。

## 两子系统的分工(decomposition)

「飞书交互卡片」被拆为两个独立 spec,各自 spec→plan→impl,**共用一个 `feishu/card.zig`**:
1. **本 spec:流式进度卡片**(出站,CardKit 流式 OpenAPI)。**先做**。
2. 回调卡片(入站点击 card.action.trigger,审批/提问可点击化)。已单独 brainstorm 完成,待本系统之后实现。

理由:两者方向相反(出站刷新 vs 入站点击)、API 不同(cardkit-v1 OpenAPI vs 长连接事件+响应帧)、集成点不同(progress worker vs 审批/提问 resolve)。合并会让 spec 臃肿、实现耦合。

## 先去风险:Spike(实现计划第 0 步)

CardKit 文档不全,以下为**唯一协议未知**,实现前用一个一次性 spike 锤死(仿 M0 长连接 spike):
- `card/create`(带 `streaming_mode:true`,卡片 JSON 2.0)的**确切端点路径 + 请求体 + 响应里 card_id 的字段路径**。
- 用 `im/v1/messages` 发送时**怎么引用 card_id**(msg_type 与 content 形状)。
- `card-element/content` 流式更新的**端点 + 请求体**(element_id、content、sequence;append vs replace 行为:文档称 new=old 前缀则打字机追加,否则整体替换)。
- `card/settings` 关流(`streaming_mode:false` + sequence)的端点 + 请求体。
- 鉴权:沿用 `tenant_access_token`(Bearer)。

spike 步骤:建卡 → 发卡到测试会话 → 推 2 次内容更新 → 关流;捕获每步的真实请求/响应存为 fixture,后续按 fixture 实现。spike 代码可临时放 `src/feishu/spike/`(仿 M0,完成后清理)。

## 架构 / 单元

沿现有边界,改动集中在 feishu/ 与一个 chatops 纯函数扩展:

### `feishu/rest.zig` — 新增 cardkit 调用
- `createStreamingCard(alloc, token, card_json) ![]u8` → 返回 `card_id`(caller 拥有)。
- `sendCardMessage(alloc, token, receive_id_type, receive_id, card_id) !void` → 发一条引用 card_id 的消息。
- `streamCardContent(alloc, token, card_id, element_id, text, sequence) !void` → 推内容更新。
- `closeStreaming(alloc, token, card_id, sequence) !void` → 关流。
- 端点形状以 spike fixture 为准(预期 `/open-apis/cardkit/v1/...`)。安全:token 不入日志。

### `feishu/card.zig`(新;与回调卡片子系统共用;纯函数 + 离线单测)
- `buildStreamingCard(...) ![]u8` → 卡片 JSON 2.0:一个 header + 一个带固定 `element_id` 的 markdown 元素(进度/回答写这里);`streaming_mode` 配置。
- 元素 `element_id` 用固定常量(单卡单元素,够用)。

### `chatops/reply_progress.zig` — 小扩展
- 加纯函数 `renderProgress(sections) []const u8`(或返回到 caller 缓冲):把已解析的 sections(tool/reasoning/assistant)渲染成紧凑的进度 markdown(如最新 assistant 文本 + 「🔧 正在执行: <tool>」状态行)。复用既有 section 解析,纯函数可单测。

### `feishu/progress.zig` — 主改动(episode 生命周期)
当前:poll → `decide()` → 一次性 `send_final` 文本 / approval / question / none。
改为:
- `beginEpisode`:worker 后台 `createStreamingCard` + `sendCardMessage`(立即「处理中」反馈)。**替代 controller 的 inline 文本 ack**(见下)。维护每 episode 的 `card_id` + 递增 `sequence`。
- 每次 poll:`renderProgress(current sections)` → `streamCardContent(card_id, element_id, text, seq++)`。
- done:把最终回答写入卡片(`streamCardContent` 写最终文本)→ `closeStreaming(card_id, seq++)`。
- 取消/出错:写最终态文本 + `closeStreaming`。
- 审批/提问动作:仍发独立文本消息(沿用现有 send_sink 文本路径,不写进卡片)。
- `decide()` 保持纯;新增 streaming 相关动作 tag 或在 worker 侧编排(实现期定,倾向扩 Action)。

### `feishu/controller.zig` — 接线
- inline 文本 ack 由流式卡片接管:onEvent 不再发「信息已收到」文本 ack(改由 worker 建卡作为首个反馈)。若 worker 建卡有可感知延迟,可保留极短 ack——实现期按真机体感定;默认去掉,避免卡片+文本重复。

## 数据流

```
飞书消息 → onEvent(parse/dedup/binding/route) → expect_ai_progress
  → progress.beginEpisode(chat_id, baseline)
      worker: createStreamingCard → card_id; sendCardMessage(chat_id, card_id)   [「处理中」卡出现]
  → worker poll loop(~3s):
      latestTranscript → reply_progress.progress + sections → renderProgress
      → streamCardContent(card_id, element_id, md, seq++)                        [卡片实时刷进度]
  → progress done:
      streamCardContent(最终回答, seq++) → closeStreaming(card_id, seq++)         [卡片定格为最终回答]
```

## 关键决策 / 默认

- **起卡时机**:每个 episode 都建卡(立即反馈)。代价 = 每条回复多 2 次 API(create+send)+ N 次更新 + 1 次关流。可接受。若轻量回复嫌浪费,可加「有 tool 才起卡」阈值——**默认不加(YAGNI)**。
- **限流**:CardKit 单卡 10 次/秒;worker ~3s 轮询远低于上限。Feishu 客户端打字机效果(`print_frequency_ms`)平滑中间过程,无需高频推。
- **sequence**:CardKit 更新需递增 sequence 排序;worker 维护每 episode 计数器。
- **审批/提问共存**:流式期间需审批/提问 → 发独立文本消息(与卡片不同条),互不干扰。AI 阻塞等待时卡片停更,resolve 后继续。
- **错误/停止**:出错或 /stop → 卡片写最终态 + 关流;不留「处理中」悬挂卡。
- **token/成本**:每条回复多若干 API 调用,可接受;记录于 ledger。
- **约束**:流式模式 10 分钟自动关(episode 一般远短于此);需飞书客户端 7.20+。

## 已知限制(v1 接受)

- 进度粒度受 worker ~3s 轮询限制——非逐 token,而是每 3s 一次状态快照(Feishu 打字机平滑)。若要更细可降轮询间隔,属调优,非 v1。
- 单卡单 markdown 元素;不做多元素富排版。
- 流式期间不嵌交互按钮(CardKit 约束:须先关流);与回调卡片的集成留后。

## 测试策略

- `feishu/card.zig`:`buildStreamingCard` 等纯函数离线单测(JSON 2.0 结构、element_id、streaming 配置)。
- `chatops/reply_progress.zig`:`renderProgress(sections)` 纯函数单测(给定 sections → 期望 markdown)。
- cardkit REST 调用:不单测网络;形状以 spike fixture 为准。
- `feishu/progress.zig`:扩展 `decide()`/编排的纯单测(episode 起→刷→收尾→关流的动作序列;取消/出错路径)。
- **内存/并发**:沿用 M2/M3 教训——任何跨 poll/跨 HTTP 存活的数据不得借用 per-call arena(token 用 self.allocator;transcript 在 transcript_mu 下 dupe)。card_id 归 episode 持有、关流后释放。
- E2E:真发一条让 AI 跑工具的消息,看卡片实时刷进度 + 收尾定格最终回答。

## 待 spike 解决的开放问题

- cardkit-v1 各端点确切路径与请求/响应体。
- 发卡消息引用 card_id 的 msg_type/content 形状。
- 流式更新 append/replace 的实际行为与 element 定位字段。
- 关流请求确切形状。
