# SSH 与远程开发

*[English](SSH-Remote-Development) · 中文*

> 发起 SSH profile 会话，解锁远程预览、下载、按工作目录上传以及端口转发。

## 发起 SSH 会话

打开会话启动器（`Ctrl+Shift+T`），从 WispTerm 内置的 **SSH 启动器**发起 SSH 会话。
这样发起会为会话附上 profile 元数据，正是它解锁了远程文件预览、远程下载、工作目录探测，
以及下文所述的自动端口转发。在本地 shell 里敲 `ssh user@host` **得不到**这些功能 ——
见 [[文件浏览器与预览|File-Explorer-zh]]。

## 认证方式

在会话启动器里保存或编辑 SSH profile 时，**认证方式**字段决定它如何认证 —— 可设为
`password`、`key` 或 `credentials`：

- `password` —— 把密码随 profile 一起保存（此前的行为）。
- `key` —— 用私钥认证。在**密钥文件**字段填入私钥路径，WispTerm 会以 `ssh -i <路径>`
  传入。
- `credentials` —— 什么都不保存，交给你已有的 SSH 配置来认证：OpenSSH 配置
  （`~/.ssh/config`）、默认密钥、`ssh-agent`，或平台凭据助手。

已有的密码 profile 保持不变；通过 **Load OpenSSH Config** 导入的 profile 默认使用
`credentials`，从而复用你的密钥和 agent。Copilot 的 `ssh_profile_save` 工具也接受同样的
`auth_method` 和 `identity_file` 选项。

## 用 tmux 保持会话不掉（`tmux -CC`）

如果远程主机装了 `tmux`，可以通过 tmux 控制模式连接，让会话在**关闭 App 或网络掉线后依然存活**。
打开会话启动器（`Ctrl+Shift+T`），选择 **Connect with tmux (keep alive)**，再选用与普通 SSH
会话相同的 SSH profile —— 无需在 profile 里单独设置，同一台服务器仍可作为普通 SSH 会话打开。

WispTerm 本身就是 tmux 客户端，所以看不到 tmux 状态栏或前缀键：远程 tmux 的**窗口变成标签页**、
**窗格变成原生分屏**。分屏、关闭窗格、新建标签都会驱动服务器上的 tmux，且每个窗格各自保留自己的
工作目录、文件预览和 agent 状态圆点。

由于会话存活在服务器上，你可以退出 WispTerm（或断网），之后通过同一个 tmux 入口**重新连接**，
回到离开时的状态。只有服务器需要装 tmux —— 本地无需任何安装。

## 上报工作目录（OSC 7）

SSH profile 会话中的拖拽上传，会在 shell 用 OSC 7 上报时使用当前远程工作目录（与
Ghostty shell 集成相同的约定）。如果远程 shell 不发 OSC 7，WispTerm 会回退到用一个新的
`ssh.exe` 辅助进程运行 `pwd`，而它通常返回登录目录而非你 `cd` 进去的目录 —— 此时会显示
一个可点击的设置提示。

把下面其中一段加入远程 shell 的启动文件，然后开一个新的 WispTerm SSH 会话。

**Bash**（`~/.bashrc`）：

```bash
__wispterm_report_cwd() {
  printf '\033]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$PWD"
}
PROMPT_COMMAND="__wispterm_report_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
```

**Zsh**（`~/.zshrc`）：

```zsh
__wispterm_report_cwd() {
  printf '\033]7;file://%s%s\a' "${HOST:-localhost}" "$PWD"
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd __wispterm_report_cwd
add-zsh-hook precmd __wispterm_report_cwd
```

**Fish**（`~/.config/fish/config.fish`）：

```fish
function __wispterm_report_cwd --on-variable PWD
    printf '\e]7;file://%s%s\a' (hostname) (string escape --style=url $PWD)
end
__wispterm_report_cwd
```

## 老旧 SSH 服务

对于仍需启用已弃用 OpenSSH 算法的老旧堡垒机或服务器，设置：

```text
ssh-legacy-algorithms = true
```

这会为 WispTerm 的 SSH profile 启动以及辅助 `ssh.exe` / `scp.exe` 命令追加 `ssh-rsa`、
`ssh-dss`、较老的 Diffie-Hellman KEX 和 CBC 加密的兼容选项。

## 通过 SSH 访问 Web 应用（端口转发）

当远程 Web 应用打印 loopback 网址（如 `http://127.0.0.1:4232` 或
`http://localhost:43455`）时，WispTerm 会通过自动建立的本地 SSH 隧道打开它。`Ctrl`/`Cmd`
点击网址即可打开。这些隧道由内嵌浏览器面板和系统浏览器共享，因此设置
`url-open-mode = system-browser` 就能让远程应用在你常用的浏览器中打开。每个远程端口各自
保留一条转发；WispTerm 优先使用相同的本地端口，仅在该端口已被占用时才递增。非 loopback
网址（如 `https://10.10.x.x` 或公网站点）直接打开。面板本身见
[[浏览器与 Jupyter 面板|Browser-Jupyter-Panel-zh]]。对于你自己配置的隧道 —— 比如把本地
代理共享给服务器 —— 见 [[端口转发与代理|Port-Forwarding-zh]]。

---
*另见：[[端口转发与代理|Port-Forwarding-zh]] · [[文件浏览器与预览|File-Explorer-zh]] · [[浏览器与 Jupyter 面板|Browser-Jupyter-Panel-zh]] · [[配置|Configuration-zh]]*
