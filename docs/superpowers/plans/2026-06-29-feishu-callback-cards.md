# 飞书交互回调卡片 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 飞书卡片内点击操作(card.action.trigger):流式进度卡片上的停止按钮 + 替换文本审批/提问提示的可点击卡片;点击后 resolve 并 3 秒内回 toast/更新卡片。

**Architecture:** 入站 card.action.trigger 走 event 帧 → controller onEvent 按 event_type 分派到 handleCardAction → 解析 value → 映射到 cancelEpisode / resolveAiApproval / resolveAiQuestion → 沿同条 WS 回响应帧(toast + 更新卡片)。卡片 JSON(按钮/已处理态/响应)在 feishu/card.zig(与流式卡片共用)。

**Tech Stack:** Zig 0.15.2;std.http.Client;Feishu CardKit JSON 2.0 + 长连接 card.action.trigger;无第三方依赖。

设计 spec:`docs/superpowers/specs/2026-06-29-feishu-callback-cards-design.md`
接续:`docs/superpowers/plans/2026-06-28-feishu-streaming-card.md`(S1–S5 已实现)

## Global Constraints

- 仅 std + 本仓代码,**不加第三方依赖**。
- `tenant_access_token`/app_secret/文件字节**绝不入日志**;URL 日志去 query。
- **Allocator 生命周期(反复栽的坑)**:跨锁/跨 HTTP/被 cache 长期持有的数据**不得借用 per-call arena**;token 用 `self.token_cache.get(self.allocator,...)`(非 arena)。
- **Zig 惰性分析坑**:未被调用的 pub fn 体不被完整分析,编译可能"假绿";接线后才暴露(参见 S5 的 rest.zig `_ = try` 修复)。新增 pub fn 写完即加调用点或测试触达。
- card.action.trigger **3 秒内必须响应**;卡片须 JSON 2.0;CardKit 单卡 10 次/秒。
- 卡片 `value` 不带 generation:过期卡片点击 → resolve 返回 false → toast「已处理/已失效」。
- 每任务末尾 commit,末行 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。
- 验证:`zig build test` 绿;触及 app 代码 `zig build test-full -Dtarget=aarch64-macos` 绿。已知 flaky(忽略):`platform.text_macos ... ASCII case folding`、`skill center tool import`(FileNotFound)、`assistant.conversation.skills ... session loads custom commands`。**test-full 偶发 transient 先重跑确认确定性**。
- **git 纪律**:禁 `git --amend`/历史改写;禁 `git add -A`/`git add .`,只 add 本任务文件;**绝不 git add .superpowers/**(gitignored)。

---

## File Structure

- `src/feishu/spike/cardaction.zig`(Task 0,临时)— 打通 card.action.trigger 抓帧 + 流式按钮可点性。
- `src/feishu/card.zig`(改)— 按钮卡片 / 已处理态 / 回调响应构造(纯)。
- `src/feishu/codec.zig`(改)— parseCardAction(纯)。
- `src/feishu/pbbp2.zig`(改)— 响应帧泛化(任意 payload)。
- `src/feishu/longconn.zig`(改,可能)— 暴露写响应帧的入口给 controller。
- `src/feishu/controller.zig`(改)— onEvent 分派 + handleCardAction。
- `src/feishu/progress.zig`(改)— 审批/提问发卡片;流式卡片加停止按钮。
- `docs/superpowers/specs/feishu-longconn-protocol-notes.md`(改)— 追加 §9 card.action.trigger(Task 0 产出)。

---

## Task 0: Spike — card.action.trigger 帧 + 流式按钮可点性（探索性,主代理交互式跑,非 TDD）

**目的:** 锤死两个未知。需运行中的 app(已连飞书)+ 临时日志 + 用户点击。

**Spike A(回调帧 + 响应):**
- [ ] 在 app 的 onEvent(或 longconn 收帧处)临时加日志:dump 收到的 event 帧 `event_type` + 原始 payload(card.action.trigger 时)。
- [ ] 发一张带按钮(value `{"act":"test"}`)的卡片到测试会话(spike 程序或临时代码;chat_id 从最近入站消息临时日志取)。
- [ ] 用户点击 → 捕获 card.action.trigger 原始 payload;记字段路径(action value、open_id、message_id/card_id、token)。
- [ ] 试响应:沿同条 WS 回 `{"toast":{"type":"success","content":"ok"}}`(复用帧,像 ACK),看飞书是否弹 toast;记响应 envelope 形状。

**Spike B(流式卡片按钮可点性):**
- [ ] 发一张 `streaming_mode:true` 且带按钮的卡片;点击,看 card.action.trigger 是否到达 + 能否在响应里更新卡片。
- [ ] **判定 + 与用户确认进度卡片形态**:可点 → 保留 streaming + 停止按钮;不可点 → 进度卡片改常规每 ~3s 整卡更新(不开 streaming_mode)。

- [ ] 把确切形状写进协议笔记 §9;保存 fixture(card.action.trigger payload JSON)。**token 打印 redact。**
- [ ] Commit `spike(feishu): de-risk card.action.trigger + streaming-card buttons`。

**Deliverable:** 协议笔记 §9 有确切帧/响应形状 + 进度卡片形态决定;fixture 供 Task 1/2 用。临时日志在 spike 后回退(不进生产提交)。

---

## Task 1: card.zig — 按钮卡片 / 已处理态 / 响应构造（纯函数）

**Files:** Modify `src/feishu/card.zig`(+ tests)

**Interfaces (Produces):**
- `pub fn buildApprovalCard(alloc, desc: []const u8) ![]u8` — header + desc + 两按钮:value `{"act":"approval","decision":"approve"}` 与 `{"act":"approval","decision":"reject"}`。
- `pub fn buildQuestionCard(alloc, question: []const u8, options: []const []const u8) ![]u8` — 每选项一按钮 value `{"act":"question","option":N}`(N=0..)。
- `pub fn buildResolvedCard(alloc, text: []const u8) ![]u8` — 纯文本 markdown 卡(无按钮),用于已处理态(「✅ 已批准」「⏹ 已停止」「已选: …」)。
- `pub fn buildCallbackResponse(alloc, toast: []const u8, card_json: ?[]const u8) ![]u8` — 回调响应 payload(toast + 可选更新卡片),形状以 Task 0 §9 为准。
- 流式卡片停止按钮:`buildStreamingCard` 增 stop 按钮(value `{"act":"stop"}`),或加 `buildStreamingCardWithStop(alloc, initial_md)`;按 Task 0 Spike B 决定(若进度卡片改常规更新,停止按钮加在常规卡上)。
- 全部用 `std.json.Stringify.valueAlloc` 构造(转义安全)。

**Tests(离线):** 每个 builder 断言:产物是合法 JSON(parseFromSlice)、含正确按钮 value(`"act":"approval"` 等)、选项数对、desc/question 转义 round-trip;buildResolvedCard 无按钮;buildCallbackResponse 含 toast 文本。
- [ ] 写失败测试 → `zig build test` 确认失败。
- [ ] 实现 builders。
- [ ] `zig build test` 绿。
- [ ] Commit `feat(feishu): card.zig interactive button cards + resolved/response builders`。

---

## Task 2: codec.parseCardAction（纯函数）

**Files:** Modify `src/feishu/codec.zig`(+ tests)

**Interfaces (Produces):**
- `pub const CardAction = struct { act: []const u8, decision: []const u8 = "", option: i64 = -1, open_id: []const u8 = "", message_id: []const u8 = "" };`(字段以 Task 0 §9 为准)
- `pub fn parseCardAction(arena, payload: []const u8) !CardAction` — 解析 card.action.trigger payload;value 是 JSON 字符串则二次解析出 act/decision/option(镜像 parseReceiveV1 的 content 双层解析)。

**Tests(离线,用 Task 0 fixture):** 给真实 card.action.trigger payload fixture → 断言 act/decision/option/ids 正确;stop/approval/question 三种 value 各一例;畸形 payload 返回 error 不崩。
- [ ] 写失败测试(用 fixture)→ 确认失败。
- [ ] 实现 parseCardAction。
- [ ] `zig build test` 绿。
- [ ] Commit `feat(feishu): codec.parseCardAction (card.action.trigger payload)`。

---

## Task 3: pbbp2 响应帧泛化

**Files:** Modify `src/feishu/pbbp2.zig`(+ tests)

**Interfaces (Produces):**
- 现有 `buildAck(a, recv)` 把 payload 写死 `{"code":200}`。新增/泛化:`buildResponse(a, recv: Frame, payload: []const u8) ![]u8`(复用收到帧的 ids/headers,payload 换成传入的;加 biz_rt header,同 ACK)。`buildAck` 改为 `buildResponse(a, recv, "{\"code\":200}")` 的封装。
- 形状以 Task 0 §9 确认的响应 envelope 为准。

**Tests(离线):** buildResponse round-trip:给一个 recv Frame + 自定义 payload → decode 回来 seqid 复用、payload 等于传入、biz_rt 在;buildAck 仍产出 `{"code":200}`(现有测试继续绿)。
- [ ] 写失败测试 → 确认失败。
- [ ] 实现 buildResponse + buildAck 封装。
- [ ] `zig build test` 绿。
- [ ] Commit `feat(feishu): pbbp2 buildResponse (generalize ack to arbitrary payload)`。

---

## Task 4: controller — onEvent 分派 + handleCardAction

**Files:** Modify `src/feishu/controller.zig`(+ tests)

**Interfaces (Consumes):** card.zig(Task1)、codec.parseCardAction(Task2)、pbbp2.buildResponse(Task3)、longconn 写帧入口、control 的 resolveAiApproval/resolveAiQuestion/aiApprovalPending/aiQuestionOptionCount、progress.cancelEpisode。

**实现:**
- onEvent 按 `msg`/帧的 `event_type` 分派:`im.message.receive_v1`(现有)/ `card.action.trigger` → `handleCardAction(payload, recv_frame)`。
- `handleCardAction`:`parseCardAction` → switch act:
  - `stop` → `self.progress.cancelEpisode()` + 给副驾发 ESC 中止(复用 stopAi 等价:`self.control.findAiSurface()` → `sendInput(ai.id, ESC, null)`);响应 toast「已停止」+ buildResolvedCard「⏹ 已停止」。
  - `approval` → `self.control.resolveAiApproval(decision==approve)`;返回 false → toast「已处理/已失效」;true → toast「已批准/已拒绝」+ resolved 卡。
  - `question` → `self.control.resolveAiQuestion(.{ .option = @intCast(option) })`;同上 false/true 分支。
- 构造 `pbbp2.buildResponse(recv, buildCallbackResponse(toast, resolved_card))` → 沿长连接回(3 秒内,复用收帧)。
- 需要 longconn 暴露一个「回写响应帧」的入口(若现有 ACK 是 longconn 内部自动回的,需让 onEvent/handleCardAction 能注入响应 payload;按现有 ACK 路径改造)。

**Tests:** 可注入 control(FakeControl 记录 resolveAiApproval/Question 调用)+ 假 card.action.trigger 帧 → 断言 stop/approval/question 各映射到正确 resolve + 响应构造;resolve=false → toast「已处理」分支。longconn 回写不单测(E2E)。
- [ ] 写失败测试 → 确认失败。
- [ ] 实现分派 + handleCardAction。
- [ ] `zig build test` + `zig build test-full -Dtarget=aarch64-macos` 绿。
- [ ] Commit `feat(feishu): handleCardAction — route card clicks to resolve + respond`。

---

## Task 5: 停止按钮(端到端打通 + 定进度卡片形态)

**Files:** Modify `src/feishu/progress.zig` + 可能 `src/feishu/card.zig`(+ tests)

**Interfaces (Consumes):** Task1 停止按钮卡;Task4 handleCardAction stop 分支。

**实现:**
- 流式进度卡片初始内容含停止按钮(经 card.zig)。按 Task 0 Spike B:若流式按钮可点,保留 streaming_mode + 停止按钮;否则进度卡片改常规每 ~3s 整卡更新(把 progress.zig 的 streamCardContent 调用换成「整卡 PATCH」,并相应调 rest——此分支较大,Spike B 确认后细化)。
- handleCardAction 的 stop 已在 Task4;本任务确保进度卡片真带按钮 + cancelEpisode 后卡片定格「⏹ 已停止」。
- worker:cancelEpisode 退出路径已由 S4 defer 关流;停止按钮触发的 cancelEpisode 复用之。

**Tests:** card.zig 停止按钮 builder 测(Task1 已覆盖则免);worker 形态改动若动逻辑则补纯测。
- [ ] 实现 + `zig build test`/`test-full` 绿。
- [ ] Commit `feat(feishu): stop button on streaming progress card`。
- [ ] **E2E(主代理)**:重建+重启;飞书发让 AI 跑工具的消息 → 进度卡片带停止按钮 → 点击 → AI 中止 + 卡片定格「已停止」+ toast。

---

## Task 6: 审批按钮

**Files:** Modify `src/feishu/progress.zig`(+ tests)

**Interfaces (Consumes):** Task1 buildApprovalCard;Task4 handleCardAction approval。

**实现:** progress worker 的审批动作(planPoll/materialize 的 send_approval_prompt 路径)从「send_sink 文本」改为「发 buildApprovalCard 交互卡片」(独立 interactive 消息)。文本兜底保留(无卡片场景/降级)。handleCardAction approval 已在 Task4。
**Tests:** worker 审批分支改动的纯测(发卡片而非文本的动作);planPoll/materialize 调整后现有测试更新。
- [ ] 实现 + 测试绿。
- [ ] Commit `feat(feishu): approval as interactive card (approve/reject buttons)`。
- [ ] **E2E**:触发一次审批(危险操作)→ 飞书出批准/拒绝卡片 → 点击 → resolveAiApproval 生效 + 卡片更新。

---

## Task 7: 提问按钮

**Files:** Modify `src/feishu/progress.zig`(+ tests)

**Interfaces (Consumes):** Task1 buildQuestionCard;Task4 handleCardAction question。

**实现:** progress worker 的提问动作从文本改为发 buildQuestionCard(每选项一按钮)。**保留打字回复**:自由文本答案 + 兜底仍走现有 question_reply 文本路径(router 已处理)。handleCardAction question 已在 Task4。
**Tests:** worker 提问分支纯测;选项渲染。
- [ ] 实现 + 测试绿。
- [ ] Commit `feat(feishu): question as interactive card (one button per option)`。
- [ ] **E2E**:触发一次 ask_user → 飞书出选项卡片 → 点击选项 → resolveAiQuestion 生效;另测打字自由文本答案仍可用。

---

## Self-Review

**Spec coverage:** 三按钮 → Task5/6/7;card.action.trigger 入站 → Task2+4;响应帧 → Task3+4;按钮卡片 → Task1;流式按钮可点性岔路 → Task0(B)+Task5;文本兜底 → Task7(+Task6);两 spike → Task0;协议未知 → Task0 标注。✅

**Placeholder scan:** spike 依赖处(payload 字段、响应 envelope、进度卡片形态)均标「以 Task 0 §9/Spike B 为准」——有意探索依赖(同 M0/CardKit spike 模式),非占位;纯函数任务(1/2/3)给了具体测试+接口。Task5 的「常规更新」分支待 Spike B 确认后细化——已显式标注为条件分支。

**Type consistency:** CardAction(Task2)字段被 Task4 handleCardAction 消费;buildApprovalCard/QuestionCard/ResolvedCard/CallbackResponse(Task1)被 Task4 用;buildResponse(Task3)被 Task4 用;value 形状(act/decision/option)在 Task1 产出、Task2 解析、Task4 映射——三处一致。

**风险:** Task 0 Spike B 若揭示流式按钮不可点,Task5 含一个较大的「进度卡片改常规更新」分支(动 progress.zig + rest);Spike 后与用户确认并细化该任务。
