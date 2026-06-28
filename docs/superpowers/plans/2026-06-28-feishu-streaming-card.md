# 飞书流式进度卡片 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AI 处理飞书消息时发一张 CardKit 流式卡片,实时刷 tool 调用进度,完成时把最终回答写入同一张卡——替代当前的文本最终回复。

**Architecture:** 一个 AI episode 一张流式卡片。`progress.zig` worker 在 episode 开始时创建+发送流式卡片(替代 inline 文本 ack),每次 ~3s 轮询渲染进度并流式推送,完成/出错时写最终态并关流。新增 `feishu/card.zig`(卡片 JSON 2.0 构造,与未来回调卡片共用)+ `rest.zig` 的 CardKit 调用 + `reply_progress.zig` 的纯渲染函数。

**Tech Stack:** Zig 0.15.2;`std.http.Client`(自带 TLS);Feishu CardKit v1 OpenAPI;无第三方依赖。

设计 spec:`docs/superpowers/specs/2026-06-28-feishu-streaming-card-design.md`

## Global Constraints

- 仅 std + 本仓代码,**不加第三方依赖**。
- `tenant_access_token` / app_secret / 文件字节**绝不入日志**;URL 日志去 query。
- **Allocator 生命周期(M2/M3 反复栽的坑)**:任何跨 poll / 跨 HTTP / 被 cache 长期持有的数据**不得借用 per-call arena**。token 用 `self.allocator`(TokenCache 长期持有);`card_id` 归 episode 持有、关流后释放;transcript 在 `progress.transcript_mu` 下 dupe 后才跨锁/跨 HTTP 用。
- CardKit:单卡 **10 次/秒**上限;更新需**递增 sequence**;流式模式 **10 分钟自动关**;需飞书客户端 **7.20+**;卡片须 **JSON 2.0** 结构(非 template)。
- Zig 0.15.2:注意 `std.fs`/`std.http` API 形状,编译报错查 std 源,别反复猜。
- 每个任务末尾 commit,提交信息末行:`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。
- 验证:`zig build test` 绿;触及 app 代码时 `zig build test-full -Dtarget=aarch64-macos` 绿。已知 flaky(非回归,忽略):`platform.text_macos ... ASCII case folding through Foundation`、`skill center tool import`(FileNotFound)、`assistant.conversation.skills ... session loads custom commands from a commands directory`。

---

## File Structure

- `src/feishu/spike/cardkit.zig`(Task 0,临时,完成后清理)— 一次性打通 CardKit 流式 API,抓 fixture。
- `src/feishu/card.zig`(新)— 卡片 JSON 2.0 构造(纯函数)。与未来回调卡片子系统共用。
- `src/chatops/reply_progress.zig`(改)— 加纯函数 `renderProgress`。
- `src/feishu/rest.zig`(改)— 加 CardKit REST 调用 + 可测的请求体构造纯函数。
- `src/feishu/progress.zig`(改)— episode 生命周期:建卡→流式刷→收尾关流。
- `src/feishu/controller.zig`(改)— 接线;inline 文本 ack 由卡片接管。
- `docs/superpowers/specs/feishu-longconn-protocol-notes.md`(改)— 追加 CardKit §(Task 0 产出)。

---

## Task 0: Spike — 锤死 CardKit 流式 API（探索性,非 TDD）

**Files:**
- Create: `src/feishu/spike/cardkit.zig`(临时)
- Modify: `docs/superpowers/specs/feishu-longconn-protocol-notes.md`(追加 CardKit §)

**目的:** CardKit v1 端点/请求体/响应文档不全。本任务用真实凭证打通「建卡→发卡→推 2 次内容→关流」,把确切形状写进协议笔记,后续任务照此实现。**这是全计划唯一协议未知。**

**已知(文档/推断,待确认):**
- 建卡:`POST /open-apis/cardkit/v1/cards`(或 `/card/create`),body 含 `type:"card_json"` + 卡片 JSON 2.0(`config.streaming_mode:true`)→ 响应 `data.card_id`。
- 发卡到会话:`POST /open-apis/im/v1/messages?receive_id_type=chat_id`,`msg_type:"interactive"`,`content` 引用 card_id(形状待确认:可能 `{"type":"card","data":{"card_id":"..."}}`)。
- 流式更新元素:`POST/PUT /open-apis/cardkit/v1/cards/:card_id/elements/:element_id/content`,body 含 `content` + `sequence`(递增)+ uuid。
- 关流:`PATCH /open-apis/cardkit/v1/cards/:card_id/settings`,body `{"settings":"{\"config\":{\"streaming_mode\":false}}","sequence":N,"uuid":...}`。
- 鉴权:`Authorization: Bearer {tenant_access_token}`。

- [ ] **Step 1:** 写 `spike/cardkit.zig`:`source ~/.zshrc` 取 `FEISHU_APP_ID/SECRET`(env);`rest.tenantAccessToken` 拿 token;一个写死的测试 chat_id(从近期 onEvent 日志取,或加一个命令行参数)。
- [ ] **Step 2:** 调建卡(streaming_mode:true,一个 markdown 元素 `element_id="md"`),打印响应,记 card_id。
- [ ] **Step 3:** 发卡到测试会话,确认飞书里出现卡片。
- [ ] **Step 4:** 推 2 次内容更新(`"步骤1…"` → `"步骤1…\n步骤2…"`,seq 递增),确认打字机刷新。
- [ ] **Step 5:** 关流;确认卡片定格。
- [ ] **Step 6:** 把每步确切端点/请求体/响应字段路径写进协议笔记新 § 「CardKit 流式卡片」;保存 1-2 个 fixture JSON。
- [ ] **Step 7:** Commit `spike(feishu): de-risk CardKit streaming API (endpoints + fixtures)`。

**Deliverable:** 协议笔记里有确切 API 形状;真机验证流式渲染可行。**后续 Task 3 的请求体以此为准。**

---

## Task 1: `feishu/card.zig` — buildStreamingCard（纯函数）

**Files:**
- Create: `src/feishu/card.zig`(+ tests)
- Modify: `src/test_fast.zig`(登记)

**Interfaces:**
- Produces: `pub const PROGRESS_ELEMENT_ID: []const u8 = "md"`;`pub fn buildStreamingCard(alloc, initial_md: []const u8) ![]u8`(→ 卡片 JSON 2.0 字符串,caller 拥有)。

**说明:** 卡片 JSON 2.0:`{"schema":"2.0","config":{"streaming_mode":true,...},"body":{"elements":[{"tag":"markdown","element_id":"md","content":"<initial_md>"}]}}`(确切字段以 Task 0 spike 为准;若 spike 显示需要 header/其它字段,按 fixture 调)。用 `std.json.Stringify.valueAlloc` 构造保证转义。

- [ ] **Step 1: 写失败测试**
```zig
test "buildStreamingCard: JSON 2.0 with streaming markdown element" {
    const a = std.testing.allocator;
    const json = try buildStreamingCard(a, "处理中…");
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"element_id\":\"md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tag\":\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "streaming_mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "处理中") != null);
    // 合法 JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
}
```
- [ ] **Step 2: 跑测试确认失败** — `zig build test`,预期 `buildStreamingCard` 未定义。
- [ ] **Step 3: 实现** `PROGRESS_ELEMENT_ID` + `buildStreamingCard`(`std.json.Stringify.valueAlloc` 构造上述结构;`element_id` 用常量)。
- [ ] **Step 4: 跑测试确认通过** — `zig build test`。
- [ ] **Step 5: 登记 test_fast.zig + Commit** `feat(feishu): card.zig buildStreamingCard (JSON 2.0)`。

---

## Task 2: `chatops/reply_progress.zig` — renderProgress（纯函数）

**Files:**
- Modify: `src/chatops/reply_progress.zig`(加 `renderProgress` + tests)

**Interfaces:**
- Consumes: 模块内已有的 section 解析(`Section{role,label,content}`,role ∈ {metadata,user,assistant,tool,reasoning,approval,question})。
- Produces: `pub fn renderProgress(alloc, current: []const u8) ![]u8`(→ 进度 markdown,caller 拥有)。给完整 transcript,内部复用既有解析,渲染**最新 assistant 文本 + 一行 tool 状态**。

**说明:** v1 渲染从简:最后一段 assistant 文本(若有)+ 若处于 running-tools 则附 `\n\n🔧 正在执行…`(可带最近 tool label)。复用模块内现有的 section 解析逻辑(`progress()` 已在用),抽出一个内部 `parseSections(current)` 供两者共用(若尚未抽出)。

- [ ] **Step 1: 写失败测试**
```zig
test "renderProgress: surfaces latest assistant text + tool status" {
    const a = std.testing.allocator;
    const transcript =
        \\[user]
        \\帮我读下 README
        \\[assistant]
        \\好的，我来读取。
        \\[tool]
        \\read_file
        \\README.md
        \\[status]
        \\running tools
    ;
    const md = try renderProgress(a, transcript);
    defer a.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "我来读取") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "🔧") != null);
}
test "renderProgress: done transcript shows final assistant text" {
    const a = std.testing.allocator;
    const transcript = "[assistant]\n这是最终答案。\n[status]\ndone";
    const md = try renderProgress(a, transcript);
    defer a.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "最终答案") != null);
}
```
> 注:测试 transcript 的 section 标记格式须与模块实际解析格式一致——实现前先看 `reply_progress.zig` 现有解析(role 标签的真实形态),按真实格式写测试 fixture。
- [ ] **Step 2: 跑测试确认失败。**
- [ ] **Step 3: 实现** `renderProgress`(复用/抽出 section 解析;渲染最新 assistant + tool 状态行)。保持纯、无 I/O。
- [ ] **Step 4: 跑测试确认通过。**
- [ ] **Step 5: Commit** `feat(chatops): reply_progress.renderProgress (sections → progress markdown)`。

---

## Task 3: `feishu/rest.zig` — CardKit REST 调用

**Files:**
- Modify: `src/feishu/rest.zig`(+ 请求体构造纯函数的 tests)

**Interfaces:**
- Consumes: Task 0 协议笔记 CardKit §(确切端点/请求体);`TokenCache`/Bearer 写法。
- Produces:
  - `pub fn createStreamingCard(alloc, token, card_json: []const u8) ![]u8`(→ card_id,caller 拥有)
  - `pub fn sendCardMessage(alloc, token, receive_id_type, receive_id, card_id: []const u8) !void`
  - `pub fn streamCardContent(alloc, token, card_id, element_id, content: []const u8, sequence: i64) !void`
  - `pub fn closeStreaming(alloc, token, card_id: []const u8, sequence: i64) !void`

**说明:** 端点/请求体**以 Task 0 spike fixture 为准**。可测的纯部分:把请求体 JSON 构造抽成纯函数(如 `buildStreamContentBody(alloc, element_id, content, seq) ![]u8`),单测其结构(含 element_id/content/sequence、合法 JSON、内容转义);HTTP 调用本身不单测(留 E2E)。镜像现有 `sendMessage`/`httpsPostWithBearer` 的写法;新增 PUT/PATCH 需要时加内部 helper。token 不入日志。

- [ ] **Step 1:** 写纯请求体构造函数的失败测试(`buildStreamContentBody` 等:断言 element_id/content/sequence 在位、合法 JSON、特殊字符转义)。
- [ ] **Step 2:** 跑测试确认失败。
- [ ] **Step 3:** 实现请求体纯函数 + 4 个 REST 包装(端点照 Task 0 fixture;复用 Bearer/arena 模式;非 200/解析失败 → 返回 error 不静默)。
- [ ] **Step 4:** 跑测试确认通过(`zig build test`)。
- [ ] **Step 5:** Commit `feat(feishu): rest CardKit calls (create/send/stream/close)`。

---

## Task 4: `feishu/progress.zig` — 流式 episode 生命周期（主改动）

**Files:**
- Modify: `src/feishu/progress.zig`(+ tests)

**Interfaces:**
- Consumes: `card.buildStreamingCard`、`card.PROGRESS_ELEMENT_ID`、`reply_progress.renderProgress`、`rest.createStreamingCard/sendCardMessage/streamCardContent/closeStreaming`。
- Produces:(内部)episode 持有 `card_id: ?[]u8` + `sequence: i64`;一个可注入的 **CardSink**(生产指向 rest 调用,测试可替换)以便离线测编排。

**说明:** 把 episode 从「一次性 send_final 文本」改为流式卡片生命周期。CardSink 接口(便于测试,避免网络):
```zig
pub const CardSink = struct {
    ctx: *anyopaque,
    create: *const fn (ctx, alloc, initial_md: []const u8) anyerror![]u8, // → card_id
    send:   *const fn (ctx, alloc, chat_id, card_id: []const u8) anyerror!void,
    stream: *const fn (ctx, alloc, card_id, content: []const u8, seq: i64) anyerror!void,
    close:  *const fn (ctx, alloc, card_id: []const u8, seq: i64) anyerror!void,
};
```
生产实现:`create`=buildStreamingCard+createStreamingCard,`stream`=streamCardContent(固定 PROGRESS_ELEMENT_ID),余同名 rest。**Allocator:** card_id 用 `self.allocator` dup 持有,episode 结束(close 后)free;轮询渲染的 markdown 用临时 arena、推送后释放。

编排(扩 `decide()` 或 worker 编排,保持可单测):
- beginEpisode:`create("处理中…")`→card_id;`send(chat_id, card_id)`;seq=1。
- 每次 poll:`renderProgress(current)`→`stream(card_id, md, seq++)`(内容无变化可跳过推送,省调用)。
- done:`stream(card_id, 最终回答, seq++)`→`close(card_id, seq++)`;释放 card_id。
- cancel/error:`stream(card_id, 最终态文本, seq++)`→`close`;释放。
- 审批/提问动作:**仍走现有文本 send_sink**(独立消息,不进卡片)——本任务不动这条路。

- [ ] **Step 1: 写失败测试**(用假 CardSink 记录调用序列):
```zig
test "episode: create+send on begin, stream on poll, close on done" {
    // 假 CardSink 记录 (op, seq) 序列
    // 模拟 begin → poll(running) → poll(done)
    // 断言:create 一次、send 一次、stream≥2 次 seq 递增、close 一次且 seq 最大
}
test "episode: cancel writes final state + closes" {
    // begin → cancel → 断言 close 被调用、card_id 已释放(无泄漏:testing.allocator)
}
```
- [ ] **Step 2: 跑测试确认失败。**
- [ ] **Step 3: 实现** episode 生命周期 + 生产 CardSink + 假 CardSink。删除/改造旧 send_final 文本路径。
- [ ] **Step 4: 跑测试确认通过**(`zig build test`,testing.allocator 验无泄漏)。
- [ ] **Step 5: Commit** `feat(feishu): streaming-card episode lifecycle in progress worker`。

---

## Task 5: `feishu/controller.zig` — 接线 + 去 inline 文本 ack

**Files:**
- Modify: `src/feishu/controller.zig`

**Interfaces:**
- Consumes: Task 4 的 CardSink(生产实现指向 Task 3 的 rest 调用);现有 token_cache/creds。

**说明:** 把生产 CardSink 接到 ProgressWorker(指向 rest CardKit 调用,token 经 `token_cache.get(self.allocator,...)`)。onEvent:**去掉「信息已收到，开始处理。」inline 文本 ack**(改由 worker 建「处理中」卡片作为首反馈);保留 route 错误兜底文本(非 AI-progress 路径仍需文本回复)。现有 controller 测试保持绿。

- [ ] **Step 1:** 接 CardSink 到 controller→worker;实现指向 rest 的生产 sink(token 用 self.allocator)。
- [ ] **Step 2:** onEvent 去掉 expect_ai_progress 路径的 inline 文本 ack(非 progress 的命令/错误兜底仍发文本)。
- [ ] **Step 3:** `zig build test` + `zig build test-full -Dtarget=aarch64-macos` 绿(忽略已知 flaky)。
- [ ] **Step 4: Commit** `feat(feishu): wire streaming CardSink; drop inline text ack`。
- [ ] **Step 5: E2E(手动)**:重建 macos-app(`-Dtarget=aarch64-macos`)+ 带凭证重启 → 飞书发一条让 AI 跑工具的消息 → 看流式卡片实时刷进度 + 收尾定格最终回答;盯日志确认 stream/close 调用、无 warn/err。

---

## Self-Review

**Spec coverage:** 范围(建卡/发/流式刷/收尾/取消)→ Task 4;tool 进度信号 → Task 2;CardKit API → Task 0+3;卡片 JSON 2.0 → Task 1;去 inline ack → Task 5;限流/sequence → Task 4(seq 递增、内容无变化跳推);错误/停止 → Task 4 cancel/error 路径;审批/提问仍文本 → Task 4 明确不动该路径;E2E → Task 5。✅ 覆盖。

**Placeholder scan:** REST 端点确切形状标注「以 Task 0 spike 为准」——这是**有意的探索依赖**(M0 同款),非占位;纯函数任务(1/2/4)给了完整测试+实现说明。card JSON 2.0 确切字段同样依赖 spike,已标注。

**Type consistency:** `PROGRESS_ELEMENT_ID`(Task1)被 Task4 生产 sink 的 stream 用;CardSink 四方法签名(Task4)与 rest 四函数(Task3)一一对应;`renderProgress(alloc,current)`(Task2)被 Task4 poll 调用。一致。

**已知风险:** Task 0 spike 若揭示发卡/流式形状与推断差异大,Task 1/3 的具体字段需相应调整(接口签名不变,仅请求体内容)。这是 spike 的本职。
