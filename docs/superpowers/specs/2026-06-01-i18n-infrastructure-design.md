# WispTerm 界面国际化（i18n）基础设施 — 设计文档

- 日期：2026-06-01
- 状态：已与用户确认，待审阅
- 主题：为 WispTerm 的 UI chrome 搭建可扩展的 i18n 基础设施，首发 English + 简体中文，并以「命令中心 + 状态 toast」两个界面作为端到端样板
- 关联反馈：GitHub Discussions [#82](https://github.com/xuzhougeng/wispterm/discussions/82)（汉化诉求）、[#97](https://github.com/xuzhougeng/wispterm/discussions/97) 第 1/2 点（配置界面中文）

## 1. 背景与目标

WispTerm 当前所有用户可见文案都是散落在各 `.zig` 文件中的英文字符串字面量（命令中心 `src/command_center_state.zig`、状态提示 `src/renderer/overlays.zig`、标题栏 `src/renderer/titlebar.zig`、AI 设置/对话框 `src/renderer/overlays.zig`、macOS 原生菜单 `src/platform/menu_macos.zig` 等）。没有任何 i18n 机制。

社区反馈集中诉求中文界面。本 feat 的目标是**先把 i18n 基础设施搭好**，而非一次性翻译全部界面：

- 新建可扩展的字符串目录（catalog）机制，编译期保证翻译完整性。
- 支持启动时**自动检测系统 locale**，并可被 config 覆盖，**重启生效**（v1 不做运行时热切换）。
- 首发语言：**`en`（源语言/回退）+ `zh-CN`**。
- 选取 **命令中心（command center / 命令面板）** 与 **状态 toast** 两个高可见界面作为样板，端到端验证机制 + CJK 渲染 + 布局健壮性。
- 其余界面文案在后续 PR 分批迁移。

### 明确不在 v1 范围

- 全量 UI 文案翻译（后续 PR 分批进行）。
- 运行时免重启的语言热切换。
- README / docs / 官网中文（另开任务，#97 第 2 点）。
- 复数（plural）/ 数字 / 日期 / 货币本地化（当前界面无此需求；将来某界面需要时再扩展）。
- RTL（从右到左）语言。

### Ghostty 对比说明

i18n catalog 与语言解析是 WispTerm 自有的产品层基础设施，[Ghostty](https://github.com/ghostty-org/ghostty) 当前无等价的应用内 UI 翻译机制，故本设计不参照 Ghostty 实现，而采用贴合本仓库 comptime 风格的方案。

## 2. 现有代码事实（实现锚点）

- **配置体系**：`src/config.zig`（`Config = @This()`，约 1899 行）采用 Ghostty 风格 `key = value` 文本格式；每个 config key 同时是 CLI flag（`--key value`）。新增 `language` 字段后，`--language zh-CN` 由现有解析体系自动支持。
- **UI chrome 文字渲染路径**：`src/renderer/titlebar.zig`
  - `renderTextLimited(text, x, y, color, max_w)`（`titlebar.zig:203`）—— 用 `std.unicode.Utf8View` 逐 codepoint 迭代，逐字调用 `renderTitlebarChar`，超宽用省略号 `0x2026` 截断。
  - `titlebarGlyphAdvance(cp)`（`titlebar.zig:341`）—— 返回**真实字形 advance**，非固定 ASCII 宽度。
- **CJK 字体回退（关键，已核实）**：`src/font/manager.zig`
  - `loadTitlebarGlyph(codepoint)`（`manager.zig:1068`）：主 titlebar face 缺字形时调用 `findOrLoadFallbackFace(codepoint, alloc)`，并对 `isCjkCodepoint(codepoint)` 用 `.normal` 渲染模式。
  - 结论：**UI chrome 文字路径今天就支持渲染中文**（标签页标题本来就能显示来自 shell/目录名的 CJK）。底层渲染能力已具备，无需新增字体逻辑。
- **样板迁移面 1 — 命令中心**：`src/command_center_state.zig`
  - 静态命令表，元素形如 `.{ .title = "New Session", .detail = "...", .shortcut = "", .action = .new_tab }`（`command_center_state.zig:51` 起）。`title` / `detail` 为英文字面量。
  - 注意：`platform_pty_command.session_launcher_detail` 等部分 detail 是来自其他模块的常量，迁移时需逐条甄别是否字面量。
- **样板迁移面 2 — 状态 toast**：`src/renderer/overlays.zig`
  - `showStatusToast("...")` 大量短文案（`overlays.zig:490` 起，如 `"WeChat login failed to start"` 等）。部分经 `std.fmt.bufPrint` 拼接动态值（如 `"WeChat login: {s}"`，`overlays.zig:573`）。
- **测试注册机制**：Zig 测试只有当文件被 `_ = @import` 进 `src/test_fast.zig`（快测）或 `src/test_main.zig`（全量）才会运行；facade 的 `const x = @import` 不注册后端测试。新模块需显式注册。
- **平台目录**：`src/platform/dirs.zig` 提供 `configDir`；无现成 locale 检测代码（全仓库无 `LANG`/`LC_ALL`/`NSLocale` 读取），需新增。

## 3. 架构：`src/i18n.zig`（方案 A — comptime 字段结构体）

### 3.1 语言枚举

```zig
pub const Lang = enum { en, zh_CN };
```

### 3.2 译文承载：字段结构体（comptime 完整性）

```zig
pub const Strings = struct {
    // —— 命令中心 ——
    cmd_new_session_title: []const u8,
    cmd_new_session_detail: []const u8,
    // … 每个可翻译串一个字段，无默认值 …
};

const en = Strings{
    .cmd_new_session_title = "New Session",
    .cmd_new_session_detail = "Open a new terminal session",
    // …
};

const zh_CN = Strings{
    .cmd_new_session_title = "新建会话",
    .cmd_new_session_detail = "打开一个新的终端会话",
    // …
};
```

- `Strings` 字段**无默认值** → 任一 locale 字面量漏填某字段，Zig 编译期直接报错。这就是「方案 A 的 comptime 完整性保证」最省样板的落地，**无需手写 comptime assert**。
- 新增一种语言 = 新增一个 `Strings{...}` 字面量；漏译会编译失败，不会静默缺词。

### 3.3 当前语言与访问

```zig
var current: *const Strings = &en;

pub fn s() *const Strings {
    return current;
}

pub fn setLang(lang: Lang) void {
    current = switch (lang) {
        .en => &en,
        .zh_CN => &zh_CN,
    };
}
```

调用点示例：

```zig
.{ .title = i18n.s().cmd_new_session_title, .detail = i18n.s().cmd_new_session_detail, ... }
showStatusToast(i18n.s().toast_wechat_login_failed);
```

> 备选调用风格：若日后更偏好 `t(.key)` 枚举形式，可在不改 catalog 数据的前提下加一层 `Key` 枚举包装；v1 采用字段结构体（完整性免费、零样板、字段名即文档）。

## 4. 语言解析（启动时，按序）

解析在程序启动早期、任何 UI 渲染前执行一次，`setLang` 后即固定（v1 重启才会重新解析）。

1. 读 config 新键 `language`，取值：
   - `auto`（**默认**）
   - `en`
   - `zh-CN`（解析时兼容 `zh`、`zh_CN`、`zh-cn` 等，大小写不敏感）
2. 若为显式语言（`en` / `zh-CN`）→ 直接采用。
3. 若为 `auto` → 检测系统 locale：
   - **POSIX（Linux / macOS）**：依次读环境变量 `LC_ALL` → `LC_MESSAGES` → `LANG`，取首个非空值的语言标签（`zh_CN.UTF-8` → `zh_CN` → `zh`）。
   - **Windows**：调用 `GetUserDefaultLocaleName`（win32 已链接，见 `build.zig` 的 `windows_system_libraries`）；API 不可用时回退读环境变量。
   - 映射规则：语言标签以 `zh` 开头（不分大小写）→ `zh_CN`；其余 → `en`。
4. 未知 config 值 / 检测失败 / 不支持的语言 → 回退 `en`（debug 日志记录）。

> macOS 未来可升级用 `NSLocale.preferredLanguages`（更贴近系统「偏好语言」而非 shell env）；v1 用 env 足够，标注为后续优化。

### Config 接入

- 在 `Config` 结构体新增 `language` 字段（默认值表示 `auto`），加入解析与（如适用的）默认值打印。
- 因每个 config key 自动是 CLI flag，`--language zh-CN` 与 `--language=auto` 自动可用。
- locale 检测逻辑放在 `src/i18n.zig`（或新建 `src/platform/locale.zig` 提供平台相关取值，由 `i18n.zig` 调用），保持平台分支隔离。

## 5. 接线与迁移策略

1. 新建 `src/i18n.zig`，在 `src/test_fast.zig` 与 `src/test_main.zig` 注册（`_ = @import("i18n.zig");`）以运行单测。
2. 启动序列中（config 解析完成后、首帧渲染前）调用语言解析 + `i18n.setLang(...)`。
3. **样板面 1 — 命令中心**（`src/command_center_state.zig`）：将静态表中的 `title` / `detail` 英文字面量逐条迁移为 `Strings` 字段 + en/zh-CN 值。**已确认** `command_entries` 是顶层 `pub const` comptime 数组（`command_center_state.zig:50`），而 `i18n.s()` 为启动时设定的运行时值，二者不能直接拼接。因此需二选一（实现计划阶段定）：
   - (a) 把 `command_entries` 从 comptime 常量改为运行时构建的函数 `commandEntries()`，内部用 `i18n.s()` 填充；或
   - (b) 在 `CommandEntry` 中以**字段访问器/枚举**保存「哪个 `Strings` 字段」，在渲染/读取处再经 `i18n.s()` 解析为文案（保持表本身 comptime）。
   倾向 (b)：改动面更小、表保持静态、与渲染时解析一致。
4. **样板面 2 — 状态 toast**（`src/renderer/overlays.zig`）：迁移 `showStatusToast` 的纯字面量；含 `bufPrint` 拼接的动态文案，将其**格式串**纳入 catalog（保留 `{s}` 占位），值参数不变。
5. 其余界面（AI agent 配置对话框、AI 设置面板、macOS 菜单、文件浏览器、错误信息等）**显式延后**到后续 PR，在 TODO/Issue 中追踪。

## 6. CJK 渲染与布局（已核实 + 风险）

- ✅ 渲染能力已具备（见 §2，`loadTitlebarGlyph` 含 CJK 回退）。
- ⚠️ **布局宽度假设**是主要剩余风险：部分按钮 / 列宽可能按 ASCII 字符数估算，中文字形更宽。缓解：`titlebarGlyphAdvance` 返回真实 advance、`renderTextLimited` 用省略号截断，可优雅降级。
- 验收：两个样板面在 zh-CN 下需在运行的 app 中目检，**无裁切 / 重叠 / 溢出**。

## 7. 错误处理与回退

- 运行时不会出现缺译文（catalog comptime 完整）。
- config `language` 非法、locale 检测失败、不支持的语言 → 回退 `en`，debug 日志。
- catalog 全为静态合法 UTF-8，无运行时解析/分配，无解析失败路径。

## 8. 测试

### 单元测试（快测套件 `test_fast`）

- locale 串 → `Lang` 映射：`zh_CN.UTF-8` / `zh` / `zh-CN` / `zh_TW` → `zh_CN`；`en_US.UTF-8` / `` / `fr` → `en`。
- config `language` 解析：`auto` / `en` / `zh-CN` / 非法值（→ 默认）/ 大小写与分隔符兼容。
- 解析优先级：显式 config 覆盖 env；`auto` 时使用 env；env 缺失回退 `en`。
- `setLang` 后 `s()` 返回对应表；抽样若干 key 在每个 `Lang` 下均非空。
- comptime 完整性由编译器强制（漏译编译失败），无需运行时用例。

### GUI 目检（遵循本仓库「not GUI-verified until run」惯例）

- `LANG=zh_CN.UTF-8` 启动 → 命令中心、toast 显示中文。
- `--language zh-CN` 启动（覆盖 en 环境）→ 同上。
- `--language en` 在中文环境下启动 → 显示英文。
- 检查布局无裁切 / 重叠。

## 9. 验收标准

- [x] `src/i18n.zig` 提供 `Lang` / `Strings` / `s()` / `setLang()`，comptime 强制每个 locale 完整。（Task 1/2）
- [x] 启动时按 §4 顺序解析语言并设置当前语言。（Task 4：`main.zig` 在 `Config.load` 后、`App.init` 前调用 `i18n.applyConfig`）
- [x] `Config` 新增 `language` 字段，`--language` CLI flag 可用（并已加入 `--help` 与示例配置）。（Task 3）
- [x] 命令中心与状态 toast 两个样板面完成迁移，en 行为不变（`orelse` 回退英文）、zh-CN 提供中文。（Task 5/6，代码层）
- [x] 新增单测覆盖 §8，`zig build test` 与 `zig build test-full` 均通过、0 失败。（2026-06-01 实测两套件 EXIT=0）
- [ ] **运行 app（zh-CN）目检通过：中文正确渲染、布局无破。** ⏳ 待在 macOS / Windows 上人工验证 —— 本仓库无 Linux GUI 后端（`backendForOs(.linux) == .unsupported`），无法在当前 WSL2/Linux 环境运行 GUI。命令见 §8「GUI 目检」。

## 10. 后续工作（追踪，不在本 PR）

- 分批迁移其余界面文案（AI agent 对话框、AI 设置面板、菜单、文件浏览器、错误信息…）。
- 迁移 `overlays.zig` 中尚未本地化的其余状态 toast（v1 仅迁移 4 条作样板；同一批 WeChat 提示里仍有英文兄弟串，如 "WeChat start failed" / "WeChat direct is not active" 等 —— **这是有意的范围控制，非遗漏**，zh 模式下这些会暂显英文）。
- macOS 用 `NSLocale.preferredLanguages` 优化 auto 检测。
- 视需要扩展：运行时热切换、繁体中文 / 更多语言、复数与日期本地化。
- README / docs / 官网中文（#97 第 2 点，另开任务）。
