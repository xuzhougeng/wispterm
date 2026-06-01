# WispTerm i18n 基础设施 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 WispTerm 的 UI chrome 搭建可扩展的 i18n 基础设施（en + zh-CN），启动时按系统 locale 自动选语言、config 可覆盖（重启生效），并把「状态 toast」与「命令中心」两个界面接通作为端到端样板。

**Architecture:** 新建 `src/i18n.zig`：扁平 `Strings` 字段结构体（en + zh_CN 两张静态表，字段无默认值 → 漏译编译期报错）承载调用点直接替换的扁平文案（toast、标签）；命令中心因英文文案已存在于 `command_center_state.command_entries` 静态表，改用「zh 覆盖」模式——`i18n.commandTitle/commandDetail(action)` 以已有的 `CommandAction` 枚举为键、用**穷尽 switch** 返回中文（`en` 时返回 `null`，调用点回退现有英文字面量），零英文重复。语言在 `main.zig` 加载完 config 后、`App.init` 前解析并 `setLang` 一次。

**Tech Stack:** Zig（comptime 字段结构体 + 穷尽 switch 保证完整性）、现有 Ghostty 风格 `key = value` config 体系、`std.process.getEnvVarOwned` 读 locale 环境变量。

**依赖与约束（实现前必读）：**
- 测试注册：Zig 测试只有被 `_ = @import` 进 `src/test_fast.zig`（快测，原生）或 `src/test_main.zig`（全量）才会跑。`i18n.zig`、`command_center_state.zig`、`config.zig` 走快测；`main.zig`/`overlays.zig` 属 app 图，只在 `zig build test-full` / 实际构建中验证。
- 导入方向（避免循环）：`i18n.zig` → `import command_center_state.zig`（仅取 `CommandAction` 类型）。`command_center_state.zig` **不**导入 i18n。`overlays.zig` 同时导入二者并在消费点调用 `i18n.commandTitle/Detail`。`config.zig` → `import i18n.zig`（仅取 `LanguageSetting` 类型），`i18n.zig` **不**导入 config（`resolve` 以 `LanguageSetting` 入参，无环）。命令中心 new_tab 的英文详情仍由原表 `entry.detail`（= `platform_pty_command.session_launcher_detail`）经 `orelse` 回退提供，故 i18n **无需**导入 pty_command。
- 命令表消费点（仅 3 处，均在 `src/renderer/overlays.zig`）：`commandEntryTitleMatches`（657）读 `entry.title`、`commandEntrySecondaryMatches`（662）读 `entry.detail`、渲染（1295）读 `entry.title`。
- `command_entries` 与 `CommandAction` 一一对应（38 项），`CommandAction` 定义于 `src/command_center_state.zig:5`。
- config 解析范式：`applyKeyValue`（`src/config.zig:680`）按 key 字符串分发；枚举字段参照 `RightClickAction.parse`（`config.zig:148`）。
- 启动锚点：`src/main.zig:152` `const cfg = try Config.load(allocator);`，其后 `render_diagnostics.enableFromConfig(...)`（`main.zig:163`）即语言解析插入点；`allocator` 在作用域内。

---

### Task 1: 创建 i18n 核心模块（Lang / Strings / s() / setLang）

**Files:**
- Create: `src/i18n.zig`
- Modify: `src/test_fast.zig`（注册 import）
- Modify: `src/test_main.zig`（注册 import）

- [ ] **Step 1: Write the failing test**

新建 `src/i18n.zig`，先只放最小机器（一个 `language_name` 字段用于验证切换），并在文件底部写测试：

