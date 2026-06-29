# 飞书配置 UI(命令面板)设计

**日期**:2026-06-29
**分支**:feat/feishu-config-ui
**前置**:飞书 channel 已合并 main(PR #416,commit 6fe7064);config.zig 已有 `feishu-enabled`/`feishu-app-id`/`feishu-app-secret` 键 + 解析。

## 目标

让用户在**命令面板**里启用/停用飞书 bot,并填写 app-id / app-secret 凭证,**配置后重启终端生效**。

**只走命令面板,不进设置 overlay**——设置 overlay 已较满,未来可能接入更多渠道,逐个塞开关会拥挤;命令面板可扩展、零视觉成本。当前用户靠环境变量 `FEISHU_APP_ID`/`FEISHU_APP_SECRET` 运行;本特性提供 UI 配置作为替代/补充,env 仍可用并覆盖。

## 非目标(v1 不做)

- **不进设置 overlay**(命令面板足够,避免未来多渠道把设置挤满)。
- `feishu-allowed-user` 字段录入(仍可经 env 或设置里的 raw config 高级编辑器设置)。
- 首次启动自动弹配置表单(飞书 opt-in,不自动打扰)。
- 配置热重载 / 免重启生效(需重启)。
- 凭证校验 / 连通性测试(只存配置,不验证)。

## 架构

复用两套现成模式,**不引入新抽象**:

1. **命令面板命令** —— 镜像微信 `connect_wechat`(center_state.zig:33/87 命令条目 + overlays.zig:673 dispatch):新增 `CommandAction` 变体 + 命令列表条目 + dispatch。
2. **凭证表单 overlay** —— 镜像 AI profile 表单(`src/renderer/overlays/assistant_profiles.zig` 的 `State{ bufs, lens, focus }` + overlays.zig 的 `openAiForm`/`setAiDefault`/`backspaceAiFormField`/`aiField`/字符输入/render):新增一个 `g_feishu_form_visible` 标志 + 一个 2 字段 `State`。

enabled 不做表单字段,而是一条独立的命令面板 toggle 命令(同微信"开关"语义),与凭证表单分离。

## 组件

### 1. 配置键(已存在,无需改 config.zig)

- `@"feishu-enabled": bool = false`
- `@"feishu-app-id": ?[]const u8 = null`
- `@"feishu-app-secret": ?[]const u8 = null`

保存用现成的 `Config.setConfigValue(allocator, key, value)`(微信开关同款)。

### 2. `src/renderer/overlays/feishu_config.zig`(新)

镜像 `assistant_profiles.zig` 的最小子集:

```zig
pub const FEISHU_FIELD_COUNT = 2; // app_id, app_secret
pub const FEISHU_FIELD_MAX = 256;

pub const FeishuField = enum(usize) { app_id = 0, app_secret = 1 };

pub const State = struct {
    bufs: [FEISHU_FIELD_COUNT][FEISHU_FIELD_MAX]u8 = undefined,
    lens: [FEISHU_FIELD_COUNT]usize = .{0} ** FEISHU_FIELD_COUNT,
    focus: usize = 0, // 0..FEISHU_FIELD_COUNT-1 = 字段;FEISHU_FIELD_COUNT = Save 按钮行

    pub fn reset(self: *State) void { ... }
    pub fn value(self: *const State, f: FeishuField) []const u8 { ... }
    pub fn append(self: *State, f: FeishuField, bytes: []const u8) void { ... } // 超长截断到 MAX,不溢出
    pub fn backspace(self: *State, f: FeishuField) void { ... }
};
```

表单行数 = `FEISHU_FIELD_COUNT + 1`(2 字段 + Save 行)。

### 3. overlays.zig:表单 open / 编辑 / 渲染 / 保存 + enabled toggle 助手

镜像 AI 表单,新增:

- `g_feishu_form_visible: bool`(threadlocal,同 `g_ai_form_visible`)。
- `feishuConfig() *feishu_config.State`(同 `assistantProfiles()`)。
- `openFeishuConfigForm()`:关其它 overlay,`g_feishu_form_visible = true`,**用当前 config 预填** app-id(secret 不预填,见安全节)。
- 键分发:接进现有 overlay 键处理(同 `if (g_ai_form_visible) ...` 的并列分支)。焦点在字段时打字 append / backspace 删字符;↑↓ 切焦点(含 Save 行);Save 行 + Enter → `saveFeishuConfig()`;Esc 关表单。
- `renderFeishuConfigForm(...)`:渲染 2 字段行 + Save 行 + "restart to apply" 提示;**app_secret 行打码**(见安全节)。
- `saveFeishuConfig()`:
  - app-id:非空 → `setConfigValue(allocator, "feishu-app-id", appId)`;留空跳过(不覆盖)。
  - app-secret:用户输入了新值 → `setConfigValue(allocator, "feishu-app-secret", newSecret)`;**留空 → 不调用 setConfigValue**(保留 env/已有配置)。
  - 关表单 + 弹重启 toast(`i18n.s().toast_feishu_config_saved`)。
  - **不**自动改 `feishu-enabled`(启用是独立命令)。
- `toggleFeishuEnabled()`:`setConfigValue(allocator, "feishu-enabled", if (cfg.@"feishu-enabled") "false" else "true")`(直接写,不经设置 action;微信走 executeSettingsAction,飞书无设置行故直写)。

### 4. 命令面板(center_state.zig):两条命令

镜像 `connect_wechat`(center_state.zig:33 枚举 / :87 列表条目 + overlays.zig:673 dispatch):

- `CommandAction` 加 `toggle_feishu` + `configure_feishu`。
- 命令列表加两条:
  - `{ title: cmd_toggle_feishu, detail: ..., action: .toggle_feishu }`
  - `{ title: cmd_configure_feishu, detail: "填写 App ID / App Secret", action: .configure_feishu }`
- overlays.zig dispatch:`.toggle_feishu => toggleFeishuEnabled()`;`.configure_feishu => openFeishuConfigForm()`。
- 更新 center_state 命令条目测试(`expectCommandEntry`)+ 命令总数。

### 5. i18n.zig:新增键(EN + zh 两表)

- `cmd_toggle_feishu`("Toggle Feishu direct" / "启用/停用飞书直连")
- `cmd_configure_feishu`("Configure Feishu bot" / "飞书 bot 配置")
- `feishu_form_app_id` / `feishu_form_app_secret` / `feishu_form_save`(表单字段 + 按钮标签)
- `feishu_form_secret_set_hint`("already set — leave blank to keep" / "已设置,留空保留")
- `toast_feishu_config_saved`("Feishu config saved — restart WispTerm to apply" / "飞书配置已保存,重启 WispTerm 生效")

(无设置 overlay 行,故不加 settings_feishu_* 键。)

## 数据流

```
启用:命令面板"启用/停用飞书直连"
  → toggleFeishuEnabled() → setConfigValue("feishu-enabled", toggle) → 写配置文件
  → (重启后 startFeishu 读取生效)

凭证:命令面板"飞书 bot 配置"
  → openFeishuConfigForm()(预填 app-id;secret 空,见安全节)
  → 用户编辑 app-id / app-secret → Save 行 Enter
  → setConfigValue("feishu-app-id", ...) + (有新 secret 才) setConfigValue("feishu-app-secret", ...)
  → 重启 toast → 关表单
```

## 安全

- **app_secret 打码**:表单内 app_secret 字段渲染为 `•` × 长度(标准密码框),不明文回显。当前代码无打码基建,新增一个最小渲染分支(仅此字段)。
- **绝不入日志**:saveFeishuConfig / openFeishuConfigForm / toggleFeishuEnabled 不 log app_secret 值(沿用飞书 channel 既有"token 不入日志"纪律)。
- **不预填 secret 明文**:打开表单时**不把已有 app-secret 读进 buffer**;字段初始为空,若已配置则显示 `feishu_form_secret_set_hint` 提示;用户**留空 → 保存不覆盖**已有 env/配置;输入新值才覆盖。app-id 非敏感,预填明文。
- **配置文件明文**:app-secret 同其它配置项明文存配置文件(本地文件,与现状一致);env `FEISHU_APP_SECRET` 仍可用并覆盖。
- 表单是给用户**自己**录入凭证用的;不替用户填。

## 测试

纯逻辑(`zig build test` fast 套件可达):

- `feishu_config.State`:append / backspace / value / reset 行为;append 超长截断到 FEISHU_FIELD_MAX 不溢出。
- center_state:新增两条命令存在且 action 正确(`expectCommandEntry`);命令总数 +2。

UI / 集成(`test-full -Dtarget=aarch64-macos` + `macos-app -Dtarget=aarch64-macos` 编译):

- saveFeishuConfig 写出正确 config 键;app-secret 留空不覆盖、有值才覆盖的分支(可对 setConfigValue 注入/桩)。
- `zig fmt --check build.zig src` 绿(新文件按 zig fmt;吸取 PR #416 教训)。

## 验证基线

- `zig build test` / `zig build test-full -Dtarget=aarch64-macos` / `zig build macos-app -Dtarget=aarch64-macos` 全绿。
- `zig fmt --check build.zig src` 绿。
- 真机:命令面板"启用飞书"切换 + "飞书 bot 配置"填 app-id/secret 保存见重启 toast;重启后飞书按配置启动。

## 文件清单

- 新增:`src/renderer/overlays/feishu_config.zig`(State)
- 改:`src/renderer/overlays.zig`(表单 open/edit/render/save + toggleFeishuEnabled + 命令 dispatch)
- 改:`src/command/center_state.zig`(两条命令 + action 枚举 + 测试)
- 改:`src/i18n.zig`(新键 EN + zh)
- (config.zig 无需改:键 + 解析已存在;**设置 overlay 不动**)
