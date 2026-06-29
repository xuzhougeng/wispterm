# 飞书配置 UI(设置 + 命令面板)设计

**日期**:2026-06-29
**分支**:feat/feishu-config-ui
**前置**:飞书 channel 已合并 main(PR #416,commit 6fe7064);config.zig 已有 `feishu-enabled`/`feishu-app-id`/`feishu-app-secret` 键 + 解析。

## 目标

让用户在 UI 里(设置 overlay + 命令面板)启用/停用飞书 bot,并填写 app-id / app-secret 凭证,**配置后重启终端生效**。对标现有微信(WeChat direct)的设置开关 + 命令面板入口,但飞书多了凭证录入(微信走 QR 登录无凭证),故新增一个凭证表单。

当前用户靠环境变量 `FEISHU_APP_ID`/`FEISHU_APP_SECRET` 运行;本特性提供 UI 配置作为替代/补充,env 仍可用并覆盖。

## 非目标(v1 不做)

- `feishu-allowed-user` 字段录入(仍可经 env 或设置里的 raw config 高级编辑器设置)。
- 首次启动自动弹配置表单(飞书 opt-in,不自动打扰)。
- 配置热重载 / 免重启生效(同微信,需重启)。
- 凭证校验 / 连通性测试(只存配置,不验证)。

## 架构

复用两套现成模式,**不引入新抽象**:

1. **设置开关行** —— 完全镜像微信 `toggle_weixin_direct`(overlays.zig:5410/5448):一个 `SettingsAction` 变体 → `Config.setConfigValue(allocator, "feishu-enabled", ...)`,渲染一行 `boolText` 开关。
2. **凭证表单 overlay** —— 镜像 AI profile 表单(`src/renderer/overlays/assistant_profiles.zig` 的 `State{ bufs, lens, focus }` + overlays.zig 的 `openAiForm`/`setAiDefault`/`backspaceAiFormField`/`aiField`/字符输入/render)。新增一个 `g_feishu_form_visible` 标志 + 一个 2 字段的 `State`。

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

    pub fn reset(self: *State) void { self.lens = .{0} ** FEISHU_FIELD_COUNT; self.focus = 0; }
    pub fn value(self: *const State, f: FeishuField) []const u8 { ... }
    pub fn append(self: *State, f: FeishuField, bytes: []const u8) void { ... }
    pub fn backspace(self: *State, f: FeishuField) void { ... }
};
```

表单行数 = `FEISHU_FIELD_COUNT + 1`(2 字段 + Save 行)。

### 3. overlays.zig:表单的 open / 编辑 / 渲染 / 保存

镜像 AI 表单函数,新增:

- `g_feishu_form_visible: bool`(threadlocal,同 `g_ai_form_visible`)。
- `feishuConfig() *feishu_config.State`(同 `assistantProfiles()`)。
- `openFeishuConfigForm()`:关其它 overlay,`g_feishu_form_visible = true`,**用当前 config 预填** app-id/app-secret(`setFeishuFormDefaults()`,见安全节对 secret 的处理)。
- 字符输入 / backspace:接进现有 overlay 键分发(同 `if (g_ai_form_visible) ...` 分支);焦点在字段时打字 append、backspace 删字符;↑↓ 切焦点(含 Save 行);焦点在 Save 行 + Enter → `saveFeishuConfig()`;Esc 关表单。
- `renderFeishuConfigForm(...)`:渲染 2 字段行 + Save 行 + "restart to apply" 提示;**app_secret 行打码**(见安全节)。
- `saveFeishuConfig()`:
  - `setConfigValue(allocator, "feishu-app-id", appIdValue)`(留空则跳过,不覆盖)。
  - app_secret:若用户输入了新值 → `setConfigValue(allocator, "feishu-app-secret", newSecret)`;**留空 → 不调用 setConfigValue**(保留 env/已有配置)。
  - 关表单 + 弹重启 toast(`i18n.s().toast_feishu_config_saved`)。
  - **不**自动改 `feishu-enabled`(启用是独立开关)。

### 4. 设置 overlay:两行

在微信开关行(`SETTINGS_CONTROL_ROW_START + 5`)附近插入飞书两行,后续行索引顺移:

- `SettingsAction` 加 `toggle_feishu_enabled` + `open_feishu_config`。
- `rowToSettingsAction`:新行 → 对应 action。
- `executeSettingsAction`:
  - `.toggle_feishu_enabled => setConfigValue(allocator, "feishu-enabled", if (cfg.@"feishu-enabled") "false" else "true")`(镜像微信)。
  - `.open_feishu_config => openFeishuConfigForm()`。
- `renderSettingsRow`:
  - 行 `飞书直连` = `boolText(cfg.@"feishu-enabled")`(同微信样式)。
  - 行 `飞书 bot 配置…` = `i18n.s().settings_value_open`(同 raw-config 行的"打开"样式)。
- 同步设置行总数常量 / 受影响的行索引测试。

### 5. 命令面板(center_state.zig):两条命令

镜像 `connect_wechat`(center_state.zig:33/87 + overlays.zig:673 dispatch):

- `CommandAction` 加 `toggle_feishu` + `configure_feishu`。
- 命令列表加两条:`{ title: "启用/停用飞书直连", action: .toggle_feishu }`、`{ title: "飞书 bot 配置", detail: "填写 App ID / App Secret", action: .configure_feishu }`。
- overlays.zig dispatch:`.toggle_feishu => executeSettingsAction(.toggle_feishu_enabled)`(复用设置 action,DRY);`.configure_feishu => openFeishuConfigForm()`。
- 更新 center_state 的命令条目测试(`expectCommandEntry`)。

### 6. i18n.zig:新增键(EN + zh 两表)

- `settings_feishu_direct`("Feishu direct" / "飞书直连")
- `settings_feishu_config`("Feishu bot config" / "飞书 bot 配置…")
- `feishu_form_app_id` / `feishu_form_app_secret` / `feishu_form_save`(表单字段 + 按钮标签)
- `cmd_toggle_feishu` / `cmd_configure_feishu`(命令面板标题/详情)
- `toast_feishu_config_saved`("Feishu config saved — restart WispTerm to apply" / "飞书配置已保存,重启 WispTerm 生效")

## 数据流

```
启用:设置开关行 / 命令面板"启用飞书"
  → setConfigValue("feishu-enabled", toggle) → 写配置文件 → (重启后 startFeishu 读取生效)