```zig
//! UI 文案国际化（i18n）核心：扁平字段目录 + 当前语言。
//! 设计见 docs/superpowers/specs/2026-06-01-i18n-infrastructure-design.md
const std = @import("std");

pub const Lang = enum { en, zh_CN };

/// 调用点直接替换的扁平文案。字段无默认值 → 任一 locale 漏填某字段编译期报错，
/// 这是「方案 A」comptime 完整性保证的落地（无需手写 assert）。
pub const Strings = struct {
    language_name: []const u8,
};

const en = Strings{
    .language_name = "English",
};

const zh_CN = Strings{
    .language_name = "中文",
};

var current: *const Strings = &en;
var active_lang: Lang = .en;

/// 当前语言的文案表。调用点：`i18n.s().language_name`。
pub fn s() *const Strings {
    return current;
}

pub fn lang() Lang {
    return active_lang;
}

pub fn setLang(l: Lang) void {
    active_lang = l;
    current = switch (l) {
        .en => &en,
        .zh_CN => &zh_CN,
    };
}

test "setLang switches the active strings table" {
    defer setLang(.en); // 复位，避免污染其它测试
    setLang(.en);
    try std.testing.expectEqualStrings("English", s().language_name);
    try std.testing.expect(lang() == .en);
    setLang(.zh_CN);
    try std.testing.expectEqualStrings("中文", s().language_name);
    try std.testing.expect(lang() == .zh_CN);
}
```

- [ ] **Step 2: 注册到测试聚合器**

在 `src/test_fast.zig` 的 `test { ... }` 块内、`_ = @import("config.zig");` 一行附近加：

```zig
    _ = @import("i18n.zig");
```

在 `src/test_main.zig` 中同样加入 `_ = @import("i18n.zig");`（放在其它 `@import` 旁，保持风格一致）。

- [ ] **Step 3: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: 构建并运行成功，包含 i18n 测试，0 失败（fast 套件全绿）。

> 说明：本任务 test 与实现同文件一次写就，Step 1 的「failing」体现在模块尚不存在/未注册时无法编译；Step 3 通过即证明机器可用。

- [ ] **Step 4: Commit**

```bash
git add src/i18n.zig src/test_fast.zig src/test_main.zig
git commit -m "feat(i18n): add core catalog module (Lang/Strings/s/setLang)"
```

---

### Task 2: locale 检测与语言解析

**Files:**
- Modify: `src/i18n.zig`（加 `LanguageSetting`、`langFromLocaleTag`、`detectSystemLang`、`resolve`、`applyConfig`）

- [ ] **Step 1: Write the failing tests**

在 `src/i18n.zig` 末尾（`test "setLang..."` 之后）追加纯函数与测试：

```zig
/// config `language` 取值。auto = 跟随系统 locale。
pub const LanguageSetting = enum {
    auto,
    en,
    zh_CN,

    /// 解析 config 值；大小写/分隔符兼容；未知返回 null。
    pub fn parse(value: []const u8) ?LanguageSetting {
        var buf: [16]u8 = undefined;
        if (value.len > buf.len) return null;
        for (value, 0..) |c, i| {
            buf[i] = switch (c) {
                'A'...'Z' => c + 32, // tolower
                '_' => '-',
                else => c,
            };
        }
        const v = buf[0..value.len];
        if (std.mem.eql(u8, v, "auto")) return .auto;
        if (std.mem.eql(u8, v, "en")) return .en;
        if (std.mem.eql(u8, v, "zh-cn") or std.mem.eql(u8, v, "zh")) return .zh_CN;
        return null;
    }
};

/// 把 locale 标签（如 "zh_CN.UTF-8" / "en_US" / "zh"）映射到支持的语言。
/// 以 "zh" 开头（不分大小写）→ zh_CN；其余 → en。
pub fn langFromLocaleTag(tag: []const u8) Lang {
    if (tag.len >= 2) {
        const a = tag[0];
        const b = tag[1];
        const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
        if (la == 'z' and lb == 'h') return .zh_CN;
    }
    return .en;
}

test "langFromLocaleTag maps zh* to zh_CN, others to en" {
    try std.testing.expect(langFromLocaleTag("zh_CN.UTF-8") == .zh_CN);
    try std.testing.expect(langFromLocaleTag("zh") == .zh_CN);
    try std.testing.expect(langFromLocaleTag("ZH-cn") == .zh_CN);
    try std.testing.expect(langFromLocaleTag("zh_TW") == .zh_CN); // v1 唯一中文落点
    try std.testing.expect(langFromLocaleTag("en_US.UTF-8") == .en);
    try std.testing.expect(langFromLocaleTag("fr") == .en);
    try std.testing.expect(langFromLocaleTag("") == .en);
    try std.testing.expect(langFromLocaleTag("z") == .en);
}

test "LanguageSetting.parse handles aliases and invalid" {
    try std.testing.expect(LanguageSetting.parse("auto").? == .auto);
    try std.testing.expect(LanguageSetting.parse("en").? == .en);
    try std.testing.expect(LanguageSetting.parse("zh-CN").? == .zh_CN);
    try std.testing.expect(LanguageSetting.parse("zh_CN").? == .zh_CN);
    try std.testing.expect(LanguageSetting.parse("ZH").? == .zh_CN);
    try std.testing.expect(LanguageSetting.parse("de") == null);
    try std.testing.expect(LanguageSetting.parse("") == null);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL —— 当前 `Strings` 等已存在，但若先只贴测试会因引用未定义符号编译失败；按 TDD，确认编译/测试不通过后再补实现（本任务 Step 1 已含实现符号，故此步主要确认新测试被纳入）。

> 实操：Step 1 已把纯函数实现一并写入。若严格 red-green，可先只贴两个 `test` 块跑一次看编译失败（引用 `langFromLocaleTag`/`LanguageSetting` 未定义），再贴实现。

- [ ] **Step 3: 写检测与解析（读 env / 入口）**

继续在 `src/i18n.zig` 追加（放在测试块之前的实现区）：

```zig
const builtin = @import("builtin");

