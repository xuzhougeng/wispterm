# cli_agent 工具：统一 CLI agent 委派框架

Issue: https://github.com/xuzhougeng/wispterm/issues/533
参考: wisp-science PR #138（codex-as-tool；本设计只取"委派"一半，不做 MCP bridge）

## 目标

让 WispTerm 内部 agent 把一个自包含的编码/分析任务委派给外部 CLI agent
（首个后端 codex），运行期间在聊天卡片显示进度，结束后拿回最终答复。
框架做成统一抽象，后续扩展 Oh-my-pi、reasonix 等后端时只加数据表行 +
一个事件解析函数。

已拍板的取舍：

- 只做 codex 后端（claude 等后续加）
- 沙箱完全放开（`--dangerously-bypass-approvals-and-sandbox`），由 WispTerm
  自己的审批门兜底
- 进度跟踪：流式解析 codex `--json` 事件推进度卡片
- 不做 MCP bridge（codex 反向访问 WispTerm 能力），有真实需求再开 issue

## 工具接口（发给模型的 schema）

- 名称 `cli_agent`，required: `agent`, `task`
- 参数：
  - `agent`: string —— 后端 key，当前仅 `codex`（描述里枚举，后端增加时只改描述）
  - `task`: string —— 完整自包含任务描述（CLI agent 看不到本对话）
  - `cwd`: string, 可选 —— 默认 agent 工作目录
  - `timeout_ms`: integer, 可选 —— 默认 600_000，钳制上限 3_600_000
- 描述要点：委派自包含编码/分析任务；CLI agent 用自己的 shell/文件工具在
  cwd 内自主工作、完全访问权限；返回最终报告；task 必须自带全部上下文。

## 统一抽象（新文件 `src/agent_tools/cli_agent.zig`）

```zig
pub const Event = struct {
    progress: ?[]u8 = null, // 推到进度卡片的一行（owned）
    final: ?[]u8 = null,    // 候选最终答复，后到覆盖先到（owned）
};

pub const Backend = struct {
    key: []const u8,                 // "codex"，agent 参数取值
    display: []const u8,             // "Codex"
    exe: []const u8,                 // PATH 上的可执行名
    base_args: []const []const u8,   // exe 之后、task 之前的固定参数
    parseEvent: *const fn (allocator, line: []const u8) ?Event,
};

pub const backends = [_]Backend{codex_backend};
pub fn find(key: []const u8) ?*const Backend;
pub fn run(ctx: *ToolContext, backend: *const Backend, task: []const u8,
           cwd: ?[]const u8, timeout_ms: u32) ![]u8;
```

`run()` 共享全部生命周期，后端零重复：

1. **审批门**：权限非 `full`（即 confirm 和 auto 模式）强制
   `ctx.requestApproval("cli_agent", task, reason)` —— 完全放开的沙箱必须有
   这道门。拒绝→ denied 结果。
2. **spawn**：argv = `{exe} ++ base_args ++ {task}`（task 位置参数，无 shell
   介入无引号问题）；cwd = 参数或 `ctx.settings.working_dir`；
   `create_no_window = true`；spawn 失败（含 FileNotFound）→ 明确返回
   "codex CLI not found or failed to start: ..."。
3. **stdout 流式**：读取线程按行收集进 mutex 队列（只做 I/O 和分行，不碰
   session）；stderr 复用 `agent_exec.CaptureOutput` 线程。
4. **轮询循环**（worker 线程，25ms tick，照 `runArgv` 现有模式含 waitpid
   注释坑）：drain 行队列 → `backend.parseEvent` → `progress` 经 ToolContext
   新增 `progress` 钩子推卡片，`final` 覆盖候选答复；检查取消与超时，触发
   即 kill 子进程。所有 session 调用留在 worker 线程（markUiDirty
   threadlocal，跨线程刷 UI 是已知坑）。
5. **结果**：`agent=codex exit_code=N [timed_out=true]\n<final>`；无 final
   （JSON 格式不识别/异常退出）回退 stdout 尾部（保尾不保头——答复在末尾），
   exit≠0 时附 stderr 尾部；`tool_output.truncateOwned` 收口。

## codex 后端

```
codex exec --json --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check -- <task>
```

`--json` 一举两得：JSONL 事件流做进度，最后一条 `agent_message` 即干净的
最终答复（免临时文件、免解析人类格式输出）。

`parseEvent`（容错为先，解析失败一律返回 null）：

- `item.completed` + `item_type=command_execution` → progress:
  `"codex: $ <command>"`
- `item.*` + `item_type=agent_message` → final: `<text>`
- 其余事件（thread.started、reasoning 等）忽略
- codex 版本间 JSON 格式有差异：解析不出 final 时靠 run() 的 stdout 尾部
  回退，工具不至于空手而归

## 注册点（新增第一方工具的固定四件套 + 钩子）

| 文件 | 改动 |
|---|---|
| `assistant/conversation/protocol.zig` | `forEachToolSpec` 加 `emitToolWithRequired("cli_agent", ...)`；`builtinToolNameReserved` 加名字 |
| `tools/first_party.zig` | `static_definitions` 加行，category=`.agent` |
| `agent_tools/mod.zig` | 分发：解析 agent/task/cwd/timeout_ms → `cli_agent.run` |
| `assistant/conversation/types.zig` | `ToolContext` 加 `progress: *const fn(...) void = noopProgress` + `emitProgress()` |
| `assistant/conversation/request.zig` | `toolContextFromRequest` wire progress → `ai_chat.appendProgressMessage(session, text) catch {}` |

不暴露给 subagent 工具集（`subagentToolAllowed` 默认 deny，无需改动）——
防递归委派。

## 明确不做

- MCP bridge、claude/其他后端（框架留好扩展点）、PATH 预检测注册
  （分发时报错同样有效）、`--json` 之外的进度来源、stdin 传 task
  （位置参数够用；>30KB task 在 Windows 会失败，接受）。

## 测试

1. `parseEvent` 纯函数：喂 codex JSONL 样本行（command_execution、
   agent_message、不认识的事件、非 JSON 行）断言 progress/final 提取。
2. `run()` 集成：假后端 exe=`/bin/sh` 吐伪造 JSONL（Windows skip，同现有
   MCP dispatch 测试模式），断言最终答复提取、progress 钩子被调（fake
   钩子计数）、非 full 权限走审批、超时/取消 kill。
3. `mod.zig` 分发：缺 agent/缺 task/未知 agent 的错误文案。
4. `protocol.zig`：schema 含 `"cli_agent"`；subagent 工具集不含。

约束：`agent_tools/**` 是叶子模块（source guard 禁 import AppWindow），
cli_agent.zig 只依赖 types.zig / exec.zig / output.zig。

## 验证

`zig build test -Dtarget=aarch64-macos` 跑快测；端到端需要本机重装 codex
（当前 npm shim 指向缺失的 vendor 二进制，`npm i -g @openai/codex`），
然后在 AI 面板让 agent 调 `cli_agent` 委派一个小任务，观察进度卡片与
最终答复。
