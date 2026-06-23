# 副驾历史面板 UI（第二阶段）：相对时间 + 时间分组 + 搜索/来源筛选

- 日期：2026-06-23
- 范围：**命令面板的「副驾历史」模态**（截图那个：标题"副驾历史"、搜索框 placeholder"最近的副驾会话"、底部"上下选择，回车重开，Delete 删除，Esc"）。即 `renderCommandPalette` 的历史模式分支。
- 前置：建立在第一阶段存储重构（per-session 文件 + 索引）之上。本阶段所需数据 `agent_history.Row`（含 `title/model/updated_at/copilot`）由 `MetaStore.buildRows` 提供，已按 `updated_at` 倒序。
- **不在范围**：file_explorer 侧栏的 agent-history 面板（另一套 `g_panel_mode == .agent_history`，input.zig:4026）；消息正文的深度全文检索（留给后续，索引已存 `search_preview` 备用）。

## 背景与问题

当前命令面板「副驾历史」模式（[overlays.zig](../../../src/renderer/overlays.zig) `renderCommandPalette` 历史分支）：
- 每行只画 `title` + 右侧 `model`/「侧栏」标记，**不显示时间**——尽管 `Row.updated_at` 已有。
- 列表是**扁平**的，没有日期分组，难定位"某天"的会话。
- 搜索框是**惰性的**：历史模式下 `commandPaletteInsertChar`/`commandPaletteBackspace`（overlays.zig:284/339）与 input.zig:2522 的字符输入都直接 `return`，框里只显示"最近的副驾会话"提示，**无法输入筛选**。
- 无法按来源（侧栏/标签页）或模型快速筛选。

## 目标 / 非目标

**目标**（用户已确认的设计取舍）
1. 每行右侧显示**相对时间**"4h ago"（复用 `copilot_picker.formatRelativeTime`）。
2. 按**本地日历日**分组：今天 / 昨天 / 过去7天 / 更早，组间插入灰色分隔标题。
3. **启用搜索框**：输入即按 **title + model** 大小写不敏感子串过滤（"扩大字段"与"按模型筛选=输入模型名"合一）。
4. **来源快捷筛选**：`Tab` 键循环 全部 → 侧栏 → 标签页，标题栏右侧显示当前 chip。
5. 导航在过滤后的会话行间移动、**跳过分组标题**；空结果显示"无匹配"。

**非目标**
- 模型不做独立 chip 循环（输入模型名即可）。
- 不触碰 file_explorer 侧栏 agent-history 面板。
- 不做消息正文全文检索。

## 设计概览

### 纯视图模块 `src/command_palette_history_view.zig`

把"过滤 + 分桶 + 生成显示项 + 导航辅助"做成无渲染、无全局状态的纯模块（加入 `test_fast.zig`，`zig build test` 覆盖）。

```zig
pub const Bucket = enum { today, yesterday, past_week, earlier };
pub const SourceFilter = enum { all, sidebar, tab };

// 显示项：分组标题，或一条会话行（row = 在 filtered 中的序号 0..filtered.len）
pub const DisplayItem = union(enum) { header: Bucket, row: usize };

pub const View = struct {
    items: []DisplayItem,   // 标题 + 行，按显示顺序（行已按 updated_at 倒序）
    filtered: []usize,      // 通过过滤的「原始 rows 下标」，按显示顺序；可选行数 = filtered.len
    pub fn rowCount(self: *const View) usize { return self.filtered.len; }
    pub fn deinit(self: *View, allocator: std.mem.Allocator) void;
};

// 本地纪元日（向下取整到天），用于稳健的"差几天"分桶（比 packed YYYYMMDD 更易算）
pub fn localEpochDay(ms: i64, tz_offset_seconds: i32) i64;
pub fn bucketFor(now_ms: i64, row_ms: i64, tz_offset_seconds: i32) Bucket; // 0→today,1→yesterday,2..6→past_week,>=7→earlier；负差(时钟偏移)按 today
pub fn rowMatches(row: agent_history.Row, query: []const u8, source: SourceFilter) bool; // (title|model 含 query) 且 来源匹配
pub fn build(
    allocator: std.mem.Allocator,
    rows: []const agent_history.Row,
    query: []const u8,
    source: SourceFilter,
    now_ms: i64,
    tz_offset_seconds: i32,
) !View;
```

