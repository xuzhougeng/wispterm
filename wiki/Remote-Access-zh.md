# 远程访问（共享会话）

*[English](Remote-Access) · 中文*

> 可选地通过 Cloudflare relay 把 WispTerm 会话共享到浏览器。默认关闭。

## 它是什么

远程访问让你通过 Cloudflare relay 从浏览器（例如手机）查看并操作正在运行的 WispTerm
会话。这是一个**需主动开启**的功能，且**默认关闭** —— 在你启用之前，没有任何数据离开
你的机器。

启用后，WispTerm 为运行中的实例创建一个共享出站 RemoteClient。所有标签和分屏都通过该
client 发布各自的 PTY 输出。

## 启用方式

在 [[配置|Configuration-zh]] 中设置这些键：

```text
remote-enabled = true
remote-server-url = https://remote.example.com
remote-server-fingerprint = sha256:...     # 可选：固定 relay 身份
remote-device-name = Workstation           # 可选：友好名称
```

- `remote-enabled` —— 启动 RemoteClient。
- `remote-server-url` —— Cloudflare relay 地址。
- `remote-server-fingerprint` —— 用于身份固定的预期 relay 指纹。
- `remote-device-name` —— 随配对发送的友好设备名。

## 会话密钥

默认每个进程的会话密钥都是随机的。生成的密钥会打印在调试控制台中，并显示在窗口内的远程
状态药丸里。**点击状态药丸即可复制**当前会话密钥，或从命令中心运行 **Copy Remote Key**。

设置 `remote-session-key = mypass` 可在多个并发本地实例间使用可预测的密钥：第一个进程得到
`mypass`，下一个 `mypass_1`，再下一个 `mypass_2`，依此类推。这只决定浏览器要输入的 relay
会话密钥 —— 它与 relay 自身的 Web 管理登录密码是分开的。

## 手机镜像

WispTerm Remote **镜像本地窗口**，因为桌面应用是状态的唯一真相来源：本地 PTY、VT 状态、
回滚、光标和分屏布局都在那里捕获，再以流的方式发送到浏览器。移动端 UI 可以聚焦单个画面，
而不是把所有分屏都挤进小屏，但它不会创建一个独立的、手机尺寸的终端网格（见
[[常见问题|FAQ-zh]]）。

## 微信直连

除了上面的中继，WispTerm 还能从微信驱动。从命令中心运行 **Connect WeChat** 并扫码绑定
账号；之后 WispTerm 会轮询微信收到的消息，转交给绑定的
[[Copilot 会话|AI-Copilot-zh]]，并把回复发回微信。其余命令中心条目用于管理绑定：
**WeChat: Start** 与 **WeChat: Stop** 在不丢失绑定的前提下暂停/恢复轮询，
**WeChat: Status** 显示连接状态，**WeChat: Unbind** 清除已保存的绑定。

---
*另见：[[配置|Configuration-zh]] · [[AI 副驾与智能体|AI-Copilot-zh]] · [[常见问题|FAQ-zh]]*
