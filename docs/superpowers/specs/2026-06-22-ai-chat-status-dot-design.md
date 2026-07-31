# AI Chat 状态指示:文字 → 彩色圆点

日期:2026-06-22

## 背景与问题

AI Chat 面板头部最右侧显示一段状态文字(`Ready` / `Done` / `Thinking…` 等),
空闲态由 `statusActionRect` 预留约 280px(`STATUS_SLOT_W`),请求进行中则显示
一个 104px 宽的 `Esc Stop` 按钮。在窄的 copilot 侧边栏里,这块文字占用过多横向
空间(模型名在窄面板下已经被隐藏)。

目标:用红/绿/黄三色圆点表示状态,大幅压缩占用,同时保留关键信息与取消能力。

代码现状:
- 渲染:`src/renderer/ai_chat_renderer.zig` `render()` 第 213–224 行
  (`if (request_inflight) renderStopButton(...) else 渲染状态文字`)。
- 状态是纯字符串 `Session.status_buf: [512]u8`,没有严重级别枚举。
- 取消请求:进行中按 `Esc` 即触发 `stopRequest()`(`src/ai_chat.zig:1472`),
  以及点击 `Esc Stop` 按钮(`input.zig:4438/4578` 调 `stopButtonHitTest` → `stopRequest`)。
- 主题色:`Config.Theme.palette: [16]Color`(`Color = [3]f32`),标准 ANSI:
  `palette[1]`=红、`palette[2]`=绿、`palette[3]`=黄。

## 目标 / 非目标

目标:
- 状态指示从文字改为固定在头部最右角的彩色圆点(直径约 9px,垂直居中)。
- 圆点颜色映射请求生命周期三态:绿=正常完整、黄=进行中、红=停止/出错。
- 用主题自带 ANSI 色,换主题自动适配。
- 进行中的黄点可点击停止(复用现有点击热区),`Esc` 仍可取消。
- 出错(红)时在圆点旁保留简短错误文字,保证可操作提示(如 Missing API key)不丢失。

非目标:
- 不改任何状态字符串本身、不改 agent 行为。
- 不动模型名 / Agent·Chat / 权限 chip(Ask/Auto/Full)这三块,只替换最右侧状态块。
- 不引入悬停 tooltip(终端 UI 无现成机制)。

## 状态 → 颜色映射

| 颜色 | 语义 | 触发条件 |
|---|---|---|
| 🟢 绿 `palette[2]` | 正常完整 | 空闲且状态为 Ready / Done(含 Done in X.Xs) / Cleared / Model switched / Context summarized / Distill preview ready(默认归类) |
| 🟡 黄 `palette[3]` | 进行中 | `request_inflight`(Thinking / Streaming / Running tools / Searching / Reading / Summarizing / Distilling / Stopping);以及空闲态下的 Approval needed、Waiting for your answer |
| 🔴 红 `palette[1]` | 停止 / 出错 | `missingApiKey()`;以及空闲态下的 Stopped、Out of memory、Could not…、Failed…、Summary unavailable… |

## 设计

### 1. 状态分级:`Session.statusKind()`

在 `src/ai_chat.zig` 新增:

```zig
pub const StatusKind = enum { ready, busy, stopped }; // ready→绿, busy→黄, stopped→红

/// 调用方需已持有 session.mutex(与 status() 一致)。
pub fn statusKind(self: *const Session) StatusKind {
    if (self.missingApiKey()) return .stopped;
    if (self.request_inflight) return .busy;
    const s = self.status();
    if (isErrorStatus(s)) return .stopped;          // Out of memory / Could not / Failed / unavailable / Stopped
    if (isWaitingStatus(s)) return .busy;           // Approval needed / Waiting for your answer
    return .ready;
}
```

`isErrorStatus` / `isWaitingStatus` 用前缀/相等匹配已知字符串;未知空闲串默认 `.ready`(绿)。
逻辑主要靠标志位(`missingApiKey` / `request_inflight`),字符串匹配只覆盖少量空闲态。
可单测,不依赖渲染。

### 2. 圆点绘制图元:`fillDot`

代码无圆形图元(全是 `fillQuad`)。在 `ai_chat_renderer.zig` 加私有辅助:
按圆方程逐行堆 `fillQuadAlpha` 近似实心圆盘(直径约 9px → ~9 行,开销可忽略),
得到真正的圆点而非方块,且不依赖字体字形。颜色取主题 ANSI 色。

### 3. 渲染替换(`render()` 213–224 行)

新逻辑(始终走同一分支,不再按 inflight 二选一):
- 计算 `kind = session.statusKind()`,选 `dot_color = palette[1/2/3]`。
- 圆点固定画在头部最右角(`x + w - LINE_PAD_X` 处,垂直居中),所有状态位置一致,便于一眼定位。
- 若 `kind == .stopped`(红):在圆点左侧渲染简短状态文字(`session.status()`,
  缺 key 时用 `MISSING_API_KEY_ACTION_TEXT`),文字向左展开,宽度受 `statusActionRect` 同款夹取规则约束,避免与权限 chip 重叠。
- 绿 / 黄:仅圆点,无文字。

### 4. 点击停止(黄点)

复用现有 `stopButtonHitTest` + `input.zig` 调用链(命中即 `stopRequest()`)。
做法:把 `stopButtonRect` 的几何改成圆点所在位置的一个便于点击的方形热区
(略大于视觉圆点,如 ~24–28px 方块),并保持仅在 `request_inflight` 时命中。
`input.zig` 两处调用点(4438/4578)无需改动。`Esc` 取消路径不变。

### 5. 出错文字点击(红点)

`missingApiKeyStatusHitTest` 继续有效(红态文字仍渲染,点击可跳配置)。
其命中矩形需跟随新的红态文字位置;沿用 `statusActionRect` 计算即可。

## 测试

- 单测(`zig build test` 快速套件,macOS 可链接通过):
  `Session.statusKind()` 覆盖 ready / busy(inflight + waiting)/ stopped(error + missingApiKey)各分支。
- UI 渲染回归:`zig build test-macos-ui`(布局/热区相关,见 `ai_chat_layout.zig` 的 `stopButtonRect` 测试,需同步更新)。
- 真机抽查:窄 copilot 侧边栏下三态圆点位置一致、黄点可点击停止、红态文字可见且可点。

## 触及文件

- `src/ai_chat.zig`:新增 `StatusKind` + `statusKind()` + 分类辅助;单测。
- `src/renderer/ai_chat_renderer.zig`:`fillDot` 辅助;改写 `render()` 状态块;
  调整 `stopButtonRect`/相关常量为圆点热区;红态文字位置。
- `src/ai_chat_layout.zig`:同步 `stopButtonRect` 几何与其测试。
- (input.zig 预期无需改动,验证为准。)

## 取舍记录

- 绿/黄态丢失精确文字(如 "Done in 3.2s"),换取空间——符合"空间小"诉求。
- 进行中不再有 `Esc Stop` 文案提示,靠黄点可点击 + Esc 兜底;接受可发现性下降。
- 错误态保留文字,因其常含可操作信息,是最需要文字的场景。
