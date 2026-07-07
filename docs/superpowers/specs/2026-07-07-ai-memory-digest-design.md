# AI 记忆归纳（Memory Digest）设计

日期：2026-07-07
状态：已确认设计，待实施
定位：先在维护者本机环境验证价值，架构上按产品功能设计（跨平台、可配置），不做一次性脚本。

## 1. 背景与目标

用户在多个 AI 编程工具里积累了大量聊天记录：WispTerm 内置 copilot、Claude Code、Codex（以及 Reasonix），分布在本机与多个远程环境（WSL、SSH 主机）。这些记录是"我在每个项目上做过什么、为什么这么做"的第一手资料，但目前只能靠人工翻。

本功能每日一次扫描所有来源的**新增**聊天记录，用 LLM 归纳成结构化 JSON：

1. **日报**：今天在所有项目上做了什么（会话级摘要 + 当日要点）。
2. **项目时间线**：按项目聚合的追加式进展记录（progress / decision / problem / todo），支撑"某个项目按时间跟踪进展"。

产物供后续独立开发的网页可视化直接读取（网页本身不在本设计范围内，本设计只固定数据契约）。

## 2. 非目标

- 不做网页/UI 展示（本期只落数据；后续网页单独立项）。
- 不做全文检索、向量化、RAG。
- 不把摘要回灌给 AI 会话当上下文（未来可基于同一产物做，不在本期）。
- 不做历史全量回填（默认只回填最近 N 天，可配置）。

## 3. 数据源

| Provider | 位置 | 格式 | 环境 | 项目归属 |
|----------|------|------|------|----------|
| Claude Code | `~/.claude/projects/<cwd-slug>/<uuid>.jsonl` | JSONL，每行带 `type`(user/assistant/system/...)、`cwd`、`gitBranch`、`timestamp`；另有 `custom-title`、`pr-link`、`summary` 元数据行 | local + WSL + SSH | 消息级 `cwd` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | JSONL，`session_meta.payload.cwd`、`turn_context` 每轮带 `cwd`、`response_item` 含 role/content | local + WSL + SSH | `session_meta.cwd` |
| Reasonix | `~/.reasonix/` | 现有 `provider_reasonix.zig` 已解析 | local + WSL + SSH | 同现有实现 |
| WispTerm copilot | `<数据目录>/agent-history/sessions/session-*.json` + `index.json` | JSON，SessionRecord{title, model, created_at/updated_at(epoch ms), messages[{role, content, tool_name, ...}]} | 仅 local | **现状无 cwd**，见 §10 |

规模参考（维护者本机）：Claude Code 645 会话 / 444MB，Codex 88 会话 / 174MB，21 个项目目录。**结论：必须增量处理，历史存量默认不动。**

## 4. 架构总览

复用现有 `src/terminal_agents/sessions/` 采集层（与"AI 会话历史"浏览器同一套），新增 `src/memory_digest/` 引擎（不叫 `memory`——`src/agent/memory.zig` 已被 agent 的"记住用户事实"工具占用）：

```
┌─ 复用（terminal_agents/sessions/）──────────────────────┐
│ source.zig    Source{Target{local,wsl,ssh}, ProviderFlags} │
│ session.zig   ScannerHost（local / wslExec / sshExecCapture）│
│ provider_*.zig parseMetadata + parseTranscript             │
│ cache.zig     FileStamp{size, mtime_ns} 模式               │
└──────────────────────────────────────────────────────────┘
                          │
┌─ 新增（src/memory_digest/）────▼────────────────────────────────┐
│ collector.zig   枚举 源×provider，按游标找新增/变更会话     │
│ provider_wispterm.zig  解析 agent-history（新 provider）    │
│ redact.zig      脱敏                                       │
│ digest.zig      LLM 归纳（map: 会话摘要；reduce: 日报+时间线）│
│ store.zig       memory/ JSON 产物读写（原子写）             │
│ scheduler.zig   每日一次触发（update_check 模式）           │
└──────────────────────────────────────────────────────────┘
```

关键复用点：

- 传输抽象：`src/terminal_agents/sessions/session.zig` 的 `ScannerHost`（LocalScannerHost / WslScannerHost→`wslExec` / SshScannerHost→`sshExecCapture`）。
- 解析：`provider_claude.zig` / `provider_codex.zig` / `provider_reasonix.zig` 的 `parseTranscript`。
- LLM 调用：`src/assistant/conversation/session.zig` 的 ChatRequest 管道 + `ai_profiles`（三协议均可）。
- 原子写：`src/platform/atomic_file.zig`。
- 数据目录：`src/platform/dirs.zig` 新增 `memoryDir()`。

