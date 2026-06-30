# 快速配置 AI（DeepSeek 一键配置）设计

**日期**：2026-06-30
**分支**：claude/musing-dewdney-5def57
**前置**：DeepSeek 已是默认 provider（session.zig:51-53 `DEFAULT_NAME="DeepSeek"` / `DEFAULT_BASE_URL="https://api.deepseek.com"` / `DEFAULT_MODEL="deepseek-v4-pro"`）；AI profile 存储（`src/assistant/profile/store.zig`）+ `ai-default-profile`/`ai-subagent-profile` 配置键（config.zig）已存在；命令面板 + Feishu 配置表单（PR #419/#420）为现成模板。

## 目标

让新手在**一个引导 overlay** 里**粘贴一次 DeepSeek API key**，点 Verify 校验通过后，自动建好两个 profile 并设为 main / subagent，即用即走：

- main 会话用 `deepseek-v4-pro`（profile 名 `DeepSeek`，写入 `ai-default-profile`）。
- Copilot subagent 用 `deepseek-v4-flash`（profile 名 `DeepSeek Flash`，写入 `ai-subagent-profile`）。
- 两个 profile 共用用户粘贴的同一个 key。
- overlay 同时引导用户去 `platform.deepseek.com` 注册拿 key + 一条教程链接（可点击打开浏览器）。

**相对 Feishu 配置流程，唯一新增的能力是「连通性校验」**：Feishu 表单明确「只存配置不验证」，本特性反过来——**校验通过才算配置成功**，校验是核心。

## 非目标（v1 不做）

- **不做多 provider 选择 / 模型下拉 / 自定义 base_url**：这是「快速配 DeepSeek 这一条路」，要全功能用现成的 AI profile 管理表单（`manage_ai_profiles`）。
- **不做重试退避 / 流式探测**：校验就是一次 `GET /models`，成功/失败二元结果。
- **不替用户改 flash 的 thinking/effort 等高级字段**：新建 profile 用文档默认值，用户后续可在 AI profile 表单里调。
- **不进设置 overlay**：同 Feishu，只走命令面板（零视觉成本、可扩展）。
- **key 不做本地格式校验**（不猜 `sk-` 前缀）：直接拿真实 API 验。

## 架构

复用 Feishu 配置表单的全套接线（命令面板命令 + 挂在 session-launcher plumbing 上的表单 overlay），**新增一个异步校验通道**。三块：

1. **命令面板命令** `quick_configure_ai` —— 镜像 `configure_feishu`（center_state.zig 枚举/条目/测试 + overlays.zig:687 dispatch + i18n.zig 双表）。
2. **引导表单 overlay** —— 镜像 `feishu_config.zig` 的 `State{ bufs, lens, focus }` + overlays.zig 的 open/close/render/输入接线。字段只有 1 个（API key）+ 2 条可点击链接行 + 1 个 Verify 行。
3. **异步校验通道**（新，本特性独有）—— 因 `g_overlay_state` 是 **threadlocal**（overlays.zig:101），worker 线程**不能碰** overlay/toast/可见性状态。故新增一个**非 threadlocal 的 mutex 保护全局**做 worker→主线程的结果通道，主线程在每帧 tick（AppWindow.zig:6670 `tickSessionLauncher` 旁）消费并落地。

> 关键约束：所有 overlay 状态变更、`setConfigValue`、`saveProfiles`、toast、关 overlay **全部在主线程**完成（与 `saveFeishuConfig` 同款），与现有代码习惯一致。worker 线程**只**做网络请求 + 写非 threadlocal 结果通道 + `postWakeup()`。

## 组件

### 1. 配置键 / profile 存储（已存在，无需改 config.zig / store.zig）

- 主配置键：`ai-default-profile`、`ai-subagent-profile`，用现成 `Config.setConfigValue(allocator, key, value)`。
- profile 存储：`assistant_profile_store.loadProfiles(allocator, out[])` / `saveProfiles(allocator, profiles[])`（全量数组读写，模式同 overlays.zig:4623-4627）。
- profile 字段写入用 `profile_codec.setProfileDefault(profile, field, value)`（profile_codec.zig:83）。

