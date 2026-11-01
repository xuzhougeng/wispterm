# 快速上手

*[English](Getting-Started) · 中文*

> 首次启动、命令中心，以及如何打开 shell、标签和 AI 会话。

## 首次启动

启动 WispTerm 后会得到一个运行默认 shell 的终端。在**首次启动**时，如果你还没有
配置 AI 提供方，WispTerm 会先弹出 AI 设置表单，让你填写提供方、模型、API Key 和
智能体模式，然后再继续。这个提示只出现一次 —— 之后在设置里管理 AI profile（见
[[AI 副驾与智能体|AI-Copilot-zh]]）。

## 命令中心

按 **`Ctrl+Shift+P`** 打开命令中心（命令面板）。输入关键字过滤，然后执行某个动作 ——
例如 `Toggle Browser`、`Copy Remote Key` 或 `Export Copilot Markdown`。几乎所有功能
都能从这里触达，这是了解 WispTerm 能做什么的最快方式。

## 会话与标签

按 **`Ctrl+Shift+T`** 打开会话启动器，从中可以：

- 新建一个 shell 标签，
- 打开 **Copilot**（内置 AI 智能体，见 [[AI 副驾与智能体|AI-Copilot-zh]]），
- 打开 **Sessions** 浏览并恢复 Codex / Claude Code 历史，
- 打开工作台页面：**端口转发**、**记忆中心**或**设置**。

可以把更多终端作为**标签**排在标签栏上，或把一个标签**分屏** —— 分屏与焦点控制见
[[标签、分屏与面板|Tabs-Splits-Panels-zh]]。

## 探查类参数

用下列参数运行 WispTerm 以查看你的环境：

```bash
wispterm --list-fonts          # 可用的系统字体
wispterm --list-themes         # 内置主题
wispterm --show-config-path    # 解析出的主配置路径
wispterm --help                # 所有命令行选项
```

## 下一步

- 整理你的工作区 → [[标签、分屏与面板|Tabs-Splits-Panels-zh]]
- 自定义外观与行为 → [[配置|Configuration-zh]] 和 [[主题与外观|Themes-Appearance-zh]]
- 让 AI 副驾干活 → [[AI 副驾与智能体|AI-Copilot-zh]]

---
*另见：[[安装|Installation-zh]] · [[标签、分屏与面板|Tabs-Splits-Panels-zh]] · [[AI 副驾与智能体|AI-Copilot-zh]]*