注意事项（来自代码库既有约束）：session.zig 顶层 `g_*` 全局有守卫上限，新状态必须并入 struct；后台线程完成后必须 `postWakeup()` 刷 UI（`markUiDirty` 是 threadlocal）。

## 5. 归一化会话模型（引擎内部）

所有 provider 解析结果统一为：

```
NormalizedSession {
    source_id:    []const u8,   // "local" | "wsl:<distro>" | "ssh:<profile_name>"
    provider:     enum { wispterm, claude, codex, reasonix },
    session_id:   []const u8,
    title:        ?[]const u8,
    project_path: ?[]const u8,  // cwd；null → 归入 "unassigned"
    git_branch:   ?[]const u8,
    started_at:   i64,          // epoch ms
    ended_at:     i64,
    messages:     []NormalizedMessage,  // 只含自游标以来的新消息
}
NormalizedMessage { role, text, ts: ?i64, tool_name: ?[]const u8 }
```

过滤规则：

- subagent 会话默认排除（复用 `types.isSubagentSession` 启发式），避免噪音。
- 纯工具输出/系统行不进摘要输入，但工具名保留（"用了什么工具"是有效信号）。

## 6. 采集与增量游标

`memory/state/cursors.json`：

```json
{
  "schema_version": 1,
  "cursors": [
    {
      "source_id": "ssh:hk",
      "provider": "claude",
      "file": "/root/.claude/projects/x/uuid.jsonl",
      "size": 12345,
      "mtime_ns": 1780000000000,
      "processed_messages": 42
    }
  ]
}
```

- 判定"有新内容"：`FileStamp(size+mtime_ns)` 不匹配（复用 `cache.stampMatches` 语义）。
- 增量单位统一为**已处理消息数**（`processed_messages`）：文件变更时整文件重解析，只取下标 ≥ processed_messages 的新消息。解析是本地 CPU 操作、成本可忽略（贵的是 LLM）；字节级尾读（processed_bytes）留作 M3 对远程大文件的优化。若重解析后总消息数 < processed_messages（文件被改写/截断），视为重写，从 0 重处理。
- **游标只在该会话归纳成功后推进**；失败不推进，下次重跑。
- 每个源独立超时（SSH 默认 15s/命令）；源不可达 → 跳过并记入 runs.json，不阻塞其他源。
- 回填上限：首次启用或长期未跑时，只处理 `updated_at >= today - backfill_days`（默认 7 天）的会话，更早的显式标记为 skipped 并 `log` 到 runs.json（不做静默截断）。
- 远程扫描沿用 session history 的枚举方式：源列表 = local（+ Windows 下 WSL 发行版）+ `ssh_hosts` 全部 profile。

## 7. 脱敏（进 LLM 前，管道内强制）

1. 结构层：WispTerm SessionRecord 的 `api_key`、`base_url` 字段在解析时直接丢弃，不进归一化模型。
2. 文本层：对消息文本做模式掩码（替换为 `[REDACTED]`）：
   - `sk-...`、`ghp_...`、`xoxb-...` 等常见 key 前缀；
   - `Bearer <token>`、`Authorization: ...`；
   - `password=`/`passwd:`/`token:` 后的非空白串；
   - 64+ 位十六进制长串、40+ 位大小写数字混合的 base64 形态长串（40 位纯十六进制的 git SHA 刻意放行——它是 artifacts 引用的有效信号，掩掉会破坏摘要质量）。
3. Prompt 层：归纳 prompt 明确要求"不得在摘要中复述任何密钥、密码、token"。

脱敏是 `redact.zig` 单独模块，带表驱动测试（每类模式至少一正一负样例）。

## 8. LLM 归纳

复用 ChatRequest 管道，profile 可配置（默认用当前默认 ai profile）。两级 map-reduce：

### map — 会话摘要（每个有新内容的会话一次调用）

输入：旧会话摘要（若有）+ 新增消息（脱敏后）。
输出（JSON，schema 见 §9 sessions[]）：一段摘要 + topics + outcome + artifacts（提到的 PR/commit/文件）。