### 2. `src/renderer/overlays/quick_ai_config.zig`（新）

镜像 `feishu_config.zig`。**只有 1 个文本字段**（API key）+ 行模型 + 校验状态 + 纯逻辑 upsert（可单测）：

```zig
pub const KEY_FIELD_MAX: usize = 256;

// 行：0 = 打开注册页；1 = 打开教程页；2 = API key 字段；3 = Verify 行。
pub const ROW_OPEN_REGISTER: usize = 0;
pub const ROW_OPEN_TUTORIAL: usize = 1;
pub const ROW_KEY: usize = 2;
pub const ROW_VERIFY: usize = 3;
pub const ROW_COUNT: usize = 4;

pub const REGISTER_URL = "https://platform.deepseek.com";
pub const TUTORIAL_URL = "https://github.com/xuzhougeng/wispterm/wiki/AI-Copilot-zh"; // 占位，wiki 补 DeepSeek 章节后改这一行

pub const MAIN_PROFILE_NAME = "DeepSeek";
pub const MAIN_MODEL = "deepseek-v4-pro";
pub const SUB_PROFILE_NAME = "DeepSeek Flash";
pub const SUB_MODEL = "deepseek-v4-flash";

pub const VerifyState = enum { idle, verifying, ok, failed };

pub const State = struct {
    key_buf: [KEY_FIELD_MAX]u8 = undefined,
    key_len: usize = 0,
    focus: usize = ROW_KEY,        // 默认聚焦 key 字段
    status: VerifyState = .idle,
    err_buf: [128]u8 = undefined,  // 失败原因（展示用，不含 key）
    err_len: usize = 0,

    pub fn reset(self: *State) void { ... }
    pub fn key(self: *const State) []const u8 { ... }
    pub fn append(self: *State, bytes: []const u8) void { ... } // 仅 ROW_KEY 焦点；超 MAX 截断
    pub fn backspace(self: *State) void { ... }                 // 退一个 UTF-8 码点
    pub fn focusNextRow(self: *State) void { ... }              // 上限 ROW_VERIFY
    pub fn focusPrevRow(self: *State) void { ... }
    pub fn setError(self: *State, msg: []const u8) void { ... }
};

/// 纯逻辑、无 IO：在 profiles[0..count] 里按名 upsert 两个 DeepSeek profile，
/// 返回新的 count。已存在同名 → 更新连接字段（name/base_url/api_key/model/protocol），
/// 保留其它字段；不存在 → 追加并补文档默认值。可单测。
pub fn upsertProfiles(
    profiles: []profile_codec.AiProfile,
    count: usize,
    api_key: []const u8,
) usize { ... }
```

### 3. `src/assistant/quick_verify.zig`（新）—— 跨线程校验通道

把跨线程机制从 threadlocal 重灾区 overlays.zig 里隔离出来：

```zig
const Outcome = enum { ok, invalid_key, network_error };

var g_mutex: std.Thread.Mutex = .{};   // 非 threadlocal：worker↔主线程通道
var g_inflight: bool = false;
var g_done: bool = false;
var g_outcome: Outcome = .ok;
var g_status: u16 = 0;                  // HTTP 状态码（失败诊断用）

/// 主线程调用：拷贝 key 到堆，spawn worker 做 GET {base_url}/models。
/// 已有请求在飞则忽略（按返回值告知）。
pub fn start(allocator, base_url: []const u8, api_key: []const u8) bool { ... }

/// 主线程每帧调用：若 worker 已完成，取走结果（一次性，清 g_done）。
pub fn take() ?struct { outcome: Outcome, status: u16 } { ... }
```

- worker：`std.http.Client.fetch(.{ .location=.{.url=endpoint}, .method=.GET, .headers=.{ .authorization=.{ .override="Bearer "++key } } })`（镜像 request.zig:574-598 的 fetch 用法，但 GET 无 body）。
  - 200 → `.ok`；401/403 → `.invalid_key`；其它状态/网络异常 → `.network_error`（记 `g_status`）。
