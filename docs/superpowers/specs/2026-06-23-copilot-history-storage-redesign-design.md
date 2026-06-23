# 副驾历史存储重构：单文件 → 每会话一文件 + 索引（懒加载）

- 日期：2026-06-23
- 范围：**仅存储架构层**。副驾历史面板的 UI 优化（日期显示、时间分组、启用搜索/来源/模型筛选）作为**第二阶段单独 spec**，本轮不做。
- 触发：用户反馈「copilot history 管理很差——单文件、不利于检索；8MB 上限有丢历史风险」。本轮把单文件存储拆成每会话一文件 + 元数据索引，并改为索引驱动、正文懒加载，为后续检索打地基。

## 背景与问题

当前副驾会话（含侧栏 Copilot 与 AI Chat 标签页）统一存放在 `agent_history.Store`，落盘为**单个 JSON 文件** `<config>/agent-history.json`：

- **8MB 致命上限**：[loadFromPath](../../../src/agent_history.zig#L286) 用 `readFileAlloc(..., MAX_HISTORY_BYTES = 8MB)`。一旦文件超过 8MB，读取直接报错并经 `else` 分支 `return err`；调用方 [ensureGlobalAgentHistoryStore](../../../src/AppWindow.zig#L5564) 用 `try` 传播，导致**整库加载失败、历史全空**。
- **整文件重写**：每次 flush 调 `saveDefault` → `saveToPath`，把整库（所有会话的所有消息正文）原子重写一遍。会话越多越慢。
- **不利于检索**：所有正文塞在一个 JSON 里，想搜消息内容必须整体解析；列表渲染也要先把整库读进内存解析。
- **一坏全丢**：单文件 JSON 局部损坏时，`fromJsonStringLenient` 只能整体回退为空库。

注：经与用户确认，**当前消息内容是完整保存的**，没有截断 bug；本轮不涉及「部分记录」问题，只解决存储结构。

## 目标 / 非目标

**目标**
1. 去掉 8MB 全局读取死线，历史规模不再有全局上限。
2. 每会话独立成文件，单文件损坏只影响该会话，其余可正常加载。
3. 维护一份轻量**元数据索引** `index.json`，让列表与（元数据级）检索无需读取所有正文。
4. 运行时改为**索引驱动 + 正文懒加载**：启动只载入索引；打开某会话时才读它的正文文件。
5. 写入精细化：只重写改动过的会话文件 + 索引，不再整库重写。
6. 从旧单文件**一次性、幂等、可回滚**地迁移到新布局。

**非目标（本轮明确不做）**
- 副驾历史面板的 UI（日期、时间分组、搜索框启用、来源/模型筛选）—— 第二阶段 spec。
- 消息正文的全文检索（FTS）。本轮只在索引里存**有界搜索预览文本**，为后续检索留接口，不实现深度全文搜索。
- 引入 SQLite 或任何新的第三方/ C 依赖。

## 现状速览（改造半径）

生产代码里真正触碰 `Store` 的调用点（其余 `*.buildRows`/`upsertRecord` 命中均为 `agent_history.zig` 内联测试）：

| 调用点 | 文件:行 | 当前行为 | 重构后 |
| --- | --- | --- | --- |
| 加载 | `AppWindow.zig:5572` `ensureGlobalAgentHistoryStore` → `loadDefault` | 读整库进内存 | 只读 `index.json`（缺失/损坏则扫描会话文件重建） |
| 列表（侧栏） | `file_explorer.zig:332` `syncAgentHistoryRows` → `buildRows` | 从内存全量构造 Row | 从索引构造 Row（不读正文） |
| 列表（命令面板） | `AppWindow.zig:5985` `snapshotAgentHistoryRowsForCommandPalette` → `buildRows` | 同上 | 同上 |
| 列表（Copilot picker） | `agent_history buildCopilotRows`（经 overlays） | 从内存筛 copilot | 从索引筛 copilot |
| 写入（AI 历史变更） | `AppWindow.zig:5615` `saveAiHistoryChangeEvent` → `upsertRecord` | upsert 内存 + 标整库 dirty | upsert：更新内存 entry + 暂存「待写记录」+ `markDirty`（去抖，**不立即写盘**） |
| 写入（关闭前持久化打开的标签） | `AppWindow.zig:5642` `persistOpenAiChatTabsToHistoryStore` → `upsertRecord` | 同上 | 同上 |
| 恢复 | `AppWindow.zig:1199 / 1273` `cloneRecordBySessionId` | 从内存克隆完整记录 | 先查内存暂存，未命中则**读该会话文件**返回完整记录 |
| 删除 | `AppWindow.zig:5972` `deleteAiChatHistorySessionId` → `deleteBySessionId` | 内存删除 + 标 dirty | 内存索引删除 + 删该会话文件 + 移除暂存 + 标脏 |
| 落盘 | `AppWindow.zig:5659` `flushAgentHistoryStoreIfDirty` → `saveDefault` | 整库重写 | 节流 flush：写所有「待写」会话文件 + 重写 `index.json`，清空暂存 |

`session_id` 形如 `session-{毫秒}-{计数}`（[ai_chat.zig:4183](../../../src/ai_chat.zig#L4183)），纯 ASCII、可直接作文件名（非法字符做净化兜底，见下）。

## 磁盘布局

```
<config>/agent-history/                # 新目录
  index.json                           # 版本化元数据索引（派生缓存，可重建）
  sessions/
    session-1719000000000-3.json       # 每会话一个完整 SessionRecord（权威源）
    ...
```

- 旧文件 `<config>/agent-history.json` 在迁移完成后改名为 `<config>/agent-history.json.bak`（**保留不删**），作为回滚与审计依据。
- 平台路径：在 `src/platform/dirs.zig` 新增 `agentHistoryDir(allocator)`（返回 `<config>/agent-history`）；现有 `agentHistoryPath`（返回旧单文件路径）保留，仅用于迁移检测与 `.bak` 重命名。

## 数据结构

会话文件（权威源，复用现有 `SessionRecord` 序列化，单条记录而非数组）：

```zig
// sessions/<id>.json  ← 直接是一个 SessionRecord 的 JSON（已含 messages 全文）
```

索引 `index.json`（派生缓存，可由会话文件重建）：

```zig
pub const IndexEntry = struct {
    session_id: []const u8,
    title: []const u8,
    model: []const u8,
    created_at: i64,
    updated_at: i64,
    copilot: bool = false,
    message_count: u32 = 0,
    // 有界搜索预览：title + 首条/末条消息截断拼接，小写归一。
    // 仅供元数据级检索与列表预览；深度全文检索为后续工作。
    search_preview: []const u8 = "",
};

pub const IndexFile = struct {
    version: u32 = 1,
    entries: []IndexEntry = &.{},
};
```

`Row`（现有结构，列表渲染用）从 `IndexEntry` 直接投影，字段一一对应，无需读正文。

## 运行时内存模型：索引驱动 + 正文懒加载

新存储抽象（暂名 `MetaStore`，落点见「模块划分」）：

- 内存常驻：`entries: []IndexEntry`（全部会话的元数据，远小于正文）。
- **不**常驻：任何 `messages` 正文。
- 接口（替换现 `Store` 的对外语义，保持调用点改动最小）：

```zig
pub const MetaStore = struct {
    allocator,
    dir: []const u8,                                  // <config>/agent-history
    entries: std.ArrayListUnmanaged(IndexEntry),      // 全部会话元数据（常驻）
    pending: std.StringHashMapUnmanaged(SessionRecord),// 改动未落盘的完整记录（去抖期间暂存）
    index_dirty: bool,                                // index.json 需重写

    pub fn open(allocator, dir) !MetaStore;          // 载入/重建索引（不读正文）
    pub fn buildRows(self, allocator) ![]Row;        // 从 entries 投影，已按 updated_at 倒序
    pub fn buildCopilotRows(self, allocator) ![]Row; // 仅 copilot==true
    // 完整记录：先查 pending，未命中则懒读 sessions/<id>.json（保留旧方法名以少改调用点）
    pub fn cloneRecordBySessionId(self, allocator, id) !?SessionRecord;
    pub fn upsertRecord(self, input) !void;          // 更新 entry + 存入 pending + index_dirty=true（不写盘）
    pub fn deleteBySessionId(self, id) bool;         // 删文件 + 删 entry + 移除 pending + index_dirty=true
    pub fn flush(self) !void;                         // 写所有 pending 会话文件 + 重写 index.json + 清空 pending
    pub fn deinit(self) void;
};
```

- 生产调用点签名基本不变：`cloneRecordBySessionId` 保留同名（内部先查 `pending` 再读盘）；`buildRows`/`buildCopilotRows`/`upsertRecord`/`deleteBySessionId`/`deinit` 同名同义。新增 `dir` 参数仅出现在 `open`。
- `upsertRecord` 把完整 `SessionRecord` 克隆进 `pending` 并刷新对应 `IndexEntry`、置 `index_dirty`、`markDirty`；**不立即写盘**。只有「改动未落盘」的少量记录短暂常驻，flush 后清空，冷会话始终懒加载。

> 决策记录：写盘走 flush_scheduler 去抖（沿用现有 350ms 防抖），`upsertRecord` 仅更新内存并暂存。理由：AI 流式回复会高频触发 upsert，若每次立即整写会话文件则一次回复内 O(n²) 写盘；去抖把多次变更合并为一次落盘。代价是改动记录在 flush 前短暂驻留内存——量小且 flush 后释放，仍符合懒加载初衷。

## 迁移（旧单文件 → 新布局）

`MetaStore.open` 启动时：

1. 若 `agent-history/index.json` 存在且 `version` 匹配 → 直接载入。
2. 否则若 `agent-history/sessions/` 存在 → **扫描重建索引**（解析每个 `*.json` 取元数据；解析失败的文件记日志跳过）。
3. 否则若旧单文件 `agent-history.json` 存在 → **执行迁移**：
   - 用**大上限/流式**读取旧文件（迁移路径不受 8MB 限制；用 `std.fs` 直接读全量或分段，避免 `readFileAlloc` 的小上限）。
   - 用现有 `Store.fromJsonStringLenient` 解析为记录集合。
   - 逐条原子写 `sessions/<sanitized_id>.json`，并累积 `IndexEntry`。
   - 原子写 `index.json`。
   - **全部成功后**才把旧文件 `rename` 为 `agent-history.json.bak`。任一步失败：保留旧文件、清理半成品目录、记日志并降级为空索引（下次启动重试），绝不删除旧数据。
4. 否则（全新用户）→ 空索引。

迁移幂等：以 `.bak` 是否已生成 + 目录是否存在为判据；重复启动不会重复迁移或覆盖。

## 文件名安全与防碰撞

- 合法字符集 `[A-Za-z0-9._-]`。`session_id` 现状全部满足。
- 不满足时（历史遗留/异常 id）：将非法字符替换为 `_`，并在末尾追加 `-{wyhash十六进制}`，保证唯一且可逆映射（真实 `session_id` 同时存在于文件内 `SessionRecord.session_id` 与 `IndexEntry.session_id`，文件名仅作存储键）。
- 删除/读取通过 `IndexEntry.session_id` → 文件名映射函数定位，映射函数为纯函数、可单测。

## 并发与落盘

- 沿用 `g_agent_history_mutex` 保护 `MetaStore`，以及 `flush_scheduler.FlushScheduler`（`markDirty`/`shouldFlush`/`beginFlush`/`deferFlush`/`failFlush`/`reset`，350ms 去抖）。
- `upsertRecord`：持锁内更新内存 entry + 克隆进 `pending` + `markAgentHistoryDirtyLocked()`（标脏并驱动去抖），**不写盘**。
- `deleteBySessionId`：持锁内删会话文件 + 删 entry + 移除 `pending` 项 + 标脏。
- `flushAgentHistoryStoreIfDirty`：沿用现有「持锁判定 `shouldFlush`」门控；判定通过后在锁内调 `MetaStore.flush()`（逐个原子写 `pending` 会话文件 + 原子写 `index.json`），成功 `beginFlush`、失败 `failFlush`。flush 经 350ms 去抖且只写少量脏文件，锁内写盘耗时可忽略，换取实现简单与 pending 所有权清晰（无需在「移出 pending 后写失败」时回填）。
- 关闭路径 `deinitGlobalAgentHistoryStore` 仍 `force` flush 一次，确保 pending 与索引全部落盘。

## 容错与可重建

- **权威/派生分离**：会话文件权威，`index.json` 派生。索引缺失、版本不符、JSON 损坏 → 一律扫描会话文件重建，不阻塞启动。
- 单个会话文件解析失败 → 记日志跳过该会话，其余正常（替代旧「一坏全丢」）。
- `getRecord` 对损坏/缺失文件返回 `null` 并记日志，调用方（恢复 hook）按现有 `error.ExpectedHistoryRecord` 路径优雅降级。

## 模块划分（保持可隔离、可单测）

- `src/agent_history.zig`：保留 `SessionRecord`/`MessageRecord`/`Row` 与 clone/free/序列化纯函数；新增单会话 `SessionRecord` 的 JSON 读写纯函数；新增 `IndexEntry`/`IndexFile` 及其 JSON 读写、`recordToIndexEntry`、`sanitizeFileName`、`buildSearchPreview` 等纯函数。
- 新文件 `src/agent_history_store.zig`（或同名命名空间）：`MetaStore`（持目录、entries、flush 逻辑、迁移、重建）。文件 IO 与全局状态解耦——所有路径/序列化/迁移逻辑写成接收 `dir`/`allocator` 的纯函数，便于用临时目录单测。
- `src/platform/dirs.zig`：新增 `agentHistoryDir` + `agentHistoryDirFromEnvForOs`（与现有 `*FromEnvForOs` 风格一致，供路径单测）。
- `src/AppWindow.zig`：`ensureGlobalAgentHistoryStore` 改为 `MetaStore.open(dir)`；`cloneRecordBySessionId` 调用点改 `getRecord`；flush 路径改为索引落盘；其余调用点签名保持。

## 测试计划（TDD）

纯逻辑用 `testing.allocator` + `std.testing.tmpDir`，尽量进 `zig build test` 快速套件；涉及 app 绑定的走 `test-full`。

1. 文件名净化/防碰撞：合法 id 原样、非法字符替换、碰撞追加 hash、映射可逆。
2. 单会话 JSON 往返：`SessionRecord` 写入再读出，字段（含 messages）一致。
3. 索引往返与投影：`recordToIndexEntry` 字段映射；`buildRows`/`buildCopilotRows` 排序（updated_at 倒序）与 copilot 过滤。
4. 索引重建：删掉 `index.json`，由 `sessions/*.json` 扫描重建，entries 与原一致。
5. 版本不符 → 重建：`index.json` 写入旧版本号，open 时触发重建。
6. 损坏容错：写入一个坏 `sessions/x.json`，open 仍成功且跳过它；坏 `index.json` 触发重建。
7. 迁移：构造旧 `agent-history.json`（多记录，含 copilot 与非 copilot），open 后 → 生成 `sessions/*` + `index.json`，旧文件变 `.bak`；再次 open 幂等（不重复迁移）。
8. 迁移失败回滚：注入写失败，旧文件保留、无 `.bak`、降级空索引。
9. upsert/delete：upsert 新会话→文件存在 + 索引含之；upsert 同 id→覆盖且 entry 更新；delete→文件与 entry 同时移除。
10. 懒加载：`buildRows` 不读正文（可用「仅索引存在、正文文件被改名」仍能列出、`getRecord` 才失败 来佐证）。
11. 8MB 回归：构造 > 8MB 的总量（多会话），新布局可全量加载（旧路径会失败）。

## 验证

- 按项目惯例，默认 `zig build` 目标是 Windows；macOS 验证用 `zig build test-full` + `zig build macos-app -Dtarget=aarch64-macos`；纯逻辑可先用 `zig build test`。
- 真机冒烟：旧版本产生的 `agent-history.json` 在新版本首启后被迁移为目录布局，副驾历史列表内容不变，旧文件留有 `.bak`；新增/删除/重开会话后目录与索引正确更新。

## 风险与回滚

- **数据安全第一**：迁移只在全部成功后改名旧文件，且只改名不删除；任何异常都保留 `agent-history.json` 原样。
- 回滚：删除 `agent-history/` 目录、把 `agent-history.json.bak` 改回 `agent-history.json`，即恢复旧版可读状态（旧版本读新目录会得到空库，但数据未丢，仍在 `.bak`）。
- 索引与会话文件不一致风险：通过「会话文件权威 + 索引可重建」消解；任何疑似不一致，删 `index.json` 重启即重建。

## 未来工作（不在本轮）

1. **第二阶段 UI spec**：副驾历史面板显示相对时间（复用 [formatRelativeTime](../../../src/copilot_picker.zig#L101)）、按时间分组标题（今天/昨天/过去7天/更早）、启用搜索框（title+model）、Tab 来源筛选（全部/侧栏/标签页）、模型筛选。本轮的 `index.json` + `search_preview` 即为其检索基础。
2. **深度全文检索**：在索引 `search_preview` 之上扩展为完整正文检索（按需扫描会话文件或建倒排）。
