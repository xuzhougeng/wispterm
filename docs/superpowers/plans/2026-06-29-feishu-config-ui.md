# 飞书配置 UI(命令面板)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在命令面板加两条命令——「启用/停用飞书直连」(切 `feishu-enabled`)与「飞书 bot 配置」(打开 App ID/App Secret 凭证表单,保存写配置 + 重启提示),不动设置 overlay。

**Architecture:** 复用两套现成模式,不引入新抽象——命令面板镜像微信 `connect_wechat`(`src/command/center_state.zig` 命令条目 + `src/renderer/overlays.zig` dispatch);凭证表单镜像 AI profile 表单(`src/renderer/overlays/assistant_profiles.zig` 的 `State{bufs,lens,focus}` + overlays.zig 的 `g_ai_form_visible` 表单分支)。保存走 `Config.setConfigValue`(同微信开关),非 profile store。

**Tech Stack:** Zig 0.15.2;WispTerm overlays + 命令面板 + config。

## Global Constraints

- **设计源**:`docs/superpowers/specs/2026-06-29-feishu-config-ui-design.md`。
- **App Secret 绝不入日志**(沿用飞书 channel 纪律);表单内 app_secret **打码显示**(`•`×长度)。
- **不预填 app-secret 明文**;保存时 **secret 留空 → 不覆盖**已有 env/配置(只有输入新值才 setConfigValue)。
- **配置后需重启**;保存/切换后弹 `showStatusToast` 提示重启。
- **config.zig 不改**(`feishu-enabled`/`feishu-app-id`/`feishu-app-secret` 键 + 解析已存在);**设置 overlay 不改**。
- 每个改 .zig 的任务收尾必须:`zig build test`、`zig build test-full -Dtarget=aarch64-macos`、`zig build macos-app -Dtarget=aarch64-macos`、`zig fmt --check build.zig src` 全绿(默认 `zig build` 是 Windows target;macos-app 抓 lazy-analysis;fmt-check 本地必跑——PR #416 教训)。
- **git 纪律**:禁 `git --amend`、禁 `git add -A`/`git add .`;只 add 任务列出的文件;**绝不** `git add .superpowers/`。提交信息末行 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

---

## Task 1: `feishu_config.zig` 凭证表单 State(纯逻辑)

**Files:**
- Create: `src/renderer/overlays/feishu_config.zig`
- Modify: `src/test_fast.zig`(加一行 import 让 State 测试进 fast 套件)

**Interfaces:**
- Produces:
  - `FEISHU_FIELD_COUNT: usize = 2`、`FEISHU_FIELD_MAX: usize = 256`
  - `FeishuField = enum(usize){ app_id = 0, app_secret = 1 }`
  - `State`:`bufs: [2][256]u8`、`lens: [2]usize`、`focus: usize`;方法 `reset()`、`value(FeishuField) []const u8`、`setValue(FeishuField, []const u8)`、`append(FeishuField, []const u8)`、`backspace(FeishuField)`、`focusNextRow()`、`focusPrevRow()`。

- [ ] **Step 1: 写 State + tests(失败先行)**

写 `src/renderer/overlays/feishu_config.zig`:

```zig
const std = @import("std");

pub const FEISHU_FIELD_COUNT: usize = 2;
pub const FEISHU_FIELD_MAX: usize = 256;

pub const FeishuField = enum(usize) {
    app_id = 0,
    app_secret = 1,
};

/// 凭证表单的固定缓冲区状态(镜像 assistant_profiles.State 的最小子集)。
/// focus: 0..FEISHU_FIELD_COUNT-1 = 字段行;FEISHU_FIELD_COUNT = Save 行。
pub const State = struct {
    bufs: [FEISHU_FIELD_COUNT][FEISHU_FIELD_MAX]u8 = undefined,
    lens: [FEISHU_FIELD_COUNT]usize = .{0} ** FEISHU_FIELD_COUNT,
    focus: usize = 0,

    pub fn reset(self: *State) void {
        self.lens = .{0} ** FEISHU_FIELD_COUNT;
        self.focus = 0;
    }

    pub fn value(self: *const State, field: FeishuField) []const u8 {
        const i = @intFromEnum(field);
        return self.bufs[i][0..self.lens[i]];
    }

    pub fn setValue(self: *State, field: FeishuField, text: []const u8) void {
        const i = @intFromEnum(field);
        const n = @min(text.len, FEISHU_FIELD_MAX);
        @memcpy(self.bufs[i][0..n], text[0..n]);
        self.lens[i] = n;
    }

    pub fn append(self: *State, field: FeishuField, bytes: []const u8) void {
        const i = @intFromEnum(field);
        for (bytes) |b| {
            if (self.lens[i] >= FEISHU_FIELD_MAX) return; // 截断,不溢出
            self.bufs[i][self.lens[i]] = b;
            self.lens[i] += 1;
        }
    }

    pub fn backspace(self: *State, field: FeishuField) void {
        const i = @intFromEnum(field);
        if (self.lens[i] == 0) return;
        var n = self.lens[i] - 1;
        while (n > 0 and (self.bufs[i][n] & 0xC0) == 0x80) : (n -= 1) {} // 退一个 UTF-8 码点
        self.lens[i] = n;
    }

    pub fn focusNextRow(self: *State) void {
        if (self.focus < FEISHU_FIELD_COUNT) self.focus += 1; // 上限 = Save 行
    }

    pub fn focusPrevRow(self: *State) void {
        if (self.focus > 0) self.focus -= 1;
    }
};

test "append then value round-trips" {
    var s = State{};
    s.append(.app_id, "cli_abc123");
    try std.testing.expectEqualStrings("cli_abc123", s.value(.app_id));
    try std.testing.expectEqualStrings("", s.value(.app_secret));
}

test "append truncates at FEISHU_FIELD_MAX without overflow" {
    var s = State{};
    const big = "x" ** (FEISHU_FIELD_MAX + 50);
    s.append(.app_secret, big);
    try std.testing.expectEqual(FEISHU_FIELD_MAX, s.value(.app_secret).len);
}

test "backspace drops one byte and is a no-op when empty" {
    var s = State{};
    s.append(.app_id, "ab");
    s.backspace(.app_id);
    try std.testing.expectEqualStrings("a", s.value(.app_id));
    s.backspace(.app_id);
    s.backspace(.app_id); // empty -> no-op, no underflow
    try std.testing.expectEqualStrings("", s.value(.app_id));
}

test "backspace drops a whole multibyte codepoint" {
    var s = State{};
    s.append(.app_id, "a\u{4f60}"); // "a你"
    s.backspace(.app_id);
    try std.testing.expectEqualStrings("a", s.value(.app_id));
}

test "setValue replaces and truncates" {
    var s = State{};
    s.append(.app_id, "old");
    s.setValue(.app_id, "new-id");
    try std.testing.expectEqualStrings("new-id", s.value(.app_id));
    const big = "y" ** (FEISHU_FIELD_MAX + 10);
    s.setValue(.app_secret, big);
    try std.testing.expectEqual(FEISHU_FIELD_MAX, s.value(.app_secret).len);
}

test "focus navigation clamps over fields and Save row" {
    var s = State{};
    try std.testing.expectEqual(@as(usize, 0), s.focus);
    s.focusPrevRow(); // clamp at 0
    try std.testing.expectEqual(@as(usize, 0), s.focus);
    s.focusNextRow();
    s.focusNextRow(); // now at FEISHU_FIELD_COUNT (Save row)
    try std.testing.expectEqual(FEISHU_FIELD_COUNT, s.focus);
    s.focusNextRow(); // clamp at Save row
    try std.testing.expectEqual(FEISHU_FIELD_COUNT, s.focus);
}

test "reset clears lengths and focus" {
    var s = State{};
    s.append(.app_id, "x");
    s.focus = FEISHU_FIELD_COUNT;
    s.reset();
    try std.testing.expectEqual(@as(usize, 0), s.value(.app_id).len);
    try std.testing.expectEqual(@as(usize, 0), s.focus);
}
```

- [ ] **Step 2: 把测试挂进 fast 套件**

`feishu_config.zig` 仅 import std(纯逻辑),可进 fast 套件。在 `src/test_fast.zig` 的 `_ = @import("...")` 聚合段(约 126–135 行那批)加一行:

```zig
    _ = @import("renderer/overlays/feishu_config.zig");
```

- [ ] **Step 3: 跑测试**

Run: `zig build test`
Expected: 通过(含上面 7 个 feishu_config State 测试);exit 0。

- [ ] **Step 4: fmt + commit**

```bash
zig fmt src/renderer/overlays/feishu_config.zig
zig fmt --check build.zig src   # 期望 exit 0
git add src/renderer/overlays/feishu_config.zig src/test_fast.zig
git commit  # feat(feishu): credential-form State (fixed-buffer fields)  + Co-Authored-By trailer
```

---

## Task 2: 凭证表单 overlay(open/编辑/渲染/保存)+ enabled toggle 助手

**Files:**
- Modify: `src/renderer/overlays.zig`
- Modify: `src/i18n.zig`(表单/toast 键)

**Interfaces:**
- Consumes: Task 1 的 `feishu_config.{State, FeishuField, FEISHU_FIELD_COUNT}`。
- Produces(供 Task 3 调用):`openFeishuConfigForm() void`、`toggleFeishuEnabled() void`。
- 注:`openFeishuConfigForm`/`toggleFeishuEnabled` 本任务内**未被调用**(Task 3 接线),都用 `fn`(文件级未调用函数 Zig 不报错;最终可达性在 Task 3 的 macos-app 验证)。`saveFeishuConfig`/render/键处理在本任务即被调用(在键分发与渲染循环里),故已被分析。

- [ ] **Step 1: i18n 键(EN + zh 两表都加,否则不编译)**

`src/i18n.zig`:在 i18n struct 定义加字段,并在**每个语言表**(EN、zh)填值:

```zig
// struct 字段
feishu_form_title: []const u8,
feishu_form_app_id: []const u8,
feishu_form_app_secret: []const u8,
feishu_form_secret_set_hint: []const u8,
feishu_form_save: []const u8,
toast_feishu_restart: []const u8,
```

EN 表:
```zig
.feishu_form_title = "Feishu bot config",
.feishu_form_app_id = "App ID",
.feishu_form_app_secret = "App Secret",
.feishu_form_secret_set_hint = "already set — leave blank to keep",
.feishu_form_save = "Save",
.toast_feishu_restart = "Feishu setting updated — restart WispTerm to apply",
```

zh 表:
```zig
.feishu_form_title = "飞书 bot 配置",
.feishu_form_app_id = "App ID",
.feishu_form_app_secret = "App Secret",
.feishu_form_secret_set_hint = "已设置,留空保留",
.feishu_form_save = "保存",
.toast_feishu_restart = "飞书配置已更新,重启 WispTerm 生效",
```

(若仓库有 >2 个语言表,每个都要填,否则缺字段编译失败。)

- [ ] **Step 2: 表单状态 + 访问器 + import**

`src/renderer/overlays.zig`:
- 顶部加 import:`const feishu_config = @import("overlays/feishu_config.zig");`(放在 `assistant_profiles` import 旁)。
- 加常量:`const FEISHU_FIELD_COUNT = feishu_config.FEISHU_FIELD_COUNT;`、`const FeishuField = feishu_config.FeishuField;`。
- 在 `g_ai_form_visible`(约 2285)旁加:`threadlocal var g_feishu_form_visible: bool = false;`、`threadlocal var g_feishu_config_state: feishu_config.State = .{};`。
- 加访问器(同 `assistantProfiles()` 约 118):`fn feishuConfig() *feishu_config.State { return &g_feishu_config_state; }`。

- [ ] **Step 3: open / toggle / save**

镜像 `openAiForm`(约 3888)清理其它 overlay 的写法,加:

```zig
fn openFeishuConfigForm() void {
    // 镜像 openAiForm:关闭其它 overlay(照搬 openAiForm 里清的那组 g_*_visible)
    g_session_launcher_visible = false;
    g_ssh_list_visible = false;
    g_ssh_form_visible = false;
    g_ai_list_visible = false;
    g_ai_form_visible = false;
    commandPaletteClose();
    const st = feishuConfig();
    st.reset();
    if (AppWindow.g_allocator) |allocator| {
        var cfg = Config.load(allocator) catch Config{};
        defer cfg.deinit(allocator);
        if (cfg.@"feishu-app-id") |id| st.setValue(.app_id, id); // app-id 预填明文;secret 不预填
    }
    st.focus = 0;
    g_feishu_form_visible = true;
}

fn toggleFeishuEnabled() void {
    const allocator = AppWindow.g_allocator orelse return;
    var cfg = Config.load(allocator) catch Config{};
    defer cfg.deinit(allocator);
    Config.setConfigValue(allocator, "feishu-enabled", if (cfg.@"feishu-enabled") "false" else "true") catch {};
    showStatusToast(i18n.s().toast_feishu_restart);
}

fn saveFeishuConfig() void {
    const allocator = AppWindow.g_allocator orelse return;
    const st = feishuConfig();
    const app_id = st.value(.app_id);
    if (app_id.len > 0) Config.setConfigValue(allocator, "feishu-app-id", app_id) catch {};
    const secret = st.value(.app_secret);
    if (secret.len > 0) Config.setConfigValue(allocator, "feishu-app-secret", secret) catch {}; // 留空不覆盖
    g_feishu_form_visible = false;
    st.reset();
    showStatusToast(i18n.s().toast_feishu_restart);
}
```

> ⚠️ `openFeishuConfigForm` 里清 overlay 的那组 `g_*_visible` 必须照搬 `openAiForm` 当前实际清的字段(读 3888 那个函数,逐个对齐),别凭这里列的猜——字段集可能随版本变。

- [ ] **Step 4: 键分发(字符 / 方向 / Enter / 退格 / Esc)**

在 overlays.zig 现有 `if (g_ai_form_visible)` 的并列处各加一个 `if (g_feishu_form_visible)` 分支,镜像其结构:

- 字符 codepoint(约 2485):
```zig
if (g_feishu_form_visible) {
    if (feishuConfig().focus >= FEISHU_FIELD_COUNT) return;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(codepoint, &buf) catch return;
    feishuConfig().append(@enumFromInt(feishuConfig().focus), buf[0..n]);
    return;
}
```
- 文本输入(约 2496,IME/粘贴):
```zig
if (g_feishu_form_visible) {
    if (feishuConfig().focus >= FEISHU_FIELD_COUNT) return false;
    feishuConfig().append(@enumFromInt(feishuConfig().focus), text);
    return true;
}
```
- 方向/Enter/退格/Esc(约 2608,镜像 AI 分支的 switch 形态):
```zig
if (g_feishu_form_visible) {
    switch (key) {
        .tab, .arrow_down => feishuConfig().focusNextRow(),
        .arrow_up => feishuConfig().focusPrevRow(),
        .enter => if (feishuConfig().focus == FEISHU_FIELD_COUNT) saveFeishuConfig(),
        .backspace => if (feishuConfig().focus < FEISHU_FIELD_COUNT)
            feishuConfig().backspace(@enumFromInt(feishuConfig().focus)),
        .escape => {
            g_feishu_form_visible = false;
            feishuConfig().reset();
        },
        else => {},
    }
    return true;
}
```

> 实际 `key` 枚举成员名/匹配方式以现有 AI 分支(2608)为准;`appendAiFormCodepoint`/`appendAiFormText` 是 AI 版的等价物,可参考其实现细节。把 feishu 分支放在 AI 分支之前或之后均可(两个 visible 标志互斥)。

- [ ] **Step 5: 渲染(含 app_secret 打码)**

找到 AI 表单的渲染入口(grep:`g_ai_form_visible` 在渲染循环里 gate 的那处 + 画 `assistantProfiles()` 字段的函数),镜像写 `renderFeishuConfigForm(...)`,并在渲染循环里加 `if (g_feishu_form_visible) renderFeishuConfigForm(...);`。要点:
- 标题 `i18n.s().feishu_form_title`;两字段行(`feishu_form_app_id` / `feishu_form_app_secret`)+ Save 行(`feishu_form_save`)+ 重启提示行。
- 高亮 `feishuConfig().focus` 当前行。
- **app_secret 行打码**:显示 `•` × `feishuConfig().lens[1]`(不画明文);若该字段为空且配置里已有 secret,显示 `i18n.s().feishu_form_secret_set_hint` 占位。app_id 行正常显示 `feishuConfig().value(.app_id)`。

> 渲染 API(布局/文字绘制函数签名)照搬 AI 表单 render 的同款调用;打一个长度匹配的 `•` 串可用栈上小 buffer 循环填充(`•` 是 3 字节 UTF-8,注意按"字符数"而非字节数画)。

- [ ] **Step 6: 构建验证**

```bash
zig fmt src/renderer/overlays.zig src/i18n.zig
zig fmt --check build.zig src                       # exit 0
zig build test                                       # exit 0
zig build test-full -Dtarget=aarch64-macos          # exit 0(忽略已知 flaky;transient 先重跑)
zig build macos-app -Dtarget=aarch64-macos          # exit 0(关键:抓 render/save 的 lazy-analysis)
```
Expected: 全绿。

- [ ] **Step 7: commit**

```bash
git add src/renderer/overlays.zig src/i18n.zig
git commit  # feat(feishu): credential-config form overlay + enabled toggle (config write, restart toast, masked secret)  + Co-Authored-By
```

---

## Task 3: 命令面板两条命令 + dispatch 接线

**Files:**
- Modify: `src/command/center_state.zig`(CommandAction 变体 + 列表条目 + 测试)
- Modify: `src/renderer/overlays.zig`(dispatch 两个 case)
- Modify: `src/i18n.zig`(命令标题/详情键)

**Interfaces:**
- Consumes: Task 2 的 `openFeishuConfigForm()`、`toggleFeishuEnabled()`;`center_state` 的 `CommandAction`。
- Produces: 命令面板出现「启用/停用飞书直连」「飞书 bot 配置」两条,点选分别 toggle / 开表单。

- [ ] **Step 1: i18n 命令文案(EN + zh 两表)**

`src/i18n.zig` 加字段 + 两表填值:
```zig
cmd_toggle_feishu: []const u8,
cmd_toggle_feishu_detail: []const u8,
cmd_configure_feishu: []const u8,
cmd_configure_feishu_detail: []const u8,
```
EN:`"Toggle Feishu direct"` / `"Enable or disable the Feishu bot (restart to apply)"` / `"Configure Feishu bot"` / `"Enter App ID / App Secret"`。
zh:`"启用/停用飞书直连"` / `"开关飞书 bot(重启生效)"` / `"飞书 bot 配置"` / `"填写 App ID / App Secret"`。

- [ ] **Step 2: center_state 命令(枚举 + 列表)+ 失败测试先行**

读 `src/command/center_state.zig`:`CommandAction` 枚举(约 33,有 `connect_wechat`)、命令列表(约 87,`.{ .title=..., .detail=..., .shortcut="", .action=.connect_wechat }`)、测试段(约 407 `expectCommandEntry`)。

- `CommandAction` 加:`toggle_feishu,` `configure_feishu,`。
- 命令列表加两条(放在 WeChat 条目附近,渠道相关聚一起):
```zig
.{ .title = i18n.s().cmd_toggle_feishu, .detail = i18n.s().cmd_toggle_feishu_detail, .shortcut = "", .action = .toggle_feishu },
.{ .title = i18n.s().cmd_configure_feishu, .detail = i18n.s().cmd_configure_feishu_detail, .shortcut = "", .action = .configure_feishu },
```
> 列表条目的 title/detail 取值方式以现有条目为准:若现有用 `i18n.s().xxx` 则照此;若用字面量则字面量。务必对齐现有写法。
- 测试(若现有测试断言命令总数,同步 +2):
```zig
try expectCommandEntry(i18n.s().cmd_toggle_feishu, .toggle_feishu);
try expectCommandEntry(i18n.s().cmd_configure_feishu, .configure_feishu);
```

- [ ] **Step 3: overlays.zig dispatch**

在命令 dispatch 处(约 673,`.connect_wechat => connectWeixinDirect(),`)加两个 case:
```zig
.toggle_feishu => toggleFeishuEnabled(),
.configure_feishu => openFeishuConfigForm(),
```
> 该 switch 若是穷尽匹配,加 CommandAction 变体后**必须**在此加 case,否则编译失败——本任务同时改枚举与 dispatch,保持穷尽。

- [ ] **Step 4: 测试 + 构建**

```bash
zig fmt src/command/center_state.zig src/renderer/overlays.zig src/i18n.zig
zig fmt --check build.zig src                       # exit 0
zig build test                                       # exit 0(含 center_state 新断言)
zig build test-full -Dtarget=aarch64-macos          # exit 0
zig build macos-app -Dtarget=aarch64-macos          # exit 0(此时 open/toggle 已被 dispatch 调用,完整可达)
```

- [ ] **Step 5: commit**

```bash
git add src/command/center_state.zig src/renderer/overlays.zig src/i18n.zig
git commit  # feat(feishu): command-palette entries — toggle enable + open config form  + Co-Authored-By
```

---

## 收尾:真机 E2E(实现完三任务后)

- `zig build macos-app -Dtarget=aarch64-macos` 重建 `.app`。
- 命令面板(打开命令面板)→ 见「启用/停用飞书直连」「飞书 bot 配置」两条。
- 「飞书 bot 配置」→ 表单出现;填 App ID、App Secret(secret 显示为 `•`);↑↓ 切字段;Save 行 Enter → 重启 toast、表单关闭。
- 检查配置文件:`feishu-app-id`/`feishu-app-secret` 已写入;**secret 不在任何日志出现**。
- 「启用/停用飞书直连」→ toast;配置 `feishu-enabled` 翻转。
- 重启 WispTerm → 飞书按配置启动(与 env 路径一致)。

## Self-Review(对照 spec)

- 命令面板 toggle + 配置表单两条 → Task 3 ✓;凭证表单 app-id/app-secret + 打码 + 保存 + 留空不覆盖 → Task 2 ✓;State → Task 1 ✓;i18n EN+zh → Task 2/3 ✓;不动 config.zig/设置 overlay → 约束 ✓。
- 类型一致:`FeishuField`/`FEISHU_FIELD_COUNT`/`State` 跨任务一致;`openFeishuConfigForm`/`toggleFeishuEnabled`/`saveFeishuConfig` 命名跨 Task 2/3 一致。
- 无占位:Task 1 全代码;Task 2/3 给新函数体 + 精确锚点(镜像处标注行号)+ 构建命令与期望。
