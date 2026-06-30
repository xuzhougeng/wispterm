# 飞书一键创建应用(扫码)设计

**日期**:2026-06-30
**分支**:claude/friendly-fermat-e74cb9
**前置**:
- 飞书 channel 已合并 main(PR #420,国际版/Lark 区域 + 群 @ 已支持);`config.zig` 已有 `feishu-enabled`/`feishu-app-id`/`feishu-app-secret` 键 + 解析。
- 飞书配置表单已存在(命令面板 `.configure_feishu` → `openFeishuConfigForm`,5 行:启用/国际版/app_id/app_secret/Save,见 `src/renderer/overlays/feishu_config.zig`)。
- 微信扫码登录面板已上线,提供可复用的二维码栈:`src/weixin/qr_code.zig`(QR Model-2 编码器)、`src/weixin/qr_panel.zig`(UI 线程快照+状态机)、`src/renderer/weixin_qr_renderer.zig`(GPU 渲染)。

## 目标

在飞书配置表单里加一个**「扫码创建应用」**入口:用户点击 → 弹一个二维码面板 → 用飞书 App 扫码确认 → 程序自动拿到新应用的 `app_id` / `app_secret` 并**回填进当前配置表单**,用户复核后 Save(走现有 `saveFeishuConfig`)。

省去"去飞书开发者后台手动建应用、抄凭据"的步骤,体验对标现有的微信扫码登录。

底层是飞书开放平台的 **OAuth 2.0 设备授权流(RFC 8628)**,即官方 "Create an app in one-click" / Go SDK `scene/registration` 包封装的协议。

## 非目标(v1 不做)

- **`addons` 预填权限/事件/回调**(协议支持,但要 gzip+base64url 编码;权限让用户在扫码后的网页上自行勾选)。
- **应用元信息预填**(`name`/`desc`/`avatar`)、`createOnly`、**更新已有应用**(`clientID`)。
- **命令面板入口**(只做配置表单内按钮;用户决定)。
- **终端内 ASCII 二维码**(直接用 GPU 面板渲染,复用微信渲染栈)。
- **成功后自动 Save / 自动启用并启动 bot**(回填后停在表单,由用户复核 + Save;Save 后按现有规则需重启生效)。
- **凭据连通性测试**(只回填,不验证)。

## 协议(从 Go SDK `larksuite/oapi-sdk-go` `scene/registration` 反推的真实线协议)

官方文档把端点藏在 SDK 后面,以下是真实 HTTP 交互。

**端点**(注意是 `accounts` 域,非现有 REST 用的 `open` 域):
```
POST https://accounts.feishu.cn/oauth/v1/app/registration        # 国内
POST https://accounts.larksuite.com/oauth/v1/app/registration    # Lark 国际
Content-Type: application/x-www-form-urlencoded
```

**Step 1 — begin(申请设备码)** 请求体:
```
action=begin&archetype=PersonalAgent&auth_method=client_secret&request_user_info=open_id
```
响应 JSON:
```json
{ "device_code": "...", "verification_uri_complete": "https://...(扫码就用这个)",
  "user_code": "...", "interval": 5, "expire_in": 600 }
```

**Step 2 — 展示 `verification_uri_complete` 给用户**(渲染成二维码)。v1 直接用原值;SDK 会额外拼 `from=sdk&tp=sdk&source=...` 等仅用于来源统计的查询参数,**v1 可不拼**(不影响功能)。

**Step 3 — poll(轮询直到用户确认)** 请求体:
```
action=poll&device_code=<上一步的 device_code>
```
响应 JSON(成功给凭据,否则给 error):
```json
{ "client_id": "cli_xxx", "client_secret": "xxx",
  "user_info": { "open_id": "...", "tenant_brand": "feishu|lark" },
  "error": "authorization_pending|slow_down|access_denied|expired_token" }
```

**轮询规则**(对齐 Go SDK `RegisterApp` 循环):
- 首次 poll **不等待**;之后每轮等 `interval` 秒。
- `client_id` 且 `client_secret` 都非空 → **成功**。
- `user_info.tenant_brand == "lark"` 且尚未切换 → 把域名换成 larksuite,**用同一 device_code 立即重 poll**(跨区兜底),只切一次。
- `error == "authorization_pending"` 或 `error == ""` → 继续轮询。
- `error == "slow_down"` → `interval += 5`,继续。
- `error == "access_denied"` → 用户拒绝,终止。
- `error == "expired_token"` 或总时长超 `expire_in` → 过期,终止。

> ⚠️ **关键差异**:`doRegistrationRequest` **完全不检查 HTTP status code**,直接解析 body(设备流的 pending/slow_down 很可能是 4xx + body 带 error)。现有 `rest.zig` 的 `httpsPost` 在非 200 时 `return error`,**不可复用**——registration 需要一个"不判 status、照常读 body"的 form-POST。

## 架构

复用现成的两套模式,引入一个新的网络模块,**不抽新公共抽象**(方案 A):

```
飞书配置表单 (feishu_config.zig)
  └─ 新增一行「扫码创建应用」 ──点击──▶ registration.start(alloc, international)
                                          │ (international 取表单当前「国际版」开关)
                                          ▼
                              src/feishu/registration.zig  [后台线程]
                                begin() → device_code + verification_uri_complete
                                loop poll() → 设备授权状态机
                                成功 → 存 client_id / client_secret
                                每次状态变 → postWakeup()   (记忆 event-driven-wakeup)
                                          │ (mutex 守护的快照)
                                          ▼
                            飞书 QR 面板 (UI线程, refresh() 拍快照)
                              · url 变了就 qr_code.encodeText(url) 重算矩阵
                              · feishu_qr_renderer.render() 画 标题/状态/二维码/按钮
                                          │
                            success 快照 ──▶ feishuConfig().setValue(app_id/secret)
                                             关面板 → 表单已填好 → 用户 Save(现有 saveFeishuConfig)
```

**复用边界**:`src/weixin/qr_code.zig` 的 `encodeText(alloc, payload) → Matrix` 是 channel 无关的纯编码器(尽管文件注释提微信),飞书直接调用,不复制。`qr_panel.zig` / `weixin_qr_renderer.zig` 与微信 controller / 状态枚举 / Unbind 语义强耦合,飞书**复制改造**而非共享——两条流语义不同(微信"登录绑定"有 Unbind,飞书"造新应用"无),且微信路径已上线,改它有回归风险。第三个渠道再要二维码时(rule of three)再抽公共件;在新文件顶部留 `// ponytail:` 注明此升级路径。

## 状态机(面板状态)

| 面板状态 | 来源 | 显示文案(占位) | 按钮 |
|---|---|---|---|
| `requesting` | 正在 begin() | "正在申请…" | Close |
| `waiting` | `authorization_pending` / 空 error | 二维码 + "请用飞书扫码确认" | Close |
| `success` | 拿到 client_id+secret | "创建成功,凭据已回填" | 无(回填后自动关面板,用户随即看到填好的表单) |
| `expired` | `expired_token` 或超 `expire_in` | "二维码已过期" | Retry / Close |
| `denied` | `access_denied` | "已取消授权" | Retry / Close |
| `error` | 网络/解析失败 | 错误提示 | Retry / Close |

`slow_down` 与 `tenant_brand==lark` 切域为**内部状态**,不单独展示给用户(仍停在 `waiting`)。

## 组件

### 1. `src/feishu/registration.zig`(新,~180 行)

设备流网络逻辑 + 后台线程 + 线程安全快照 + 状态机。

```zig
//! 飞书一键创建应用 — OAuth 设备授权流 (RFC 8628)。
//! ponytail: 复制改造微信二维码面板,而非抽公共件——两条流语义不同且微信已上线。
//!           第三个渠道要二维码面板时再抽 shared qr-login 组件。
//!
//! 安全不变量(沿用 rest.zig):app_secret / device_code / 完整 url 查询
//! 绝不打印、记日志或落盘。verification_uri 因要渲染成二维码而对用户可见,
//! 但同样不写日志。

const std = @import("std");
const types = @import("types.zig");
const qr_code = @import("../weixin/qr_code.zig");

fn accountsBase(international: bool) []const u8 {
    return if (international) "https://accounts.larksuite.com"
                            else "https://accounts.feishu.cn";
}

pub const StatusKind = enum { requesting, waiting, success, expired, denied, err };

/// UI 线程读取的快照(mutex 守护)。
pub const Snapshot = struct {
    status: StatusKind,
    verify_url: []const u8 = "", // 借快照内 buffer
    app_id: []const u8 = "",
    app_secret: []const u8 = "",
};

// begin / poll 的 JSON 响应结构、不判 status 的 postForm、状态机循环。
// 线程 + mutex + 快照接口(start / snapshot / retry / stop)镜像 weixin/controller.zig。
```

form-POST helper(关键:不 gate status):
```zig
fn postForm(alloc, arena, base: []const u8, form_body: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var out: std.Io.Writer.Allocating = .init(arena);
    _ = try client.fetch(.{
        .location = .{ .url = <base ++ "/oauth/v1/app/registration"> },
        .method = .POST, .keep_alive = false, .payload = form_body,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .response_writer = &out.writer,
    });
    return out.toArrayList().items; // ← 不判 status,照常返回 body
}
```

> form 值需 URL 编码;begin 的参数全是固定 ASCII token,`device_code` 由服务端生成(URL-safe),用 `std.Uri` 的百分号编码或确认安全后直拼。

### 2. `src/renderer/feishu_qr_renderer.zig`(新,~120 行)

从 `weixin_qr_renderer.zig` 改:标题 "创建飞书应用";按钮仅 Retry(过期/拒绝/错误时)/ Close;读飞书面板的快照而非微信全局。二维码矩阵渲染逻辑(`renderQrMatrix`)与微信相同,照搬。

### 3. UI 接线(改动,均镜像微信对应行)

- **`src/renderer/overlays/feishu_config.zig`**:`FEISHU_ROW_COUNT` 5→6,在 app_id 上方插入「扫码创建应用」行(action 行,非输入字段);更新 `SAVE_ROW` 等索引。
- **`src/renderer/overlays.zig`**:
  - 该行回车/点击 → 读 `feishuConfig().international` → `registration.start(alloc, international)` 开面板。
  - 面板动作处理(Close/Retry),镜像 `weixinQrPanelHandleAction`(overlays.zig:849)。
  - `refresh()` 命中 success → `feishuConfig().setValue(.app_id, ...)` / `setValue(.app_secret, ...)`,关面板。
- **`src/input.zig`**:键/鼠标路由到飞书面板(镜像微信 `weixinQrPanelConsumesChar` / `:3135` esc / `:3136` enter-retry / `:5316` 点击)。
- **`src/AppWindow.zig`**:render passes 调 `feishu_qr_renderer.render(...)`(镜像 `:4400` / `:7121`)+ deinit(镜像 `:7204`)。
- **守卫文件**:`src/renderer/gpu/gl_backend_guard.zig` 用 `@embedFile` 登记了 `weixin_qr_renderer.zig`,新 renderer 按同样方式登记;`command_palette_effect_guard.zig` 等如有断言按需更新。

### 4. 配置键(已存在,无需改 config.zig)

回填目标即现有 `feishu-app-id` / `feishu-app-secret`;Save 走现有 `saveFeishuConfig` → `Config.setConfigValue`。

## 线程与安全

- 后台线程 + mutex 守护快照(镜像 `weixin/controller.zig`);UI 线程只读快照,不碰网络。
- 后台线程改状态后必须 `postWakeup()` 刷新 UI(记忆 event-driven-wakeup:`markUiDirty` 是 threadlocal,worker 线程改 UI 不发 wakeup 不刷新)。
- 面板关闭 / app 退出时 `stop()` 线程并 join,释放快照 buffer;`AppWindow` deinit 调用(镜像微信 `weixin_qr_renderer.deinit`)。
- 安全不变量见模块注释:`app_secret`/`device_code`/完整 url-query 不落日志。

## 测试

`registration.zig` 内纯状态机单测(不联网):喂构造的 poll 响应序列,断言状态转移——
- `{error:"authorization_pending"}` → 停 `waiting`;
- `{error:"slow_down"}` → interval+5 且停 `waiting`;
- `{user_info.tenant_brand:"lark"}` → 触发切域(断言切换标志,且不重复切);
- `{client_id, client_secret}` → `success` 且快照带回凭据;
- `{error:"access_denied"}` → `denied`;`{error:"expired_token"}` → `expired`。

把状态转移抽成纯函数 `step(prev_state, poll_resp) -> next_state` 便于测试,网络循环只调它。QR 编码已被 `qr_code.zig` 现有测试覆盖。

## 风险 / 待核

- **`qr_code.zig` 容量**:`verification_uri_complete` 约 100–200 字符的 URL;需确认编码器支持的 QR 版本容量够(微信登录 payload 量级相近,大概率够)。不够则在实现阶段提升支持的 version。
- **form 值编码**:确认 `device_code` 无需额外转义,或统一走百分号编码。
- **HTTP status 处理**:务必让 `postForm` 不 gate status,否则 pending/slow_down 直接打断轮询(见协议节)。