凭证:设置"飞书 bot 配置…" / 命令面板"飞书 bot 配置"
  → openFeishuConfigForm()(预填 app-id;secret 见安全节)
  → 用户编辑 app-id / app-secret → Save
  → setConfigValue("feishu-app-id", ...) + (有新 secret 才) setConfigValue("feishu-app-secret", ...)
  → 重启 toast → 关表单
```

## 安全

- **app_secret 打码**:表单内 app_secret 字段渲染为 `•` × 长度(标准密码框行为),不明文回显。当前代码无打码基建,新增一个最小渲染分支(仅此字段)。
- **绝不入日志**:saveFeishuConfig / openFeishuConfigForm 不 log app_secret 值(沿用飞书 channel 既有"token 不入日志"纪律)。
- **预填 secret 的处理**:打开表单时**不把已有 app-secret 明文读进 buffer**。app_secret 字段初始为空,并显示占位提示(如已配置则提示"已设置,留空保留");用户**留空 → 保存时不覆盖**已有 env/配置值;输入新值才覆盖。app-id 非敏感,可预填明文。
- **配置文件明文**:app-secret 同其它配置项明文存配置文件(本地文件,与现状一致);env `FEISHU_APP_SECRET` 仍可用并覆盖。
- 表单是给用户**自己**录入凭证用的;不替用户填。

## 测试

纯逻辑(走 `zig build test` fast 套件可达的模块):

- `feishu_config.State`:append / backspace / value / reset 行为;append 超长截断到 FEISHU_FIELD_MAX 不溢出。
- center_state:新增两条命令存在且 action 正确(`expectCommandEntry`);命令总数 +2。
- 设置行映射:`rowToSettingsAction` 新行 → `toggle_feishu_enabled` / `open_feishu_config`;微信及后续行映射不回归(顺移后仍正确)。

UI / 集成(`test-full -Dtarget=aarch64-macos` + `macos-app -Dtarget=aarch64-macos` 编译):

- 保存写出正确 config 键(可对 setConfigValue 做注入/桩,或在 settings 行 toggle 路径断言)。
- app_secret 留空不覆盖、有值才覆盖的分支。
- `zig fmt --check build.zig src` 绿(本特性新文件按 zig fmt;吸取 PR #416 教训)。

## 验证基线

- `zig build test` / `zig build test-full -Dtarget=aarch64-macos` / `zig build macos-app -Dtarget=aarch64-macos` 全绿。
- `zig fmt --check build.zig src` 绿。
- 真机:设置里开关飞书 + 打开配置表单填 app-id/secret + 保存见重启 toast;重启后飞书按配置启动。

## 文件清单

- 新增:`src/renderer/overlays/feishu_config.zig`(State)
- 新增:`docs/superpowers/specs/2026-06-29-feishu-config-ui-design.md`(本文)
- 改:`src/renderer/overlays.zig`(open/edit/render/save/save + 设置 action + 命令 dispatch)
- 改:`src/command/center_state.zig`(两条命令 + action 枚举 + 测试)
- 改:`src/i18n.zig`(新键 EN + zh)
- (config.zig 无需改:键 + 解析已存在)