- worker 收尾：锁 mutex 写 outcome + `g_done=true` + 解锁 → `postWakeup()`（同 request.zig worker 唤醒 UI 的机制）→ 释放堆上的 key。

### 4. `src/renderer/overlays.zig`：表单 open/close/render/输入/tick/落地

镜像 Feishu 接线（下方「集成点」表逐一对应），新增：

- `const quick_ai_config = @import("overlays/quick_ai_config.zig");` + `const quick_verify = @import("../assistant/quick_verify.zig");`
- 访问器 `quickAiForm() *QuickAiFormState` / `quickAi() *quick_ai_config.State`（同 `feishuForm()`/`feishuConfig()`）。
- `openQuickAiForm()`：关其它 overlay → `commandPaletteClose()` 后置 `g_session_launcher_visible=true` + `quickAiForm().visible=true` + `quickAi().reset()`。**不预填 key**（安全节）。
- `closeQuickAiForm()`：`visible=false` + `reset()`。
- 输入分发，接进现有 `if (feishuForm().visible) ...` 并列分支：
  - **字符/粘贴**（overlays.zig:2496/2523 分支）：仅 `focus==ROW_KEY` 时 `quickAi().append(...)`。
  - **键**（overlays.zig:2587 分支）：↑↓/Tab 切焦点；Esc 关；Enter 按行——`ROW_OPEN_REGISTER`→`platform_open_url.open(alloc, .{.url=REGISTER_URL})`；`ROW_OPEN_TUTORIAL`→开 TUTORIAL_URL；`ROW_KEY`→焦点下移到 `ROW_VERIFY`；`ROW_VERIFY`→`startQuickAiVerify()`；Backspace（key 焦点）→`quickAi().backspace()`。
- `startQuickAiVerify()`（主线程）：key 空 → `quickAi().setError(empty 提示)` 不发请求；否则 `quickAi().status=.verifying` + `quick_verify.start(alloc, DEFAULT_BASE_URL, key)`。
- `tickQuickAiVerify()`（主线程，每帧）：`quick_verify.take()` 若有结果——
  - `.ok` → `applyQuickAiConfig()`（见下）→ `showStatusToast(i18n done)` → `closeQuickAiForm()`。
  - `.invalid_key` / `.network_error` → `quickAi().status=.failed` + `quickAi().setError(对应文案)`。
- `applyQuickAiConfig()`（主线程，全 IO 在此）：
  1. `loadAiProfiles()` 进 `assistantProfiles().profiles`（复用 overlays.zig:4623）。
  2. `count = quick_ai_config.upsertProfiles(profiles, count, key)`。
  3. `saveAiProfiles()`（overlays.zig:4627）。
  4. `Config.setConfigValue(alloc, "ai-default-profile", "DeepSeek")` + `Config.setConfigValue(alloc, "ai-subagent-profile", "DeepSeek Flash")`。
- `renderQuickAiForm(...)`（接进 `renderSessionLauncher` overlays.zig:5215，模式同 Feishu render 分支）：渲染标题 + 引导说明 + 2 条 URL 行（高亮可点击）+ key 字段行（**打码** `•`，安全节）+ Verify 行 + 一行状态文字（`idle`/`校验中…`/`✅ 配置完成`/`❌ <err>`）。
- 鼠标命中目标（overlays.zig:2251 枚举 + :2744 dispatch）：加 `.quick_ai_verify` / `.quick_ai_register` / `.quick_ai_tutorial` 三个目标，点击等价于对应行 Enter。
- commit 清理（overlays.zig:2437 模式）：`quickAiForm().visible=false`，防渲染门用陈旧状态。
- 标题/行数（overlays.zig:4690/4873）：`quickAiForm().visible` → form title / `ROW_COUNT`。

### 5. `src/renderer/overlays/state.zig`：wrapper（新结构）

镜像 `FeishuFormState`（state.zig:23）：

```zig
pub const QuickAiFormState = struct {
    config: quick_ai_config.State = .{},
    visible: bool = false,
};
// OverlayState 加字段：quick_ai: QuickAiFormState = .{},
```

### 6. `src/command/center_state.zig`：命令

镜像 `configure_feishu`（center_state.zig:38 枚举 / :93 条目 / :417 测试）：

