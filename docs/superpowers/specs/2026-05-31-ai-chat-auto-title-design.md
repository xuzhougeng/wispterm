# AI Chat 对话自动命名 — 设计文档

- 日期：2026-05-31
- 状态：已与用户确认，待审阅
- 主题：AI Chat 对话在第一轮对话完成后，用 LLM 自动生成有意义的标题

## 1. 背景与问题

WispTerm 的 AI Chat 功能（`src/ai_chat.zig`）里，每个对话 `Session` 有一个 `title`（标题）字段，显示在 tab 标签（`src/appwindow/tab.zig:73`）、历史记录列表（`src/agent_history.zig` 的 `SessionRecord.title`）和 AI 设置面板（`src/renderer/overlays.zig`）。

当前新建对话的标题默认是常量 `DEFAULT_NAME = "DeepSeek"`（`src/ai_chat.zig:24`），初始化时若未显式传入名字就用它（`src/ai_chat.zig:861`）。结果是**所有新对话标题都一样**，多个对话 tab / 历史条目无法区分。

用户已可手动重命名 tab（`src/appwindow/tab.zig:818` → `session.setTitle()`），但需要手动操作。

目标：参照主流 AI 产品（ChatGPT / Claude）的行为，在**第一轮对话完成后**自动用 LLM 生成一个能概括对话主题的简短标题，替换默认值。

### Ghostty 对比说明

