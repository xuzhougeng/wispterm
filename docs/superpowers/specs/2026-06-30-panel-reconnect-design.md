# 面板进程退出后原地重连 (Panel Reconnect / Re-run on Exit)

- 日期: 2026-06-30
- 状态: 设计已批准，待出实现计划

## 背景与目标

当面板里的进程退出（SSH 连接断开、用户误输 `exit`、远端 kill 等），面板会停在
`[WispTerm] Process exited with code X.` 状态并保持打开，但**目前无法在同一个面板里重新运行**，
用户只能关掉面板再手动新开一个、重新敲一遍 `ssh ...`。

目标：在退出的面板里**按 Enter 即可原地重跑该面板最初启动的命令**（ssh / 本地 shell / 任意命令通用）。

## 行为规格（用户视角）

1. 进程退出后，退出提示行变为：
   `[WispTerm] Process exited with code 0. Press Enter to reconnect.`
2. 该面板获得焦点时按 **Enter** → 在**同一个面板**里重跑最初的命令：
   - 保留滚动历史（不清屏），先打印一行 `[WispTerm] Reconnecting…` 作分隔，新进程输出接在后面。
   - 用**当前**面板尺寸（面板可能在退出后被 resize 过）。
   - 工作目录用最初启动时的 cwd。
3. 退出状态下，Enter 以外的按键维持现状（不写入死 pty）；关闭面板仍走已有的 close-pane 快捷键。
4. 重连失败（如 ssh 连不上）→ 新进程再次退出 → 回到退出提示 → 再按 Enter 重试。纯用户驱动，**无自动循环**。

## 实现路线

**原地重启（复用同一个 Surface）**，而非销毁重建。理由：贴合"同一个面板"语义、保留滚动历史、
不需要对 split-tree / 焦点做手术。代价是 respawn 时要把进程相关字段逐个复位，通过抽取共享 helper 收敛风险。

## 架构与实现

涉及的核心结构（参考勘探，定位以函数/结构名为准，具体行号在计划阶段于本 worktree 重新定位）：

- `src/Surface.zig` — `Surface`：每个面板的核心，持有 `pty`、`command`（子进程）、`terminal`（含滚动历史）、
  退出状态（`io_state: IoState` union，`exited` 原子标志，`ExitInfo`）。构造入口 `Surface.init()`。
  退出由 `markExited()` 置位，退出提示由打印 io 状态的函数（勘探中的 `paintIoStatus()`）输出。
- `src/termio/ReadThread.zig` — PTY 读线程；读到 EOF（0 字节）后线程函数返回，并触发 `markExited`。
- `src/input.zig` — 按键分发；key→PTY 字节在此处理。
- `src/keybind.zig` / `src/input/command_dispatch.zig` — 动作/快捷键注册（**本期不新增动作**，见 YAGNI）。

### ① Surface 存启动参数

在 `Surface` 上新增两个 Surface 自有的字段：

- `respawn_command`: 启动命令（POSIX 上是 `:0`-terminated 的 command line；存时 **dup 一份**，因为原 slice 由调用方持有/释放）。
- `respawn_cwd: ?[]const u8`: 工作目录副本（同样 dup）。

填充时机：`Surface.init()` 成功起进程后，dup 入参的 command/cwd 存上。
释放时机：`Surface.deinit()` 里 free。

**不存** env（在 fork 出的子进程 `childExec` 里统一设置，重跑走同一条 exec 路径）、**不存** grid 尺寸（重连用当前尺寸）。

### ② 抽取 `startProcess()` helper

把 `Surface.init()` 尾部"开 pty → `command.start()` 起进程 → 起 PTY 读线程"这一段抽成
`Surface.startProcess()`，供 `init()` 与 `respawn()` 共用，避免两处复制起进程逻辑导致漂移。

### ③ `Surface.respawn()`

前置条件：仅当 `io_state == .exited` 时可调用（此时旧读线程已随 EOF 返回，无并发竞态；从主线程的按键路径调用）。步骤：

1. 确保旧读线程已结束并 join/清理其 handle（EOF 后线程函数已返回；避免 thread handle 泄漏）。
2. 关闭旧 pty master，复位 `command`（旧 pid 已在退出时 reap）。
3. 复位退出状态：`io_state` → 运行态、`exited` 原子标志 → false、清 `ExitInfo`。
4. 向 `terminal` 打印一行 `[WispTerm] Reconnecting…`（保留既有滚动历史，不清屏）。
5. 调 `startProcess()`，用 `respawn_command` + `respawn_cwd` + **当前** grid 尺寸重开 pty、起进程、起新读线程。
6. 失败处理：`startProcess()` 失败时按现有 init 失败路径处理（标记退出/打印错误），用户可再次按 Enter 重试。

### ④ 退出提示追加

修改打印退出状态的函数（`paintIoStatus()` 一类），在
`[WispTerm] Process exited with code X.` 后追加 ` Press Enter to reconnect.`

### ⑤ input.zig 拦 Enter

在按键→PTY 路径里，写 PTY 之前判断：若当前焦点 surface 处于 `.exited`：
- 是 **Enter** → 调 `surface.respawn()`，吞掉该键（不写 pty）。
- 其它键 → 维持现状。

## 明确不做（YAGNI）

- 不做 `reconnect-on-exit` 自动重连配置。
- 不新增快捷键入口（仅退出面板按 Enter）。以后若要加全局快捷键：在 `keybind.zig` 加 action、
  `command_dispatch.zig` 加分发、路由到同一个 `respawn()`，约几行。
- 不清屏、不加重试计数器、不重抓 env、不保留/重放 SSH 认证（SSH 会按正常流程重新认证）。

## 涉及文件

- `src/Surface.zig`：新增 `respawn_command`/`respawn_cwd` 字段；`init()` 填充、`deinit()` 释放；
  抽取 `startProcess()`；新增 `respawn()`；退出提示追加文案。
- `src/input.zig`：退出态下拦截 Enter → `respawn()`。
- `src/termio/ReadThread.zig`：确认读线程在 EOF 后的清理/可被重启（respawn 起新线程与 init 同路）。

## 测试

退出→重连这条逻辑非平凡（PTY + 线程），留**一个可跑的检查**即可：

在 app 测试二进制里加一个 Zig test（`zig build test-full -Dtarget=aarch64-macos` 运行）：
用一个会立即退出的命令（如 `true` / 短命令）`init` 一个 headless Surface，等其进入 `.exited`，
断言 `respawn_command` 已存；调 `respawn()`，断言 `io_state` 由 `.exited` → 运行态、
子进程 pid 变化（确实重新 fork），再次退出后 `io_state` 回到 `.exited`。
（headless Surface 构造参考 `Surface.initVirtual()` / 现有 Surface 测试。）