- `CommandAction` 加 `quick_configure_ai`。
- 命令条目：`.{ .title = "Settings: Quick Configure AI", .detail = "Paste one DeepSeek API key to set up main + subagent models", .shortcut = "", .action = .quick_configure_ai }`。
- 更新命令条目测试（`expectCommandEntry("Settings: Quick Configure AI", .quick_configure_ai)`）+ 命令总数 +1。

### 7. `src/i18n.zig`：新增 arms（exhaustive switch，不加不编译）

- 命令标题 switch（i18n.zig:840 区）：`.quick_configure_ai => "设置：快速配置 AI"`。
- 命令详情 switch（i18n.zig:893 区）：`.quick_configure_ai => "粘贴一个 DeepSeek API key，自动配好主模型 + subagent"`。
- 表单文案键（EN+zh 双表，模式同 `feishu_form_*`）：`quick_ai_form_title`、`quick_ai_register_hint`、`quick_ai_tutorial_hint`、`quick_ai_key_label`、`quick_ai_verify_btn`、状态文案 `quick_ai_verifying` / `quick_ai_done` / `quick_ai_invalid_key` / `quick_ai_network_err` / `quick_ai_empty_key`。

### 8. `src/AppWindow.zig`：主线程 tick

在 `runMainLoop` 的 `while(running)` 里、`overlays.tickSessionLauncher()`（AppWindow.zig:6670）旁加一行 `overlays.tickQuickAiVerify();`。

## 数据流（含异步时序）

```
命令面板 "Settings: Quick Configure AI"
  → openQuickAiForm()（关其它 overlay，挂 session-launcher，reset）

[主线程] 用户读引导 → 回车/点击 URL 行 → platform_open_url.open（浏览器开注册页/教程）
[主线程] 用户粘贴/打字 key → quickAi().append
[主线程] 回车/点击 Verify 行 → startQuickAiVerify
           key 空 → setError("先粘贴 key") 停
           否则 status=.verifying，quick_verify.start(...) spawn worker

[worker]  GET https://api.deepseek.com/models  (Bearer key)
           200→ok / 401,403→invalid_key / 其它→network_error
           锁 mutex 写结果 + g_done=true，postWakeup()，free key

[主线程] 下一帧 tickQuickAiVerify → quick_verify.take()
           .ok          → applyQuickAiConfig（upsert 2 profile + saveProfiles
                          + setConfigValue×2）→ toast「AI 配置完成」→ closeQuickAiForm
           .invalid_key → status=.failed, setError("key 无效")
           .network_error → status=.failed, setError("网络错误 <status>")
```

落地后：下次 New Agent 读 `ai-default-profile=DeepSeek`（v4-pro）；Copilot subagent 工具读 `ai-subagent-profile=DeepSeek Flash`（v4-flash）；两 profile 从磁盘加载，key 一致。无需重启。

## 线程模型与跨线程通道（重点）

- `g_overlay_state` / `g_session_launcher_visible` 等是 **threadlocal**（overlays.zig:101/2293）：worker 看到的是自己零初始化副本，**禁止**在 worker 里读写 overlay 状态、toast、可见性、调 `showStatusToast` / 关 overlay。
- 唯一跨线程载体 = `quick_verify.zig` 里的非 threadlocal `g_*` + `g_mutex`：worker 只写它，主线程只读它（`take()` 一次性消费）。
- `applyQuickAiConfig` 的 `setConfigValue`/`saveProfiles` 虽是文件 IO，但放主线程执行（与 `saveFeishuConfig` 一致），避免「worker 写 WispTerm 配置」这种本仓库没有的新范式。
- worker 完成必须 `postWakeup()`，否则主线程不刷新、`tickQuickAiVerify` 拿不到结果（event-driven 渲染，见 memory `event-driven-wakeup`）。

## 错误处理

