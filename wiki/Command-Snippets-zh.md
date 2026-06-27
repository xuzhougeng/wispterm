# 命令片段（Command Snippets）

*[English](Command-Snippets) · 中文*

> 把常用命令定义一次，就能从命令中心一键发送到任意会话——本地 shell、WSL、
> PowerShell 或 SSH。

## 什么是命令片段

命令片段是一段带名字的文本，从命令中心（`Ctrl+Shift+P`，macOS 上是
`Cmd+Shift+P`）触发。选中它时，WispTerm 会把文本发送到**当前活动会话**，无论它
是什么。这是 WispTerm 对 WindTerm、SecureCRT 等工具按钮栏的回应：把固定命令放在
终端里，而不必在每台 SSH 登录的机器上维护同一套 shell 别名。

## 片段放在哪里

每个片段是一个 Markdown 文件，放在配置文件旁边的 `snippets/` 目录中
（参见 [[配置|Configuration-zh]]）：

- **Windows：** `%APPDATA%\wispterm\snippets\`
- **macOS：** `~/Library/Application Support/wispterm/snippets/`
- **Linux：** `$XDG_CONFIG_HOME/wispterm/snippets/`（回退：`~/.config/wispterm/snippets/`）

目录不存在就新建一个。文件名无所谓——`deploy.md`、`gs.md`，只要以 `.md` 结尾。

## 文件格式

front matter 设置标题，正文是要发送的文本：

```markdown
---
name: deploy
description: build and ship to production
---
make deploy
```

- `name` —— 必填。显示在命令中心，也是过滤时输入的关键词。
- `description` —— 可选。过滤时同样会被匹配。
- **正文** —— 闭合的 `---` 之后的全部内容，原封不动逐字节发送到会话。

### 立即执行还是仅插入

正文按原样发送，所以结尾的换行就是开关：

- **以换行结尾** → 选中即立即执行（上面的例子）。多数编辑器保存时会自动补一个
  结尾换行，所以这是默认行为。
- **结尾无换行** → 文本只被插入到提示符，方便你先检查或修改，再自己按回车。

每次打开命令中心都会重新读取片段，所以编辑后无需重启 WispTerm 即可生效。

## 触发一个片段

1. 先聚焦你想让命令落入的会话（终端标签或 SSH 面板）。
2. 用 `Ctrl+Shift+P`（macOS 上 `Cmd+Shift+P`）打开命令中心。
3. 输入片段 `name` 或 `description` 的一部分来过滤；片段行右侧带有 `send` 标记。
4. 按回车或点击该行，把它发送到当前活动会话。

## 让 Copilot 帮你创建

你完全可以不碰编辑器。[[AI 副驾|AI-Copilot-zh]] 自带 `write_file` 工具，直接描述
需求即可：

> 帮我建一个 WispTerm 命令片段，名字叫 `gs`，运行 `git status`。片段放在
> `~/Library/Application Support/wispterm/snippets/`，是一个带 `name:` front
> matter 的 Markdown 文件，命令写在正文里、以换行结尾，这样选中就会执行。

Copilot 会把 `.md` 文件写好；重新打开命令中心，片段就能用了。