每个会话的最新摘要持久化在 `state/session_summaries.json`（key = `provider:session_id`），作为下次增量 map 的"旧摘要"输入；daily 文件里的 sessions[] 是当天快照，不承担这个职责。

Token 控制：

- 每条消息截断至 max_chars（默认 2000，保头 2/3 尾 1/3）；
- 单次输入预算（默认 ~24k chars）超限则会话内分块：逐块"摘要+携带前块摘要"滚动压缩；
- 增量语义：prompt 要求"在旧摘要基础上合并新进展"，避免每天重写全史。

### reduce — 日报 + 项目时间线（当天各一次调用）

输入：当天全部会话摘要（不再碰原始消息）。
输出：

1. `daily/YYYY-MM-DD.json` 的 projects[] 与 highlights[]；
2. 每个活跃项目一条 timeline entry（events 按 progress/decision/problem/todo 分类）。

会话数极多时（>50）reduce 先按项目分桶各自 reduce，再合并 highlights（第二层小调用）。

输出格式保证：所有 LLM 输出要求纯 JSON；解析失败重试一次（重试时附上解析错误），再失败则该会话/该天标记 failed 进 runs.json，不写半成品产物。

## 9. 产物 JSON 树（网页可视化的数据契约）

根目录：`<数据目录>/memory/`（`dirs.zig: memoryDir()`）。所有文件原子写、UTF-8、带 `schema_version`（当前 1）。

```
memory/
├── index.json
├── daily/
│   └── 2026-07-07.json
├── projects/
│   └── <slug>/
│       ├── project.json
│       └── timeline.json
└── state/
    ├── cursors.json
    └── runs.json        # state/ 不属于对外契约，网页不读
```

### index.json

```json
{
  "schema_version": 1,
  "generated_at": 1783500000000,
  "days": ["2026-07-07", "2026-07-06"],
  "projects": [
    { "slug": "phantty", "name": "phantty", "last_active": "2026-07-07", "session_count": 42 }
  ]
}
```

### daily/YYYY-MM-DD.json

```json
{
  "schema_version": 1,
  "date": "2026-07-07",
  "generated_at": 1783500000000,
  "model": "deepseek-v4-pro",
  "sessions": [
    {
      "provider": "claude",
      "source_id": "local",
      "session_id": "uuid",
      "project": "phantty",
      "title": "记忆功能设计",
      "summary": "……",
      "topics": ["memory", "design"],
      "outcome": "completed | in_progress | abandoned | unknown",
      "artifacts": [{ "type": "pr|commit|file|url", "ref": "…" }],
      "message_count_new": 37
    }
  ],
  "projects": [
    { "slug": "phantty", "summary": "……", "session_refs": ["uuid"] }
  ],
  "highlights": ["……"]
}
```

### projects/<slug>/project.json

```json
{
  "schema_version": 1,
  "slug": "phantty",
  "name": "phantty",
  "paths": ["/Users/xuzhougeng/Documents/Code/phantty"],
  "aliases": ["ssh:hk:/root/phantty"],
  "first_seen": "2026-07-01",
  "last_active": "2026-07-07"
}
```

### projects/<slug>/timeline.json

```json
{
  "schema_version": 1,
  "slug": "phantty",
  "entries": [
    {
      "date": "2026-07-07",
      "summary": "……",
      "events": [
        { "type": "progress|decision|problem|todo", "text": "……", "refs": ["session:uuid", "pr:511"] }
      ],
      "session_refs": ["uuid"]
    }
  ]
}
```

幂等规则：重跑某天 → `daily/<date>.json` 整文件覆盖；`timeline.json` 中该 date 的 entry 替换（按 date 去重）；`index.json` 重新生成。

## 10. 项目归属

- slug 生成：取 `project_path` 末段目录名，小写、非法字符转 `-`；冲突（不同路径同名）时加短哈希后缀。
- 同项目多环境：远程路径作为 alias 记入 `project.json.aliases`（如 `ssh:hk:/root/phantty`）。首版按"末段目录名相同即同项目"合并；错并可后续在 project.json 手工拆（网页侧编辑不在本期）。
- worktree：路径含 `.claude/worktrees` 或与已知项目 path 前缀匹配 → 归并到主项目。
- `project_path == null`（WispTerm 存量记录等）→ 固定 slug `unassigned`。

### WispTerm 写入端补洞（本设计包含的小改动）

`src/agent/history.zig` 的记录结构增加两个可选字段（JSON 解析用默认值兼容旧文件，无需迁移）：