- key 空：不发请求，行内提示 `quick_ai_empty_key`。
- 校验在飞（status==.verifying / `quick_verify` g_inflight）：忽略重复 Verify。
- 401/403：`quick_ai_invalid_key`（key 无效，让用户重粘）。
- 其它 HTTP / 网络异常：`quick_ai_network_err` + 状态码，overlay 保持打开可重试。
- `setConfigValue`/`saveProfiles` 失败：`catch` → toast 失败提示，不静默吞。
- 失败时**不落地**任何 profile/config（仅 200 才 `applyQuickAiConfig`）。

## 安全

- **key 绝不入日志**：`quick_verify` / `startQuickAiVerify` / `applyQuickAiConfig` 不 log key 值（沿用 Feishu「凭证不入日志」纪律）。
- **key 字段打码**：render 时 key 字段显示 `•`×长度，不明文回显（同 Feishu app_secret 打码分支）。
- **不预填 key**：打开表单 key 字段为空（即使已有 DeepSeek profile 也不读其 key 进 buffer）。
- **err_buf 不含 key**：失败文案只放状态码/类别，绝不回显 key 片段。
- key 明文存 profile 文件（hex 编码，与现有 AI profile 一致，非新增暴露面）。

## 测试

纯逻辑（`zig build test` fast 套件可达，模式同 feishu_config 测试）：

- `quick_ai_config.State`：append（超 MAX 截断不溢出）/ backspace（UTF-8 整码点）/ key / reset / 焦点 clamp。
- `quick_ai_config.upsertProfiles`：
  - 空 profiles → 追加 2 个，name/model/base_url/api_key/protocol 正确，main=v4-pro、sub=v4-flash。
  - 已存在同名 → 更新 key/model、count 不变、其它字段保留。
  - 混合（仅一个存在）→ 一更一增。
- center_state：新命令存在且 action 正确（`expectCommandEntry`）+ 命令总数 +1。

UI / 集成（`test-full -Dtarget=aarch64-macos` + `macos-app` 编译）：

- `tickQuickAiVerify` 三分支（ok→落地+关 / invalid / network）的状态机（可对 `quick_verify.take` 注入桩 outcome）。
- `applyQuickAiConfig` 写出 `ai-default-profile=DeepSeek` / `ai-subagent-profile=DeepSeek Flash` 两键 + 两 profile 落盘。
- `zig fmt --check build.zig src` 绿（新文件按 zig fmt，吸取 PR #416 教训）。

> 网络层（`quick_verify` 的真实 GET /models）不进单测；真机校验见验证基线。

## 验证基线

- `zig build test`（fast）/ `zig build test-full -Dtarget=aarch64-macos` / `zig build macos-app -Dtarget=aarch64-macos` 全绿。
- `zig fmt --check build.zig src` 绿。
- 真机：命令面板「Settings: Quick Configure AI」→ 点注册/教程链接开浏览器 → 粘贴**有效** key 点 Verify → 见「✅ 配置完成」toast + overlay 关闭；`~/.config/wispterm/ai_profiles` 出现 `DeepSeek`+`DeepSeek Flash` 两行、配置文件出现两 `ai-*-profile` 键；New Agent 默认用 v4-pro。
- 真机反例：粘贴**无效** key 点 Verify → 见「❌ key 无效」、overlay 不关、无 profile 落地。

## 文件清单

- 新增：`src/renderer/overlays/quick_ai_config.zig`（State + upsertProfiles + 纯逻辑单测）
- 新增：`src/assistant/quick_verify.zig`（跨线程校验通道 + worker GET /models）
- 改：`src/renderer/overlays/state.zig`（`QuickAiFormState` wrapper + OverlayState 字段）
- 改：`src/renderer/overlays.zig`（import + 访问器 + open/close/render/输入/鼠标目标/`startQuickAiVerify`/`tickQuickAiVerify`/`applyQuickAiConfig`/commit 清理/标题行数）
- 改：`src/command/center_state.zig`（`quick_configure_ai` 枚举 + 命令条目 + 测试 + 计数）
- 改：`src/i18n.zig`（命令标题/详情 arms + 表单文案键 EN+zh）
- 改：`src/AppWindow.zig`（`runMainLoop` 加 `overlays.tickQuickAiVerify()`）
- （config.zig / store.zig / profile_codec.zig 无需改：键、读写、字段 setter 均已存在）
