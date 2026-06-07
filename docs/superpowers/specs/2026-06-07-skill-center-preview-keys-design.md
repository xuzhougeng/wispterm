# Skill Center：space=预览 / enter=确认 + 服务器技能预览

- 日期：2026-06-07
- 状态：设计已批准，待实现
- 相关背景：[skill-center-design](2026-06-06-skill-center-design.md)、[skill-sync-async-design](2026-06-07-skill-sync-async-design.md)（本设计复用其后台 op 机制）

## 1. 动机

两个交互问题：

1. **键位不直观**：当前主库列表 `Enter` 是「预览」（`sc_legend_v2 = "[⏎] preview …"`），而 overlay 里 `Enter` 是「确认选择」——同一个键在不同上下文含义不一致。期望统一为 `space`=预览、`enter`=确认。
2. **导入无法预览**：进入导入列表（选定 target 后的服务器技能列表）后，用户只能直接 `Enter` 导入，**无法先预览服务器上某个技能的内容**再决定是否导入。

## 2. 目标与非目标

**目标：**
1. 全局统一键位：`space`=预览选中项、`enter`=确认/执行。
2. 主库列表 `Enter` = 部署选中库技能（等同 `d`）。
3. 导入列表 `space` = **预览选中的服务器技能**（SKILL.md），**异步 ssh 读取，不阻塞主线程**。
4. 底部 legend 随上下文显示对应快捷键。

**非目标（YAGNI）：**
- 不为 import picker（仅选 target 阶段、无技能对象）提供 space 预览。
- 不改变 deploy 的「无中间列表，scan→decide」流程。
- 不做预览内容的 diff/编辑（只读预览）。

## 3. 键位映射（`src/input.zig`）

当前（`input.zig:1484-1517`）：`Enter` → overlay active ? `skillCenterOverlaySelect` : `skillCenterPreviewSelected`。

改为：

| 上下文 | `space` | `enter` |
|--------|---------|---------|
| 主库列表（无 overlay） | `skillCenterPreviewSelected()`（库技能，本地，已存在） | `skillCenterDeploy()`（部署选中技能） |
| import list overlay | `skillCenterPreviewServerSkill()`（**新**，服务器技能，异步） | `skillCenterOverlaySelect()`（导入，不变） |
| deploy picker overlay | 预览正在部署的库技能（`skillCenterPreviewSelected` 等效——picker 不改库 sel_row，库 selected 仍是要部署的技能） | `skillCenterOverlaySelect()`（确认 target，不变） |
| import picker overlay | 无操作（无技能对象） | `skillCenterOverlaySelect()`（确认 target，不变） |
| confirm overlay | 无操作 | `skillCenterOverlaySelect()`（确认，不变） |

实现：在 `input.zig` 的 skill-center 分支里
- 新增 `space` 键分支（key_code = 空格），按上表分派：取 `skillCenterOverlayKind()`（新的轻量查询，返回当前 overlay 种类）决定调 `skillCenterPreviewServerSkill` / `skillCenterPreviewSelected` / 无操作。
- `enter` 分支：overlay active → `skillCenterOverlaySelect`（不变）；否则 → `skillCenterDeploy()`（替换原 `skillCenterPreviewSelected`）。

> 为避免 input.zig 直接读 overlay 内部状态，新增一个 `AppWindow.skillCenterSpacePreview()` 包装函数：它在内部判断 overlay 种类并执行正确的预览（import list → 服务器预览；其他/主库 → 库预览；import picker / confirm → 无操作）。input.zig 的 space 分支只调这一个函数，保持 input.zig 平台/状态中立。

## 4. 服务器技能预览（异步，复用 op 机制）

复用 [skill-sync-async-design](2026-06-07-skill-sync-async-design.md) 落地的 `skill_center.Session` 后台 op 机制。

### `skill_center.zig`
给 `OpResult` 增加一个变体：
```zig
/// preview finished: show the fetched SKILL.md in the markdown preview panel.
preview: struct { title: []u8, content: []u8 },
```
`OpResult.deinit` 的 `.preview` 分支释放 `title` 与 `content`。

### `AppWindow.zig`
- 新增 `SkillPreviewJob`：
  - 字段：`conn: ?ssh_connection.SshConnection`、`name: []u8`（owned）、`cmd: []u8`（owned，预构造的 `cat '<root>/<name>/SKILL.md'`）。
  - `run`（后台线程）：`SkillLocExec{ .conn = conn }.exec(cmd)`（local 走 localPosixExec，remote 走 sshExecCapture，均已并发读、不死锁）→ 成功返回 `.preview{ title=dup(name), content=stdout }`；失败返回 `.failed`。
  - `destroy`：释放 `name`、`cmd`，destroy job。
- 新增 `skillCenterPreviewServerSkill()`（UI 线程）：
  - 取 active session；锁内读 `model.overlay`，仅当是 `.import_list` 时取 `il.target` + `il.names[il.sel]`（dup name）+ `skillCenterTargetConn(target)`。
  - 构造 `root_expr = homeRootExpr(target.software.rootRel())`，再用 `skill_center.catCommand` 或等价构造 `cat '<root>/<name>/SKILL.md'`（注意 shell 引用；`<root>` 是 `"$HOME"/'…'` 形式，name 需 shell 引用，拼接为 `<root>/'<name>'/'SKILL.md'`）。
  - `session.startOp(SkillPreviewJob, window_backend.postWakeup, i18n.s().sc_busy_loading)`；忙则 toast `sc_toast_op_busy`；rejection 时 `SkillPreviewJob.destroy`。