// Windows 在 env 缺失 LANG/LC_* 时，从用户界面语言（LANGID）兜底。
// 主语言号 = LANGID & 0x3FF；LANG_CHINESE = 0x04。仅由 Windows 构建验证，
// 原生（Linux）测试不覆盖此分支。
extern "kernel32" fn GetUserDefaultUILanguage() callconv(.winapi) u16;

/// 读系统 locale 环境变量（LC_ALL → LC_MESSAGES → LANG），映射到语言。
/// 都读不到时：Windows 回落到 GetUserDefaultUILanguage，其余平台 → en。
/// 调用方提供 allocator；本函数内部释放临时串。
pub fn detectSystemLang(allocator: std.mem.Allocator) Lang {
    const vars = [_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" };
    for (vars) |name| {
        const val = std.process.getEnvVarOwned(allocator, name) catch continue;
        defer allocator.free(val);
        if (val.len == 0) continue;
        return langFromLocaleTag(val);
    }
    if (builtin.os.tag == .windows) {
        if ((GetUserDefaultUILanguage() & 0x3ff) == 0x04) return .zh_CN; // LANG_CHINESE
    }
    return .en;
}

/// 按优先级解析最终语言：config 显式值优先；auto 跟随系统 locale；
/// 任何不可解析情形回退 en。
pub fn resolve(allocator: std.mem.Allocator, setting: LanguageSetting) Lang {
    return switch (setting) {
        .en => .en,
        .zh_CN => .zh_CN,
        .auto => detectSystemLang(allocator),
    };
}

/// 启动时调用一次：解析 config 的 language 设定并设置当前语言。
pub fn applyConfig(allocator: std.mem.Allocator, setting: LanguageSetting) void {
    setLang(resolve(allocator, setting));
}
```

并补一个解析优先级测试（追加到测试区）：

```zig
test "resolve: explicit setting beats system; auto follows env-mapping" {
    const a = std.testing.allocator;
    try std.testing.expect(resolve(a, .en) == .en);
    try std.testing.expect(resolve(a, .zh_CN) == .zh_CN);
    // auto 取决于运行环境 env，至少应返回二者之一且不崩溃。
    const auto = resolve(a, .auto);
    try std.testing.expect(auto == .en or auto == .zh_CN);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS —— 新增 3 个测试全过，fast 套件 0 失败。

- [ ] **Step 5: Commit**

```bash
git add src/i18n.zig
git commit -m "feat(i18n): locale detection + language resolution (config>auto>en)"
```

---

### Task 3: config 新增 `language` 字段

**Files:**
- Modify: `src/config.zig`（import i18n、加字段、加 `applyKeyValue` 分支、加测试）

- [ ] **Step 1: Write the failing test**

在 `src/config.zig` 现有 config 解析测试附近（参照 `applyKeyValue(allocator, "auto-update-check", ...)` 用法，约 `config.zig:1759`）追加：

```zig
test "config: language parses auto/en/zh-CN and rejects invalid" {
    const allocator = std.testing.allocator;
    var cfg = Config{};
    defer cfg.deinit(allocator);

    // 默认应为 auto
    try std.testing.expect(cfg.language == .auto);

    cfg.applyKeyValue(allocator, "language", "zh-CN", ".");
    try std.testing.expect(cfg.language == .zh_CN);

    cfg.applyKeyValue(allocator, "language", "en", ".");
    try std.testing.expect(cfg.language == .en);

    // 非法值保持上一次有效值（en），仅告警
    cfg.applyKeyValue(allocator, "language", "klingon", ".");
    try std.testing.expect(cfg.language == .en);

    cfg.applyKeyValue(allocator, "language", "auto", ".");
    try std.testing.expect(cfg.language == .auto);
}
```

> 若 `Config{}` 默认构造在本仓库不可用，参照同文件其它 config 测试的构造方式（多数测试直接 `var cfg = Config{};` 利用字段默认值）。

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL —— `cfg.language` 字段不存在，编译错误。

- [ ] **Step 3: 加字段与解析分支**

在 `src/config.zig` 顶部 import 区（`const themes = @import("themes.zig");` 附近）加：

```zig
const i18n = @import("i18n.zig");
```

在 config 字段声明区（参照 `@"ai-default-profile": []const u8 = "",` 一带，约 `config.zig:307`）加字段：

```zig
/// 界面语言：auto（跟随系统 locale，默认）、en、zh-CN。重启生效。
language: i18n.LanguageSetting = .auto,
```

在 `applyKeyValue`（`config.zig:680`）的分发链中，选一处合适位置（例如 `right-click-action` 分支之后）加：

```zig
    } else if (std.mem.eql(u8, key, "language")) {
        if (i18n.LanguageSetting.parse(value)) |setting| {
            self.language = setting;
        } else {
            log.warn("unknown language: {s}", .{value});
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS —— `config: language parses ...` 通过，fast 套件 0 失败。

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "feat(config): add language setting (auto/en/zh-CN)"
```

---

### Task 4: 启动时解析并设置语言

**Files:**
- Modify: `src/main.zig`（config 加载后调用 `i18n.applyConfig`）

- [ ] **Step 1: 加导入**

在 `src/main.zig` 顶部 import 区加（与其它 `@import` 并列）：

```zig
const i18n = @import("i18n.zig");
```

- [ ] **Step 2: 在 config 加载后设置语言**

在 `src/main.zig:152` `const cfg = try Config.load(allocator);` 与 `render_diagnostics.enableFromConfig(...)`（`main.zig:163`）之间插入：

```zig
    // 解析界面语言（config 显式值 > 系统 locale > en），重启生效。
    // 必须在任何窗口/UI 渲染前完成。
    i18n.applyConfig(allocator, cfg.language);
```

- [ ] **Step 3: 构建验证（app 图，不在 fast 测试内）**

Run: `zig build 2>&1 | tail -20`
Expected: 构建成功，无编译错误。

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat(i18n): resolve UI language at startup from config/locale"
```

---

### Task 5: 命令中心接通 zh 覆盖（样板面 1）

**Files:**
- Modify: `src/i18n.zig`（加 `commandTitle` / `commandDetail` 穷尽 switch）
- Modify: `src/renderer/overlays.zig`（3 个消费点改走 i18n 覆盖）

- [ ] **Step 1: Write the failing test（i18n 覆盖逻辑）**

在 `src/i18n.zig` 顶部实现区加导入与函数（注意导入方向：i18n → command_center_state，单向）：

```zig
const command_center_state = @import("command_center_state.zig");
const CommandAction = command_center_state.CommandAction;
```

加 zh 覆盖函数（`en` 时返回 null，调用点回退现有英文字面量；`zh_CN` 时穷尽 switch 返回中文——漏写某 action 编译期报错）：

```zig
/// 命令中心标题的本地化覆盖。en（及未来源语言）返回 null，调用点用英文原表值。
pub fn commandTitle(action: CommandAction) ?[]const u8 {
    if (active_lang != .zh_CN) return null;
    return switch (action) {
        .new_tab => "新建会话",
        .new_agent => "新建智能体",
        .manage_ai_profiles => "管理 AI 配置",
        .select_agent_history => "选择智能体历史",
        .split_right => "向右分屏",
        .split_down => "向下分屏",
        .split_left => "向左分屏",
        .split_up => "向上分屏",
        .focus_previous => "上一个面板",
        .focus_next => "下一个面板",
        .equalize_splits => "均分面板",
        .close_split_or_tab => "关闭面板 / 标签页",
        .toggle_sidebar => "切换侧边栏",
        .toggle_file_explorer => "切换文件浏览器",
        .toggle_browser_panel => "切换浏览器",
        .toggle_quake => "切换下拉终端",
        .open_settings => "设置",
        .show_shortcuts => "键盘快捷键",
        .open_config => "打开配置文件",
        .font_size_decrease => "减小字号",
        .font_size_increase => "增大字号",
        .toggle_maximize => "切换最大化",
        .copy_remote_key => "复制远程密钥",
        .connect_wechat => "连接微信",
        .start_wechat => "微信：启动",
        .stop_wechat => "微信：停止",
        .wechat_status => "微信：状态",
        .unbind_wechat => "微信：解绑",
        .export_ai_chat_markdown => "导出 AI 对话 Markdown",
        .export_ai_chat_markdown_clean => "导出 AI 对话 Markdown（精简）",
        .show_version => "版本",
        .check_for_updates => "检查更新",
        .download_update => "下载更新",
        .open_latest_release => "打开最新发布",
        .update_skills => "更新技能",
    };
}

/// 命令中心详情的本地化覆盖。约定同 commandTitle。
pub fn commandDetail(action: CommandAction) ?[]const u8 {
    if (active_lang != .zh_CN) return null;
    return switch (action) {
        .new_tab => "选择 Shell、SSH、WSL 或 AI 智能体",
        .new_agent => "用默认 AI 配置打开一个新的智能体标签页",
        .manage_ai_profiles => "创建、编辑或删除已保存的 AI 配置",
        .select_agent_history => "打开命令中心的智能体历史选择器",
        .split_right => "在右侧创建一个面板",
        .split_down => "在下方创建一个面板",
        .split_left => "在左侧创建一个面板",
        .split_up => "在上方创建一个面板",
        .focus_previous => "把焦点移到上一个面板",
        .focus_next => "把焦点移到下一个面板",
        .equalize_splits => "重置当前标签页的分屏大小",
        .close_split_or_tab => "关闭当前面板或标签页；再按一次关闭最后一个面板",
        .toggle_sidebar => "显示或隐藏标签侧边栏",
        .toggle_file_explorer => "显示或隐藏左侧文件浏览器",
        .toggle_browser_panel => "为本地或 SSH 链接打开已配置的浏览器",
        .toggle_quake => "显示或隐藏下拉式终端窗口",
        .open_settings => "打开设置页",
        .show_shortcuts => "显示快捷键参考浮层",
        .open_config => "打开 WispTerm 配置文件",
        .font_size_decrease => "把终端文字调小",
        .font_size_increase => "把终端文字调大",
        .toggle_maximize => "最大化或还原窗口",
        .copy_remote_key => "复制当前 WispTerm 远程会话密钥",
        .connect_wechat => "扫码连接微信直连控制",
        .start_wechat => "用已保存的微信绑定开始轮询",
        .stop_wechat => "停止轮询并保留已保存的微信绑定",
        .wechat_status => "显示微信直连连接状态",
        .unbind_wechat => "清除已存储的微信直连绑定",
        .export_ai_chat_markdown => "把当前 AI 对话保存为 Markdown",
        .export_ai_chat_markdown_clean => "保存用户提问与最终回答（不含思考过程）",
        .show_version => "显示 WispTerm 版本",
        .check_for_updates => "在 GitHub Releases 检查是否有新版本",
        .download_update => "把最新更新下载到「下载」文件夹",
        .open_latest_release => "打开最新的 WispTerm GitHub Release",
        .update_skills => "从 GitHub 下载最新技能",
    };
}

test "commandTitle/Detail: null on en, zh string on zh_CN" {
    defer setLang(.en);
    setLang(.en);
    try std.testing.expect(commandTitle(.open_settings) == null);
    try std.testing.expect(commandDetail(.open_settings) == null);
    setLang(.zh_CN);
    try std.testing.expectEqualStrings("设置", commandTitle(.open_settings).?);
    try std.testing.expectEqualStrings("打开设置页", commandDetail(.open_settings).?);
}
```

- [ ] **Step 2: Run test to verify it fails then passes（core）**

Run: `zig build test 2>&1 | tail -20`
Expected: 先因 `commandTitle` 未定义 FAIL（若先贴 test），补实现后 PASS；穷尽 switch 若漏 action 会编译报错（这是完整性保证）。最终 fast 套件 0 失败。

- [ ] **Step 3: 改 overlays.zig 三个消费点**

在 `src/renderer/overlays.zig` 顶部 import 区确认/新增：

```zig
const i18n = @import("../i18n.zig");
```

改 `commandEntryTitleMatches`（`overlays.zig:656-658`）：

```zig
fn commandEntryTitleMatches(entry: CommandEntry, filter: []const u8) bool {
    return containsIgnoreCase(i18n.commandTitle(entry.action) orelse entry.title, filter);
}
```

改 `commandEntrySecondaryMatches`（`overlays.zig:660-664`）：

```zig
fn commandEntrySecondaryMatches(entry: CommandEntry, filter: []const u8) bool {
    var shortcut_buf: [64]u8 = undefined;
    return containsIgnoreCase(i18n.commandDetail(entry.action) orelse entry.detail, filter) or
        containsIgnoreCase(commandEntryShortcut(entry, &shortcut_buf), filter);
}
```

改渲染处（`overlays.zig:1295`），把 `entry.title` 换成本地化值：

```zig
                        renderTitlebarTextLimited(i18n.commandTitle(entry.action) orelse entry.title, title_x, text_y, row_title_color, shortcut_left - title_x - 18);
```

- [ ] **Step 4: 构建验证（overlays 属 app 图）**

Run: `zig build 2>&1 | tail -20`
Expected: 构建成功。再跑全量测试 `zig build test-full 2>&1 | tail -20`，0 失败。

- [ ] **Step 5: Commit**

```bash
git add src/i18n.zig src/renderer/overlays.zig
git commit -m "feat(i18n): localize command center via CommandAction zh overrides"
```

---

### Task 6: 状态 toast 接通（样板面 2，扁平 s() 模式）

**Files:**
- Modify: `src/i18n.zig`（`Strings` 增 toast 字段 + en/zh 值）
- Modify: `src/renderer/overlays.zig`（替换选定的 toast 字面量）

- [ ] **Step 1: Write the failing test（字段存在且非空）**

在 `src/i18n.zig` 的 `Strings` 结构体加字段（无默认值），并在 `en`、`zh_CN` 两表都赋值：

```zig
// Strings 内追加：
    toast_wechat_not_connected: []const u8,
    toast_wechat_poller_started: []const u8,
    toast_wechat_poller_stopped: []const u8,
    toast_wechat_direct_disabled: []const u8,
```

```zig
// en 表内追加：
    .toast_wechat_not_connected = "WeChat not connected",
    .toast_wechat_poller_started = "WeChat poller started",
    .toast_wechat_poller_stopped = "WeChat poller stopped",
    .toast_wechat_direct_disabled = "WeChat direct disabled",
```

```zig
// zh_CN 表内追加：
    .toast_wechat_not_connected = "微信未连接",
    .toast_wechat_poller_started = "微信轮询已启动",
    .toast_wechat_poller_stopped = "微信轮询已停止",
    .toast_wechat_direct_disabled = "微信直连已禁用",
```

追加测试：

```zig
test "toast strings: en source and zh translation both present" {
    defer setLang(.en);
    setLang(.en);
    try std.testing.expectEqualStrings("WeChat not connected", s().toast_wechat_not_connected);
    setLang(.zh_CN);
    try std.testing.expectEqualStrings("微信未连接", s().toast_wechat_not_connected);
    try std.testing.expect(s().toast_wechat_poller_started.len > 0);
    try std.testing.expect(s().toast_wechat_poller_stopped.len > 0);
    try std.testing.expect(s().toast_wechat_direct_disabled.len > 0);
}
```

> 完整性保证：`Strings` 新增字段无默认值，若 `zh_CN` 漏赋某字段，`zig build test` 会因缺字段编译报错。

- [ ] **Step 2: Run test to verify it passes（core）**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS，fast 套件 0 失败（若 zh 表漏字段则编译失败 —— 修正后再过）。

- [ ] **Step 3: 替换 overlays.zig 中选定 toast 字面量**

在 `src/renderer/overlays.zig` 中，把以下 `showStatusToast("...")` 调用的字面量替换为 i18n 字段（按字符串匹配，替换全部出现处）：

- `showStatusToast("WeChat not connected")` → `showStatusToast(i18n.s().toast_wechat_not_connected)`
- `showStatusToast("WeChat poller started")` → `showStatusToast(i18n.s().toast_wechat_poller_started)`
- `showStatusToast("WeChat poller stopped")` → `showStatusToast(i18n.s().toast_wechat_poller_stopped)`
- `showStatusToast("WeChat direct disabled")` → `showStatusToast(i18n.s().toast_wechat_direct_disabled)`

> 其余 toast（含 `bufPrint` 拼接的动态文案、其它 WeChat/文件传输提示）**本任务不动**，留待后续 PR 分批迁移（见 spec §10）。`i18n` 已在 Task 5 于 overlays 顶部导入，无需重复。

- [ ] **Step 4: 构建 + 全量测试**

Run: `zig build 2>&1 | tail -20 && zig build test-full 2>&1 | tail -20`
Expected: 构建成功；test-full 0 失败。

- [ ] **Step 5: Commit**

```bash
git add src/i18n.zig src/renderer/overlays.zig
git commit -m "feat(i18n): localize selected WeChat status toasts via s()"
```

---

### Task 7: 全量校验 + 文档校准 + GUI 目检

**Files:**
- Modify: `docs/superpowers/specs/2026-06-01-i18n-infrastructure-design.md`（勾掉验收项，如有）
- 无新代码

- [ ] **Step 1: 全套测试**

Run: `zig build test 2>&1 | tail -5 && zig build test-full 2>&1 | tail -5`
Expected: 两套件均 0 失败（参照基线：test-full 约数百通过、4 skipped、0 failed，计数随新增测试增长）。

- [ ] **Step 2: GUI 目检（中文）**

Run（任选其一，需图形环境）：

```bash
LANG=zh_CN.UTF-8 zig build run
# 或显式覆盖：
zig build run -- --language zh-CN
```

人工确认：
- 打开命令中心（命令面板）：标题/详情显示中文（如「设置」「打开设置页」）。
- 触发任一已迁移的微信 toast（如停止轮询）：显示中文。
- 文字**无方块（tofu）**、无裁切/重叠（验证 §6 布局健壮性）。

- [ ] **Step 3: GUI 目检（英文回退）**

Run:

```bash
zig build run -- --language en
```

确认：在中文系统环境下强制 en 时，上述界面回到英文（命令中心英文、toast 英文）。

- [ ] **Step 4: 校准 spec 验收清单**

在 `docs/superpowers/specs/2026-06-01-i18n-infrastructure-design.md` §9 勾选已完成项；如目检发现布局问题，记录到 §10 后续工作。

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-01-i18n-infrastructure-design.md
git commit -m "docs(i18n): check off acceptance criteria after verification"
```

---

## 完成后

所有任务完成且 `zig build test` / `zig build test-full` 全绿、GUI 目检通过后，本分支 `feat/i18n-infrastructure` 即可进入 `superpowers:finishing-a-development-branch`（合并 / 开 PR）。后续界面文案迁移（AI agent 对话框、设置面板、菜单、文件浏览器、错误信息、其余 toast）按 spec §10 另起 PR。