- `SessionRecord.cwd: ?[]const u8` — 会话创建/绑定终端时的工作目录（copilot 绑定 Surface 时取该终端 cwd；独立聊天取 `defaultWorkingDir()`）；
- `MessageRecord.ts: ?i64` — 消息写入时刻（epoch ms）。

旧记录两字段缺失：cwd → `unassigned`；ts → 用会话 `updated_at` 近似，整会话按其 `updated_at` 归日。

## 11. 调度

照 `update_check.zig` 模式，不引入 cron 依赖：

- 事件循环低频检查（复用现有 tick）：`runs.json.last_run_date != today` 且 `now >= 当日 run_after 时点`（默认 04:00 本地时间）且距 app 启动 ≥ 5 分钟（避免抢启动资源）→ 触发。
- 触发后起一个后台线程跑完整管道（采集→归纳→写产物），线程内不碰 UI 状态，完成后 `postWakeup()`。
- 同一天只成功运行一次；手动触发入口（命令面板 "Run memory digest now"）复用同一管道，允许覆盖当天产物。
- app 当天从未启动 → 次日启动后按回填逻辑补跑昨天（消息按时间戳归日，跨天会话切齐到各自日期）。

## 12. 配置项（config 文件）

键统一用 `memory-digest-` 前缀（`memory-` 会与既有 agent 记忆工具的 `ai-memory-enabled` 混淆）：

| 键 | 默认 | 说明 |
|----|------|------|
| `memory-digest-enabled` | `false` | 总开关（首版默认关，稳定后再默认开） |
| `memory-digest-profile` | 空（用第一个 ai profile） | 归纳用的 AI profile 名 |
| `memory-digest-run-after` | `04:00` | 每日运行时点下限 |
| `memory-digest-scan-remote` | `true` | 是否扫描 WSL/SSH 源（M3） |
| `memory-digest-backfill-days` | `7` | 首次/断档回填上限 |
| `memory-digest-max-chars` | `2000` | 单条消息截断 |

## 13. 错误处理与幂等

- 单会话归纳失败：跳过、记 runs.json、游标不推进，不影响其他会话。
- 单源不可达（SSH 掉线等）：整源跳过、记录，次日自动重试。
- reduce 失败：当天 daily/timeline 不写，map 阶段的会话摘要结果缓存在 `state/`（作为下次 map 的旧摘要输入），次日重试 reduce。
- 所有产物写入走原子写；任何时刻崩溃不会留下半个 JSON。
- runs.json 记录每次运行：date、started/finished、per-source 状态、失败清单、LLM 调用次数与 token 估算（成本可见）。

## 14. 测试策略

- 解析/归一化：每个 provider 一组 fixture 文件（含真实格式样例脱敏版），验证增量游标（processed_bytes / message_count）语义。
- 脱敏：表驱动正负样例。
- store：幂等覆盖、timeline 按 date 替换、原子写。
- digest：LLM 调用打桩（注入固定 JSON 响应），验证 map/reduce 编排、分块、失败路径；不做真实网络测试。
- 调度：时间注入测试（模拟跨天、当天已跑、run_after 未到）。
- 测试归属：跑在 `zig build test`（fast）能覆盖的纯逻辑模块尽量放 fast；涉及 app 状态的进 test-full。macOS 验证用 `test-full -Dtarget=aarch64-macos`。

## 15. 分期实施

| 期 | 内容 | 出口标准 |
|----|------|----------|
| M1 | `src/memory_digest/` 骨架：collector（仅 local）+ provider_wispterm + 归一化 + cursors + store（daily 仅落"原始会话清单"无 LLM） | 本机跑通，daily JSON 里能看到三源当天会话列表 |
| M2a | 脱敏 + LLM map/reduce 管道（CLI 手动触发真实 LLM） | CLI 一次运行产出带摘要的日报与项目时间线 |
| M2b | 配置项 + app 内每日调度（update_check 模式） | 每日自动产出真实日报与项目时间线 |
| M3 | 远程源（WSL/SSH via ScannerHost）+ 回填/补跑 + runs.json 成本报表 | 多环境增量稳定运行一周 |
| M4 | WispTerm 写入端补 cwd/ts；命令面板手动触发入口 | 新会话项目归属正确 |

网页可视化在 M2 产物稳定后即可并行启动（契约=本文件 §9）。