- `pollSkillCenterOp` 增加 `.preview` 分支：`markdown_preview_panel.open(.markdown, v.title, "SKILL.md", v.content)`（open 内部 dup content/title，所以 `defer result.deinit` 之后安全）。

> 命令构造细节：服务器技能路径与库技能布局一致（`<root>/<name>/SKILL.md`）。`ImportState` 当前只保留 `names`+`markers`，不含 rel_path——用 `name` 现场构造路径即可，无需扩展 `ImportState`。

### 加载反馈
`startOp` 已把 `busy_msg` 写入 `session.status`（panel header 可见）。预览用 `sc_busy_loading`（「加载中…」）。op 完成时 worker 清 status；`pollSkillCenterOp` 打开预览面板。

## 5. legend 随上下文（`src/i18n.zig` + `AppWindow.zig`）

当前 `view.legend` 固定 `sc_legend_v2`。改为按 `model.overlay` 选：
- 主库（`.none`/`.busy`）：`sc_legend_v2` 更新为 `[space] 预览  [↵] 部署  [i] 导入  [r] 重扫`（en：`[space] preview  [↵] deploy  [i] import  [r] rescan`）。
- import list：新增 `sc_legend_import` = `[space] 预览  [↵] 导入  [esc] 返回`（en：`[space] preview  [↵] import  [esc] back`）。
- picker / confirm：沿用 `sc_legend_v2`（或保持现状的简短提示）；不单独定制（YAGNI）。

`AppWindow` 构建 view 时：`const legend = if (model.overlay == .import_list) i18n.s().sc_legend_import else i18n.s().sc_legend_v2;`。

新增 i18n 串：`sc_legend_import`、`sc_busy_loading`（en + zh_CN，两表都加）；并改写 `sc_legend_v2` 两表文案。

## 6. 错误处理与并发

- 预览失败（ssh 失败 / SKILL.md 不存在）→ Job 返回 `.failed` → `pollSkillCenterOp` 的 `.failed` 分支显示 toast（沿用 `sc_toast_no_conn`；或更贴切的 `sc_toast_read_failed`——见下）。
  - 决策：`.failed` 是通用失败，目前 `.failed` 分支显示 `sc_toast_no_conn`。预览失败既可能是连不上也可能是读不到。保持沿用 `sc_toast_no_conn`（避免给 `.failed` 加来源区分，YAGNI）。
- 并发：预览也走 `startOp`，与 transfer/scan/import-scan 互斥（同一时刻一个 op）；若有 op 在跑，预览被拒 → toast `sc_toast_op_busy`。这是可接受行为（用户极少在同步进行中再点预览）。
- 生命周期：`SkillPreviewJob` 与其他 Job 同构，`destroy` 释放自身 owned 字段；`OpResult.preview` 由 `pollSkillCenterOp` 的 `defer result.deinit` 释放（open 已 dup）。

## 7. 测试

- `skill_center`：`OpResult.preview` 的 `deinit` 释放 title+content（注入构造的 preview result，testing allocator 验无泄漏）。
- 命令构造：服务器 SKILL.md 路径/shell 引用的纯函数单测（含带空格/引号的技能名）。
- 现有 op 测试（startOp/takePendingOp/closing）保持绿。
- `markdown_preview_panel.open` dup 行为已确认（`applyContentForOwner` 用 page_allocator.dupe），无需新测。
- 键位：input.zig 难以单元测试（依赖全局），靠 macos-app 编译 + 手动验证。

## 8. 改动文件

| 文件 | 改动 |
|------|------|
| `src/input.zig` | space 分支（调 `skillCenterSpacePreview`）；enter 分支主库改调 `skillCenterDeploy` |
| `src/skill_center.zig` | `OpResult` 加 `.preview` 变体 + deinit 分支 |
| `src/AppWindow.zig` | `SkillPreviewJob`；`skillCenterPreviewServerSkill`；`skillCenterSpacePreview` 包装；`pollSkillCenterOp` 加 `.preview` 分支；view.legend 按 overlay 选 |
| `src/i18n.zig` | 改写 `sc_legend_v2`；新增 `sc_legend_import`、`sc_busy_loading`（en+zh_CN） |

## 9. 风险与权衡

- **预览与同步互斥**：单 op 槽意味着同步进行中无法预览。可接受（一次一个操作），符合现有 UI 模型。
- **路径构造假设**：假设服务器技能布局为 `<root>/<name>/SKILL.md`（与库一致）。若服务器技能 SKILL.md 路径不同，预览会失败并 toast——可接受的降级。
- **deploy picker 的 space 预览**：复用 `skillCenterPreviewSelected`，预览「当前库选中技能」（deploy picker 不改 `sel_row`，库 `selected()` 仍是要部署的技能）。语义正确、实现简单；属边角但零额外成本，故按 §3 表格实现，不降级。
