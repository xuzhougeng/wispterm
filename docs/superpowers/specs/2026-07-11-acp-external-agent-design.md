# ACP 外部 agent 会话设计

日期:2026-07-11
状态:已确认(定位、后端、MVP 范围经用户拍板)

## 背景与目标

现有 `cli_agent` 工具(spec: 2026-07-10-cli-agent-tool-design.md)把 codex 当作
copilot 的一个"一次性委派"工具:spawn `codex exec --json`、解析私有 JSONL、
开头批一次权限、中途不可交互。这个形态不够好:交互是单向的、权限被迫
`--dangerously-bypass`、每接一家 agent 要写一份私有输出解析。

本设计改走 **ACP(Agent Client Protocol,双向 JSON-RPC 2.0 over stdio)**:
WispTerm 作为 ACP client,外部 agent(Claude Code、Codex 等)驱动整个会话。
`cli_agent` 工具及其注册代码随之删除。

**目标(MVP,一次交付)**

1. copilot 侧栏新增"外部 agent 会话":profile 选 ACP 类型后,该会话由外部
   agent 进程驱动——消息流、思考流、工具卡片、中途权限审批、取消,全部进
   现有聊天 UI。
2. client 声明 `terminal` 能力:agent 跑命令通过 `terminal/*` 落在真实的
   WispTerm pane(复用 agent 终端租约),用户实时旁观。
3. 首批验收后端:**claude-code-acp**(Zed 维护的 Claude Code 适配器)与
   **codex-acp**(Codex 适配器)。
4. 删除 `cli_agent` 工具全部代码与注册点。

**非目标**

- `fs/read_text_file` / `fs/write_text_file` client 能力:那是编辑器"未保存
  buffer"场景,终端没有;能力永久声明 false。agent 用自带文件工具。
- `session/load` 会话恢复、slash commands、agent mode 切换、图片内容块:
  Phase 2 按需再做。
- HTTP 传输、ACP server 角色(WispTerm 只做 client)。
- 用自研 loop 的工具集去"增强"外部 agent——外部 agent 自带工具,两边不混。

## 架构

```
用户输入 ──> session.zig(ACP profile 分支)
               │ spawn acpTurnThreadMain(每轮 turn 一个工作线程,替代 requestThreadMain)
               v
         acp/client.zig  <──stdio JSON-RPC──>  agent 子进程(claude-code-acp / codex-acp)
               │ 回调(vtable)
               v
   session 渲染:消息流/思考流/工具卡片/审批 UI/终端 pane
```

### 新模块(std-only,可 `zig test` 单测,仿 mcp_client.zig 风格)

**`src/acp/schema.zig`** — 协议类型与解析。

- `SessionUpdate` 变体:`agent_message_chunk`、`agent_thought_chunk`、
  `tool_call`、`tool_call_update`、`plan`。
- `ContentBlock`:MVP 只解析 `text`,其余变体忽略。
- `session/request_permission` 的 option 结构
  (`optionId` / `name` / `kind: allow_once|allow_always|reject_once|reject_always`)。
- 解析容错:未知 update 变体、未知字段直接忽略(协议仍在演进,沿用
  codexParseEvent 的宽容策略);解析失败的帧记日志跳过,不断会话。

**`src/acp/client.zig`** — 双向 JSON-RPC 连接。

- spawn 子进程(命令来自 profile),stdin 写出,stdout reader 线程按行分帧
  (沿用 cli_agent 的 LineStream 模式;cli_agent 删除前把该模式搬过来)。
- 出站请求:`id -> pending` 表 + condvar,调用方(turn 线程)阻塞等响应。
- 入站三类:
  - response → 唤醒对应 pending;
  - request(`session/request_permission`、`terminal/*`)→ 回调,返回值序列
    化写回响应;
  - notification(`session/update`)→ 回调。
- 回调是小 vtable,由会话驱动层实现。reader 线程只做 IO+分帧+分派,
  **不碰 UI**;所有 UI 更新经 postWakeup(markUiDirty 是 threadlocal,老坑)。
- MVP 方法面(出站):`initialize`、`session/new`、`session/prompt`、
  `session/cancel`(notification)。
- `initialize` 声明 clientCapabilities:`terminal: true`,`fs.*: false`。
  协议版本不匹配 → 明确报错进聊天卡片。

### 会话驱动(session.zig 适配)

- 现状:`sendChat` spawn `requestThreadMain`(HTTP LLM,session.zig:2833)。
  新增:profile 为 ACP 类型时 spawn `acpTurnThreadMain`。
- **进程生命周期**:每个 chat 会话懒启动一个 agent 子进程 + 一个 ACP
  session(首条消息时 `initialize` + `session/new`,cwd = 绑定终端的工作
  目录,与现有 copilot 语义一致)。会话/窗口关闭 → `session/cancel` + kill
  子进程,挂在 AppWindow.deinit(吸取 tmux shutdownAll 曾无调用点的教训)。