- `build`：顺序遍历已排序的 `rows`，对每条先 `rowMatches` 过滤；保留者计算 `bucketFor`，当桶相对上一保留行变化时先 push 一个 `.header`，再 push `.row`（序号为它在 `filtered` 中的位置）。桶因排序天然连续。
- `rowMatches`：`containsIgnoreCase(title, q) or containsIgnoreCase(model, q)`（复用 `command_palette_model.containsIgnoreCase`），且 `source==all || (source==sidebar && copilot) || (source==tab && !copilot)`。

### 渲染（`renderCommandPalette` 历史分支改造）

- 每帧取 `now_ms = std.time.milliTimestamp()`、`tz = ai_history_time.localOffsetSeconds()`、当前 `query`（复用 `g_command_palette_filter`）、当前 `source`（来自 state），调 `view.build(...)`，渲染后 `deinit`。
- 标题栏：标题"副驾历史"右侧加来源 chip（`i18n` 全部/侧栏/标签页）；搜索框由"惰性提示"改为显示可编辑的 `query`（空时显示 placeholder）。
- 列表：遍历 `view.items` 做窗口化渲染（见下）。`.header` 画一行居中/缩进的灰色分组标题；`.row` 画 `title` + 右侧 `model`/「侧栏」+ 最右 `formatRelativeTime(now_ms, rows[filtered[ord]].updated_at)`；当 `ord == 选中序号` 高亮。
- 空 `filtered`：居中显示"无匹配"。

### 选择 / 滚动

- 状态 `command_palette_history_selected` 改为**过滤后会话行的序号**（0..rowCount），每次 `build` 后 clamp 到 `rowCount`。
- 上/下移动只在 `[0, rowCount)` 间走（沿用 `commandPaletteMoveAgentHistory` 的 wrap 逻辑，行数传 `rowCount`）。
- 滚动：把可视窗口从"对会话行取窗"改为"**对 `view.items`（含标题）取窗**"，并保证选中会话行对应的 DisplayItem 落在窗口内（由选中行的 display 下标推算首行）。沿用现有 `commandPaletteLayout`/`rendered_rows` 的固定行高与行数，标题占一个行槽。

### 输入（input.zig 历史模式键位 @2924 + 字符输入 @2522）

历史模式按键，在现有 Esc/Up/Down/Enter/Delete 基础上：
- **可打印字符** → 插入 `g_command_palette_filter`（解除 overlays.zig:284 与 input.zig:2522 的历史模式 `return` 守卫，使其在历史模式也插入）。
- **Backspace** → 删除 query 末个 codepoint（解除 overlays.zig:339 守卫；历史模式新增 backspace 处理）。
- **Tab** → 循环来源筛选 `all→sidebar→tab→all`。
- **Delete** → 维持"删除选中会话"（语义不变，与 Backspace 编辑 query 不冲突）。
- Up/Down/Enter/Esc 不变（Enter 重开选中会话，Esc 离开历史模式）。
- 进入历史模式时**重置** `query` 为空、`source` 为 `all`、选中为 0。

### 状态（command_center_state.zig）

`State` 新增 `command_palette_history_source: command_palette_history_view.SourceFilter = .all`，并加：
- `commandPaletteCycleHistorySource(self)`：`.all→.sidebar→.tab→.all`。
- 进入历史模式（`commandPaletteOpenAgentHistory`）时把 source 复位为 `.all`、`command_palette_history_selected = 0`、清空 filter。
（`command_center_state` 引入对纯模块 `command_palette_history_view` 的 import 仅为 `SourceFilter` 枚举；两者都在 fast 套件，无循环依赖风险。）

### i18n（i18n.zig Strings）

新增字段（中英各一份）：
- 分组标题：`cmd_palette_group_today`/`_yesterday`/`_past_week`/`_earlier`（今天/昨天/过去7天/更早；Today/Yesterday/Past 7 days/Earlier）。
- 来源 chip：`cmd_palette_source_all`/`_sidebar`/`_tab`（全部/侧栏/标签页；All/Sidebar/Tab）。
- 更新 `cmd_palette_footer_history` 提示，体现：输入筛选 · ↑↓ 选择 · Tab 来源 · 回车重开 · Delete 删除 · Esc 返回。

## 接线点小结

