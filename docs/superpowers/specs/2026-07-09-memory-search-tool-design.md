# Memory Search Tool 设计（copilot 检索历史 agent 会话）

日期：2026-07-09
关联：`2026-07-07-ai-memory-digest-design.md`（digest 管道与产物格式）

## 1. 目标与场景

用户在远程服务器（如 SSH profile `CPU2`）上用 codex / claude code 做过某个分析，
之后忘了细节。在 copilot 里提问：

> "我在 CPU2 上做过一个 xx 分析，帮我找到对应的 session"

copilot 检索本地 memory digest 产物，回答：哪天、哪台机器、哪个项目、做了什么、
结论/产出是什么，并附上 `session_id` 和 transcript 文件路径（定位信息）。

**交付形态只有"回答 + 定位信息"**：不做自动跳转历史会话、不做远端 resume。

## 2. 方案概述

新增一个首方 copilot tool `memory_search`，查询 digest 已生成的
`$CONFIG_DIR/memory/daily/YYYY-MM-DD.json` 产物。命中则返回结构化定位信息；
未命中且用户提到远程主机时，由 tool description 引导模型改用已有的
`ssh_session_exec` 到目标主机现场 grep transcript（零新增基础设施的实时兜底）。

不做：SQLite/FTS/embedding 索引、专用 UI、自动触发即时 digest 扫描。
digest 的 summary + topics 本身就是为检索准备的压缩层，先用足它。

## 3. Tool 定义

```
memory_search(
  keywords: []string,   // 候选词列表，OR 匹配
  source?: string,      // 可选，子串匹配 source_id（"CPU2" → "ssh:CPU2"）
  days?: uint = 30,     // 只扫最近 N 天的 daily 文件
)
```

### 匹配语义

- 每个 keyword 做**大小写不敏感的子串匹配**，匹配域：
  `summary`、`title`、`topics[]`、`project`。
- keywords 之间是 **OR**：任一命中即入选。
- 排序：命中 keyword 数降序，再按日期降序。返回上限 20 条。
- `source` 过滤：大小写不敏感子串匹配 `DailySession.source_id`。
- `days` 按 daily 文件名（`YYYY-MM-DD.json`）过滤，不读超范围的文件。

### Tool description 中的模型引导（关键，不是代码）

1. **候选词生成**：指示模型先从用户问题中提炼 3–6 个候选筛选词
   （中英文变体、工具名、领域术语、可能出现在摘要里的同义说法），
   一次调用全部传入 `keywords`，靠 OR + 命中数排序召回。
2. **实时兜底**：若无命中且用户提到远程主机，改用 `ssh_session_exec`
   到该主机执行类似
   `grep -rli <词> ~/.claude/projects ~/.codex/sessions | head`
   的命令现场查找，再读取命中文件片段作答。
3. **搜不到就如实说**，并提示可开启 `memory-digest-scan-remote`
   或手动运行 "Run memory digest now"。

### 返回格式

纯文本，每条命中一段：

```
[2026-07-05] ssh:CPU2 · project: rnaseq-pipeline · outcome: completed
summary: 用 DESeq2 做了差异表达分析，输出 ...
topics: DESeq2, RNA-seq, 差异表达
session: claude / a1b2c3d4-... 
transcript: ~/.claude/projects/-root-rnaseq-pipeline/a1b2c3d4-....jsonl
```

无命中时返回明确的 "no match" 文案 + 已扫描的日期范围，便于模型走兜底。

## 4. 数据面配套改动（最小）

`store.DailySession` 增加字段：

```zig
source_file: []const u8 = "",   // transcript 文件路径（远端为远端路径）
```

来源：采集侧 `CollectedSession.source_file` 已有该值（本地/远端 JSONL 路径），
只是 M1–M5 没写进 daily 产物。改动点：

- `src/memory_digest/store.zig`：struct 加字段（带默认值，旧产物解析兼容，
  `ignore_unknown_fields` 双向无痛）。
- `src/memory_digest/run.zig`：构造 `DailySession` 处透传 `s.source_file`。

历史 daily 产物没有该字段 → 显示为空，模型可按
`provider + session_id` 推导常见路径，不做回填。

## 5. 实现结构

| 改动 | 文件 | 说明 |
|------|------|------|
| tool 实现 | `src/agent_tools/memory_search.zig`（新） | 复用 `memory_viewer.zig:loadDigest` 的读法：遍历 `memory/daily/*.json`，`parseFromSliceLeaky(store.Daily)`，过滤+排序+格式化 |
| daily 读取复用 | `src/memory_viewer.zig` 或抽到 `memory_digest/store.zig` | 把"遍历+解析 daily"抽成 store 的公共函数，viewer 与 tool 共用 |
| tool 注册 | `src/tools/first_party.zig` | `static_definitions` 加 `memory_search`，category = `.memory`（自动受 `memory_enabled` 开关约束） |
| tool 分派 | `src/agent_tools/mod.zig` | `executeToolCall` 加分支，参照 `memory_recall` |
| schema/描述 | tool 定义处 | 参数 schema + §3 的模型引导文案 |
| 产物字段 | `store.zig` + `run.zig` | §4 |

权限：只读本地 JSON，无需 approval（同 `memory_recall`）。
兜底走 `ssh_session_exec` 时沿用该 tool 自身的既有审批流程，不新增。

## 6. 数据流

```
用户提问 "我在 CPU2 做过 xx 分析，找到那次 session"
  → copilot 提炼候选词 ["xx", "英文变体", "工具名", ...]
  → memory_search(keywords, source="CPU2")
      命中 → 回答 + 日期/主机/项目/summary/session_id/transcript 路径
      未命中 → ssh_session_exec 到 CPU2 现场 grep ~/.claude ~/.codex
             → 仍未命中 → 如实说明 + 建议开 remote scan / 手动跑 digest
```

## 7. 测试

- `store.zig`：`DailySession.source_file` 序列化/旧格式反序列化各一例。
- `memory_search.zig`：内存/临时目录造 2–3 个 daily 文件，覆盖
  OR 命中排序、source 过滤、days 截断、无命中文案。跑 `zig build test`（fast 套件）。
- 手动 E2E：真机开 copilot 问一次 CPU2 场景（digest 需已有数据）。

## 8. 已知边界（ponytail 上限）

- **source 匹配的是 SSH profile 名**（`source_id = "ssh:<profile>"`），不是真实
  hostname。profile 名 ≠ 机器名时对不上。升级路径：读
  `SavedSshProfile.host` 建 profile→host 映射再匹配。
- **只覆盖 digest 已归纳的会话**（remote scan 需开启、当天需已跑）；
  空窗期靠 `ssh_session_exec` 实时兜底。
- **子串 OR 匹配，无分词/同义词/评分模型**；召回质量靠模型生成候选词弥补。
- copilot 侧边栏自身会话（`agent-history/copilot/`）不在本期检索范围，
  digest 覆盖到它时自然生效。
