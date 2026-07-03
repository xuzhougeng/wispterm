# Deferred Tool Catalog — 延迟工具目录设计

日期:2026-07-03
状态:已与用户确认设计,待实现
分支基线:main(含 PR #473 的 MCP 面板 + `mcp_config` 工具)

## 问题

Copilot 每轮请求全量注入 ~31 个内置工具 + 所有启用 MCP server 的全部工具 schema
(`protocol.zig buildRequestJson → appendToolSchemas`),且 app 启动时同步 spawn
全部 MCP server 做 tools/list 发现(`main.zig:242 → reloadMcpTools →
mcp_registry.discover`)。三个痛点:

1. **上下文膨胀**:MCP 一多,schema 注入量爆炸,模型选工具变笨。
2. **模型不会用**:skill 列表对模型完全不可见(只能靠用户点名走 `skill_info`);
   MCP 工具虽然可见但淹没在大列表里。
3. **启停时机**:启动即 spawn 全部 server,同步阻塞,常驻浪费。

## 已确认的决策

| 决策点 | 结论 |
|--------|------|
| 评估者 | 模型自助(无前置路由、无小模型调用) |
| 目录来源 | tools/list 结果磁盘缓存,启动不 spawn server |
| 延迟范围 | 仅 MCP 工具 + skill;31 个内置工具保持常驻 |
| 发现面 | system prompt 目录摘要(每 server/skill 一行)+ 整 server 粒度激活 |
| 明确不做 | 关键词搜索、embedding、小模型路由、idle 进程回收、per-tool 激活 |

## 架构

把「配置了哪些 MCP/skill」与「本轮注入哪些 schema」解耦:

```
启动: 读 mcp_catalog.json(0 个 server 进程)→ 构建目录
用户: "帮我搜索 xxx 博客"
模型: 看到目录摘要里的 jina → 调 mcp_activate("jina")
系统: 缓存命中 → 会话级激活 → 返回该 server 工具清单文本
模型: 调 search_jina_blog(...)
系统: server 未运行 → spawn → 执行 → 按现状管理进程
```

## 组件

### 1. 磁盘目录缓存 `<configDir>/mcp_catalog.json`

每个 server 一条:

```json
{
  "jina": {
    "config_hash": "<hash of command+args+env>",
    "tools": [{ "name": "...", "description": "...", "schema": { } }],
    "discovered_at": 1234567890
  }
}
```

- `config_hash`:server 的 command+args+env 哈希;mcp.json 里该 server 配置
  变更 → hash 不匹配 → 该条缓存失效(视为未发现)。
- **写入时机**:
  - MCP 面板「测试连接」probe 成功时顺手写入;
  - `mcp_activate` 现场发现(无缓存时 spawn + tools/list)后写入;
  - 工具调用时 server 报 unknown tool → 重跑 tools/list 更新缓存(见错误处理)。
- **读取时机**:启动时只读此文件建目录。`main.zig` 启动路径不再 spawn 任何
  server(消灭同步发现阻塞)。
- 无缓存的 enabled server 在目录里仍列出,仅有名字,标注"未发现";首次激活时
  现场连接补全。
- `enabled=false` 的 server 语义不变:彻底不进目录。

### 2. 目录摘要(system prompt 注入)

(计划阶段修订:摘要在 session 层拼进 system_prompt——
`composeSystemPromptWithMemory` 之后追加——而非改 `buildRequestJson`;
一处代码同时覆盖三种协议。)

请求构建时追加一小段(仅当存在未激活 server 或 skill 时):

```
Inactive MCP servers (call mcp_activate to use):
- jina: 21 tools — search_jina_blog, primer, ... 
- filesystem: (not yet discovered)
Skills (call skill_info to load):
- pdf-tools: extract and convert PDF files
```

- 每 server 一行:名字 + 工具数 + 前几个工具名(或未发现标注)。
- 每 skill 一行:名字 + description,复用现有
  `loadSkillSuggestionListFromRoots()`(skills.zig:51)。
  这同时解决 skill 对模型不可见的问题。
- 已激活的 server 从"Inactive"段消失(schema 已注入,无需重复)。

### 3. 激活状态(计划阶段修订:进程级全局)

- 激活集是**进程级全局**内存 set(mutex 保护,不持久化,随 app 生灭),
  而非 per-session:工具执行层(agent_tools,受 source guard 约束)拿不到
  Session 指针,且跨会话共享激活是可接受甚至有益的行为。
- 请求构建时只克隆已激活 server 的 specs 注入
  (`mcp_registry.cloneActivatedSpecs`);dispatch 快照保持全量已发现工具,
  这直接实现了"兜底自动执行"(见第 5 节)。
- 激活后立即生效:agent loop 在执行过 mcp_activate 的那轮结束时刷新
  ChatRequest 的 spec/dispatch 快照,同轮后续 API 调用即带上 schema。

### 4. 元工具 `mcp_activate`

新文件 `src/agent_tools/mcp_activate.zig`,模式照抄 `mcp_config.zig`:

- `mcp_activate(server_name)`:
  - 缓存命中 → 标记激活 → 返回该 server 工具清单文本;
  - 无缓存 → 现场 spawn + tools/list + 写缓存 + 激活(即首次发现);
  - 未知名字 → 返回可用 server 名单。
- 注册点(与 mcp_config 完全同构):
  - `agent_tools/mod.zig executeToolCall` 加分派臂;
  - `protocol.zig` `emitTool` 广告 + `builtinToolNameReserved`;
  - `tools/first_party.zig static_definitions`;
  - `test_fast.zig` 引入。
- 权限:激活是只读性质(不改配置、不执行外部命令的副作用仅为 spawn 已配置的
  server),不走 requestApproval;真实工具调用的审批维持现状。

### 5. 弱模型兜底(自动激活)

`agent_tools/mod.zig` 的 MCP 分派处:模型直接调用了**目录里存在但未激活**的
MCP 工具名 → 视为隐式激活并正常执行,不报错。弱模型(glm 等)不遵守
activate 协议也能用,省一轮往返。

### 6. 生命周期

- server 进程只在两个时机启动:① `mcp_activate` 现场发现;② 真实工具调用。
- 调用路径的进程管理保持现状不变(激活只管 schema 注入,不管进程)。
- 不做 idle 回收。`// ponytail: 激活后按现状管理,需要时再加超时回收`。

## 错误处理

| 场景 | 行为 |
|------|------|
| activate 未知 server | 返回目录可用名单文本 |
| 现场发现 spawn 失败 | 返回错误文本(走现有工具错误链路),不激活、不写缓存 |
| 缓存过时(server 工具改名/删除) | (计划阶段修订:不自动重试)MCP 错误文本原样返回给模型;模型可再调 mcp_activate 触发重发现。spawn-per-call 下无进程状态可言,自动重试收益低 |
| mcp_catalog.json 损坏 | 按无缓存处理(全部"未发现"),下次发现时重写 |

## 测试(全部进 test_fast.zig,用 tmp config dir)

1. 目录缓存:读写 round-trip、config_hash 失效、损坏文件降级。
2. 激活过滤:未激活 server 的工具不出现在 buildRequestJson 输出;激活后出现。
3. 目录摘要:含未发现 server、含 skill 行、全部激活时段落消失。
4. 兜底:未激活工具名分派 → 隐式激活 + 执行。
5. `mcp_activate`:命中/未知名字两条路径。

## 涉及文件

| 文件 | 改动 |
|------|------|
| `src/tools/mcp_catalog.zig` | 新增:缓存读写、config_hash、目录构建 |
| `src/tools/mcp_registry.zig` | discover 不再启动即跑;暴露按需发现单个 server |
| `src/agent_tools/mcp_activate.zig` | 新增:元工具 |
| `src/agent_tools/mod.zig` | 分派臂 + 兜底自动激活 |
| `src/assistant/conversation/protocol.zig` | 目录摘要注入 + 激活过滤 + 广告 mcp_activate |
| `src/assistant/conversation/session.zig` | activated_mcp_servers 会话状态;reloadMcpTools 改读缓存 |
| `src/main.zig` | 启动路径去掉同步发现 |
| `src/renderer/overlays.zig` / `overlays/mcp_servers.zig` | probe 成功写目录缓存 |
| `src/tools/first_party.zig`、`src/test_fast.zig` | 注册 + 测试挂载 |

## 迁移

- `mcp.json` 格式不变,用户无感。
- 升级后首次启动无缓存:目录全部"未发现",面板测试连接或首次激活时自动补全。
  不做一次性后台全量发现(YAGNI,首次激活的现场发现足够)。
