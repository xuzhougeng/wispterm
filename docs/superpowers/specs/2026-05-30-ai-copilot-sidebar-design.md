# 设计：右侧 AI Copilot 侧栏（Issue #98）

- 日期：2026-05-30
- 关联 Issue：[#98 终端本身的 AI copilot](https://github.com/xuzhougeng/wispterm/issues/98)
- 状态：设计已确认，待写实现计划

## 1. 背景与动机

当前 AI 能力以独立的 **AI Agent tab** 形式存在。它要操作某个终端时，必须先 `terminal_list`
枚举所有 surface，再 `terminal_select` 选一个 `surface_id`，存在两个痛点：

1. 入口绕（`Ctrl+Shift+T` → 选 “AI Agent”）。
2. Agent 需要自己在多个 surface 里猜“当前那个”，**会选错 tab**。

目标：一个**快捷键唤起、停靠在当前终端右侧的 AI copilot 侧栏**，自动以“当前聚焦终端”为
上下文，无需手动选 tab。

## 2. 关键发现（已存在、可复用的基础设施）

- `TabState` 已带 `kind: terminal | ai_chat` 与 `ai_chat_session: ?*ai_chat.Session`
  字段（`src/appwindow/tab.zig:40-49`）——per-tab 会话存储天然就位。
- `browser_panel` 是一套成熟的**右侧面板状态机**：`g_visible` / `g_width` / `onTabClosed`
  / `onTabReordered` / `setWidth` / `panelWidthForWindow` / `maxWidthForWindow`
  （`src/browser_panel.zig:55-114`）。
- `file_explorer` 是**左侧 GL 渲染、可拉宽、可开关**的面板范式。
- `g_agent_context_surface_id` 在每次活动 surface 切换时自动写成当前聚焦终端
  （`src/AppWindow.zig:738-746` `syncActiveSurfaceCaches`），并被
  `collectAgentToolSnapshot`（`src/AppWindow.zig:2427`）用作 `is_context` / `active_tab`。
- 工具宿主（`collectAgentToolSnapshot` 等 ToolHost 实现）与 `ChatRequest.write_context_surface_id`
  字段（`src/ai_chat.zig:261`、写入点 `:4271`）均可原样复用。

结论：「自动上下文」的**数据基础已存在**，本期主要补：右侧 GL 面板、快捷键入口、把 Agent
默认锚定到当前终端。

## 3. 已确认的设计决策

| 维度 | 决定 |
|---|---|
| 实现方案 | 方案 1：新建 `ai_sidebar` 模块，把现有 `ai_chat.Session` 宿主进右侧 GL 面板 |
| 会话模型 | 每个终端 tab 各自一个对话（per-tab） |
| 右侧共存 | 互斥单槽：开 copilot 自动收起 browser / Markdown 预览，反之亦然 |
| 工具范围 | 全量工具，默认锚定当前终端（免 `terminal_select`） |
| 上下文注入 | 混合——每条用户消息附轻量快照（cwd + 最近 ~40 行可见输出） |
| 会话存储 | 终端 tab 新增独立字段 `copilot_session`（不复用 `ai_chat_session`） |
| AI Profile | 与 AI Agent 共用同一个默认 profile（同 model / key / 协议） |
| 开关快捷键 | `Ctrl+Shift+A`（macOS 自动 → `Cmd+Shift+A`），可在 config 重映射 |
| 宽度 | 跨 tab 共享 `g_width`，**不持久化**（重启回默认） |

## 4. 架构

### 4.1 新模块 `src/ai_sidebar.zig`（状态 + 布局）

只负责面板状态与布局数学，**不重写聊天渲染**。公开接口镜像 `browser_panel`：

```
threadlocal var g_visible: bool
threadlocal var g_width: f32 = DEFAULT_WIDTH
const DEFAULT_WIDTH / MIN_WIDTH / MAX_WIDTH / MIN_CONTENT_WIDTH / RESIZE_HIT_WIDTH

fn isVisibleForActiveTab() bool   // g_visible && 当前 tab.kind == .terminal
fn width() f32                    // 可见则 g_width，否则 0
fn setWidth / maxWidthForWindow / panelWidthForWindow
fn onTabClosed / onTabReordered   // tab 生命周期相关的宽度/状态维护
fn toggle / show / hide
```

与 `browser_panel` 的关键差异：browser_panel 是「单一 owner tab」模型；copilot 是**每个终端
tab 各自一份会话**，因此**不设 `g_owner_tab`**。`g_visible` 是全局开关，面板永远渲染「当前
活动终端 tab」自己的会话，切 tab 即切对话。

### 4.2 会话存储（扩展 TabState）

终端 tab 新增独立字段：

```
copilot_session: ?*ai_chat.Session = null,   // 仅终端 tab 的 copilot 使用
```

- 首次在某终端 tab 打开 copilot 时**惰性创建** `Session`，用默认 AI profile。
- `TabState.deinit` 的 `.terminal` 分支需补释放 `copilot_session`（当前该分支仅
  `tree.deinit()`，`src/appwindow/tab.zig:76-87`）。
- 切 tab 不销毁会话，仅切换面板渲染目标。

### 4.3 布局集成（互斥单槽）

- 在 `rightPanelsWidth()`（`src/AppWindow.zig:638`）的和里加入 `ai_sidebar.width()`；终端内容
  区自动让出宽度，沿用现有三段式布局，不动左面板。
- **互斥仲裁**（集中在一个小函数）：`ai_sidebar.show()` 时隐藏 `browser_panel` 与
  `markdown_preview_panel`；这两者 show 时置 `ai_sidebar.g_visible = false`。保证右侧任意
  时刻只有一个面板。
- 宽度：`g_width` 为 threadlocal 全局，跨 tab 共享；不持久化（与 browser_panel 行为一致）。

## 5. 行为

### 5.1 绑定目标 = 当前聚焦 surface

- 直接以 `g_agent_context_surface_id`（已自动跟踪当前聚焦终端）为绑定目标，copilot 不另维护。
- 同一 tab 内切分屏焦点 → 绑定目标随之改变；对话历史不变，后续命令打到新焦点 surface。

### 5.2 工具默认目标（全量工具，免 terminal_select）

- copilot 会话复用**同一套 ToolHost**，工具全集保留。
- 构建 copilot 的 chat request 时**预置 `write_context_surface_id` = 绑定 surface**
  （`src/ai_chat.zig:261` / `:4271`）。于是 `ssh_session_exec` / `wsl_session_exec` /
  `terminal_repl_exec` 等在模型**未显式给 `surface_id` 时默认落到绑定的当前终端**。
- copilot 变体系统提示词告知模型：「你已绑定到用户当前终端，默认在它上面操作；仅当用户明确
  要操作别的终端/服务器时才用 `terminal_list` / `terminal_select`。」既防串台又保留跨终端能力。

### 5.3 混合上下文注入

- 每次提交用户消息前，从绑定 surface 取一份**轻量快照**附到该轮上下文：`cwd` + 最近
  `N`（默认常量 `≈40`）行可见输出。
- 复用 `buildRemoteSurfaceSnapshot`（`agentSurfaceSnapshot`，`src/AppWindow.zig:2459`）的能力，
  做一个只取尾部 N 行 + cwd 的「轻量版」。
- 完整历史 / 翻屏仍靠模型按需 `terminal_snapshot`。
- 轻量快照为**每轮即时生成的瞬时上下文**，不写入可重放的对话历史存档（区别于 skill 注入的
  replayable tool result）。

### 5.4 快捷键与焦点

- 新增 `Action.toggle_ai_copilot`，加入 `keybind.zig` 的 `Action` 枚举与 `default_bindings`，
  默认 `Ctrl+Shift+A`（mac 经现有 Ctrl→Cmd 重映射逻辑变为 `Cmd+Shift+A`）。
- 按下：打开侧栏并**把焦点直接落到 copilot 输入框**（可立即打字）；再按收起、焦点回终端。
- 仅终端 tab 生效（`isVisibleForActiveTab` 已挡非终端 tab）。

### 5.5 生命周期与降级

| 事件 | 行为 |
|---|---|
| 关闭整个终端 tab | 该 tab 的 `copilot_session` 随 `TabState.deinit` 释放（对话消失，符合 per-tab） |
| tab 重排 | 会话挂在 TabState 上随 tab 移动；`onTabReordered` 仅处理宽度/可见状态 |
| 分屏内关闭被绑定 surface | 对话保留；绑定目标自动回退到该 tab 新聚焦 surface |
| 绑定的 SSH 断开但 surface 仍在 | 对话保留；命令工具走现有 SSH 失败路径返回错误信息 |
| 请求进行中切走 / 关 tab | 复用现有 `Esc` 停止 + `requestCancelled` 取消路径；关 tab 前确保 in-flight 请求被取消，避免悬空指针 |

## 6. 渲染与输入

### 6.1 渲染（复用 ai_chat 绘制）

- 不重写聊天 UI：现有气泡 / 思考块 / 工具块绘制 + `ai_chat_layout.zig`（`x/w` 参数化）原样用。
- AppWindow 算好右侧矩形（`x = width − rightPanelsWidth`、宽 `ai_sidebar.width()`、高 = 内容区
  高）后，调现有 ai_chat 绘制例程，传入**当前活动终端 tab 的 `copilot_session` + 该窄矩形**。
- 复用 `ai_chat_scrollbar_model.zig` 滚动条与拉宽 grip（仿 browser_panel 的 `RESIZE_HIT_WIDTH`
  命中区 + `setWidth`）。

### 6.2 输入路由

- copilot 可见且持焦时，键鼠先喂 copilot（输入框编辑、滚动、选区复制、`Esc` 停止/收起），
  复用 `ai_chat_composer*` / `ai_chat_input_text.zig`。
- 焦点不在 copilot 时按键照常进终端。
- 焦点切换：`Ctrl+Shift+A` 打开即夺焦；点终端区域还焦终端；`Esc`（非请求中）收起侧栏并还焦终端。

## 7. 测试

纯逻辑做单测，并放进会被 `@import` 注册的测试文件（`test_fast.zig` / `test_main.zig`，否则
不会运行）：

- `ai_sidebar` 宽度夹取 / `panelWidthForWindow` / 互斥仲裁（开 copilot 关 browser、反之）。
- 轻量快照构造（cwd + 尾部 N 行截断；空输出 / 超长行边界）。
- copilot request 预置 `write_context_surface_id` = 绑定 surface（仿现有
  `write_context_surface_id` 测试，`src/ai_chat.zig:5891` 附近）。
- 默认目标逻辑：模型未给 `surface_id` 时落到绑定 surface。

回归基线：`zig build test` 原生运行；`test-full -Dtarget=x86_64-windows-gnu` 维持 497/499
（1 个已知 Windows-API 失败 + 1 skip）。

## 8. 范围边界（YAGNI / 本期不做）

- 宽度持久化（重启回默认）。
- per-surface 独立对话（已选 per-tab）。
- 并排叠加多个右面板（已选互斥单槽）。
- copilot 独立 profile（用 Agent 默认 profile）。
- 新增流式输出（沿用现有协议；anthropic 仍非流式）。
- 把 copilot 对话纳入 session 持久化 / 恢复（首期对话随 tab 生命周期；如需后续接 `/resume`）。

## 9. 影响文件一览（预估）

- 新增：`src/ai_sidebar.zig`。
- 改：`src/appwindow/tab.zig`（`copilot_session` 字段 + `.terminal` deinit）。
- 改：`src/keybind.zig`（`Action.toggle_ai_copilot` + 默认绑定）。
- 改：`src/AppWindow.zig`（`rightPanelsWidth` 纳入、互斥仲裁、矩形计算与渲染/输入路由、动作分发、
  copilot request 预置绑定 surface、轻量快照构造）。
- 改：`src/ai_chat.zig`（copilot 变体系统提示词；轻量快照辅助；默认目标逻辑，多数可复用现有路径）。
- 改：测试文件（新单测注册）+ 文档（`docs/ai-agent.md` 增 copilot 段落）。
