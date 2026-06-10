# 端口转发

*[English](Port-Forwarding) · 中文*

> 运行绑定到已保存 SSH profile 的静默 SSH 隧道。最典型的用途，是让远程开发服务器用上你本机上运行的 HTTP/SOCKS 代理。

WispTerm 维护一份全局的端口转发规则列表。每条规则关联到你的一个已保存 SSH
profile（见 [[SSH 与远程开发|SSH-Remote-Development-zh]]），并启动一个独立的 OpenSSH
辅助进程，转发单个 loopback 端口。这些规则与 [[SSH 与远程开发|SSH-Remote-Development-zh]]
里的*自动* URL 隧道不同 —— 后者按需打开远程 Web 应用，而这些是你自己定义的持久转发。

## 打开管理器

打开命令中心，选择 **端口转发**（"Manage SSH port forwarding rules"）。规则是全局的，
即使关闭管理标签也会继续运行 —— 关闭标签不会停止辅助进程。

列表会显示每条规则的名称、方向、端点和状态。按 **Enter** 启动或停止选中的规则。

## 反向代理隧道

这是常见的代理/VPN 场景：你已经在本机的 `127.0.0.1:7890` 上跑着一个本地代理（Clash、
V2Ray、mihomo……），希望让远程服务器的流量从这里出去。

按 **n** 新增一条规则 —— 默认就是这个形状，名为 **Local proxy**：

```text
Reverse: server 127.0.0.1:7890  ->  local 127.0.0.1:7890
```

选择服务器的 SSH profile，端口保持 `7890`（或与你的代理端口一致），保存。一条反向
（`-R`）转发会让服务器的 loopback `127.0.0.1:7890` 连到你本机上的代理。

然后在服务器上，把标准的代理变量指向该端口：

```sh
export HTTP_PROXY=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890
```

`curl`、`pip`、`apt`、`git` 等大多数工具现在都会经由你的本地代理出网。

## 本地转发

本地（`-L`）转发方向相反：让监听在服务器 loopback 上的服务可以从你本机访问。适用于绑定在
服务器 `127.0.0.1` 上的仪表盘、数据库或 notebook：

```text
Local: local 127.0.0.1:8888  ->  server 127.0.0.1:8888
```

在本地打开 `http://127.0.0.1:8888` 就能访问服务器上的服务。（对于会自己打印网址的远程
Web 应用，WispTerm 已经会自动建立隧道 —— 见 [[SSH 与远程开发|SSH-Remote-Development-zh]]。）

## 规则字段与快捷键

每条规则包含：

- **Profile** —— 由哪个已保存 SSH profile 承载隧道。该 profile 上设置的 `ProxyJump` 会被沿用。
- **方向** —— **reverse**（`-R`，服务器用你的本地端口）或 **local**（`-L`，你用服务器的端口）。
- **本地 / 远程主机与端口** —— 隧道的两端。主机必须是 loopback（见下文）。
- **Enabled** —— 规则是否启用。
- **Auto-start** —— 规则的 profile 连接时自动启动辅助进程。

在管理器中：**n** 新建、**e** 编辑、**d** 删除、**Enter** 启动/停止、**Space** 启用/停用、
**a** 切换自动启动、**r** 重启、**Esc** 关闭。在规则表单中，用 **↑/↓** 或 **Tab** 在字段间
移动，输入即可编辑字段，**Space** 切换方向或自动启动，**Enter** 保存，**Esc** 取消。

## 安全与 SSH 说明

- **仅限 loopback。** 主机必须是 `127.0.0.1` 或 `localhost`；WispTerm 拒绝 `0.0.0.0` 和其它非 loopback 地址，因此规则绝不会把端口暴露给局域网。
- **独立辅助进程。** 每条规则各跑自己的 OpenSSH 进程，且不使用 `ControlMaster`、`ControlPersist` 或 `ControlPath`，因此不会与你 SSH 配置里的连接复用冲突。

---
*另见：[[SSH 与远程开发|SSH-Remote-Development-zh]] · [[浏览器与 Jupyter 面板|Browser-Jupyter-Panel-zh]] · [[配置|Configuration-zh]]*
