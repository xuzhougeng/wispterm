# Agent 终端控制

*[English](Agent-Terminal-Control) · 中文*

> `wisptermctl` 是一个可选开启的本机控制 CLI，供脚本和外部 agent 使用。它可以列出 pane、读取终端文本、发送输入、等待输出，并在运行中的 WispTerm 实例里打开新 tab。

## 启用

把下面配置加入 WispTerm config，然后重启：

```text
agent-control-enabled = true
# agent-control-port = 0   # 可选；0 = 让系统选择一个空闲 loopback 端口
```

WispTerm 会绑定 `127.0.0.1` listener，并在平台配置目录下写入带随机 token 和端口的
`agent-control.json`。`wisptermctl` 会自动读取这个文件；不需要手动传 token 或端口。

## `wisptermctl` 客户端

`wisptermctl` 是单独的二进制。 本地构建：

```sh
zig build wisptermctl
```

### 命令

```sh
wisptermctl panes
wisptermctl get-text -t <surface-id> [--recent N]
wisptermctl send-text -t <surface-id> "<text>"
wisptermctl wait-for -t <surface-id> "<substring>" [--timeout SECONDS]
wisptermctl spawn [--cwd DIR] [-- program args...]
```

Surface id 来自 `wisptermctl panes`。`send-text` 会解码 C 风格转义，例如
`\n`、`\r`、`\t`、`\\` 和 `\xNN`。

### Spawn 示例

`spawn` 会在运行中的实例里打开新 tab，不会新开窗口：

```sh
wisptermctl spawn --cwd "F:\1_Bio-analysis" -- claude -r 1b42b2ea   # the issue's use case
wisptermctl spawn --cwd /home/me/code                              # just a shell in that dir
wisptermctl spawn                                                  # new tab, active tab's cwd
```

省略 `--cwd` 时，新 tab 使用 active tab 的 cwd。省略 `--` 后面的命令时，WispTerm
会启动配置里的默认 shell。

### Pane 自动化示例

```sh
id=$(wisptermctl panes | jq -r '.tabs[0].surfaces[0].id')
wisptermctl send-text -t "$id" "cargo test\n"
wisptermctl wait-for  -t "$id" "test result:" --timeout 120
wisptermctl get-text  -t "$id" --recent 200
```

## 安全

- 除非设置 `agent-control-enabled = true`，否则 API 默认关闭。
- listener 只绑定 loopback（`127.0.0.1`），不会公开到网络。
- 每个请求都必须携带 discovery file 里的 token。

## 限制

- `wait-for` 匹配 literal substring，不是 regex。
- 暂时没有每条命令的 exit-status API。
- 特殊键通过字节转义发送，例如 `\x03` 表示 Ctrl-C。
- 没有 off-machine 模式；这里只支持本机 loopback。
