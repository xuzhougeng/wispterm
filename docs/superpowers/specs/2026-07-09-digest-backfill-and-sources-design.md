# Digest Backfill 与来源增强设计

日期：2026-07-09
关联：`2026-07-07-ai-memory-digest-design.md`（digest 主 spec）、`2026-07-09-memory-search-tool-design.md`（memory_search）

## 1. 背景与问题

真机调查结论（2026-07-09）：

1. **codex 搜不到的根因**：本地 3 个 codex 会话全部在 LLM 归纳（M2，07-07 上线）
   之前被 M1 raw 路径采集，游标已推进 → summary store 0 条 codex 记录，daily
   条目无 summary/topics，唯一可搜文本是原始首消息 title。匹配逻辑本身无 bug
   （真机数据模拟验证通过）。
2. **远端历史缺席**：`ssh:hk`/`ssh:GZDlab_Co` 采集报 RemoteHomeFailed；
   `ssh:CPU`/`ssh:openwebui`/`ssh:GX5689` 状态 ok 但采 0 条且无法区分
   "真没有"与"静默不兼容"（如 BSD find）。当前 scan-remote=false（默认），
   最近运行只扫 local。五台 TCP 全通，非网络问题。
3. **来源展示不足**：daily JSON / Memory Center / memory_search 结果均看不出
   记忆来自哪些服务器的哪些会话。

## 2. 范围

三个子特性，一个 milestone：

- **A. 归纳回填（backfill）**：修 codex 搜不到的根因，兼救所有历史空洞。
- **B. 采集诊断**：把 `ok(0)` 变成可解释的 per-provider 明细。
- **C. 来源展示**：daily JSON 产物 / Memory Center / memory_search 三处。

不做：远端会话回填（远端采集修好后新会话自然归纳）；embedding/全文索引；
Memory Center 新面板/钻取交互；RemoteHomeFailed 的自动修复（先靠 B 定位）。

## 3. A：归纳回填

### 触发与扫描

`run.zig` 的 map+reduce 路径（`runWithLlm`）在正常增量归纳之后、reduce 之前
增加 backfill 阶段：

1. 枚举磁盘上**所有** `daily/*.json`（不限 backfill-days 窗口——目标空洞在
   06-30~07-06，早于窗口）。
2. 收集其中 `summary == ""` 且 `source_id == "local"` 的会话条目。
3. 每次运行回填上限 **8 个**会话（防止首次回填撑爆 LLM 预算；剩余的下次运行
   继续。ponytail: 固定上限，真不够再做配置键）。

### 原文定位（两级）

1. 条目带 `source_file`（#534 之后写入的）且文件存在 → 直接按 provider
   解析器读取全量消息。
2. `source_file == ""`（历史条目）→ 用 collector 的既有枚举能力全量列出该
   provider 的本地会话（**不按游标过滤**），按 `session_id` 匹配得到路径与
   消息。匹配不到（原文件已删）→ 跳过，不再重试（该条目永远保持无 summary，
   属可接受降级）。

### 归纳与回写

- 复用 `digest.summarizeSession`（old_summary 传 null，全量消息作输入，
  受既有 max-chars/input-budget 约束）。
- 成功 → 写 summary store（既有 key 规则）+ 更新对应 daily 条目的
  summary/topics/outcome/artifacts/source_file（经 mergeDailyWithExisting
  同款原子写）；同时并入当日 reduce 重算（日报/时间线随之更新）。
- LLM 失败 → 沿用既有失败隔离（跳过本条，下次运行重试）。
- 持久化顺序不变式保持：summaries 先落盘，daily 后写，游标不受 backfill
  影响（backfill 不推进游标）。

### 幂等

回填成功后条目 summary 非空，下次扫描自然不再命中；同一会话在 summary store
已有记录则直接用已有 summary 回写 daily（不重复调 LLM——覆盖"上次写 store
成功但写 daily 失败"的窗口）。

## 4. B：采集诊断

### 现状

`RunRecord.sources[]` 只有 `{source_id, status, detail, sessions_collected}`，
`detail` 仅在硬失败时有错误名。

### 改动

远端采集（`remote.zig`）为每个 source 记录 per-provider 明细，写进
`detail` 字段（保持 schema 不变，纯文本，人可读）：

```
"claude: 12 files, 3 new; codex: 0 files; find: ok"
"claude: skipped (no ~/.claude/projects); codex: 0 files; find: no-stamps(BSD?)"
"home: FAILED (exit 255, stderr: Permission denied)"
```

具体来源：

- `$HOME` 探测失败 → detail 记 exec 退出码与 stderr 前 120 字符（当前只有
  错误名 RemoteHomeFailed，定位不了是认证、banner 污染还是 shell 差异）。
- 每 provider：目录是否存在、find 找到的文件数、无 stamps（BSD find）等
  已有 warn 日志升级为 detail 字段内容。
- 本地采集同样补 per-provider 计数（local 的 `detail` 现在也是空）。

runs.json 的既有 schema 不变（只是把 detail 用起来），网页契约无影响。

## 5. C：来源展示

### C1. daily JSON（网页契约 §9 增补）

`Daily` 增加顶层字段：

```zig
pub const DailySource = struct {
    source_id: []const u8,          // "local" | "ssh:CPU" | ...
    providers: []const []const u8,  // ["claude","codex"]
    session_count: u32,
};
// Daily 增加：sources: []const DailySource = &.{},
```

写 daily 时从 `sessions[]` 聚合生成（纯派生数据，旧文件缺字段解析为默认空，
网页向后兼容）。

### C2. Memory Center

digest 行的 detail 文本追加来源分布，如：

```
6 sessions · local×4 · ssh:CPU×2
```

数据从 daily 的 `sessions[]` 聚合（C1 的同一逻辑），只改 `memory_viewer.zig`
的行构建文案，无新面板。

### C3. memory_search 结果

结果头部加一行扫描覆盖说明：

```
Scanned 9 daily files, sources: local (23 sessions), ssh:CPU (2 sessions).
```

无命中时同样输出该行——让"没搜到"能自解释（某台服务器根本没进库 vs 进了库
但没命中）。

## 6. 测试

- A：backfill 单元测试（临时目录造 daily + 假会话文件：有 source_file /
  无 source_file 需枚举匹配 / 原文件已删跳过 / summary store 已有记录不重调
  LLM——LLM 用打桩 completer）。
- B：remote.zig 既有打桩测试扩展断言 detail 内容；本地计数一例。
- C1：store 测试断言 sources 聚合与旧文件兼容。
- C2/C3：viewer 行文案一例；memory_search 头部行断言（改既有 3 测试）。
- 全部进 fast 套件（`zig build test`），收尾跑
  `test-full -Dtarget=aarch64-macos`。

## 7. 已知边界（ponytail 上限）

- 回填每轮上限 8 个、只回填 local——远端修好前远端无历史条目，真出现再放开。
- 原文件已删的空洞永久保留（不造假 summary）。
- detail 是人读文本非结构化字段——网页要机器解析时再升级 schema。
- RemoteHomeFailed 的根因定位依赖 B 上线后的下一次真机运行。