- **消息映射**:
  - `agent_message_chunk` → 现有流式 assistant 渲染;
  - `agent_thought_chunk` → 现有思考/reasoning 展示;
  - `tool_call` / `tool_call_update` → 现有工具卡片(标题、kind、状态
    pending→in_progress→completed/failed、content 文本;`diff` 内容 MVP 先
    以文本渲染);
  - `plan` → 一条进度注记(persist_to_history=false)。
- **权限**:`session/request_permission` options 原样透传到现有
  `ToolContext.ask` 多选 UI,用户选择的 `optionId` 写回响应;会话被停止时
  回 `cancelled` outcome。stop 按钮 → `session/cancel`,随后该轮 prompt 以
  `stopReason: cancelled` 收尾。
- **历史**:外部 agent 会话的转写(用户消息、agent 消息、工具卡片)进现有
  会话持久化;上下文由 agent 自持,WispTerm 不回放历史给 agent(重启进程
  即新会话,UI 提示"上下文已重置")。

### terminal 能力(MVP 内)

复用 `ToolHost` 与 agent 终端租约(PR #543):

- `terminal/create`(command/args/cwd/env)→ `ToolHost.spawnTab` 起真实
  pane 执行命令,租约归该 agent 实例;`terminalId` = surface_id。
- `terminal/output` → 该 surface 的屏幕+回滚捕获(`surfaceSnapshot` 路径),
  按 `outputByteLimit` 截断,进程已退出时附 exitStatus。
- `terminal/wait_for_exit` → 阻塞等 surface 子进程退出(termio 已有退出
  跟踪),返回 exit code/signal。
- `terminal/kill` → 终止 surface 子进程,pane 保留(用户可看最后输出)。
- `terminal/release` → 解除租约;pane 是否关闭沿用现有 agent 终端策略
  (保留给用户,agent 不再持有)。
- agent 在 `tool_call` content 里嵌 `{type:"terminal",terminalId}` 时,工具
  卡片显示"在终端中运行"并可点击聚焦该 pane;MVP 不做卡片内嵌终端画面。

### Profile / 入口

- `AiProfile` 增加 provider 类型字段(`api` | `acp`)+ 一个自由命令字段
  (argv 整串,按空白切分;不经 shell)。
- 预置两个模板:**Claude Code**(`npx @zed-industries/claude-code-acp`)、
  **Codex**(codex-acp 适配器,默认命令联调时定死)。命令可编辑——ACP
  适配器生态还在变,不确定性由该字段吸收。
- ACP profile 不需要 API key/model 字段;表单按类型显隐。

### 删除 cli_agent(同一 MVP 内,放在外部 agent 会话验收通过之后)

删除点(以 `grep -rn cli_agent src/` 为准):

- `src/agent_tools/cli_agent.zig` 整文件(LineStream 模式先迁入 acp/client.zig);
- `src/agent_tools/mod.zig`:import、`executeToolCall` 分发分支、相关测试;
- `src/assistant/conversation/protocol.zig`:保留名列表、`emitToolWithRequired`
  注册、相关测试;
- `src/tools/first_party.zig`:目录项;
- `src/test_fast.zig`:import 行。

### 错误处理

- spawn 失败 / initialize 失败或版本不匹配 → 聊天卡片一条明确错误(措辞
  参照 cli_agent 的 "not found or failed to start",含命令与 cwd)。
- agent 进程中途崩溃 → 当轮以错误收尾;下一条用户消息自动重启进程、新开
  ACP session,并提示上下文已重置。
- 协议帧解析失败 → 记日志跳过;JSON-RPC 层面错误响应 → 映射为该请求的
  Zig error 返回给调用方。
- 终端能力各方法对无效 terminalId、越权 surface 返回 JSON-RPC 错误响应。

### 测试

- `acp/schema.zig`、`acp/client.zig`:std-only 单测。fake agent 用
  `/bin/sh` 回放/应答 JSON-RPC 帧(cli_agent 已验证此法),覆盖:双向请求
  路由、权限往返、session/update 分发、进程崩溃、协议版本不匹配。
- 会话驱动与 terminal 能力:进 test-full 的 session 测试(macOS 上须
  `test-full -Dtarget=aarch64-macos` 才真跑)。
- E2E 验收:真机 claude-code-acp 与 codex-acp 各过一轮完整对话,含中途
  权限审批 + agent 经 terminal/create 在真实 pane 跑命令 + 取消。
- 推送前 `zig fmt`(CI fmt gate)。

### PR 切分(体量预估 ~1300 行新增 + 删除)

1. **acp 核心**:schema.zig + client.zig + 单测(纯协议,不接 UI)。
2. **会话接线**:profile 类型 + acpTurnThreadMain + 消息/权限映射。
3. **terminal 能力 + cli_agent 删除**:terminal/* 实现 + 全部删除点 + E2E 验收。