| 关注点 | 文件 | 改动 |
| --- | --- | --- |
| 过滤/分桶/显示项（纯逻辑） | `src/command_palette_history_view.zig`（新建） | View/Bucket/SourceFilter/build/bucketFor/rowMatches/localEpochDay |
| 渲染历史分支 | `src/renderer/overlays.zig` `renderCommandPalette` | 用 View 渲染、相对时间、分组标题、来源 chip、可编辑搜索框、窗口化 |
| 历史键位 | `src/input.zig`（~2522 字符、~2924 历史键） | 启用字符/Backspace、Tab 循环来源 |
| 选择/来源状态 | `src/command_center_state.zig` | `command_palette_history_source` + cycle + 进入复位 |
| 文案 | `src/i18n.zig` | 分组/来源/footer 字段 |
| 测试装配 | `src/test_fast.zig` | `_ = @import("command_palette_history_view.zig");` |

## 测试

### 单元测试（`zig build test`，纯视图模块）
- `localEpochDay` / `bucketFor`：今天(0)/昨天(1)/过去7天(2..6)/更早(>=7)；跨时区（UTC+8、UTC-8）边界；负差（时钟偏移）归 today。
- `rowMatches`：title 命中、model 命中、都不命中；source=all/sidebar/tab 三态过滤。
- `build`：多桶在边界处各插一个 header；过滤后只剩部分桶；空结果（items 空、filtered 空）；filtered 顺序 = 排序顺序；header 不计入 rowCount。
- 导航辅助：选中序号在 `[0,rowCount)` clamp/wrap，分组标题不可选。

### macos-e2e（`make test-macos-e2e`，新增 `tests/macos_e2e/test_copilot_history.py`）
鉴于 overlay/AI-chat 文本无法经 ctl `get-text` 断言（只读终端 pane），采用**输入驱动 + 可观测信号**：
1. **预置数据**：在隔离 HOME 的配置目录下预写 `agent-history/sessions/<id>.json` + `index.json`（数条会话，含 copilot 与非 copilot、不同 `updated_at`）——顺带端到端验证第一阶段存储加载。
2. **驱动**（real CGEvent）：toggle 命令面板 → 选择/进入「副驾历史」→ 输入一个只匹配某会话的筛选词 → ↑↓ 导航 → Tab 切来源 → Esc 关闭。
3. **断言**（可观测）：
   - 流程后做一次终端 round-trip（`send_text "echo e2e-ok\n"` + `wait_for "e2e-ok"`）——证明历史模式的字符/Tab/方向键/Esc 处理不崩、不卡、不吞终端输入（呼应"overlay 输入处理回归"类历史问题）。
   - 回车重开某会话后断言 `panes()` 较基线发生变化（证明重开链路被执行）。
   - overlay 内的相对时间/分组文本**不在 e2e 断言**（由单测覆盖）。
4. 历史模式的精确进入序列（命令面板键位 + 选择「副驾历史」项）在实施计划里定死。

## 验证
- `zig build test`（fast，含新视图模块 + command_center_state 测试）。
- `zig build test-full`（含 overlays/input 相关 app 测试）。
- `zig build macos-app -Dtarget=aarch64-macos`（真机构建）。
- `make test-macos-e2e`（新增的 copilot 历史 e2e）。
- 真机手测：打开副驾历史 → 看到相对时间与今天/昨天/过去7天/更早分组 → 输入筛 title/model → Tab 切来源 chip → ↑↓ 跳过分组标题 → 回车重开。

## 风险
- **滚动窗口化**：从"对会话行取窗"改为"对含标题的 DisplayItem 取窗"是最易错处——需保证选中行始终可见且标题不抢占导航。以单测覆盖 build 的 items 结构 + 真机手测滚动。
- **输入语义重叠**：Backspace 编辑 query vs Delete 删除会话——已明确分工，避免误删会话。
- **e2e 进入序列脆弱**：无"副驾历史"菜单项，需经命令面板选择项进入；序列在 plan 固化，必要时回退为"最小冒烟（能开能输入不崩）"。
- 主线程 overlay 键/字符处理需置 `g_force_rebuild`（项目既有约定，避免方向键"不跟手"）。

## 未来工作
- 深度全文检索：在 `index.json.search_preview` 之上扩为消息正文检索（需让面板拿到 IndexEntry 而非仅 Row）。
- 把相对时间/分组同样应用到 file_explorer 侧栏 agent-history 面板（另一表面）。