AI Chat 是 WispTerm 独有功能，[Ghostty](https://github.com/ghostty-org/ghostty) 没有等价物（与 `remote/` 同属 AGENTS.md 中"无需对照 Ghostty"的例外）。因此本设计不参照 Ghostty，而是参照 ChatGPT / Claude 的"首轮对话后自动命名"惯例。

## 2. 现有代码事实（实现锚点）

- **对话完成注入点**（均在后台 IO 线程，调用时会取 `session.mutex`）：
  - 非流式：`appendAssistantResult`（`src/ai_chat.zig:3011`）
  - 流式：`finishAssistantStream`（`src/ai_chat.zig:3198`）
  - 两者完成时都会清 `request_inflight = false`、`captureHistoryChangeLocked()`、解锁后 `notifyHistoryChange`。
- **线程模型**：`submit()`（`src/ai_chat.zig:1595`）在锁内构建 `ChatRequest`，`std.Thread.spawn(requestThreadMain, …)`，handle 存入 `session.request_thread`；一个 session 只有一个请求线程，下次 `submit` 先 `join` 旧线程。请求线程主函数 `requestThreadMain`（`src/ai_chat.zig:2769`）。
- **消息结构**（`Message`，`src/ai_chat.zig:47`）：`role` 为 `user` / `assistant` / `tool`。
  - 用户提问：`role = .user`。
  - 最终回答：`role = .assistant`（由 `appendAssistantResult` / `finishAssistantStream` 产生）。
  - Agent 模式中间步骤（工具调用进度、工具结果）：`role = .tool`（`appendProgressMessage`，`src/ai_chat.zig:3079`，`persist_to_history = false`）。
  - **关键结论**：首轮里**最终回答是唯一的 `.assistant` 消息**，中间 tool call 往返都是 `.tool` 消息。
- **设置标题**：`setTitle()`（`src/ai_chat.zig:1184`）是 thread-safe 的，并触发历史持久化快照（见测试 `src/ai_chat.zig:5370` "setTitle emits history hook snapshot"）。
- **配置字段**：`Session` 持有 `base_url` / `api_key` / `model` / `protocol`（用于现有请求）。

## 3. 已确认的需求决策

| 决策点 | 选择 |
|--------|------|
| 生成方式 | 额外调用一次 LLM（轻量请求） |
| 触发时机 | 第一轮对话完成后，每个 session 仅一次 |
| 标题语言 | 跟随对话内容语言 |
| 生成依据 | 首轮 `user` 提问 + 最终 `assistant` final answer；**排除中间的 tool call / tool 结果** |
| 使用的模型 | 复用对话当前模型（`base_url` / `api_key` / `model` / `protocol`） |
| 失败回退 | **静默保留默认标题**，不报错、不打扰用户 |
| 手动命名 | 永不覆盖用户的手动重命名 |

## 4. 设计

### 4.1 数据结构改动

`Session` 新增两个字段：

```zig
auto_title_attempted: bool = false,   // 本 session 是否已尝试过自动命名（确保只触发一次）
title_thread: ?std.Thread = null,     // 自动命名后台线程 handle，沿用 request_thread 的生命周期管理
```

`auto_title_attempted` **仅存在于内存**，不持久化到 history。

### 4.2 触发条件

在 `appendAssistantResult` 和 `finishAssistantStream` 把最终 assistant 消息写入后、**解锁之后**，统一调用 `maybeAutoTitle(session)`。自动命名当且仅当以下条件全部满足时触发：

1. `!session.auto_title_attempted`（本 session 尚未尝试过）。
2. `session.title() == DEFAULT_NAME`（标题仍是默认值 → 用户未手动命名、也非历史恢复的已命名会话）。
3. `session.api_key_len > 0`（配置可用）。
4. `session.messages` 中存在至少一条 `.user` 消息和这条刚完成的 `.assistant` final answer。

满足时：在锁内把 `auto_title_attempted = true` 置位（防止重复），快照出标题请求所需的全部输入，然后 `spawn` 标题线程。

> 边缘说明：判断 2 用 `title == DEFAULT_NAME` 已能拦掉历史恢复的已命名会话。对于"历史里有 assistant 消息但标题仍是 DEFAULT_NAME"的半截旧会话（极少见：之前完成过但当时没命名成功），实现时在**历史恢复入口**（`initWithProtocol` / 会话 restore 路径）检测到 messages 已含 `.assistant` 消息时，把 `auto_title_attempted = true`，以保持"仅首轮触发"语义、避免对旧会话意外发请求。

### 4.3 首轮内容提取

构造一个独立的、平台无关的纯函数（便于单测）：

```
extractFirstTurn(messages) -> { user_text, assistant_text }
```

- `user_text`：第一条 `role = .user` 消息的内容。
- `assistant_text`：第一条 `role = .assistant` 消息的内容（即 final answer）。
- 跳过所有 `role = .tool` 消息（工具进度 / 工具结果）。
- 两段各自截断到上限（例如 user ≤ 1500 字符、assistant ≤ 1500 字符，合计控制 token），按 UTF-8 字符边界安全截断。

### 4.4 标题生成请求

- **复用**快照出来的 `base_url` / `api_key` / `model` / `protocol`，构造一个**独立的精简请求**：
  - **非流式**、`include_tools = false`、不走 agent 工具循环。
  - system prompt（英文，要求跟随对话语言输出）：
    > You are titling a chat conversation. Given the user's first message and the assistant's reply, produce a short, specific title that captures the topic. Rules: 2–6 words; no surrounding quotes; no trailing punctuation; reply with the title only; write the title in the **same language the user is using**.
  - user 内容：
    > User: {user_text}\n\nAssistant: {assistant_text}
- 复用现有 HTTP / 协议基础设施（`runChatRequestForMessages` 系或其底层），但传入独立的 messages 数组，不复用 `session.messages`。

### 4.5 线程与生命周期

- `maybeAutoTitle` 在锁内置位 `auto_title_attempted`、快照输入，解锁后 `std.Thread.spawn(titleThreadMain, …)`，handle 存入 `session.title_thread`。
- `titleThreadMain`：
  1. 用快照配置发标题请求。
  2. 失败 / 超时 / 空结果 → 直接返回（静默，保留默认标题）。
  3. 成功 → 清理标题（见 4.6）。
  4. 若 `!session.closing` **且 `session.title() == DEFAULT_NAME`**（再次确认期间用户没手动改名），调用 `session.setTitle(cleaned)`（thread-safe，触发历史持久化）。
- **生命周期**：`title_thread` 沿用 `request_thread` 的 join 模式 —— `Session.deinit` / close 时 `join`（如已存在），避免 use-after-free。`titleThreadMain` 内对 session 的所有访问都走既有的 `closing` 原子标志和 `mutex` 保护。
- 与新一轮请求并存：若标题请求进行中用户又发了消息，`submit` 只管理 `request_thread`，两线程并存；对 `session` 的读写均加锁，互不破坏。

### 4.6 标题清理（平台无关纯函数 `cleanTitle`）

对 LLM 返回文本：

1. trim 首尾空白。
2. 只取第一行（截到首个 `\n`）。
3. 去掉成对的首尾引号 / 书名号（`"` `'` `「」` `『』` `《》` 等）。
4. 折叠内部连续空白为单个空格。
5. 去掉句末标点（`.` `。` `!` `！` `?` `？` `,` `，`）。
6. 按 UTF-8 边界截断到 `title_buf`（128 字节）与 tab 显示宽度上限。
7. 若清理后为空 → 放弃（返回 null，保留默认标题）。

### 4.7 错误处理

API 失败 / 网络错误 / 超时 / 协议解析失败 / 空标题 / 清理后为空 → **一律静默放弃**，保留默认标题，**不修改状态栏**（避免覆盖"对话完成"的正常状态提示）。日志可记 debug 级别。

## 5. 关键实现选择（备选与推荐）

**标题请求的线程方式：**

- **A（推荐）**：独立 `title_thread`，复用现有 HTTP 请求函数，deinit 时 join。简单，与现有 `request_thread` 模式一致，与流式 / 停止逻辑解耦。
- B：在现有 `request_thread` 完成流程末尾顺带发第二个请求。缺点：阻塞 `request_thread` 的 join、与流式完成路径耦合、与"停止"逻辑纠缠。

采用 A。

## 6. 测试计划

平台无关纯逻辑纳入 `src/test_fast.zig` 的快速套件：

- `cleanTitle`：带引号 / 多行 / 超长（>128 字节，含多字节中文）/ 含句末标点 / 纯空白 / 空字符串等输入 → 期望输出。
- `extractFirstTurn`：`[user, assistant]`、`[user, tool, tool, assistant]`（agent 模式，确认排除 tool）、超长截断（UTF-8 边界）等。
- `shouldAutoTitle`（触发条件判断的纯函数版本）：首轮 + 默认标题 → true；标题非默认 → false；`auto_title_attempted` 已置位 → false；无 api_key → false。
- mock API 响应 → 标题被正确设置：复用现有 mock 测试基础设施（参考 `src/ai_chat.zig:5945` 一带的 mock response 测试）。

不在 fast 套件里发真实网络请求。完整套件 `zig build test-full` 为合并前门禁。

## 7. 非目标（YAGNI）

- 不做用户可配置的标题模型（仅复用对话模型；如未来需要，可加 `ai-chat-title-model` 配置项，本次不做）。
- 不做"重新生成标题"按钮 / 命令。
- 不做基于多轮（首轮之后）的标题更新。
- 不做标题生成的流式显示。
- 不改 `remote/` web 端逻辑（标题通过既有 history / snapshot 通道自然下发，无需改动）。

## 8. 涉及文件预估

- `src/ai_chat.zig`：`Session` 新增字段；`maybeAutoTitle` / `titleThreadMain` / `extractFirstTurn` / `cleanTitle` / `shouldAutoTitle`；在 `appendAssistantResult`、`finishAssistantStream` 末尾调用；`deinit` 中 join `title_thread`；历史恢复入口置位 `auto_title_attempted`；新增单元测试。
- `src/test_fast.zig`：登记新增的平台无关测试模块（若拆分为独立模块）。

设计验证仍需在实现时确认：历史恢复入口的确切位置、`runChatRequestForMessages` 能否被复用于"无工具、独立 messages"的精简请求（或需要一个更底层的小封装）。
